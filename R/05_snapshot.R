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
  # Weekly snapshots start after the first full slate, not after a stray early game: 2026-27 had
  # 2 games on Sunday 11-01 before the 119-game opening night on Monday 11-02, which made 11-02 a
  # weekly fit on 2 games. Every earlier season opens with its full slate (80-126 games).
  n_day <- table(d1$game_date[d1$season_type == "regular"])
  slate <- as.Date(names(n_day)[n_day >= 20][1])
  if (is.na(slate)) slate <- opening
  mondays <- seq(slate + 1, max(slate + 1, end), by = "day")
  mondays <- mondays[is_monday(mondays) & mondays <= end]
  every <- max(1, cfg$snap_every %/% 7)
  mondays <- mondays[(seq_along(mondays) - 1) %% every == 0]
  dates <- sort(unique(c(if (preseason) opening, mondays, if (end > opening) end)))
  sel <- selection_monday(d1)
  kind <- ifelse(dates == opening, "preseason", ifelse(dates == end, if (live) "live" else "final", "weekly"))
  kind[!is.na(sel) & dates == sel & kind == "weekly"] <- "selection"
  # each snapshot predicts until the next fixed one (a Monday); in a live season the last Monday
  # predicts its week and today's snapshot the week from today, so neither input moves day to day
  fixed <- dates[kind != "live"]
  nxt <- vapply(seq_along(dates), function(i) {
    later <- fixed[fixed > dates[i]]
    if (length(later)) later[1] else if (live) dates[i] + cfg$snap_every else NA_real_
  }, numeric(1))
  data.frame(snap_date = dates, next_date = as.Date(nxt), kind = kind)
}

