# ==============================================================================
# check_build.R — post-build checks. `Rscript check_build.R` exits non-zero on any FAIL;
# WARNs are worth a look but don't block. Can also be source()d interactively.
# ==============================================================================

suppressMessages(library(targets))
source("R/01_ingest.R"); source("R/03_model.R")
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
  low <- cov$season > min(cov$season) & cov$prior_torvik < 0.95 * cov$d1_teams   # the carry-over season uses no Torvik prior
  if (any(low)) say("WARN", "Torvik preseason matched < 95% of teams in ", paste(cov$season[low], collapse = ", "), " (add rows to data/torvik_names.csv)")
}

# D1 membership and venues
if (!is.null(cov) && !is.null(cov$ineligible)) {
  say("INFO", "teams not yet NCAA-tournament eligible: ", paste(sprintf("%d: %d", cov$season, cov$ineligible), collapse = ", "))
  if (any(cov$conf_differs > 0)) say("WARN", "CBBD games and ESPN's membership disagree on a conference in ", paste(cov$season[cov$conf_differs > 0], collapse = ", "))
  say("INFO", "venues recoded to a team's floor: ", sum(cov$site_recoded, na.rm = TRUE), " games; ESPN and CBBD neutral flags disagree on ",
      sum(cov$neutral_disagree), " (tar_read(venues))")
}

# Every completed D1 game CBBD has is in the games table, and the player tables are filled
con <- DBI::dbConnect(duckdb::duckdb(dbdir = "data/cbb.duckdb", read_only = TRUE, shared_home = FALSE))
tabs <- DBI::dbListTables(con)
seasons <- DBI::dbGetQuery(con, "SELECT DISTINCT season FROM games ORDER BY season")$season
miss <- vapply(seasons, function(s) {
  cb <- cbbd_games(s)
  have <- DBI::dbGetQuery(con, sprintf("SELECT game_id FROM games WHERE season = %d", s))$game_id
  sum(cb$cbbd_status %in% "final" & !is.na(cb$home_conf) & !is.na(cb$away_conf) & !cb$game_id %in% have)
}, integer(1))
say(if (any(miss > 0)) "WARN" else "OK", "completed D1 games in CBBD missing from the games table: ",
    if (any(miss > 0)) paste(sprintf("%d: %d", seasons[miss > 0], miss[miss > 0]), collapse = ", ") else "none")
