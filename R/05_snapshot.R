# ==============================================================================
# Snapshots: when to fit, what each fit keeps, and the backtest over all of them.
#
# A season's snapshot dates: opening night (preseason, prior only), then every Monday, then the
# day after the title game (the final ratings, which seed next season's prior). In a live season
# the last snapshot is today. Each snapshot predicts the D1 games until the next one.
# Fits keep summaries, not draws.
# ==============================================================================

is_monday <- function(d) as.POSIXlt(d)$wday == 1

# Selection Monday: the day after the Sunday before the first NCAA tournament game
selection_monday <- function(games) {
  first <- suppressWarnings(min(games$game_date[games$ncaa]))
  if (!is.finite(first)) return(as.Date(NA))
  d <- first - 1
  while (as.POSIXlt(d)$wday != 0) d <- d - 1
  d + 1
}

snapshot_dates <- function(games, season, today = Sys.Date(), cfg = model_config(), preseason = TRUE, final_only = FALSE) {
  d1 <- games[games$division == "d1", ]
  played <- d1$game_date[d1$played]
  opening <- min(d1$game_date[d1$season_type == "regular"])
  live <- !season_final(season, today)
  if (live && today <= opening) return(data.frame(snap_date = opening, next_date = opening + cfg$snap_every, kind = "preseason"))
  end <- if (live) min(today, max(d1$game_date) + 1) else max(played) + 1
  if (final_only) return(data.frame(snap_date = end, next_date = as.Date(NA), kind = "final"))
  mondays <- seq(opening + 1, end, by = "day")
  mondays <- mondays[is_monday(mondays)]
  mondays <- mondays[seq(1, length(mondays), by = max(1, cfg$snap_every %/% 7))]
  dates <- sort(unique(c(if (preseason) opening, mondays, if (end > opening) end)))
  sel <- selection_monday(d1)
  kind <- ifelse(dates == opening, "preseason", ifelse(dates == end, if (live) "live" else "final", "weekly"))
  kind[!is.na(sel) & dates == sel & kind == "weekly"] <- "selection"
  nxt <- c(dates[-1], if (live) end + cfg$snap_every else as.Date(NA))
  data.frame(snap_date = dates, next_date = nxt, kind = kind)
}

# One snapshot: fit, then the tables the dashboard and backtest read
run_snapshot <- function(inp, season, kind = "weekly", cfg = model_config()) {
  fit <- fit_snapshot(inp, cfg)
  tag <- function(df) if (is.null(df) || !nrow(df)) NULL else data.frame(season = as.integer(season), snap_date = inp$snap_date, kind = kind, df)
  ratings <- summarise_ratings(fit, inp)
  resume <- if (nrow(inp$games)) {
    w <- wab_draws(fit, inp, bubble = bubble_rank(season, cfg))
    dplyr::left_join(ratings[, c("team_id", "team", "conf")], summarise_resume(w, inp), by = "team_id")
  }
  preds <- if (nrow(inp$upcoming)) {
    keep <- c("game_id", "game_date", "home_id", "away_id", "home", "away", "neutral", "season_type", "tournament",
              "played", "home_score", "away_score", "spread", "total_line")
    pr <- predict_games(fit, inp, inp$upcoming)
    pr[, c(intersect(keep, names(pr)), "pred_margin", "pred_poss", "p_home")]
  }
  list(
    ratings = tag(ratings), resume = tag(resume), predictions = tag(preds),
    params = tag(data.frame(t(colMeans(fit$par)), n_games = nrow(inp$games), n_nd = inp$stan$N_nd, secs = fit$secs)),
    gates = tag(data.frame(t(fit$gates), worst = fit$worst$variable[1],
                           pass = fit$gates[["max_rhat"]] <= 1.01 && fit$gates[["min_ess"]] >= 400 &&
                                  fit$gates[["divergences"]] == 0 && fit$gates[["min_ebfmi"]] > 0.2))
  )
}

combine_snapshots <- function(...) {
  snaps <- unlist(list(...), recursive = FALSE)
  pick <- function(nm) dplyr::bind_rows(lapply(snaps, `[[`, nm))
  list(ratings = pick("ratings"), resume = pick("resume"), predictions = pick("predictions"),
       params = pick("params"), gates = pick("gates"))
}

# Next season's carry-over: the season's last snapshot
season_final_prior <- function(snaps) {
  r <- snaps[[length(snaps)]]$ratings
  data.frame(team_id = r$team_id, prev_dev = r$rating, prev_sd = r$sd)
}

# Every prediction of a completed game, scored against the result and the closing line
run_backtest <- function(predictions) {
  p <- predictions[predictions$played %in% TRUE, ]
  p$actual <- p$home_score - p$away_score
  p$line <- -p$spread
  p$home_win <- as.integer(p$actual > 0)
  p$period <- ifelse(as.integer(format(p$game_date, "%m")) %in% c(11, 12), "Nov-Dec", "Jan-Apr")
  score <- function(d) d |> dplyr::summarise(
    games = dplyr::n(), with_line = sum(!is.na(line)),
    mae = mean(abs(actual - pred_margin)), rmse = sqrt(mean((actual - pred_margin)^2)),
    mae_line = mean(abs(actual - line), na.rm = TRUE),
    mae_on_lined = mean(abs(actual - pred_margin)[!is.na(line)]),
    ats = mean((sign(actual - line) == sign(pred_margin - line))[!is.na(line) & actual != line & pred_margin != line]),
    brier = mean((p_home - home_win)^2),
    logloss = -mean(home_win * log(p_home) + (1 - home_win) * log(1 - p_home)),
    .groups = "drop")
  list(games = p,
       overall = score(p),
       by_season = score(dplyr::group_by(p, season)),
       by_period = score(dplyr::group_by(p, season, period)))
}

# Development: keep opening night plus the last n - 1 dates (n = 0 keeps all)
limit_snaps <- function(dates, n) {
  if (n <= 0 || nrow(dates) <= n) return(dates)
  d <- dates[c(1, (nrow(dates) - n + 2):nrow(dates)), ]
  d$next_date[1] <- d$snap_date[2]
  d
}

# One branch's Stan input (dates is a one-row slice of snapshot_dates())
snapshot_input <- function(games, dates, teams, prior, cfg = model_config()) {
  inp <- prepare_input(games, dates$snap_date, teams, prior, cfg,
                       next_date = if (is.na(dates$next_date)) NULL else dates$next_date)
  inp$kind <- dates$kind
  inp
}

# Per-season data coverage: games, how many the model can use, lines, the efficiency signal,
# preseason prior sources
coverage_report <- function(games, priors, teams) {
  do.call(rbind, lapply(names(games), function(s) {
    g <- games[[s]]; d1 <- g[g$division == "d1", ]
    src <- attr(priors[[s]], "sources")
    data.frame(season = as.integer(s), d1_teams = nrow(teams[[s]]),
               d1_games = nrow(d1), d1_played = sum(d1$played), nond1_played = sum(g$played[g$division == "nond1"]),
               eff_share = mean(d1$has_eff[d1$played]), line_share = mean(!is.na(d1$spread[d1$played])),
               ot = sum(d1$ot[d1$played]), neutral = sum(d1$neutral[d1$played] == 1),
               neutral_disagree = sum((d1$neutral == 1) != d1$cbbd_neutral, na.rm = TRUE),
               prior_own = src[["own"]], prior_torvik = src[["torvik"]])
  }))
}
