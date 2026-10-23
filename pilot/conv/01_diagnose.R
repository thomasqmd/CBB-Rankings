# Convergence pilot, step 1: which parameters fail the gates, and does centering r fix it?
source("R/01_ingest.R"); source("R/02_prep.R"); source("R/03_model.R")
suppressMessages(library(dplyr))
games <- readRDS("data/derived/pilot_games.rds")$`2026`
prev <- readRDS("data/derived/prior_2025.rds"); teams <- team_conferences(games)
mod <- cmdstanr::cmdstan_model("stan/power.stan", quiet = TRUE)
cases <- expand.grid(snap = as.Date(c("2025-11-10", "2025-11-24", "2026-02-02")), dynamic = c(FALSE, TRUE))
out <- parallel::mclapply(seq_len(nrow(cases)), function(k) {
  cfg <- model_config(dynamic = cases$dynamic[k])
  inp <- prepare_input(games, cases$snap[k], teams, prev, cfg)
  fit <- mod$sample(data = inp$stan, chains = 4, parallel_chains = 4, iter_warmup = 500, iter_sampling = 500,
                    adapt_delta = 0.9, seed = 2026, refresh = 0, show_messages = FALSE)
  pars <- c("sigma_conf", "sigma_team", "b_prev", "hca", "sigma_m", "nu", "tau", "lambda", "sigma_eff", "kappa")
  s <- posterior::summarise_draws(fit$draws(c(pars, "r", "mu_conf")), "rhat", "ess_bulk", "ess_tail")
  r <- posterior::as_draws_matrix(fit$draws("r")); rc <- r - rowMeans(r)
  sc <- posterior::summarise_draws(posterior::as_draws_array(posterior::as_draws(rc)), "rhat", "ess_bulk")
  # mean of raw r across teams = the unidentified common level
  lvl <- posterior::summarise_draws(posterior::draws_matrix(level = rowMeans(r)), "rhat", "ess_bulk")
  grp <- function(v) ifelse(grepl("^r\\[", v), "r (raw)", ifelse(grepl("^mu_conf", v), "mu_conf", v))
  worst <- s |> mutate(g = grp(variable)) |> group_by(g) |> summarise(min_ess = min(ess_bulk), max_rhat = max(rhat)) |> arrange(min_ess)
  list(case = cases[k, ], worst = worst, centred = c(min_ess = min(sc$ess_bulk), max_rhat = max(sc$rhat)), level = lvl,
       div = sum(fit$diagnostic_summary(quiet = TRUE)$num_divergent))
}, mc.cores = 3)
for (o in out) {
  cat("\n=== snap", format(o$case$snap), "dynamic", o$case$dynamic, "| divergences", o$div, "\n")
  print(as.data.frame(o$worst), digits = 3)
  cat("centred r: min ESS", round(o$centred["min_ess"]), "max Rhat", round(o$centred["max_rhat"], 3),
      "| common level: ESS", round(o$level$ess_bulk), "Rhat", round(o$level$rhat, 3), "\n")
}
saveRDS(out, "pilot/conv/01_diagnose.rds")
