# Convergence pilot, step 3: centred conference means, and games against non-D1 teams.
# Gates on every snapshot; predictions scored on the next 14 days (games with a closing line).
source("R/01_ingest.R"); source("R/02_prep.R"); source("R/03_model.R")
suppressMessages(library(dplyr))
games <- readRDS("data/derived/pilot_games.rds")$`2026`
nd_file <- "data/derived/pilot_nd_games_2026.rds"
if (!file.exists(nd_file)) saveRDS(build_games(2026, "nond1"), nd_file)
nd_games <- readRDS(nd_file)
cat("non-D1 games:", nrow(nd_games), "| by", format(as.Date("2025-12-01")), ":", sum(nd_games$game_date < as.Date("2025-12-01")), "\n")
prev <- readRDS("data/derived/prior_2025.rds"); teams <- team_conferences(games)
invisible(cmdstanr::cmdstan_model("stan/power.stan", quiet = TRUE))

setups <- list(
  base        = model_config(),
  centred     = model_config(conf_carry = TRUE, conf_centred = TRUE),
  centred_14d = model_config(conf_carry = TRUE, conf_centred = TRUE, state_days = 14),
  centred_nd  = model_config(conf_carry = TRUE, conf_centred = TRUE, use_nd = TRUE)
)
snaps <- as.Date(c("2025-11-10", "2025-11-24", "2025-12-08", "2025-12-22", "2026-01-05", "2026-02-02", "2026-03-02"))
jobs <- expand.grid(setup = names(setups), snap = snaps, stringsAsFactors = FALSE)
res <- parallel::mclapply(seq_len(nrow(jobs)), function(j) {
  cfg <- setups[[jobs$setup[j]]]; sd <- jobs$snap[j]
  inp <- prepare_input(games, sd, teams, prev, cfg, nd_games)
  f <- fit_snapshot(inp, cfg)
  new <- games[games$game_date >= sd & games$game_date < sd + 14 & !is.na(games$spread), ]
  pr <- predict_games(f, inp, new)
  act <- pr$home_score - pr$away_score
  list(row = data.frame(setup = jobs$setup[j], snap = sd, t(f$gates), secs = f$secs, worst = f$worst$variable[1],
             n_nd = inp$stan$N_nd, n_pred = nrow(pr), mae = mean(abs(act - pr$pred_margin)), mae_line = mean(abs(act + pr$spread)),
             logloss = -mean(ifelse(act > 0, log(pr$p_home), log(1 - pr$p_home)))),
       par = colMeans(f$par))
}, mc.cores = 3)
bad <- vapply(res, inherits, logical(1), "try-error")
if (any(bad)) { print(res[bad][[1]]); stop("failed jobs") }
rows <- bind_rows(lapply(res, `[[`, "row")) |>
  mutate(pass = max_rhat <= 1.01 & min_ess >= 400 & divergences == 0 & min_ebfmi > 0.2,
         period = ifelse(snap < as.Date("2026-01-01"), "Nov-Dec", "Jan-Mar"))
saveRDS(list(rows = rows, res = res, jobs = jobs), "pilot/conv/04_grid2.rds")
summ <- rows |> group_by(setup) |> summarise(pass = sum(pass), fits = n(), min_ess = min(min_ess), max_rhat = max(max_rhat),
  div = sum(divergences), secs = mean(secs), worst = paste(names(sort(table(worst), decreasing = TRUE))[1:2], collapse = "/"), .groups = "drop") |>
  arrange(match(setup, names(setups)))
acc <- rows |> group_by(setup, period) |> summarise(n = sum(n_pred), mae = weighted.mean(mae, n_pred),
  mae_line = weighted.mean(mae_line, n_pred), logloss = weighted.mean(logloss, n_pred), .groups = "drop")
print(as.data.frame(summ)); print(as.data.frame(acc), digits = 4)
print(as.data.frame(rows |> select(setup, snap, max_rhat, min_ess, divergences, worst, secs, mae)), digits = 3)