for (t in c("player_box", "rosters", "substitutions")) {
  if (!t %in% tabs) { say("WARN", "no ", t, " table"); next }
  n <- DBI::dbGetQuery(con, sprintf("SELECT season, COUNT(*) n FROM %s GROUP BY season ORDER BY season", t))
  say("INFO", t, " rows: ", paste(sprintf("%d: %s", n$season, format(n$n, big.mark = ",", trim = TRUE)), collapse = ", "))
}
inj <- sort(Sys.glob(file.path("data", "raw", "espn", "injuries", "injuries_*.json")))
if (!season_final(current_cbb_season())) {
  last <- if (length(inj)) as.Date(sub(".*_([0-9]{8})\\.json$", "\\1", utils::tail(inj, 1)), "%Y%m%d") else as.Date(NA)
  if (is.na(last) || Sys.Date() - last > 1) say("WARN", "injury report last archived ", format(last), " (scripts/poll_injuries.sh)")
  if ("injuries" %in% tabs) say("INFO", sprintf("injury reports: %d days archived, %d player rows", length(inj),
                                                DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM injuries")$n))
}
DBI::dbDisconnect(con, shutdown = TRUE)

# Backtest vs the closing line
bt <- tryCatch(tar_read(backtest), error = \(e) NULL)
if (!is.null(bt) && nrow(bt$overall) && bt$overall$games > 0) {
  o <- bt$overall
  say("INFO", sprintf("backtest: %d games, MAE %.2f (line %.2f on %d lined games), log loss %.4f, ATS %.1f%%",
                      o$games, o$mae, o$mae_line, o$with_line, o$logloss, 100 * o$ats))
  if (o$mae_on_lined - o$mae_line > 0.25) say("WARN", "model MAE more than 0.25 pts worse than the closing line")
  v <- bt$vs_overall
  if (!is.null(v) && nrow(v) && v$games > 0) {
    say("INFO", sprintf("vs Torvik (%d games with both and a line): MAE %.3f / Torvik %.3f / line %.3f, log loss %.4f / Torvik %.4f",
                        v$games, v$mae, v$mae_torvik, v$mae_line, v$logloss, v$logloss_torvik))
    if (v$mae > v$mae_torvik) say("WARN", "model MAE worse than Torvik's")
  }
  l <- bt$vs_line
  if (!is.null(l) && nrow(l) && l$games > 0) {
    say("INFO", sprintf("vs the line (%d games): MAE %.3f / %.3f, Brier %.4f / %.4f, log loss %.4f / %.4f, CRPS %.3f / %.3f; 80%% interval coverage %.1f%%",
                        l$games, l$mae, l$mae_line, l$brier, l$brier_line, l$logloss, l$logloss_line, l$crps, l$crps_line, 100 * o$cov80))
    if (abs(o$cov80 - 0.8) > 0.03) say("WARN", "80% predictive intervals off nominal by more than 3 pp")
    e <- bt$ats_edge
    if (!is.null(e)) say("INFO", paste0("ATS by |model - line|: ", paste(sprintf("%s %s %.1f%% (%d)", e$period, e$edge, 100 * e$ats, e$games), collapse = ", ")))
  }
  if (!is.null(o$mae_total) && is.finite(o$mae_total_on_lined)) {
    say("INFO", sprintf("totals: MAE %.2f (closing total %.2f on the same games)", o$mae_total_on_lined, o$mae_total_line))
    if (o$mae_total_on_lined - o$mae_total_line > 0.5) say("WARN", "total MAE more than 0.5 pts worse than the closing total")
  }
}

# Shot model calibration (out of sample): a family off by more than 2 pp
sc <- tryCatch(tar_read(shot_calibration), error = \(e) NULL)
if (!is.null(sc) && nrow(sc)) {
  off <- sc[abs(sc$diff) > 0.02 & sc$shots >= 2000, ]
  say(if (nrow(off)) "WARN" else "OK", "shot model within 2 pp of the actual make rate by family and season",
      if (nrow(off)) paste0(" except ", paste(sprintf("%d %s %+.1f", off$season, off$family, 100 * off$diff), collapse = ", ")) else "")
}

# Preseason priors: how many teams had our rating, Torvik's, and the roster regression
if (!is.null(snaps)) {
  src <- lapply(sort(unique(snaps$ratings$season)), function(s) {
    a <- tryCatch(attr(tar_read_raw(paste0("prior_", s)), "sources"), error = \(e) NULL)
    if (!is.null(a)) sprintf("%d: %s", s, paste(names(a), a, collapse = " "))
  })
  src <- unlist(src)
  if (length(src)) say("INFO", "prior sources (teams): ", paste(src, collapse = "; "))
}

# Resume odds: per snapshot with a season simulation, P(field) sums to the field size and
# P(auto bid) to the number of conferences
if (!is.null(snaps) && !is.null(snaps$resume$p_field)) {
  rs <- snaps$resume[!is.na(snaps$resume$p_field), ]
  tot <- stats::aggregate(cbind(p_field, p_auto) ~ season + snap_date, rs, sum)
  tot$field <- vapply(tot$season, field_size, integer(1))
  bad <- abs(tot$p_field - tot$field) > 0.5
  say(if (any(bad)) "FAIL" else "OK", sprintf("P(field) sums to the field size in %d of %d snapshots", sum(!bad), nrow(tot)))
  if (any(bad)) print(utils::head(tot[bad, ], 10), row.names = FALSE)
  say("INFO", sprintf("P(auto bid) per snapshot sums to %.1f-%.1f", min(tot$p_auto), max(tot$p_auto)))
  if (any(rs$p_field < -1e-9 | rs$p_field > 1 + 1e-9)) say("FAIL", "P(field) outside [0, 1]")
}

# Dashboard rendered after the latest snapshot
if (!is.null(snaps) && file.exists("docs/index.html")) {
  age <- difftime(file.mtime("docs/index.html"), max(tar_meta(fields = time)$time, na.rm = TRUE), units = "mins")
  say(if (age < -1) "WARN" else "OK", "docs/index.html ", if (age < -1) "is older than the last built target" else "is current")
}

if (fails > 0 && !interactive()) quit(status = 1)
