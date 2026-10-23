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

test_that("a season replaces its rows, and an empty table is fine", {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  db_replace_season(con, "t", data.frame(x = 1:2), 2015)
  db_replace_season(con, "t", data.frame(x = 3L), 2016)
  db_replace_season(con, "t", data.frame(x = integer()), 2015)
  expect_equal(DBI::dbGetQuery(con, "SELECT season, x FROM t")$season, 2016L)
})
