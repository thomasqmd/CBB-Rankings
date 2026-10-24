# Pooled priors for the hierarchy scales and the weekly drift (todo, Phase 3).
# Refits each season's final snapshot (2015-2026, from the targets build) with vague priors on
# sigma_conf, sigma_team and tau, then pools them by random-effects meta-analysis (DerSimonian-
# Laird): centre = pooled mean, predictive sd = sqrt(between-season variance + se of the mean^2).
# sigma_conf and tau show no between-season variation (Q below its df); model_config() rounds the
# predictive sds up (0.17 -> 0.2, 0.31 -> 0.35) and keeps tau at the pilot's 0.1 (0.055 here),
# since the vague tau fits did not fully converge (R-hat up to 1.06).
source("R/01_ingest.R"); source("R/02_prep.R"); source("R/03_model.R")
suppressMessages(library(dplyr))
invisible(cmdstanr::cmdstan_model("stan/power.stan", quiet = TRUE))

seasons <- 2015:2026
vague <- list(sigma_conf_prior = c(0, 10), sigma_team_prior = c(0, 10), tau_prior = c(0, 2))
cfg <- model_config()

res <- parallel::mclapply(seasons, function(s) {
  inp <- targets::tar_read_raw(paste0("inputs_", s))
  inp <- inp[[length(inp)]]                        # the final snapshot
  inp$stan[names(vague)] <- vague
  f <- fit_snapshot(inp, cfg)
  p <- f$par
  data.frame(season = s, snap_date = inp$snap_date, t(f$gates), secs = f$secs, worst = f$worst$variable[1],
             sigma_conf = mean(p$sigma_conf), sigma_conf_sd = sd(p$sigma_conf),
             sigma_team = mean(p$sigma_team), sigma_team_sd = sd(p$sigma_team),
             tau = mean(p$tau), tau_sd = sd(p$tau), b_prev = mean(p$b_prev))
}, mc.cores = as.integer(Sys.getenv("POOL_JOBS", "3")))
bad <- vapply(res, inherits, logical(1), "try-error"); if (any(bad)) { print(res[bad][[1]]); stop("failed") }
rows <- bind_rows(res) |> mutate(pass = max_rhat <= 1.01 & min_ess >= 400 & divergences == 0 & min_ebfmi > 0.2)
saveRDS(rows, "pilot/conv/07_pooled_priors.rds")

pool <- function(m, s) {
  w <- 1 / s^2; mu <- sum(w * m) / sum(w); Q <- sum(w * (m - mu)^2)
  t2 <- max(0, (Q - (length(m) - 1)) / (sum(w) - sum(w^2) / sum(w)))
  ws <- 1 / (s^2 + t2)
  c(round(sum(ws * m) / sum(ws), 2), round(sqrt(t2 + 1 / sum(ws)), 3))
}
pooled <- list(sigma_conf_prior = pool(rows$sigma_conf, rows$sigma_conf_sd),
               sigma_team_prior = pool(rows$sigma_team, rows$sigma_team_sd),
               tau_prior = pool(rows$tau, rows$tau_sd))
print(as.data.frame(rows), digits = 3)
str(pooled)
saveRDS(list(rows = rows, pooled = pooled), "pilot/conv/07_pooled_priors.rds")
