# Convergence pilot, step 2: which setup passes the gates (R-hat <= 1.01, ESS >= 400, no
# divergences, E-BFMI > 0.2) without hurting predictions? Dynamic, luck-adjusted model.
source("R/01_ingest.R"); source("R/02_prep.R"); source("R/03_model.R")
suppressMessages(library(dplyr))
games <- readRDS("data/derived/pilot_games.rds")$`2026`
prev <- readRDS("data/derived/prior_2025.rds"); teams <- team_conferences(games)
invisible(cmdstanr::cmdstan_model("stan/power.stan", quiet = TRUE))

setups <- list(
  base_7d          = model_config(),
  states_14d       = model_config(state_days = 14),
  conf_carry       = model_config(conf_carry = TRUE),
  conf_carry_14d   = model_config(conf_carry = TRUE, state_days = 14),
  conf_carry_14d_long = model_config(conf_carry = TRUE, state_days = 14, warmup = 1000, sampling = 1000)
)
snaps <- as.Date(c("2025-11-24", "2026-01-05", "2026-02-02", "2026-03-02"))
jobs <- expand.grid(setup = names(setups), snap = snaps, stringsAsFactors = FALSE)
res <- parallel::mclapply(seq_len(nrow(jobs)), function(j) {
  cfg <- setups[[jobs$setup[j]]]; sd <- jobs$snap[j]
  inp <- prepare_input(games, sd, teams, prev, cfg)
  f <- fit_snapshot(inp, cfg)
  new <- games[games$game_date >= sd & games$game_date < sd + 14 & !is.na(games$spread), ]
  pr <- predict_games(f, inp, new)
  act <- pr$home_score - pr$away_score
  data.frame(setup = jobs$setup[j], snap = sd, t(f$gates), secs = f$secs,
             ess_per_sec = f$gates[["min_ess"]] / f$secs,
             tau = mean(f$par$tau), b_prev = mean(f$par$b_prev), sigma_conf = mean(f$par$sigma_conf),
             n_pred = nrow(pr), mae = mean(abs(act - pr$pred_margin)), mae_line = mean(abs(act + pr$spread)),
             logloss = -mean(ifelse(act > 0, log(pr$p_home), log(1 - pr$p_home))))
}, mc.cores = 3)
bad <- vapply(res, inherits, logical(1), "try-error")
if (any(bad)) print(res[bad][[1]])
res <- bind_rows(res[!bad]) |>
  mutate(pass = max_rhat <= 1.01 & min_ess >= 400 & divergences == 0 & min_ebfmi > 0.2)
saveRDS(res, "pilot/conv/02_grid.rds")
summ <- res |> group_by(setup) |> summarise(pass = sum(pass), fits = n(), min_ess = min(min_ess), max_rhat = max(max_rhat),
  div = sum(divergences), mean_secs = mean(secs), mae = weighted.mean(mae, n_pred), logloss = weighted.mean(logloss, n_pred),
  tau = mean(tau)) |> arrange(match(setup, names(setups)))
print(as.data.frame(summ), digits = 4)
print(as.data.frame(res |> select(setup, snap, max_rhat, min_ess, divergences, secs, mae, tau)), digits = 3)
