# ==============================================================================
# Prior sensitivity (2026-10-30): power-scaling of the hyperparameter priors (priorsense) on
# pipeline snapshots, early season (the second Monday) and Selection Monday, three seasons.
# Uses pilot/stan/power_ps.stan (stan/power.stan plus lprior) with each game's margin log
# density as the likelihood. Flags: prior-data conflict (sensitive to both) or a weak
# likelihood (prior sensitive only).
#   Rscript pilot/18_priorsense.R      -> pilot/out/18_priorsense.rds
# ==============================================================================

suppressMessages({ library(targets); library(dplyr) })
tar_source("R")
OUT <- "pilot/out/variants"
stan <- file.path(OUT, "power_ps.stan")
file.copy("pilot/stan/power_ps.stan", stan, overwrite = TRUE)
mod <- cmdstanr::cmdstan_model(stan, quiet = TRUE)
cfg <- model_config(stan_file = stan, save_loglik = TRUE)
PARS <- c("hca", "sigma_m", "sigma_team", "sigma_conf", "b_prev", "b_prev2", "tau", "lambda", "sigma_eff", "kappa")

out <- bind_rows(lapply(c(2018, 2022, 2026), function(s) {
  d <- tar_read_raw(paste0("dates_", s))
  d <- d[c(which(d$kind == "weekly")[2], which(d$kind == "selection")), ]
  bind_rows(lapply(seq_len(nrow(d)), function(i) {
    inp <- snapshot_input(tar_read_raw(paste0("games_", s)), d[i, ], tar_read_raw(paste0("teams_", s)), tar_read_raw(paste0("prior_", s)), cfg)
    fit <- mod$sample(data = inp$stan, chains = 4, parallel_chains = 4, iter_warmup = 1000, iter_sampling = 1000,
                      adapt_delta = 0.9, seed = 2026, refresh = 0, show_messages = FALSE)
    ps <- priorsense::powerscale_sensitivity(fit, variable = PARS)
    data.frame(season = s, snap_date = d$snap_date[i], n_games = inp$stan$N_games, as.data.frame(ps))
  }))
}))
saveRDS(out, "pilot/out/18_priorsense.rds")
print(out, digits = 3)
