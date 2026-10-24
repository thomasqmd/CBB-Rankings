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
  bench_rank <- NA_real_
  resume <- if (nrow(inp$games)) {
    w <- wab_draws(fit, inp, field = field_size(season, cfg), champs = inp$champs)
    bench_rank <- mean(attr(w, "bench_rank"))
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
    params = tag(data.frame(t(colMeans(fit$par)), bench_rank = bench_rank, n_games = nrow(inp$games), n_nd = inp$stan$N_nd, secs = fit$secs)),
    gates = tag(data.frame(t(fit$gates), worst = fit$worst$variable[1],
                           pass = fit$gates[["max_rhat"]] <= 1.01 && fit$gates[["min_ess"]] >= 400 &&
                                  fit$gates[["divergences"]] == 0 && fit$gates[["min_ebfmi"]] > 0.2))
  )
}

combine_snapshots <- function(..., polls = NULL) {
  snaps <- unlist(list(...), recursive = FALSE)
  pick <- function(nm) dplyr::bind_rows(lapply(snaps, `[[`, nm))
  list(ratings = pick("ratings"), resume = pick("resume"), predictions = pick("predictions"),
       params = pick("params"), gates = pick("gates"), polls = polls)
}

# Each poll release goes to the snapshot on or just before its date (preseason polls, released
# before opening night, to the first snapshot); when several releases of one poll land on a
# snapshot, the latest is kept
match_polls <- function(polls, dates) {
  if (is.null(polls) || !nrow(polls)) return(NULL)
  snaps <- sort(dates$snap_date)
  i <- findInterval(as.numeric(polls$poll_date), as.numeric(snaps))
  polls$snap_date <- snaps[pmax(i, 1L)]
  latest <- stats::ave(as.numeric(polls$poll_date), polls$snap_date, polls$poll, FUN = max)
  out <- polls[as.numeric(polls$poll_date) == latest, ]
  out[, c("season", "snap_date", setdiff(names(out), c("season", "snap_date")))]
}

# Next season's carry-over: the season's last snapshot
season_final_prior <- function(snaps) {
  r <- snaps[[length(snaps)]]$ratings
  data.frame(team_id = r$team_id, prev_dev = r$rating, prev_sd = r$sd)
}

# Torvik's ratings at each snapshot: the time-machine file for the day before (so he has the
# same games the snapshot has), Torvik names -> ESPN ids. lg_o / lg_t: D1 averages in that file.
torvik_snapshots <- function(dates, teams, season, overrides = "data/torvik_names.csv") {
  dplyr::bind_rows(lapply(dates$snap_date, function(d) {
    f <- fetch_torvik_tm(d - 1)
    if (is.na(f)) return(NULL)
    tv <- read_torvik_tm(f)
    lg_o <- mean(tv$adj_o); lg_t <- mean(tv$adj_t)
    tv <- torvik_team_ids(tv, teams, overrides)
    data.frame(season = as.integer(season), snap_date = d, team_id = tv$team_id, adj_o = tv$adj_o, adj_d = tv$adj_d,
               adj_t = tv$adj_t, lg_o = lg_o, lg_t = lg_t)
  }))
}

# Torvik's neutral-court margin (home perspective, points): tempo = t_h t_a / avg, each side's
# points per 100 = own offence x opponent defence / avg
torvik_margin <- function(p, tv) {
  k <- function(id) match(paste(p$season, p$snap_date, id), paste(tv$season, tv$snap_date, tv$team_id))
  h <- tv[k(p$home_id), ]; a <- tv[k(p$away_id), ]
  (h$adj_o * a$adj_d - a$adj_o * h$adj_d) / h$lg_o * (h$adj_t * a$adj_t / h$lg_t) / 100
}

