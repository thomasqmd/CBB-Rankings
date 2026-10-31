# ==============================================================================
# Variant backtest (Phase 2-3 tuning). Each variant refits a fixed subset of the pipeline's
# snapshots for 2015-16 to 2025-26 (opening night and every third Monday, ~8 a season) with
# 4 x 500 draws and predicts the games of the following week (until the pipeline's next snapshot),
# so every variant is scored on the same games. Inputs come from the targets store.
#
#   Rscript pilot/12_variants.R base eff100 ...     (results: pilot/out/variants/<name>.rds)
#   Rscript pilot/12_variants.R summary [ref]       (each variant vs ref, default base, on the games both predicted)
# ==============================================================================

suppressMessages({ library(targets); library(dplyr) })
tar_source("R")
OUT <- "pilot/out/variants"
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)
SEASONS <- 2016:2026
WORKERS <- 4

BASE_CFG <- list(hca_prior = c(4, 2), hca_prior_season = NULL, use_prev2 = FALSE, margin_family = 1L)
# The defaults adopted 2026-10-24 (model_config()); the 2026-10-30 variants are scored against these.
# The targets store's priors are the roster prior with prev2 since the 2026-10-25 rebuild, so
# rerunning `base` now would not reproduce the Phase 1 base.
CUR_CFG <- list(hca_prior = c(4.5, 0.4), hca_prior_season = list("2021" = c(3, 0.5)), use_prev2 = TRUE, margin_family = 2L)

# Closing lines of the games played before the snapshot, per 100 regulation possessions (lines variant)
add_lines <- function(inp) {
  g <- inp$games
  k <- which(!is.na(g$spread))
  poss <- dplyr::coalesce(g$poss_reg, g$poss, 70)[k]
  inp$stan$N_line <- length(k); inp$stan$line_game <- k; inp$stan$line100 <- -100 * g$spread[k] / poss
  inp
}
gt_games <- function(s, rules, ift = NULL) list(gt = rules, ift = ift)
VARIANTS <- list(
  base        = list(),
  eff100      = list(cfg = list(eff_col = "eff100")),
  margin_only = list(cfg = list(use_eff = FALSE)),
  static      = list(cfg = list(dynamic = FALSE)),
  hca_pooled  = list(cfg = function(s) list(hca_prior = if (s == 2021) c(3, 0.5) else c(4.5, 0.4))),
  team_hca    = list(cfg = list(team_hca = TRUE)),
  ot50        = list(cfg = list(ot_weight = 0.5)),
  ot100       = list(cfg = list(ot_weight = 1)),
  prev2       = list(cfg = list(use_prev2 = TRUE), prev2 = TRUE),
  normal      = list(cfg = list(margin_family = 2L)),
  mixture     = list(cfg = list(margin_family = 3L)),
  gt_none     = list(signals = list(gt = list(), ift = NULL)),
  gt_tight    = list(signals = list(gt = list(c(secs_left = 600, lead = 25), c(secs_left = 300, lead = 20)), ift = NULL)),
  gt_loose    = list(signals = list(gt = list(c(secs_left = 720, lead = 16), c(secs_left = 360, lead = 12)), ift = NULL)),
  ift         = list(signals = list(gt = GT_RULES, ift = c(secs_left = 60, lead = 8))),
  roster      = list(prior = "pilot/out/roster_priors.rds"),       # pilot/13_roster_prior.R
  # 2026-10-30, against `current`
  current     = list(cfg = CUR_CFG),
  lines       = list(cfg = CUR_CFG, stan = "pilot/stan/power_lines.stan", extra = add_lines),
  midweek     = list(cfg = CUR_CFG, shift = 3)                     # Thursday snapshots: predict Thu-Sun from 3 more days of games
)

snap_subset <- function(d) {
  keep <- d$kind == "preseason" | (seq_len(nrow(d)) %% 3 == 2 & d$kind %in% c("weekly", "selection"))
  d[keep & !is.na(d$next_date), ]
}

