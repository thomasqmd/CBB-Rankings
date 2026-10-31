# ==============================================================================
# Simulation-based calibration (2026-10-30). Keeps a real snapshot's structure (2024-25, the
# fourth Monday: its teams, conferences, priors, schedule, weights, non-D1 games), draws every
# hyperparameter and team effect from the model's priors, simulates the efficiency signal and
# the margins as stan/power.stan specifies (normal margins), refits, and records each true
# value's rank among 99 thinned posterior draws. A calibrated sampler gives uniform ranks.
#   Rscript pilot/17_sbc.R [reps]      -> pilot/out/17_sbc.rds
# ==============================================================================

suppressMessages({ library(targets); library(dplyr) })
tar_source("R")
REPS <- as.integer(commandArgs(trailingOnly = TRUE)[1]); if (is.na(REPS)) REPS <- 200L
L <- 99L
OUT <- "pilot/out/variants"
stan <- file.path(OUT, "power.stan")
file.copy("stan/power.stan", stan, overwrite = TRUE)
mod <- cmdstanr::cmdstan_model(stan, quiet = TRUE)
cfg <- model_config(stan_file = stan)
s <- 2025
d <- tar_read_raw(paste0("dates_", s)); d <- d[which(d$kind == "weekly")[4], ]
inp <- snapshot_input(tar_read_raw(paste0("games_", s)), d, tar_read_raw(paste0("teams_", s)), tar_read_raw(paste0("prior_", s)), cfg)
sd0 <- inp$stan

hn <- function(m, s) { repeat { x <- rnorm(1, m, s); if (x > 0) return(x) } }       # normal truncated at 0
simulate <- function(sd) {
  p <- list(sigma_conf = hn(sd$sigma_conf_prior[1], sd$sigma_conf_prior[2]), sigma_team = hn(sd$sigma_team_prior[1], sd$sigma_team_prior[2]),
            b_prev = { repeat { x <- rnorm(1, 0.7, 0.2); if (x > 0 && x < 1.2) break }; x }, b_prev2 = rnorm(1, 0.2, 0.2),
            hca = rnorm(1, sd$hca_prior[1], sd$hca_prior[2]), sigma_m = hn(14, 5), tau = hn(sd$tau_prior[1], sd$tau_prior[2]),
            lambda = hn(0.7, 0.3), sigma_eff = hn(12, 5), kappa = rnorm(1, 0.5, 0.5), r_nd = rnorm(1, -25, 10), sigma_nd = hn(10, 5))
  mu_conf <- p$sigma_conf * rnorm(sd$N_conf)
  r0 <- mu_conf[sd$team_conf] + p$b_prev * sd$prev_dev + p$b_prev2 * sd$prev2_dev + sqrt(p$sigma_team^2 + (p$b_prev * sd$prev_sd)^2) * rnorm(sd$N_teams)
  step <- sqrt(sd$state_gap) * rnorm(sd$N_states)
  cs <- ave(step, sd$state_team, FUN = cumsum)                                     # states are in order within a team
  r_state <- r0[sd$state_team] + p$tau * cs
  mu <- r_state[sd$home_state] - r_state[sd$away_state] + p$hca * sd$home_adv
  sw_m <- sqrt(sd$w_m); sw_e <- sqrt(sd$w_e); e <- sd$has_eff == 1
  eff <- ifelse(e, rnorm(sd$N_games, p$lambda * mu, p$sigma_eff / sw_e), 0)
  margin <- ifelse(e, rnorm(sd$N_games, mu + p$kappa * (eff - p$lambda * mu), p$sigma_m / sw_m),
                   rnorm(sd$N_games, mu, sqrt((p$sigma_m / sw_m)^2 + (p$kappa * p$sigma_eff / sw_e)^2)))
  nd <- if (sd$N_nd) rnorm(sd$N_nd, r_state[sd$nd_state] - p$r_nd + p$hca * sd$nd_venue,
                           sqrt((p$sigma_m^2 + (p$kappa * p$sigma_eff)^2) / sd$nd_w + p$sigma_nd^2)) else numeric()
  sd$eff <- eff; sd$margin <- margin; sd$nd_margin <- nd
  # team ratings at the snapshot are draws (drift since the last state); compare the latest states
  last <- tapply(seq_len(sd$N_states), sd$state_team, max)
  k <- as.integer(names(last))[1:5]
  list(sd = sd, truth = c(unlist(p[c("hca", "sigma_m", "sigma_team", "sigma_conf", "b_prev", "b_prev2", "tau", "lambda", "sigma_eff", "kappa")]),
                         setNames(r_state[last[as.character(k)]], paste0("r_state[", last[as.character(k)], "]"))))
}

set.seed(2026)
sims <- lapply(seq_len(REPS), function(i) simulate(sd0))
res <- parallel::mclapply(seq_len(REPS), function(i) {
  x <- sims[[i]]
  fit <- mod$sample(data = x$sd, chains = 2, parallel_chains = 2, iter_warmup = 500, iter_sampling = 500,
                    adapt_delta = 0.9, seed = i, refresh = 0, show_messages = FALSE)
  dr <- posterior::as_draws_matrix(fit$draws(names(x$truth)))
  keep <- round(seq(1, nrow(dr), length.out = L))
  diag <- fit$diagnostic_summary(quiet = TRUE)
  data.frame(rep = i, variable = names(x$truth), truth = x$truth,
             rank = vapply(names(x$truth), \(v) sum(dr[keep, v] < x$truth[[v]]), numeric(1)),
             mean = colMeans(dr[, names(x$truth)]), sd = apply(dr[, names(x$truth)], 2, stats::sd),
             divergences = sum(diag$num_divergent))
}, mc.cores = 8, mc.preschedule = FALSE)
res <- bind_rows(res[!vapply(res, inherits, logical(1), "try-error")])
saveRDS(res, "pilot/out/17_sbc.rds")
# Uniformity: chi-square over 10 bins of the rank (0..L), and the z-score of the posterior mean
tab <- res |> mutate(variable = sub("\\[.*", "[team]", variable)) |> group_by(variable) |> summarise(
  n = n(), p_unif = suppressWarnings(chisq.test(table(cut(rank, seq(-0.5, L + 0.5, length.out = 11))))$p.value),
  mean_rank = mean(rank) / L, z_bias = mean((mean - truth) / sd), cov80 = mean(abs(truth - mean) <= 1.2816 * sd), .groups = "drop")
print(as.data.frame(tab), digits = 3)
cat("fits with divergences:", sum(tapply(res$divergences, res$rep, max) > 0), "of", length(unique(res$rep)), "\n")
