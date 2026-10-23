# Pilot step 8: the numbers behind the dashboard sketch (Selection Sunday 2026 fit).
source("R/01_ingest.R"); source("R/02_prep.R"); source("R/03_model.R"); source("R/04_resume.R")
suppressMessages(library(dplyr))
games <- readRDS("data/derived/pilot_games.rds")$`2026`
w <- readRDS("data/derived/pilot_wab.rds"); fit <- readRDS("data/derived/pilot_fit_20260316.rds")
teams <- team_conferences(games)
pre <- games |> filter(game_date < as.Date("2026-03-16"))
rec <- bind_rows(transmute(pre, team_id = home_id, w = home_score > away_score), transmute(pre, team_id = away_id, w = away_score > home_score)) |>
  group_by(team_id) |> summarise(wins = sum(w), losses = sum(!w))
seeds <- games |> filter(ncaa) |> {\(g) bind_rows(transmute(g, team_id = home_id, seed = home_seed), transmute(g, team_id = away_id, seed = away_seed))}() |>
  group_by(team_id) |> summarise(seed = min(seed, na.rm = TRUE))
r <- fit$r; colnames(r) <- teams$team_id[order(teams$team_id)]
tid <- sort(teams$team_id)
pw <- data.frame(team_id = tid, pw = colMeans(r), pw_lo = apply(r, 2, quantile, .1), pw_hi = apply(r, 2, quantile, .9))
prk <- t(apply(-r, 1, rank, ties.method = "random"))
pw$prk <- round(colMeans(prk)); pw$prk_lo <- apply(prk, 2, quantile, .1); pw$prk_hi <- apply(prk, 2, quantile, .9)
pw$prk <- rank(-pw$pw, ties.method = "first")
inp <- list(teams = data.frame(team_id = tid))
# schedule strength: expected losses of the #45 team against each schedule
s <- w$summary |> select(team_id, team, conf, wab, wab_lo, wab_hi, wab_rank, wab_rank_lo, wab_rank_hi, auto_bid, p_at_large) |>
  left_join(pw, by = "team_id") |> left_join(rec, by = "team_id") |> left_join(seeds, by = "team_id") |>
  mutate(rrk = rank(-wab, ties.method = "first")) |> arrange(rrk)
s$in_field <- s$team_id %in% w$field
out <- s |> mutate(across(c(wab, wab_lo, wab_hi), \(x) round(x, 2)), across(c(pw, pw_lo, pw_hi), \(x) round(x, 1)),
                   p_at_large = round(p_at_large, 3), wab_rank_lo = round(wab_rank_lo), wab_rank_hi = round(wab_rank_hi))
jsonlite::write_json(head(out, 40) |> select(rrk, team, conf, wins, losses, wab, wab_lo, wab_hi, rrk_lo = wab_rank_lo, rrk_hi = wab_rank_hi,
                     p_al = p_at_large, auto = auto_bid, pw, pw_lo, pw_hi, prk, prk_lo, prk_hi, seed, in_field),
                     "pilot/out/dash_rankings.json", digits = NA, auto_unbox = TRUE)
# bubble: non-champions ranked 30-48 by WAB
bub <- out |> filter(!auto_bid) |> mutate(al = row_number()) |> filter(al >= 29, al <= 46) |> select(al, team, conf, wins, losses, wab, p_al = p_at_large, prk, seed, in_field)
jsonlite::write_json(bub, "pilot/out/dash_bubble.json", digits = NA, auto_unbox = TRUE)
cat("hca:", round(mean(fit$par$hca), 2), " teams:", nrow(s), " games through 3/15:", nrow(pre), "\n")
# matchup Duke v Michigan, neutral
id <- function(n) teams$team_id[teams$team == n][1]
mu <- r[, as.character(id("Duke"))] - r[, as.character(id("Michigan"))]
tp <- team_tempo(pre, teams, model_config()); lg <- attr(tp, "league")
poss <- tp$tempo[tp$team_id == id("Duke")] + tp$tempo[tp$team_id == id("Michigan")] - lg
sc <- fit$par$sigma_game / sqrt(poss / 70)
cat("Duke v Michigan neutral: spread", round(mean(mu) * poss / 100, 1), "P(Duke)", round(mean(pt(mu / sc, fit$par$nu)), 3), "poss", round(poss, 1), "\n")
# team page: Texas (last at-large in WAB order) game log with WAB contribution per game and quadrant
team <- "Texas"; t_id <- id(team)
rb <- apply(r, 1, \(x) sort(x, decreasing = TRUE)[45])
tg <- pre |> filter(home_id == t_id | away_id == t_id) |> arrange(game_date) |>
  mutate(is_home = home_id == t_id, opp_id = ifelse(is_home, away_id, home_id), opp = ifelse(is_home, away, home),
         site = ifelse(neutral == 1, "N", ifelse(is_home, "H", "A")), venue = ifelse(neutral == 1, 0, ifelse(is_home, 1, -1)),
         pf = ifelse(is_home, home_score, away_score), pa = ifelse(is_home, away_score, home_score), win = pf > pa)
pb <- sapply(seq_len(nrow(tg)), \(k) { m <- rb - r[, as.character(tg$opp_id[k])] + fit$par$hca * tg$venue[k]
  mean(pt(m / (fit$par$sigma_game / sqrt(tg$poss_reg[k] / 70)), fit$par$nu)) })
tg$p_bubble <- round(pb, 2); tg$wab_g <- round(tg$win - pb, 2)
tg$opp_prk <- pw$prk[match(tg$opp_id, pw$team_id)]
tg$quad <- with(tg, ifelse((site == "H" & opp_prk <= 30) | (site == "N" & opp_prk <= 50) | (site == "A" & opp_prk <= 75), 1,
                     ifelse((site == "H" & opp_prk <= 75) | (site == "N" & opp_prk <= 100) | (site == "A" & opp_prk <= 135), 2,
                     ifelse((site == "H" & opp_prk <= 160) | (site == "N" & opp_prk <= 200) | (site == "A" & opp_prk <= 240), 3, 4))))
jsonlite::write_json(tg |> transmute(date = format(game_date, "%b %d"), site, opp, opp_prk, quad, res = ifelse(win, "W", "L"), score = paste0(pf, "–", pa), p_bubble, wab_g),
                     "pilot/out/dash_team.json", digits = NA, auto_unbox = TRUE)
print(table(tg$quad, tg$win))
# games: one Saturday slate from the backtest (lux_dynamic), biggest games by combined power
bt <- bind_rows(lapply(readRDS("data/derived/pilot_backtest.rds"), `[[`, "pred")) |> filter(variant == "lux_dynamic", game_date == as.Date("2026-02-07"), !is.na(spread))
bt <- bt |> mutate(hp = pw$prk[match(home_id, pw$team_id)], ap = pw$prk[match(away_id, pw$team_id)]) |> arrange(pmin(hp, ap) + pmax(hp, ap)) |> head(12)
jsonlite::write_json(bt |> transmute(away, home, hp, ap, model = round(pred_margin, 1), line = -spread, p_home = round(p_home, 2), final = paste0(away_score, "–", home_score), actual = home_score - away_score),
                     "pilot/out/dash_games.json", digits = NA, auto_unbox = TRUE)
cat("slate games:", nrow(bt), "\n")
