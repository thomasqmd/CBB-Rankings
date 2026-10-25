# ==============================================================================
# Variant backtest (Phase 2-3 tuning). Each variant refits a fixed subset of the pipeline's
# snapshots for 2015-16 to 2025-26 (opening night and every third Monday, ~8 a season) with
# 4 x 500 draws and predicts the games of the following week (until the pipeline's next snapshot),
# so every variant is scored on the same games. Inputs come from the targets store.
#
#   Rscript pilot/12_variants.R base eff100 ...     (results: pilot/out/variants/<name>.rds)
#   Rscript pilot/12_variants.R summary             (-> pilot/out/12_variants.md)
# ==============================================================================

suppressMessages({ library(targets); library(dplyr) })
tar_source("R")
OUT <- "pilot/out/variants"
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)
SEASONS <- 2016:2026
WORKERS <- 4

BASE_CFG <- list(hca_prior = c(4, 2), hca_prior_season = NULL, use_prev2 = FALSE, margin_family = 1L)
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
  roster      = list(prior = "pilot/out/roster_priors.rds")        # pilot/13_roster_prior.R
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
  stan <- file.path(OUT, "power.stan")
  file.copy("stan/power.stan", stan, overwrite = TRUE)
  cmdstanr::cmdstan_model(stan, quiet = TRUE)
  tasks <- list()
  for (s in SEASONS) {
    g <- if (is.null(v$signals)) tar_read_raw(paste0("games_", s)) else signal_games(s, name, v$signals)
    tm <- tar_read_raw(paste0("teams_", s)); pr <- tar_read_raw(paste0("prior_", s))
    if (isTRUE(v$prev2)) pr <- dplyr::left_join(pr, final_ratings(s - 2), by = "team_id")
    if (!is.null(v$prior)) pr <- readRDS(v$prior)[[as.character(s)]]
    d <- snap_subset(tar_read_raw(paste0("dates_", s)))
    extra <- if (is.function(v$cfg)) v$cfg(s) else v$cfg
    # the defaults the 2026-10-24 runs used (model_config() has since moved to the adopted ones)
    cfg <- do.call(model_config, utils::modifyList(c(list(stan_file = stan, warmup = 500, sampling = 500), BASE_CFG), if (is.null(extra)) list() else extra))
    res_s <- g[g$division %in% "d1", c("game_id", "played", "home_score", "away_score", "spread", "total_line")]
    for (i in seq_len(nrow(d))) tasks[[length(tasks) + 1]] <- list(s = s, inp = snapshot_input(g, d[i, ], tm, pr, cfg), cfg = cfg,
                                                                   kind = d$kind[i], res = res_s)
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

summarise_variants <- function() {
  files <- Sys.glob(file.path(OUT, "*.rds"))
  files <- files[!grepl("/(games_|summary_)", files)]
  xs <- lapply(files, readRDS)
  names(xs) <- vapply(xs, `[[`, character(1), "name")
  common <- Reduce(intersect, lapply(xs, \(x) with(x$pred[x$pred$played %in% TRUE, ], paste(season, game_id))))
  base <- score_variant(xs$base, common)
  ll <- function(p, y) -(y * log(p) + (1 - y) * log(1 - p))
  rows <- lapply(names(xs), function(n) {
    p <- score_variant(xs[[n]], common)
    p <- p[match(paste(base$season, base$game_id, base$snap_date), paste(p$season, p$game_id, p$snap_date)), ]
    d_ae <- abs(p$actual - p$pred_margin) - abs(base$actual - base$pred_margin)
    d_ll <- ll(p$p_home, p$win) - ll(base$p_home, base$win)
    nd <- p$period == "Nov-Dec"
    g <- xs[[n]]$gates
    data.frame(variant = n, games = nrow(p), mae = mean(abs(p$actual - p$pred_margin)),
               d_mae = mean(d_ae), se = stats::sd(d_ae) / sqrt(nrow(p)),
               d_mae_novdec = mean(d_ae[nd]), d_mae_janapr = mean(d_ae[!nd]),
               logloss = mean(ll(p$p_home, p$win)), d_logloss = mean(d_ll),
               gates_pass = mean(g$max_rhat <= 1.01 & g$min_ess >= 200 & g$divergences == 0), secs = mean(g$secs))
  })
  tab <- bind_rows(rows) |> arrange(d_mae)
  tab
}

args <- commandArgs(trailingOnly = TRUE)
if (identical(args, "summary")) {
  tab <- summarise_variants()
  print(tab, digits = 4)
  saveRDS(tab, file.path(OUT, "summary_table.rds"))
} else {
  for (a in args) run_variant(a)
}
