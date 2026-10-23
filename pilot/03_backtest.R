# Pilot step 3: rolling backtest over 2025-26. Every two weeks, fit on games before the snapshot
# and predict games until the next one; compare variants with each other and the closing line.
source("R/01_ingest.R"); source("R/02_prep.R"); source("R/03_model.R")
suppressMessages(library(dplyr))
games <- readRDS("data/derived/pilot_games.rds")$`2026`
prev <- readRDS("data/derived/prior_2025.rds")
nd <- readRDS("data/derived/pilot_nd_games.rds")$`2026`
teams <- team_conferences(games)
invisible(cmdstanr::cmdstan_model("stan/power.stan", quiet = TRUE))

variants <- list(
  margin_static = model_config(use_eff = FALSE, dynamic = FALSE),
  shotq_static  = model_config(eff_col = "eff100", dynamic = FALSE),
  lux_static    = model_config(eff_col = "lux100", dynamic = FALSE),
  lux_dynamic   = model_config(eff_col = "lux100", dynamic = TRUE)
)
snaps <- seq(as.Date("2025-11-10"), as.Date("2026-03-16"), by = 14)
ends <- c(snaps[-1], as.Date("2026-04-10"))
jobs <- expand.grid(v = names(variants), k = seq_along(snaps), stringsAsFactors = FALSE)
out <- parallel::mclapply(seq_len(nrow(jobs)), function(j) {
  v <- jobs$v[j]; k <- jobs$k[j]
  inp <- prepare_input(games, snaps[k], teams, prev, variants[[v]], nd)
  f <- fit_snapshot(inp, variants[[v]])
  new <- games[games$game_date >= snaps[k] & games$game_date < ends[k], ]
  pr <- predict_games(f, inp, new)
  list(pred = data.frame(variant = v, snap = snaps[k], pr), gates = data.frame(variant = v, snap = snaps[k], t(f$gates), secs = f$secs))
}, mc.cores = 2)
saveRDS(out, "data/derived/pilot_backtest.rds")
