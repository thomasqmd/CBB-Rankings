source("R/01_ingest.R"); source("R/02_prep.R"); source("R/03_model.R")
games <- readRDS("data/derived/pilot_games.rds")$`2026`
prev <- readRDS("data/derived/prior_2025.rds"); teams <- team_conferences(games)
invisible(cmdstanr::cmdstan_model("stan/power.stan", quiet = TRUE))
cfgs <- list(cc14 = model_config(conf_carry = TRUE, state_days = 14), static_cc = model_config(conf_carry = TRUE, dynamic = FALSE))
out <- parallel::mclapply(names(cfgs), function(n) { inp <- prepare_input(games, as.Date("2026-02-02"), teams, prev, cfgs[[n]]); fit_snapshot(inp, cfgs[[n]])$worst }, mc.cores = 2)
names(out) <- names(cfgs); print(out)
