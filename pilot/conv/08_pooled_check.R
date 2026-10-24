# Pooled priors (model_config(), from 07_pooled_priors.R) on the hardest 2026 snapshots: gates, and next-week
# predictions against the build's (old in-sample priors) on the same games.
suppressMessages({library(dplyr); for (f in c("R/01_ingest.R", "R/02_prep.R", "R/03_model.R")) source(f)})
cfg0 <- model_config()
pooled <- cfg0[c("sigma_conf_prior", "sigma_team_prior", "tau_prior")]
s <- targets::tar_read(snapshots)
dts <- targets::tar_read(dates_2026)
pick <- which(as.character(dts$snap_date) %in% c("2025-11-10", "2025-11-24", "2025-12-08", "2026-01-05", "2026-01-19", "2026-02-16"))
cfg <- model_config()
res <- parallel::mclapply(pick, function(i) {
  inp <- targets::tar_read(inputs_2026, branches = i)[[1]]
  inp$stan[names(pooled)] <- pooled
  f <- fit_snapshot(inp, cfg)
  pr <- predict_games(f, inp, inp$upcoming[inp$upcoming$played %in% TRUE, ])
  old <- s$predictions[s$predictions$season == 2026 & s$predictions$snap_date == inp$snap_date, c("game_id", "pred_margin", "p_home")]
  m <- merge(pr[, c("game_id", "home_score", "away_score", "pred_margin", "p_home")], old, by = "game_id", suffixes = c("", "_old"))
  act <- m$home_score - m$away_score; y <- act > 0
  ll <- function(p) -mean(ifelse(y, log(p), log(1 - p)))
  data.frame(snap = inp$snap_date, t(f$gates), worst = f$worst$variable[1], secs = round(f$secs),
             sigma_conf = mean(f$par$sigma_conf), sigma_team = mean(f$par$sigma_team), tau = mean(f$par$tau),
             n = nrow(m), mae = mean(abs(act - m$pred_margin)), mae_old = mean(abs(act - m$pred_margin_old)),
             ll = ll(m$p_home), ll_old = ll(m$p_home_old))
}, mc.cores = 3)
bad <- vapply(res, inherits, logical(1), "try-error"); if (any(bad)) { print(res[bad][[1]]); stop("failed") }
rows <- bind_rows(res); saveRDS(rows, "pilot/conv/08_pooled_check.rds")
print(rows, digits = 3)
cat("weighted MAE new", weighted.mean(rows$mae, rows$n), "old", weighted.mean(rows$mae_old, rows$n),
    "| log loss new", weighted.mean(rows$ll, rows$n), "old", weighted.mean(rows$ll_old, rows$n), "\n")