# Games with the efficiency signal rebuilt under other garbage-time / intentional-foul rules (cached)
signal_games <- function(s, name, sig) {
  f <- file.path(OUT, sprintf("games_%s_%d.rds", name, s))
  if (file.exists(f)) return(readRDS(f))
  d <- tar_read_raw(paste0("data_", s))
  p <- annotate_plays(read_plays(s), gt_rules = sig$gt, ift_rule = sig$ift)
  p <- p[p$game_id %in% d$games$game_id, ]
  d$shots <- shot_table(p); d$free_throws <- ft_table(p); d$game_live <- live_table(p)
  rm(p); gc()
  g <- season_games(d, tar_read_raw(paste0("shotmodel_", s)), tar_read_raw(paste0("data_", s - 1))$free_throws)
  saveRDS(g, f)
  g
}

final_ratings <- function(s) {
  r <- tar_read(snapshots)$ratings
  r <- r[r$season == s & r$kind == "final", ]
  data.frame(team_id = r$team_id, prev2_dev = r$rating)
}

run_variant <- function(name) {
  v <- VARIANTS[[name]]
  src <- if (is.null(v$stan)) "stan/power.stan" else v$stan
  stan <- file.path(OUT, basename(src))
  file.copy(src, stan, overwrite = TRUE)
  cmdstanr::cmdstan_model(stan, quiet = TRUE)
  tasks <- list()
  for (s in SEASONS) {
    g <- if (is.null(v$signals)) tar_read_raw(paste0("games_", s)) else signal_games(s, name, v$signals)
    tm <- tar_read_raw(paste0("teams_", s)); pr <- tar_read_raw(paste0("prior_", s))
    if (isTRUE(v$prev2)) pr <- dplyr::left_join(pr, final_ratings(s - 2), by = "team_id")
    if (!is.null(v$prior)) pr <- readRDS(v$prior)[[as.character(s)]]
    d <- snap_subset(tar_read_raw(paste0("dates_", s)))
    if (!is.null(v$shift)) d$snap_date <- d$snap_date + v$shift
    extra <- if (is.function(v$cfg)) v$cfg(s) else v$cfg
    # the defaults the 2026-10-24 runs used (model_config() has since moved to the adopted ones)
    cfg <- do.call(model_config, utils::modifyList(c(list(stan_file = stan, warmup = 500, sampling = 500), BASE_CFG), if (is.null(extra)) list() else extra))
    res_s <- g[g$division %in% "d1", c("game_id", "played", "home_score", "away_score", "spread", "total_line")]
    for (i in seq_len(nrow(d))) {
      inp <- snapshot_input(g, d[i, ], tm, pr, cfg)
      if (!is.null(v$extra)) inp <- v$extra(inp)
      tasks[[length(tasks) + 1]] <- list(s = s, inp = inp, cfg = cfg, kind = d$kind[i], res = res_s)
    }
  }
  message(name, ": ", length(tasks), " fits")
  res <- parallel::mclapply(tasks, function(t) {
    fit <- fit_snapshot(t$inp, t$cfg)
    pr <- if (nrow(t$inp$upcoming)) predict_games(fit, t$inp, t$inp$upcoming)
    if (!is.null(pr)) pr <- dplyr::left_join(pr[, setdiff(names(pr), names(t$res)[-1])], t$res, by = "game_id")   # upcoming carries schedule columns only
    list(pred = if (!is.null(pr)) data.frame(season = t$s, snap_date = t$inp$snap_date, kind = t$kind,
                                             pr[, c("game_id", "game_date", "home_id", "away_id", "site", "played", "home_score", "away_score",
                                                    "spread", "total_line", "pred_margin", "pred_poss", "p_home")]),
         gates = data.frame(season = t$s, snap_date = t$inp$snap_date, t(fit$gates), secs = fit$secs),
         par = data.frame(season = t$s, snap_date = t$inp$snap_date, t(colMeans(fit$par))))
  }, mc.cores = WORKERS, mc.preschedule = FALSE)
  bad <- vapply(res, inherits, logical(1), "try-error")
  if (any(bad)) warning(sum(bad), " fits failed: ", paste(unique(unlist(res[bad])), collapse = "; "))
  res <- res[!bad]
  out <- list(name = name, pred = bind_rows(lapply(res, `[[`, "pred")), gates = bind_rows(lapply(res, `[[`, "gates")),
              par = bind_rows(lapply(res, `[[`, "par")))
  saveRDS(out, file.path(OUT, paste0(name, ".rds")))
  invisible(out)
}

