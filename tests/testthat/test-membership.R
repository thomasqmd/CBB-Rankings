test_that("D1 teams take CBBD conference names and eligibility from the transitions table", {
  f <- withr::local_tempfile(fileext = ".json")
  jsonlite::write_json(data.frame(espn_conf_id = c(46L, 46L, 46L, 5L), espn_conf = c("Atlantic Sun", "Atlantic Sun", "Atlantic Sun", "Big Ten"),
                                  team_id = c(91L, 2L, 3L, 4L)), f)
  gc <- data.frame(team_id = c(91L, 2L), team = c("Bellarmine", "B"), conf = c("ASUN", "ASUN"))
  tr <- data.frame(team_id = 91L, first_d1 = 2021L, first_eligible = 2025L)
  t <- d1_teams_table(2022, f, gc[, 1:2], gc, tr)
  expect_equal(t$conf, c("ASUN", "ASUN", "ASUN", "Big Ten"))   # team 3 by its conference's vote, team 4 by ESPN's name
  expect_equal(t$eligible, c(FALSE, TRUE, TRUE, TRUE))
  expect_true(d1_teams_table(2025, f, gc[, 1:2], gc, tr)$eligible[1])
})

test_that("season teams: listed teams without games drop out of a final season, not a live one", {
  d1 <- data.frame(team_id = 1:4, team = c("A", "B", "C", "D"), conf = "X", eligible = c(TRUE, TRUE, TRUE, FALSE))
  g <- data.frame(home_id = c(1L, 2L), away_id = c(2L, 4L), home = c("A", "B"), away = c("B", "D"),
                  home_conf = "X", away_conf = "X", division = "d1")
  expect_equal(season_teams(d1, g)$team_id, c(1L, 2L, 4L))
  expect_equal(season_teams(d1, g, live = TRUE)$team_id, 1:4)
  g2 <- rbind(g, data.frame(home_id = 9L, away_id = 1L, home = "Z", away = "A", home_conf = "Y", away_conf = "X", division = "d1"))
  expect_warning(t <- season_teams(d1, g2), "not on ESPN's D1 list")
  expect_true(9L %in% t$team_id)
})

test_that("an ineligible champion leaves the automatic bid to the eligible standings leader", {
  teams <- data.frame(team_id = 1:3, team = c("A", "B", "C"), conf = "X", eligible = c(FALSE, TRUE, TRUE))
  g <- data.frame(home_id = c(1L, 2L, 1L), away_id = c(2L, 3L, 3L), home_conf = "X", away_conf = "X",
                  game_type = NA, season_type = "regular", home_score = c(70, 70, 70), away_score = c(60, 60, 60))
  inp <- list(teams = teams, games = g, snap_date = as.Date("2026-03-20"))
  r <- matrix(c(5, 0, -5), nrow = 2, ncol = 3, byrow = TRUE)
  par <- data.frame(hca = c(4, 4), sigma_game = c(15, 15), nu = c(20, 20))
  sim <- season_sim(r, par, inp, champs = data.frame(team_id = 1L, game_date = as.Date("2026-03-14")))
  expect_equal(which(sim$auto[1, ]), 2L)
})

test_that("conference tournaments: brackets give byes to top seeds, the winner takes the bid", {
  expect_equal(bracket_order(8), c(1L, 8L, 4L, 5L, 2L, 7L, 3L, 6L))
  teams <- data.frame(team_id = 1:5, team = LETTERS[1:5], conf = "X", eligible = TRUE)
  inp <- list(teams = teams, games = data.frame(home_id = integer(), away_id = integer(), home_conf = character(), away_conf = character(),
                                                game_type = character(), season_type = character(), home_score = numeric(), away_score = numeric()),
              snap_date = as.Date("2026-03-01"))
  r <- matrix(c(40, 0, 0, 0, 0), nrow = 200, ncol = 5, byrow = TRUE)     # team 1 far better
  par <- data.frame(hca = rep(4, 200), sigma_game = rep(10, 200), nu = rep(20, 200))
  sim <- season_sim(r, par, inp, tourney = data.frame(conf = "X", size = 4L))
  expect_true(all(rowSums(sim$auto) == 1))
  expect_gt(mean(sim$auto[, 1]), 0.95)
  expect_equal(nrow(sim$tourney), 200 * 3)                               # 4 teams: 3 games per draw
  sim0 <- season_sim(r, par, inp, tourney = data.frame(conf = "X", size = 0L))   # no tournament: leader
  expect_true(all(sim0$auto[, 1]))
})

test_that("Colley ratings average 1/2 and order a round robin by wins", {
  ti <- c(1L, 2L, 1L, 3L, 2L, 3L); oi <- c(2L, 1L, 3L, 1L, 3L, 2L); win <- c(TRUE, FALSE, TRUE, FALSE, TRUE, FALSE)
  cr <- colley(ti, oi, win, 3)
  expect_equal(mean(cr), 0.5)
  expect_true(cr[1] > cr[2] && cr[2] > cr[3])
})

test_that("injury reports parse to one row per player", {
  x <- read_espn_injuries(test_path("fixtures", "injuries_20261024.json"))
  expect_equal(nrow(x), 1)
  expect_equal(x$report_date, as.Date("2026-10-24"))
  expect_equal(x$athlete_id, 4712863L)
  expect_equal(x$status, "Out")
  expect_equal(x$return_date, as.Date("2026-11-20"))
  expect_equal(nrow(read_espn_injuries(character())), 0)
})
