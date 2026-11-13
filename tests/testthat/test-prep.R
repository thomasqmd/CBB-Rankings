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

test_that("closing lines: the archive, then ESPN, then CBBD settle the side; CBBD keeps the size", {
  g <- data.frame(game_id = 1:8, season = 2026L,
                  site = c(0L, 0L, 0L, 1L, 1L, 0L, 0L, 1L), neutral_site = c(TRUE, TRUE, TRUE, FALSE, FALSE, TRUE, TRUE, FALSE),
                  cbbd_neutral = FALSE,
                  spread = c(12.5, -26.5, -9, -6, NA, 1, 7, -10),           # CBBD's median, home side
                  spread_abs = c(12.5, 26.5, 9, 6, NA, 1, 7, 10),
                  line_split = c(FALSE, TRUE, TRUE, FALSE, NA, TRUE, FALSE, TRUE),
                  total_line = c(140, 132.5, 150, 145, NA, 130, 135, 150))
  books <- data.frame(season = 2026L, family = "draftkings")
  odds <- data.frame(
    game_id   = c(1L, 2L, 5L, 5L, 7L),
    book      = c("DraftKings", "DraftKings", "Caesars", "MGM", "Bovada"),
    spread    = c(-11.5, 26.5, -7, -7.5, 7),
    home_fav  = c(TRUE, FALSE, TRUE, TRUE, FALSE),
    away_fav  = c(FALSE, TRUE, FALSE, FALSE, TRUE),
    total     = c(139, 132, 141, 142, 136))
  sbr <- data.frame(game_id = c(3L, 2L), sbr_side = c(-1, -1), sbr_spread = c(9, 26.5), sbr_total = c(151, 132.5))
  out <- resolve_lines(g, odds, sbr, books)
  # 1 Syracuse vs Drexel: every CBBD provider reversed, an accepted ESPN book has the home side
  #   favoured; ESPN's side, CBBD's size
  # 2 a reversed consensus among split providers: the archive's favourite (ESPN agrees), the median
  #   absolute size
  # 3 split, no accepted ESPN book: the archive's favourite
  # 4 non-neutral, providers agree: CBBD as it was
  # 5 no CBBD line, non-neutral: filled from ESPN (every book counts off a neutral court)
  # 6 split within a pick'em, nothing else: CBBD's median
  # 7 neutral, only a book-season not accepted: no side
  # 8 split providers, no other source: no side
  expect_equal(out$spread, c(-12.5, 26.5, 9, -6, -7.25, 1, NA, NA))
  expect_equal(out$spread_source, c("espn", "archive", "archive", "cbbd", "espn", "cbbd", NA, NA))
  expect_equal(out$line_filled, c(FALSE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE))
  expect_equal(out$total_line, c(140, 132.5, 150, 145, 141.5, 130, 135, 150))
  expect_false(any(c("spread_abs", "line_split") %in% names(out)))
})

test_that("archive games match on date and both scores, with a team name to confirm", {
  g <- data.frame(game_id = 1:3, game_date = as.Date(c("2017-11-23", "2017-11-23", "2017-11-24")),
                  home = c("Western Kentucky", "Elon", "Kansas City"), away = c("Purdue", "Towson", "Seattle U"),
                  home_score = c(77L, 70L, 66L), away_score = c(73L, 60L, 61L))
  sbr <- data.frame(date = as.Date(c("2017-11-23", "2017-11-23", "2017-11-23")),
                    team_a = c("WesternKentucky", "Duke", "UMKC"), team_b = c("Purdue", "Kansas", "SeattleU"),
                    pts_a = c(77L, 70L, 66L), pts_b = c(73L, 60L, 61L), fav_a = c(-1, 1, 1), spread = c(19, 5, 3), total = 140)
  out <- sbr_games(g, sbr)
  expect_equal(out$game_id, c(1L, 3L))               # Elon-Towson has the scores of Duke-Kansas, not its teams
  expect_equal(out$sbr_side, c(-1, 1))               # Purdue favoured; a day's late tip-off still matches
})

test_that("no model input carries the closing line", {
  g <- toy_games()
  g$total_line <- 140; g$spread_source <- "cbbd"; g$line_filled <- FALSE
  inp <- prepare_input(g, as.Date("2025-11-12"), teams, NULL, model_config())
  expect_gt(nrow(inp$games), 0)
  expect_false(any(LINE_COLS %in% names(inp$games)))
})

