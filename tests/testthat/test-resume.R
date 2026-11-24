test_that("WAB on Torvik's ratings: champions and best-rated teams take the bids, the benchmark is the last at-large", {
  teams <- data.frame(team_id = 1:6, conf = rep(c("X", "Y"), each = 3), eligible = c(FALSE, TRUE, TRUE, TRUE, TRUE, TRUE))
  rating <- c(21, 11, 1, 16, 6, -4)
  tv <- data.frame(team_id = 1:5, tv = c(20, 10, 0, 15, 5))          # team 6 has no Torvik rating: imputed as -5
  games <- data.frame(home_id = 3L, away_id = 6L, home_score = 70, away_score = 60, neutral = 0L, poss_reg = 70)
  par <- list(hca = 2, sigma_game = 10, nu = 1e4)
  # X's champion is team 2; Y's bid goes to its best-rated team, 4; team 1 is ineligible, so the
  # one at-large place, the benchmark, is team 5 (rating 5)
  out <- torvik_resume(teams, games, tv, rating, par, field = 3L, champs = 2L)
  expect_equal(out$tv_wab[out$team_id == 3], 1 - stats::pt((5 + 5 + 2) / 10, 1e4), tolerance = 1e-8)
  expect_equal(out$tv_wab[out$team_id == 6], -stats::pt((5 - 0 - 2) / 10, 1e4), tolerance = 1e-8)
  expect_equal(out$tv_rrk[out$team_id == 3], 1L)
  expect_setequal(out$team_id, c(3L, 6L))                            # teams without games get no WAB
})

test_that("WAB on Torvik's ratings needs games and enough rated teams", {
  teams <- data.frame(team_id = 1:2, conf = "X")
  tv <- data.frame(team_id = 1:2, tv = c(1, 0))
  par <- list(hca = 0, sigma_game = 10, nu = 1e4)
  g0 <- data.frame(home_id = integer(), away_id = integer(), home_score = numeric(), away_score = numeric(), neutral = integer(), poss_reg = numeric())
  expect_equal(nrow(torvik_resume(teams, g0, tv, c(1, 0), par, field = 2L)), 0)
  g1 <- data.frame(home_id = 1L, away_id = 2L, home_score = 70, away_score = 60, neutral = 0L, poss_reg = 70)
  expect_equal(nrow(torvik_resume(teams, g1, tv, c(1, 0), par, field = 68L)), 0)
})
