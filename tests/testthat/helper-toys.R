# Toy season shared by the model and analysis tests
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
