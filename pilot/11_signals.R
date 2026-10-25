# ==============================================================================
# Phase 2-3 signal checks that need no refit (-> pilot/out/11_signals.md):
#   1. shot model calibration, out of sample, by family and season (the shot_calibration target)
#   2. possessions: play-by-play count vs the box-score estimate
#   3. semi-home edge: neutral-site games in one team's home state, from backtest residuals
#   4. non-D1 opponents: ESPN id stability across seasons
#   5. absences: rotation players missing (box scores) vs backtest residuals
#   Rscript pilot/11_signals.R       -> pilot/out/11_signals.rds
# ==============================================================================

suppressMessages({ library(targets); library(dplyr) })
tar_source("R")
SEASONS <- 2015:2026
out <- list()

# 1. Shot model calibration
out$shots <- tar_read(shot_calibration)
print(as.data.frame(tidyr::pivot_wider(out$shots[, c("season", "family", "diff")], names_from = family, values_from = diff)), digits = 2)

# 2. Possessions: possession changes in regulation (runs of `gain` by the same team, one per
#    half start) vs the box-score estimate, games without OT
out$poss <- bind_rows(lapply(c(2016, 2020, 2023, 2026), function(s) {
  p <- annotate_plays(read_plays(s))
  p <- p[p$elapsed <= 2400 & p$period_number <= 2 & !is.na(p$gain), ]
  g <- p |> group_by(game_id, period_number) |>
    summarise(runs = sum(gain != dplyr::lag(gain, default = -1L)), .groups = "drop") |>
    group_by(game_id) |> summarise(pbp_poss = (sum(runs) + 2) / 2, .groups = "drop")
  gm <- tar_read_raw(paste0("games_", s))
  g <- inner_join(g, gm[gm$played & !gm$ot, c("game_id", "poss")], by = "game_id")
  r <- g$pbp_poss / g$poss - 1
  data.frame(season = s, games = nrow(g), box = mean(g$poss), pbp = mean(g$pbp_poss), ratio = mean(g$pbp_poss) / mean(g$poss),
             med_abs_pct = median(abs(r)), within2 = mean(abs(r) < 0.02), cor = cor(g$pbp_poss, g$poss))
}))
print(out$poss, digits = 4)

# 3. Semi-home edge: a team's home state = the state of its most-used home venue
bt <- tar_read(backtest)$games
gs <- bind_rows(lapply(SEASONS, \(s) tar_read_raw(paste0("games_", s))[, c("season", "game_id", "state", "home_id", "away_id", "site")]))
hs <- gs[gs$site == 1 & !is.na(gs$state), ] |> count(season, team_id = home_id, state) |>
  arrange(season, team_id, desc(n)) |> distinct(season, team_id, .keep_all = TRUE)
b <- left_join(bt[bt$site == 0, ], gs[, c("season", "game_id", "state")], by = c("season", "game_id"))
b$h_state <- hs$state[match(paste(b$season, b$home_id), paste(hs$season, hs$team_id))]
b$a_state <- hs$state[match(paste(b$season, b$away_id), paste(hs$season, hs$team_id))]
b$tie <- ifelse(b$h_state == b$state & b$a_state != b$state, 1, ifelse(b$a_state == b$state & b$h_state != b$state, -1, 0))
b$res <- b$actual - b$pred_margin
out$semi <- b[!is.na(b$tie), ] |> mutate(o = ifelse(tie == 0, res, res * tie)) |>
  group_by(group = ifelse(tie == 0, "neither/both", "one team's home state"), postseason = season_type != "regular") |>
  summarise(n = n(), mean = mean(o), se = sd(o) / sqrt(n()), .groups = "drop")
print(out$semi)

# 4. Non-D1 ids
gall <- bind_rows(lapply(c(SEASONS[1] - 1, SEASONS), \(s) tar_read_raw(paste0("games_", s))))
nd <- gall[gall$division == "nond1", ]
x <- bind_rows(data.frame(season = nd$season, id = nd$home_id, name = nd$home, d1 = !is.na(nd$home_conf)),
               data.frame(season = nd$season, id = nd$away_id, name = nd$away, d1 = !is.na(nd$away_conf)))
x <- x[!x$d1, ]
u <- distinct(x, id, name)
out$nond1 <- data.frame(ids = n_distinct(u$id), missing_ids = sum(is.na(x$id)),
                        ids_multi_name = n_distinct(u$id[duplicated(u$id)]), names_multi_id = n_distinct(u$name[duplicated(u$name)]),
                        seen_2plus = sum(table(distinct(x, id, season)$id) >= 2))
print(out$nond1)

# 5. Absences (add_absences(): rotation players, >= ABSENCE_MPG over the last ABSENCE_WINDOW games, absent)
res <- list(); share <- c()
for (s in 2016:2026) {
  g <- add_absences(tar_read_raw(paste0("games_", s)), read_season(s)$player_box)
  bs <- bt[bt$season == s, ]; k <- match(bs$game_id, g$game_id)
  bs$dm <- g$home_missing[k] - g$away_missing[k]; res[[as.character(s)]] <- bs
  d1 <- g[g$played & g$division == "d1", ]; share[as.character(s)] <- mean(c(d1$home_missing, d1$away_missing) > 0)
}
b <- bind_rows(res); b$res <- b$actual - b$pred_margin
out$absences <- list(share = share, coef = summary(lm(res ~ dm, b))$coefficients)
print(out$absences)

saveRDS(out, "pilot/out/11_signals.rds")
