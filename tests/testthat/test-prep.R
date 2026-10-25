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

test_that("a neutral game on one team's floor is that team's home game", {
  floors <- data.frame(team_id = c(1L, 2L, 3L, 4L), venue_id = c(10L, 20L, 30L, 30L))
  g <- data.frame(home_id = c(1L, 1L, 1L, 1L, 5L, 3L, 1L), away_id = c(2L, 2L, 2L, 2L, 6L, 4L, 2L),
                  venue_id = c(10L, 99L, 20L, 20L, 10L, 30L, NA), neutral_site = c(TRUE, TRUE, TRUE, FALSE, TRUE, TRUE, FALSE))
  v <- venue_site(g, floors)
  expect_equal(v$site, c(1L, 0L, -1L, -1L, 0L, 0L, 1L))   # shared floor (3, 4) stays neutral
  expect_equal(v$site_note[c(1, 3, 4)], c("neutral, home team's floor", "neutral, away team's floor", "away team's floor"))
  expect_true(all(is.na(v$site_note[c(2, 5, 6, 7)])))
})

test_that("a floor needs FLOOR_MIN_GAMES non-neutral home games", {
  s <- data.frame(venue_id = c(10L, 10L, 11L, 12L, 12L), home_id = 1L, neutral_site = c(FALSE, FALSE, FALSE, TRUE, TRUE))
  expect_equal(team_floors(s)$venue_id, 10L)
})

test_that("summary-API games become schedule rows with box-score possessions", {
  x <- read_espn_summaries(test_path("fixtures", "summary_400853175.json"))
  expect_equal(x$game_id, 400853175L)
  expect_equal(x$game_date, as.Date("2015-11-20"))             # 00:30 UTC on the 21st is the 20th in the East
  expect_equal(c(x$home_id, x$away_id, x$home_score, x$away_score), c(2623L, 135L, 69L, 74L))
  expect_true(x$neutral_site)
  expect_equal(x$poss, mean(c(56 - 8 + 12 + 0.475 * 19, 54 - 13 + 11 + 0.475 * 37)))
})
