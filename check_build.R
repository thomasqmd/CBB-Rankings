# ==============================================================================
# check_build.R — post-build checks. `Rscript check_build.R` exits non-zero on any FAIL;
# WARNs are worth a look but don't block. Can also be source()d interactively.
# ==============================================================================

suppressMessages(library(targets))
source("R/01_ingest.R")
fails <- 0L
say <- function(level, ...) {
  cat(sprintf("[%s] %s\n", level, paste0(...)))
  if (level == "FAIL") fails <<- fails + 1L
}

# Errored targets
meta <- tar_meta(fields = c(name, error), complete_only = FALSE)
err <- meta[!is.na(meta$error), ]
if (nrow(err)) for (i in seq_len(nrow(err))) say("FAIL", "target ", err$name[i], ": ", err$error[i]) else say("OK", "no errored targets")

snaps <- tryCatch(tar_read(snapshots), error = \(e) NULL)
if (is.null(snaps)) {
  say("FAIL", "no snapshots target yet")
} else {
  # Convergence gates on every snapshot; the live season's latest must pass
  g <- snaps$gates
  say(if (all(g$pass)) "OK" else "WARN", sprintf("gates: %d of %d snapshots pass (R-hat <= 1.01, ESS >= 400, no divergences, E-BFMI > 0.2)", sum(g$pass), nrow(g)))
  if (any(!g$pass)) print(utils::head(g[!g$pass, c("season", "snap_date", "kind", "max_rhat", "min_ess", "divergences", "worst")], 20), row.names = FALSE)
  live <- g[g$season == current_cbb_season(), ]
  if (nrow(live)) {
    last <- live[which.max(live$snap_date), ]
    say(if (last$pass) "OK" else "FAIL", sprintf("live snapshot %s (%s) %s the gates", format(last$snap_date), last$kind, if (last$pass) "passes" else "fails"))
    stale <- as.numeric(Sys.Date() - last$snap_date)
    if (stale > 2 && !season_final(current_cbb_season())) say("WARN", "live snapshot is ", stale, " days old")
  }

  # Ratings sanity per snapshot: team count and D1 mean
  r <- snaps$ratings
  per <- stats::aggregate(rating ~ season + snap_date, r, \(x) c(n = length(x), mean = mean(x)))
  bad <- abs(per$rating[, "mean"]) > 1e-6
  say(if (any(bad)) "FAIL" else "OK", "ratings centred on the D1 mean in every snapshot")
  say("INFO", "teams per season: ", paste(unique(sprintf("%d: %d", per$season, per$rating[, "n"])), collapse = ", "))
}

# Coverage
cov <- tryCatch(tar_read(coverage), error = \(e) NULL)
if (!is.null(cov)) {
  print(cov, row.names = FALSE, digits = 3)
  played <- cov$d1_played > 0
  if (any(cov$eff_share[played] < 0.8)) say("WARN", "efficiency signal below 80% of games in ", paste(cov$season[played & cov$eff_share < 0.8], collapse = ", "))
  if (any(cov$line_share[played] < 0.7)) say("WARN", "closing lines below 70% of games in ", paste(cov$season[played & cov$line_share < 0.7], collapse = ", "))
  if (any(cov$prior_torvik < 0.95 * cov$d1_teams)) say("WARN", "Torvik preseason matched < 95% of teams in ", paste(cov$season[cov$prior_torvik < 0.95 * cov$d1_teams], collapse = ", "), " (add rows to data/torvik_names.csv)")
}

# Backtest vs the closing line
bt <- tryCatch(tar_read(backtest), error = \(e) NULL)
if (!is.null(bt) && nrow(bt$overall) && bt$overall$games > 0) {
  o <- bt$overall
  say("INFO", sprintf("backtest: %d games, MAE %.2f (line %.2f on %d lined games), log loss %.4f, ATS %.1f%%",
                      o$games, o$mae, o$mae_line, o$with_line, o$logloss, 100 * o$ats))
  if (o$mae_on_lined - o$mae_line > 0.25) say("WARN", "model MAE more than 0.25 pts worse than the closing line")
}

if (fails > 0 && !interactive()) quit(status = 1)
