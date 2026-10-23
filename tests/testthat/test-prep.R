plays <- function() data.frame(
  game_id = 1L, game_play_number = 1:6, home_team_id = 10L, away_team_id = 20L,
  type_text = c("JumpShot", "Defensive Rebound", "MadeFreeThrow", "MadeFreeThrow", "LayUpShot", "Offensive Rebound"),
  txt = c("a misses jumper", "b defensive rebound", "c made free throw.", "c made free throw.", "d makes layup", "e offensive rebound"),
  team_id = c(10L, 20L, 20L, 20L, 10L, 10L), athlete_id_1 = 1:6,
  shooting_play = c(TRUE, FALSE, TRUE, TRUE, TRUE, FALSE), scoring_play = c(FALSE, FALSE, TRUE, TRUE, TRUE, FALSE),
  points_attempted = c(2, 0, 1, 1, 2, 0), x = NA_real_, y = NA_real_,
  home_score = c(0, 0, 0, 0, 2, 2), away_score = c(0, 0, 1, 2, 2, 2),
  elapsed = c(10, 12, 20, 20, 25, 30), period_number = 1L, game_date = as.Date("2025-11-03"))

test_that("only the last free throw of a trip hands over the ball (no '1 of 2' in the text)", {
  p <- annotate_plays(plays())
  expect_true(is.na(p$gain[3]))
  expect_equal(p$gain[4], 10L)
  expect_equal(p$poss_start[5], 20)             # home possession began at the second free throw
  expect_equal(shot_table(p)$transition, c(0L, 1L))
})

test_that("shot families are coarse and stable", {
  f <- shot_family(c("x makes 3-foot dunk", "x misses tip shot", "x driving layup", "x hook shot", "x step back jumpshot"),
                   c("DunkShot", "TipShot", "LayUpShot", "JumpShot", "JumpShot"))
  expect_equal(as.character(f), c("dunk", "tip", "layup", "hook", "jumper"))
  expect_equal(levels(f), SHOT_FAMILIES)
  # a player's name is not the shot
  g <- shot_family(c("aaron hooker made three point jumper.", "tyler tipton misses layup", "a made jumper. assisted by b hooker."),
                   c("Three Point Jump Shot", "LayUpShot", "JumpShot"))
  expect_equal(as.character(g), c("jumper", "layup", "jumper"))
})

test_that("FT% before a game uses only earlier attempts", {
  ft <- data.frame(game_id = c(1L, 1L, 2L), game_date = as.Date(c("2025-11-03", "2025-11-03", "2025-11-07")),
                   team_id = 10L, athlete_id = 7L, made = c(1L, 1L, 0L), excl = FALSE)
  r <- ft_rates_to_date(ft)
  lg <- 2 / 3
  expect_equal(r$ft_pct[1], lg)                                  # nothing before game 1
  expect_equal(r$ft_pct[3], (2 + FT_SHRINK * lg) / (2 + FT_SHRINK))
})