test_that("ESPN books are judged by family, and the live season borrows the last judged season's", {
  expect_equal(espn_book_family(c("Caesars Sportsbook (New Jersey)", "Caesar's", "BOVADA.lv", "ESPN BET")),
               c("caesars", "caesars", "bovada", "espnbet"))
  g <- data.frame(game_id = 1:2, season = c(2027L, 2027L), site = 0L, neutral_site = TRUE, cbbd_neutral = FALSE)
  odds <- data.frame(game_id = 1:2, book = c("DraftKings", "Bovada"), spread = c(-5, -5), home_fav = TRUE, away_fav = FALSE, total = 140)
  e <- espn_sides(odds, g, data.frame(season = 2026L, family = "draftkings"))
  expect_equal(e$espn_side, c(1, NA))
  expect_equal(e$espn_total, c(140, 140))
})

test_that("a stray ESPN book is outvoted; an even split is left unsettled", {
  g <- data.frame(game_id = 1:2, season = 2022L, site = 1L, neutral_site = FALSE, cbbd_neutral = FALSE)
  odds <- data.frame(game_id = c(1L, 1L, 1L, 2L, 2L), book = c("DraftKings", "MGM", "Unibet", "DraftKings", "MGM"),
                     spread = c(-3.5, -3.5, 1, -4, 4), home_fav = c(TRUE, TRUE, FALSE, TRUE, FALSE),
                     away_fav = c(FALSE, FALSE, TRUE, FALSE, TRUE), total = 140)
  e <- espn_sides(odds, g, data.frame(season = 2022L, family = "draftkings"))
  expect_equal(e$espn_side, c(1, NA))
  expect_equal(e$espn_abs, c(3.5, 4))
})

test_that("ESPN's zero-spread placeholder is no line; books around zero with a total are a pick'em", {
  g <- data.frame(game_id = 1:2, season = 2016L, site = 1L, neutral_site = FALSE, cbbd_neutral = FALSE)
  odds <- data.frame(game_id = c(1L, 2L, 2L, 2L), book = c("teamrankings", "BOVADA.lv", "Westgate", "Opening"),
                     spread = c(0, -1, 1, 0), home_fav = c(FALSE, TRUE, FALSE, FALSE), away_fav = c(FALSE, FALSE, TRUE, FALSE),
                     total = c(NA, 156, 155.5, 156.5))
  e <- espn_sides(odds, g, data.frame(season = 2016L, family = "bovada"))
  expect_equal(e$game_id, 2L)
  expect_equal(e$espn_side, 0)
})

test_that("an ESPN total of 0 or -1 is no total, and does not make a placeholder a pick'em", {
  g <- data.frame(game_id = 1:3, season = 2016L, site = 1L, neutral_site = FALSE, cbbd_neutral = FALSE)
  odds <- data.frame(game_id = c(1L, 1L, 2L, 3L), book = c("numberfire", "BOVADA.lv", "numberfire", "teamrankings"),
                     spread = c(10.5, 10.5, -8.5, 0), home_fav = c(FALSE, FALSE, TRUE, FALSE),
                     away_fav = c(TRUE, TRUE, FALSE, FALSE), total = c(0, 141, -1, 0))
  e <- espn_sides(odds, g, data.frame(season = 2016L, family = "bovada"))
  expect_equal(e$game_id, 1:2)
  expect_equal(e$espn_total, c(141, NA))
  expect_equal(e$espn_side, c(-1, 1))
})

test_that("where the archive and an accepted ESPN book disagree, the archive's favourite stands", {
  g <- data.frame(game_id = 1L, season = 2019L, site = 0L, neutral_site = TRUE, cbbd_neutral = FALSE,
                  spread = -17, spread_abs = 17, line_split = TRUE, total_line = 142.5)
  # Santa Clara (home) vs Minnesota, 2018-11-20: Minnesota favoured by 17
  odds <- data.frame(game_id = 1L, book = "Caesars", spread = -17, home_fav = TRUE, away_fav = FALSE, total = 142)
  sbr <- data.frame(game_id = 1L, sbr_side = -1, sbr_spread = 18, sbr_total = 142.5)
  out <- resolve_lines(g, odds, sbr, data.frame(season = 2019L, family = "caesars"))
  expect_equal(out$spread, 17)
  expect_equal(out$spread_source, "archive")
})