# Every prediction of a completed game, scored against the result and the closing line, and
# against Torvik's ratings at the same snapshot. Torvik's home court and margin sd come from
# earlier seasons only (none for the first season, which is left out of the comparison).
run_backtest <- function(predictions, torvik = NULL) {
  p <- predictions[predictions$played %in% TRUE, ]
  p$actual <- p$home_score - p$away_score
  p$line <- -p$spread
  p$home_win <- as.integer(p$actual > 0)
  p$period <- ifelse(as.integer(format(p$game_date, "%m")) %in% c(11, 12), "Nov-Dec", "Jan-Apr")
  p$pred_torvik <- p$p_torvik <- NA_real_
  if (!is.null(torvik) && nrow(torvik)) {
    raw <- torvik_margin(p, torvik)
    home <- 1 - p$neutral
    for (s in sort(unique(p$season))) {
      past <- p$season < s & !is.na(raw)
      if (!any(past)) next
      hca <- mean((p$actual - raw)[past & home == 1])
      sd_m <- stats::sd((p$actual - raw - hca * home)[past])
      now <- p$season == s
      p$pred_torvik[now] <- raw[now] + hca * home[now]
      p$p_torvik[now] <- stats::pnorm(p$pred_torvik[now] / sd_m)
    }
  }
  ll <- function(p_, y) -mean(y * log(p_) + (1 - y) * log(1 - p_))
  score <- function(d) d |> dplyr::summarise(
    games = dplyr::n(), with_line = sum(!is.na(line)),
    mae = mean(abs(actual - pred_margin)), rmse = sqrt(mean((actual - pred_margin)^2)),
    mae_line = mean(abs(actual - line), na.rm = TRUE),
    mae_on_lined = mean(abs(actual - pred_margin)[!is.na(line)]),
    ats = mean((sign(actual - line) == sign(pred_margin - line))[!is.na(line) & actual != line & pred_margin != line]),
    brier = mean((p_home - home_win)^2),
    logloss = ll(p_home, home_win),
    .groups = "drop")
  # Head to head on the games all three predicted (model, Torvik, closing line)
  vs <- function(d) d |> dplyr::filter(!is.na(pred_torvik), !is.na(line)) |> dplyr::summarise(
    games = dplyr::n(),
    mae = mean(abs(actual - pred_margin)), mae_torvik = mean(abs(actual - pred_torvik)), mae_line = mean(abs(actual - line)),
    rmse = sqrt(mean((actual - pred_margin)^2)), rmse_torvik = sqrt(mean((actual - pred_torvik)^2)),
    rmse_line = sqrt(mean((actual - line)^2)),
    logloss = ll(p_home, home_win), logloss_torvik = ll(p_torvik, home_win),
    closer_than_torvik = mean((abs(actual - pred_margin) < abs(actual - pred_torvik))[pred_margin != pred_torvik]),
    .groups = "drop")
  list(games = p,
       overall = score(p),
       by_season = score(dplyr::group_by(p, season)),
       by_period = score(dplyr::group_by(p, season, period)),
       vs_overall = vs(p),
       vs_period = vs(dplyr::group_by(p, period)),
       vs_season = vs(dplyr::group_by(p, season)))
}

# Development: keep opening night plus the last n - 1 dates (n = 0 keeps all)
limit_snaps <- function(dates, n) {
  if (n <= 0 || nrow(dates) <= n) return(dates)
  d <- dates[c(1, (nrow(dates) - n + 2):nrow(dates)), ]
  d$next_date[1] <- d$snap_date[2]
  d
}

# One branch's Stan input (dates is a one-row slice of snapshot_dates()); champs = the season's
# conference champions (champions table), for the resume benchmark's automatic bids
snapshot_input <- function(games, dates, teams, prior, cfg = model_config(), champs = NULL) {
  inp <- prepare_input(games, dates$snap_date, teams, prior, cfg,
                       next_date = if (is.na(dates$next_date)) NULL else dates$next_date)
  inp$kind <- dates$kind
  inp$champs <- champs
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
