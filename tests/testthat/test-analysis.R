test_that("every prior setting reaches the Stan data", {
  inp <- prepare_input(toy_games(), as.Date("2025-11-12"), teams, NULL, model_config())
  for (f in PRIOR_FIELDS) expect_equal(inp$stan[[f]], model_config()[[f]], info = f)
  inp2 <- prepare_input(toy_games(), as.Date("2025-11-12"), teams, NULL, model_config(kappa_prior = c(0, 9)))
  expect_equal(inp2$stan$kappa_prior, c(0, 9))
})

test_that("pooling equal seasons gives their mean and the standard error of the mean", {
  refits <- data.frame(season = 2015:2018, variable = "tau", mean = 0.5, sd = 0.2)
  p <- pool_priors(refits)
  expect_equal(p$pooled_mean, 0.5)
  expect_equal(p$between_sd, 0)
  expect_equal(p$predictive_sd, 0.2 / sqrt(4))
})

test_that("pooling widens the prior by the variation between seasons beyond estimation noise", {
  refits <- data.frame(season = 2015:2020, variable = "hca", mean = c(3, 5, 3, 5, 3, 5), sd = 0.1)
  p <- pool_priors(refits)
  expect_gt(p$between_sd, 0.9)
  expect_gt(p$predictive_sd, p$between_sd)
  # 2021 (limited attendance) is left out of home court
  p2 <- pool_priors(rbind(refits, data.frame(season = 2021L, variable = "hca", mean = -10, sd = 0.1)))
  expect_equal(p2$pooled_mean, p$pooled_mean)
})

test_that("pooled priors round the sd up to the next 0.05, at least 0.1", {
  pooled <- data.frame(variable = c("sigma_conf", "sigma_team", "tau", "hca"),
                       pooled_mean = c(1.4812, 4.2711, 0.5634, 4.5), predictive_sd = c(0.17, 0.31, 0.055, 0.4))
  v <- pooled_prior_values(pooled)
  expect_equal(v$sigma_conf_prior, c(1.48, 0.2))
  expect_equal(v$sigma_team_prior, c(4.27, 0.35))
  expect_equal(v$tau_prior, c(0.56, 0.1))
  expect_equal(v$hca_prior, c(4.5, 0.4))
})

test_that("prior perturbations widen and shift the chosen groups only", {
  cfg <- model_config()
  w <- perturb_priors(cfg, sd_mult = 5, groups = "drift")
  expect_equal(w$tau_prior, c(cfg$tau_prior[1], 5 * cfg$tau_prior[2]))
  expect_equal(w$sigma_conf_prior, cfg$sigma_conf_prior)
  s <- perturb_priors(cfg, shift = 1, groups = "home")
  expect_equal(s$hca_prior[1], cfg$hca_prior[1] + cfg$hca_prior[2])
  expect_equal(s$hca_prior_season[["2021"]][1], sum(cfg$hca_prior_season[["2021"]]))
  low <- perturb_priors(cfg, shift = -10, groups = "carry")
  expect_gte(low$b_prev_prior[1], 0.05)
})

test_that("WAB against a fixed benchmark: a win adds 1 - p, a loss subtracts p", {
  sd <- list(state_team = 1:3, home_state = c(1L, 2L), away_state = c(2L, 3L), home_adv = c(0, 0), w_m = c(1, 1))
  r <- matrix(c(10, 0, -10), 1)
  par <- data.frame(hca = 0, sigma_game = 10, nu = 1e4)
  # game 1: team 1 (home) beats team 2; game 2: team 3 (away) beats team 2
  w <- wab_fixed(r, par, sd, win = c(1, 0), b = 2)                 # the benchmark is team 2's rating, 0
  p_vs1 <- stats::pt((0 - 10) / 10, 1e4); p_vs2 <- 0.5; p_vs3 <- stats::pt((0 + 10) / 10, 1e4)
  expect_equal(w[1, 1], 1 - p_vs2, tolerance = 1e-8)
  expect_equal(w[1, 2], (0 - p_vs1) + (0 - p_vs3), tolerance = 1e-8)
  expect_equal(w[1, 3], 1 - p_vs2, tolerance = 1e-8)
})

test_that("the NCAA field gives each conference one automatic bid", {
  g <- data.frame(ncaa = TRUE, home_id = c(1L, 3L), away_id = c(2L, 4L), home_seed = c(1L, 2L), away_seed = c(16L, 15L))
  tm <- data.frame(team_id = 1:4, conf = c("X", "X", "Y", "Z"))
  champs <- data.frame(conf = "X", team_id = 2L)
  f <- ncaa_field(g, tm, champs, 2026)
  expect_equal(sort(f$team_id[f$auto]), c(2L, 3L, 4L))           # X's champion; Y and Z have one team each
  expect_false(f$auto[f$team_id == 1])
})

test_that("prior draws and simulated games have the shapes of the Stan data", {
  inp <- prepare_input(toy_games(), as.Date("2025-11-12"), teams, NULL, model_config())
  set.seed(1)
  p <- draw_prior(inp$stan)
  expect_length(p$r_state, inp$stan$N_states)
  expect_length(p$r_now, inp$stan$N_teams)
  sim <- simulate_games(inp$stan, p)
  expect_length(sim$margin, inp$stan$N_games)
  expect_true(all(sim$eff[inp$stan$has_eff == 0] == 0))
})
