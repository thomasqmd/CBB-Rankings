# ==============================================================================
# Roster prior (Phase 4): features from Torvik's player tables, regression fit on earlier seasons
# only, compared with the blend prior (ours + Torvik) on the first weeks of each season: every D1
# game before the third Monday, predicted from the prior alone (+ home court).
#   Rscript pilot/13_roster_prior.R      -> pilot/out/roster_priors.rds, pilot/out/13_roster_prior.md
# ==============================================================================

suppressMessages({ library(targets); library(dplyr) })
tar_source("R")
SEASONS <- 2015:2026
snaps <- tar_read(snapshots)
cfg <- model_config(prior_method = "roster")

final_of <- function(s) {
  r <- snaps$ratings[snaps$ratings$season == s & snaps$ratings$kind == "final", ]
  data.frame(team_id = r$team_id, prev_dev = r$rating, prev_sd = r$sd)
}

priors <- list(); hist <- NULL; feats <- list()
for (s in SEASONS) {
  tm <- tar_read_raw(paste0("teams_", s))
  ro <- roster_features(s, tm, tar_read_raw(paste0("teams_", s - 1)))
  p <- build_prior(final_of(s - 1), tar_read_raw(paste0("data_", s))$torvik_pre, tm, cfg, roster = ro, history = hist)
  priors[[as.character(s)]] <- p
  f <- attr(p, "features"); fin <- final_of(s)
  f$final <- fin$prev_dev[match(f$team_id, fin$team_id)]
  feats[[as.character(s)]] <- f
  hist <- bind_rows(hist, f[!is.na(f$final), ])
  message(s, ": roster prior for ", attr(p, "sources")[["roster"]], " teams")
}
saveRDS(priors, "pilot/out/roster_priors.rds")

# Prior-only predictions of the first weeks' games
hca <- snaps$params$hca[snaps$params$kind == "final"]
ev <- bind_rows(lapply(SEASONS, function(s) {
  g <- tar_read_raw(paste0("games_", s)); g <- g[g$division == "d1" & g$played, ]
  opening <- min(g$game_date[g$season_type == "regular"])
  mon <- opening + 1:14; mon <- mon[format(mon, "%u") == "1"][2]
  g <- g[g$game_date < mon, ]
  old <- tar_read_raw(paste0("prior_", s)); new <- priors[[as.character(s)]]
  pr <- function(p) {
    d <- p$prev_dev[match(g$home_id, p$team_id)] - p$prev_dev[match(g$away_id, p$team_id)]
    (dplyr::coalesce(d, 0) + mean(hca) * game_site(g)) * g$poss / 100
  }
  data.frame(season = s, actual = g$home_score - g$away_score, blend = pr(old), roster = pr(new))
}))
tab <- ev |> group_by(season) |> summarise(games = n(), blend = mean(abs(actual - blend)), roster = mean(abs(actual - roster)), .groups = "drop")
tab <- bind_rows(tab, ev |> summarise(season = NA, games = n(), blend = mean(abs(actual - blend)), roster = mean(abs(actual - roster))))
print(tab, n = 20)
fit <- lm(reformulate(ROSTER_TERMS, "final"), bind_rows(feats))
print(summary(fit)$coefficients, digits = 3)
saveRDS(list(tab = tab, coef = summary(fit)$coefficients, feats = bind_rows(feats)), "pilot/out/roster_eval.rds")