score_variant <- function(x, games = NULL) {
  p <- x$pred[x$pred$played %in% TRUE, ]
  if (!is.null(games)) p <- p[paste(p$season, p$game_id) %in% games, ]
  p$actual <- p$home_score - p$away_score
  p$win <- as.integer(p$actual > 0)
  p$period <- ifelse(as.integer(format(p$game_date, "%m")) %in% c(11, 12), "Nov-Dec", "Jan-Apr")
  p
}

# Normal CRPS; the predictive sd per game is the one implied by p_home and pred_margin
crps_norm <- function(y, mu, s) { z <- (y - mu) / s; s * (z * (2 * stats::pnorm(z) - 1) + 2 * stats::dnorm(z) - 1 / sqrt(pi)) }
implied_sd <- function(m, p) { s <- abs(m / stats::qnorm(pmin(pmax(p, 1e-6), 1 - 1e-6))); ifelse(abs(m) > 2 & is.finite(s), s, 11) }

summarise_variants <- function(ref = "base") {
  files <- Sys.glob(file.path(OUT, "*.rds"))
  files <- files[!grepl("/(games_|summary_)", files)]
  xs <- lapply(files, readRDS)
  names(xs) <- vapply(xs, `[[`, character(1), "name")
  ll <- function(p, y) -(y * log(p) + (1 - y) * log(1 - p))
  r0 <- score_variant(xs[[ref]])
  rows <- lapply(names(xs), function(n) {
    p <- score_variant(xs[[n]])
    key <- intersect(paste(p$season, p$game_id), paste(r0$season, r0$game_id))
    p <- p[match(key, paste(p$season, p$game_id)), ]; b <- r0[match(key, paste(r0$season, r0$game_id)), ]
    d_ae <- abs(p$actual - p$pred_margin) - abs(b$actual - b$pred_margin)
    d_ll <- ll(p$p_home, p$win) - ll(b$p_home, b$win)
    d_br <- (p$p_home - p$win)^2 - (b$p_home - b$win)^2
    d_cr <- crps_norm(p$actual, p$pred_margin, implied_sd(p$pred_margin, p$p_home)) - crps_norm(b$actual, b$pred_margin, implied_sd(b$pred_margin, b$p_home))
    nd <- p$period == "Nov-Dec"
    g <- xs[[n]]$gates
    data.frame(variant = n, games = nrow(p), mae = mean(abs(p$actual - p$pred_margin)),
               d_mae = mean(d_ae), se = stats::sd(d_ae) / sqrt(nrow(p)),
               d_mae_novdec = mean(d_ae[nd]), d_mae_janapr = mean(d_ae[!nd]),
               logloss = mean(ll(p$p_home, p$win)), d_logloss = mean(d_ll), d_brier = mean(d_br), d_crps = mean(d_cr),
               gates_pass = mean(g$max_rhat <= 1.01 & g$min_ess >= 200 & g$divergences == 0), secs = mean(g$secs))
  })
  bind_rows(rows) |> arrange(d_mae)
}

args <- commandArgs(trailingOnly = TRUE)
if (identical(args[1], "summary")) {
  ref <- if (length(args) > 1) args[2] else "base"
  tab <- summarise_variants(ref)
  print(tab, digits = 4)
  saveRDS(tab, file.path(OUT, if (ref == "base") "summary_table.rds" else paste0("summary_", ref, ".rds")))
} else {
  for (a in args) run_variant(a)
}
