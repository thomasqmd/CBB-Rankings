toy_games <- function() {
  d <- as.Date("2025-11-03") + c(0, 3, 7, 10, 14)
  data.frame(game_id = 1:5, game_date = d, home_id = c(1L, 2L, 3L, 1L, 2L), away_id = c(2L, 3L, 1L, 3L, 1L),
             home = c("A", "B", "C", "A", "B"), away = c("B", "C", "A", "C", "A"),
             home_conf = "X", away_conf = "X", division = "d1", season_type = "regular", ncaa = FALSE,
             neutral = 0L, played = c(TRUE, TRUE, TRUE, FALSE, FALSE), home_score = c(70, 60, 65, NA, NA),
             away_score = c(60, 66, 64, NA, NA), poss_reg = 70, margin100 = c(14, -8.6, 1.4, NA, NA),
             has_eff = c(TRUE, TRUE, TRUE, FALSE, FALSE), lux100 = c(10, -5, 0, 0, 0), poss_live = 60, spread = -3)
}
teams <- data.frame(team_id = 1:3, team = c("A", "B", "C"), conf = "X")

test_that("a snapshot fits only games played before its date and predicts the next window", {
  inp <- prepare_input(toy_games(), as.Date("2025-11-12"), teams, NULL, model_config(), next_date = as.Date("2025-11-20"))
  expect_equal(inp$stan$N_games, 3)
  expect_equal(nrow(inp$upcoming), 2)
  expect_false(anyNA(unlist(inp$stan)))
})

test_that("a preseason snapshot has no games and still builds", {
  inp <- prepare_input(toy_games(), as.Date("2025-11-03"), teams, NULL, model_config())
  expect_equal(inp$stan$N_games, 0)
  expect_equal(inp$stan$N_states, 0)
  expect_equal(nrow(inp$tempo), 3)
})

test_that("the preseason prior blends our rating with Torvik's", {
  prev <- data.frame(team_id = 1:2, prev_dev = c(10, -10), prev_sd = 2)
  tv <- data.frame(team = c("A", "C"), adj_em = c(20, 0))      # centred: +10, -10
  p <- build_prior(prev, tv, teams, model_config(prior_torvik_weight = 0.5))
  expect_equal(p$prev_dev[p$team_id == 1], 10)
  expect_equal(p$prev_dev[p$team_id == 2], -10)                  # ours only
  expect_equal(p$prev_dev[p$team_id == 3], -10)                  # Torvik only
  expect_equal(p$prev_sd[p$team_id == 3], model_config()$prior_sd_default)
})

test_that("snapshot dates: opening night, Mondays, the day after the final", {
  g <- toy_games(); g$played <- TRUE
  d <- snapshot_dates(g, 2026, today = as.Date("2026-10-01"))
  expect_equal(d$kind[1], "preseason")
  expect_equal(d$kind[nrow(d)], "final")
  expect_true(all(is_monday(d$snap_date[d$kind == "weekly"])))
  expect_equal(d$snap_date[nrow(d)], max(g$game_date) + 1)
  expect_true(is.na(d$next_date[nrow(d)]))
  live <- snapshot_dates(g, 2026, today = as.Date("2025-10-20"))
  expect_equal(nrow(live), 1)
  expect_equal(live$kind, "preseason")
  expect_equal(nrow(limit_snaps(d, 2)), 2)
})

test_that("a stray game the day before opening night doesn't start the weekly snapshots", {
  # 2 games on Sunday 2026-11-01, the full slate on Monday 11-02
  g <- toy_games()[c(1, 1, rep(2, 20), 3), ]
  g$game_id <- seq_len(nrow(g)); g$played <- TRUE
  g$game_date <- as.Date(c("2026-11-01", "2026-11-01", rep("2026-11-02", 20), "2026-11-12"))
  d <- snapshot_dates(g, 2027, today = as.Date("2026-11-03"))
  expect_equal(d$snap_date, as.Date(c("2026-11-01", "2026-11-03")))
  expect_equal(d$kind, c("preseason", "live"))
  d <- snapshot_dates(g, 2027, today = as.Date("2026-11-10"))
  expect_equal(d$snap_date[d$kind == "weekly"], as.Date("2026-11-09"))
  expect_equal(d$next_date[1], as.Date("2026-11-09"))            # preseason covers opening week
})
