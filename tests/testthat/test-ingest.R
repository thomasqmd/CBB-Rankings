test_that("season numbering follows the spring year", {
  expect_equal(current_cbb_season(as.Date("2026-10-23")), 2027L)
  expect_equal(current_cbb_season(as.Date("2026-03-15")), 2026L)
  expect_equal(season_label(2026), "2025-26")
  expect_false(season_final(2027, as.Date("2026-11-10")))
  expect_true(season_final(2026, as.Date("2026-10-23")))
})

test_that("CBBD windows tile the season without gaps", {
  w <- cbbd_windows(2026)
  expect_equal(nrow(w), 4)
  expect_equal(w$end[-4], w$start[-1])
  expect_equal(w$start[1], as.Date("2025-10-01"))
})

test_that("team names normalise and Torvik overrides win", {
  expect_equal(name_key("Michigan St."), "michigan state")
  expect_equal(name_key("Texas A&M"), "texas a and m")
  teams <- data.frame(team_id = c(41L, 127L, 152L), team = c("UConn", "Michigan State", "NC State"))
  tv <- data.frame(team = c("Connecticut", "Michigan St.", "N.C. State", "Nowhere"), adj_em = 1:4)
  m <- torvik_team_ids(tv, teams, overrides = file.path("..", "..", "data", "torvik_names.csv"))
  expect_equal(sort(m$team_id), c(41L, 127L, 152L))
})

test_that("CBBD lines: mixed-sign providers keep their size and are flagged as split", {
  p <- function(spread, hml, aml, ou = 132.5) list(spread = spread, overUnder = ou, homeMoneyline = hml, awayMoneyline = aml)
  rec <- function(id, ...) list(gameId = id, homeTeamId = 206L, awayTeamId = 295L, lines = list(...))
  l <- list(
    # Northern Arizona (home) vs Texas, neutral, 2022-11-21: ESPN BET had Texas -26 (the home
    # side +26, moneyline +2000); consensus' spread and teamrankings' both fields came reversed
    rec(13082L, p(26, 2000, -6000), p(-26.5, 2033, -9231), p(-26.5, -3525, 1573)),
    rec(2L, p(-7, -300, 240), p(-7.5, -320, 250)),                    # agreeing providers
    rec(3L, p(-1, -115, -105), p(1, -105, -115)),                     # a pick'em the books split on
    rec(4L, p(NULL, NULL, NULL, NULL)),                               # no numbers
    rec(5L, p(-12, 900, -1500))                                       # one provider at odds with itself
  )
  out <- cbbd_lines(2023, l)
  expect_equal(out$cbbd_id, c(13082L, 2:5))
  expect_equal(out$spread, c(-26.5, -7.25, 0, NA, -12))
  expect_equal(out$spread_abs, c(26.5, 7.25, 1, NA, 12))
  expect_equal(out$line_split, c(TRUE, FALSE, TRUE, FALSE, TRUE))
  expect_equal(out$total_line, c(132.5, 132.5, 132.5, NA, 132.5))
  expect_equal(nrow(cbbd_lines(2023, list())), 0)
})

test_that("the odds archive names the favourite by row, whatever the sign or a pick'em", {
  x <- data.frame(Date = c("1123", "1123", "222", "222", "301", "301"), Rot = c("713", "714", "729", "730", "801", "802"),
                  Team = c("WesternKentucky", "Purdue", "Florida", "Kentucky", "Iona", "Siena"),
                  Final = c("77", "73", "59", "65", "70", "68"), Close = c("148", "19", "136.5", "-4.5", "pk", "140"))
  out <- parse_sbr(x, 2018)
  expect_equal(out$date, as.Date(c("2017-11-23", "2018-02-22", "2018-03-01")))
  expect_equal(out$fav_a, c(-1, -1, 0))
  expect_equal(out$spread, c(19, 4.5, 0))
  expect_equal(out$total, c(148, 136.5, 140))
})

test_that("a season replaces its rows, and an empty table is fine", {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  db_replace_season(con, "t", data.frame(x = 1:2), 2015)
  db_replace_season(con, "t", data.frame(x = 3L), 2016)
  db_replace_season(con, "t", data.frame(x = integer()), 2015)
  expect_equal(DBI::dbGetQuery(con, "SELECT season, x FROM t")$season, 2016L)
})

test_that("a season with new columns rewrites the table", {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  db_replace_season(con, "t", data.frame(x = 1:2), 2015)
  db_replace_season(con, "t", data.frame(x = 3L, y = "a"), 2016)
  out <- DBI::dbGetQuery(con, "SELECT season, x, y FROM t ORDER BY x")
  expect_equal(out$season, c(2015L, 2015L, 2016L))
  expect_equal(out$y, c(NA, NA, "a"))
})