# One snapshot: fit, then the tables the dashboard and backtest read
run_snapshot <- function(inp, season, kind = "weekly", cfg = model_config()) {
  fit <- fit_snapshot(inp, cfg)
  tag <- function(df) if (is.null(df) || !nrow(df)) NULL else data.frame(season = as.integer(season), snap_date = inp$snap_date, kind = kind, df)
  ratings <- summarise_ratings(fit, inp)
  bench_rank <- NA_real_
  resume <- if (nrow(inp$games)) {
    w <- wab_draws(fit, inp, field = field_size(season, cfg), champs = inp$champs, tourney = inp$tourney)
    bench_rank <- mean(attr(w, "bench_rank"))
    ratings[, c("team_id", "team", "conf")] |>
      dplyr::left_join(summarise_resume(w, inp), by = "team_id") |>
      dplyr::left_join(team_sheet(fit, inp, ratings), by = "team_id")
  }
  preds <- if (nrow(inp$upcoming)) {
    keep <- c("game_id", "game_date", "home_id", "away_id", "home", "away", "neutral", "site", "season_type", "tournament")
    pr <- predict_games(fit, inp, inp$upcoming)
    pr[, c(intersect(keep, names(pr)), "pred_margin", "pred_poss", "pred_total", "p_home")]
  }
  list(
    ratings = tag(ratings), resume = tag(resume), predictions = tag(preds),
    params = tag(data.frame(t(colMeans(fit$par)), bench_rank = bench_rank, mu_p = inp$tempo$mu_p[1], mu_t = inp$tempo$mu_t[1],
                            n_games = nrow(inp$games), n_nd = inp$stan$N_nd, secs = fit$secs)),
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

# Every snapshot carries each poll's latest release on or before its date, so a poll stays on
# the snapshots after it until the next release (preseason polls, released before opening night,
# also go to any snapshot before them)
match_polls <- function(polls, dates) {
  if (is.null(polls) || !nrow(polls)) return(NULL)
  snaps <- sort(unique(dates$snap_date))
  out <- do.call(rbind, lapply(split(polls, polls$poll), function(p) {
    rel <- sort(unique(p$poll_date))
    pick <- rel[pmax(findInterval(as.numeric(snaps), as.numeric(rel)), 1L)]
    do.call(rbind, lapply(seq_along(snaps), \(k) cbind(snap_date = snaps[k], p[p$poll_date == pick[k], ])))
  }))
  rownames(out) <- NULL
  out[, c("season", "snap_date", setdiff(names(out), c("season", "snap_date")))]
}

# Next season's carry-over: the season's last snapshot (rating and its sd; tempo and total
# effects with the league levels, for the tempo submodel)
season_final_prior <- function(snaps) {
  r <- snaps[[length(snaps)]]$ratings
  p <- snaps[[length(snaps)]]$params
  out <- data.frame(team_id = r$team_id, prev_dev = r$rating, prev_sd = r$sd)
  if (!is.null(r$tempo_eff)) {
    out$prev_t <- r$tempo_eff; out$prev_s <- r$total_eff
    out$prev_mu_p <- p$mu_p; out$prev_mu_t <- p$mu_t
  }
  out
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

# Normal CRPS of y under Normal(mu, s)
crps_normal <- function(y, mu, s) { z <- (y - mu) / s; s * (z * (2 * stats::pnorm(z) - 1) + 2 * stats::dnorm(z) - 1 / sqrt(pi)) }

# Every prediction of a completed game (from the latest snapshot before it), scored against the
# result, the closing line and total, and against Torvik's ratings at the same snapshot. Torvik's
# home court and margin sd come from earlier seasons only (none for the first season, which is
# left out of the comparison). The model's predictive sd per game is the one its p_home implies
# (normal margins); the line's win probability and CRPS use the sd of the line's errors in
# earlier seasons (the first season's own). outcomes: season, game_id, played, scores, spread,
# total_line.
run_backtest <- function(predictions, torvik = NULL, outcomes = NULL) {
  if (!is.null(outcomes)) {
    predictions <- predictions[, setdiff(names(predictions), c("played", "home_score", "away_score", "spread", "total_line"))]
    predictions <- dplyr::left_join(predictions, outcomes[, c("season", "game_id", "played", "home_score", "away_score", "spread", "total_line")],
                                    by = c("season", "game_id"))
  }
  p <- predictions[predictions$played %in% TRUE, ]
  p <- p[order(p$season, p$game_id, p$snap_date, decreasing = TRUE), ]
  p <- p[!duplicated(p[, c("season", "game_id")]), ]
  p$actual_total <- p$home_score + p$away_score
  if (is.null(p$pred_total)) p$pred_total <- NA_real_
  p$actual <- p$home_score - p$away_score
  p$line <- -p$spread
  p$home_win <- as.integer(p$actual > 0)
  p$period <- ifelse(as.integer(format(p$game_date, "%m")) %in% c(11, 12), "Nov-Dec", "Jan-Apr")
  sd_imp <- abs(p$pred_margin / stats::qnorm(pmin(pmax(p$p_home, 1e-6), 1 - 1e-6)))
  p$pred_sd <- ifelse(abs(p$pred_margin) > 2 & is.finite(sd_imp), sd_imp, NA_real_)
  p$pred_sd <- dplyr::coalesce(p$pred_sd, stats::ave(p$pred_sd, p$season, FUN = \(x) stats::median(x, na.rm = TRUE)))
  line_sd <- tapply(p$actual - p$line, p$season, \(x) sqrt(mean(x^2, na.rm = TRUE)))
  prev_sd <- stats::setNames(c(line_sd[1], utils::head(line_sd, -1)), names(line_sd))
  p$line_sd <- prev_sd[as.character(p$season)]
  p$p_line <- stats::pnorm(p$line / p$line_sd)
  p$pred_torvik <- p$p_torvik <- NA_real_
  if (!is.null(torvik) && nrow(torvik)) {
    raw <- torvik_margin(p, torvik)
    home <- game_site(p)
    for (s in sort(unique(p$season))) {
      past <- p$season < s & !is.na(raw)
      if (!any(past)) next
      hca <- mean(((p$actual - raw) * home)[past & home != 0])
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
    crps = mean(crps_normal(actual, pred_margin, pred_sd)),
    cov80 = mean(abs(actual - pred_margin) <= stats::qnorm(0.9) * pred_sd),
    mae_total = mean(abs(actual_total - pred_total), na.rm = TRUE),
    mae_total_line = mean(abs(actual_total - total_line), na.rm = TRUE),
    mae_total_on_lined = mean(abs(actual_total - pred_total)[!is.na(total_line)], na.rm = TRUE),
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
  # Model against the closing line on the games with one: margin, win probability and CRPS
  vl <- function(d) d |> dplyr::filter(!is.na(line)) |> dplyr::summarise(
    games = dplyr::n(),
    mae = mean(abs(actual - pred_margin)), mae_line = mean(abs(actual - line)),
    rmse = sqrt(mean((actual - pred_margin)^2)), rmse_line = sqrt(mean((actual - line)^2)),
    brier = mean((p_home - home_win)^2), brier_line = mean((p_line - home_win)^2),
    logloss = ll(p_home, home_win), logloss_line = ll(p_line, home_win),
    crps = mean(crps_normal(actual, pred_margin, pred_sd)), crps_line = mean(crps_normal(actual, line, line_sd)),
    .groups = "drop")
  list(games = p,
       overall = score(p),
       vs_line = vl(p),
       vs_line_period = vl(dplyr::group_by(p, period)),
       # Against the spread by how far the model is from the line
       ats_edge = p |> dplyr::filter(!is.na(line), actual != line, pred_margin != line) |>
         dplyr::mutate(edge = cut(abs(pred_margin - line), c(0, 2, 4, 6, Inf), labels = c("0-2", "2-4", "4-6", "6+"), include.lowest = TRUE)) |>
         dplyr::group_by(period, edge) |>
         dplyr::summarise(games = dplyr::n(), ats = mean(sign(actual - line) == sign(pred_margin - line)), .groups = "drop"),
       by_season = score(dplyr::group_by(p, season)),
       by_period = score(dplyr::group_by(p, season, period)),
       vs_overall = vs(p),
       vs_period = vs(dplyr::group_by(p, period)),
       vs_season = vs(dplyr::group_by(p, season)),
       calibration = p |> dplyr::mutate(bin = pmin(floor(p_home * 20), 19)) |> dplyr::group_by(bin) |>
         dplyr::summarise(n = dplyr::n(), pred = mean(p_home), obs = mean(home_win), .groups = "drop"))
}

# A season's results, joined to the predictions by run_backtest()
game_outcomes <- function(games) {
  games[games$division %in% "d1", c("season", "game_id", "played", "home_score", "away_score", "spread", "total_line")]
}

# Development: keep opening night plus the last n - 1 dates (n = 0 keeps all)
limit_snaps <- function(dates, n) {
  if (n <= 0 || nrow(dates) <= n) return(dates)
  d <- dates[c(1, (nrow(dates) - n + 2):nrow(dates)), ]
  d$next_date[1] <- d$snap_date[2]
  d
}

# One branch's Stan input (dates is a one-row slice of snapshot_dates()); champs = the season's
# conference champions (champions table) and tourney = conference-tournament sizes (tourney_sizes()
# of an earlier season), for the season simulation's automatic bids
snapshot_input <- function(games, dates, teams, prior, cfg = model_config(), champs = NULL, tourney = NULL) {
  inp <- prepare_input(games, dates$snap_date, teams, prior, cfg,
                       next_date = if (is.na(dates$next_date)) NULL else dates$next_date)
  inp$kind <- dates$kind
  inp$champs <- if (!is.null(champs)) champs[champs$game_date < dates$snap_date, ]      # only finals played by then
  inp$tourney <- tourney
  inp
}

# Per-season data coverage: games, how many the model can use, lines, the efficiency signal,
# venues (recoded to a team's floor; ESPN and CBBD neutral flags disagreeing), D1 membership
# (teams ESPN lists, those not yet NCAA-tournament eligible, teams whose conference in CBBD's games
# differs from ESPN's listing), preseason prior sources
coverage_report <- function(games, priors, teams) {
  do.call(rbind, lapply(names(games), function(s) {
    g <- games[[s]]; d1 <- g[g$division == "d1", ]
    src <- attr(priors[[s]], "sources")
    tm <- teams[[s]]
    gc <- team_conferences(g)
    data.frame(season = as.integer(s), d1_teams = nrow(tm),
               ineligible = if (is.null(tm$eligible)) NA_integer_ else sum(!tm$eligible),
               conf_differs = sum(gc$conf != tm$conf[match(gc$team_id, tm$team_id)], na.rm = TRUE),
               d1_games = nrow(d1), d1_played = sum(d1$played), nond1_played = sum(g$played[g$division == "nond1"]),
               eff_share = mean(d1$has_eff[d1$played]), line_share = mean(!is.na(d1$spread[d1$played])),
               ot = sum(d1$ot[d1$played]), neutral = sum(game_site(d1)[d1$played] == 0),
               neutral_disagree = sum((d1$neutral == 1) != d1$cbbd_neutral, na.rm = TRUE),
               site_recoded = if (is.null(d1$site_note)) NA_integer_ else sum(!is.na(d1$site_note[d1$played])),
               prior_own = src[["own"]], prior_torvik = src[["torvik"]])
  }))
}
