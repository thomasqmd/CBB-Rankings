# Non-D1 games under the converging setup (informative priors, 4 x 1000, non-centred conferences).
source("R/01_ingest.R"); source("R/02_prep.R"); source("R/03_model.R")
suppressMessages(library(dplyr))
games <- readRDS("data/derived/pilot_games.rds")$`2026`
nd_games <- readRDS("data/derived/pilot_nd_games_2026.rds")
prev <- readRDS("data/derived/prior_2025.rds"); teams <- team_conferences(games)
invisible(cmdstanr::cmdstan_model("stan/power.stan", quiet = TRUE))
cfgs <- list(d1_only = model_config(), with_nd = model_config(use_nd = TRUE))
snaps <- as.Date(c("2025-11-10", "2025-11-24", "2025-12-08", "2025-12-22", "2026-01-05", "2026-02-02", "2026-03-02"))
jobs <- expand.grid(setup = names(cfgs), snap = snaps, stringsAsFactors = FALSE)
res <- parallel::mclapply(seq_len(nrow(jobs)), function(j) {
  cfg <- cfgs[[jobs$setup[j]]]; sd <- jobs$snap[j]
  inp <- prepare_input(games, sd, teams, prev, cfg, nd_games)
  f <- fit_snapshot(inp, cfg)
  new <- games[games$game_date >= sd & games$game_date < sd + 14 & !is.na(games$spread), ]
  pr <- predict_games(f, inp, new); act <- pr$home_score - pr$away_score
  data.frame(jobs[j, ], t(f$gates), secs = f$secs, worst = f$worst$variable[1], n_nd = inp$stan$N_nd,
             n_pred = nrow(pr), mae = mean(abs(act - pr$pred_margin)), mae_line = mean(abs(act + pr$spread)),
             logloss = -mean(ifelse(act > 0, log(pr$p_home), log(1 - pr$p_home))))
}, mc.cores = 3)
bad <- vapply(res, inherits, logical(1), "try-error"); if (any(bad)) { print(res[bad][[1]]); stop("failed") }
rows <- bind_rows(res) |> mutate(pass = max_rhat <= 1.01 & min_ess >= 400 & divergences == 0 & min_ebfmi > 0.2,
                                 period = ifelse(snap < as.Date("2026-01-01"), "Nov-Dec", "Jan-Mar"))
saveRDS(rows, "pilot/conv/06_nond1.rds")
print(as.data.frame(rows |> group_by(setup) |> summarise(pass = sum(pass), fits = n(), min_ess = min(min_ess), max_rhat = max(max_rhat), div = sum(divergences), secs = mean(secs))))
print(as.data.frame(rows |> group_by(setup, period) |> summarise(n = sum(n_pred), mae = weighted.mean(mae, n_pred), logloss = weighted.mean(logloss, n_pred), .groups = "drop")), digits = 4)
print(as.data.frame(rows |> select(setup, snap, n_nd, max_rhat, min_ess, divergences, worst, mae, logloss)), digits = 4)
