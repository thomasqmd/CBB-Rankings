# ==============================================================================
# Model inputs, fitting and summaries. A snapshot at date d uses games played before d.
# ==============================================================================

# Resume benchmark: the last team in. Per draw, the automatic bids (one per conference) leave
# the power ranking and the benchmark is the n-th best remaining team, n = field size - automatic
# bids (36 with 32 conferences, 37 with 31; the 76-team field from 2027 adds 8).
field_size <- function(season, cfg = model_config()) if (season >= cfg$field76_from) 76L else 68L

model_config <- function(...) {
  utils::modifyList(list(
    stan_file = "stan/power.stan",
    eff_col = "lux100",          # efficiency signal: "lux100" (luck-adjusted) or "eff100" (shot quality)
    use_eff = TRUE,
    dynamic = TRUE,
    state_days = 7,              # random-walk period: one state per team per period with a game
    conf_carry = FALSE,          # carry conference strength separately from within-conference rating
    conf_centred = FALSE,        # centred conference means (better once conferences have many games)
    use_nd = TRUE,               # include games against non-D1 teams (one pooled non-D1 level)
    # Informative scale priors are what make every snapshot pass the gates (pilot/out/07_convergence.md),
    # pooled from vague-prior refits of each season's final snapshot, 2015-2026 (pilot/conv/07_pooled_priors.R)
    sigma_conf_prior = c(1.48, 0.2), sigma_team_prior = c(4.27, 0.35), tau_prior = c(0.56, 0.1),
    chains = 4, warmup = 1000, sampling = 1000, adapt_delta = 0.9, seed = 2026,
    poss_ref = 70,               # possessions at which a per-100 rate has unit weight
    tempo_shrink = 4,            # games of league-average tempo in each team's tempo estimate
    prior_torvik_weight = 0.5,   # preseason prior: weight on Torvik's preseason rating vs our final rating (pilot A8)
    prior_sd_default = 3,        # carry-over sd for a team with no rating of ours last season
    field76_from = 2027L,         # first season of the 76-team field
    snap_every = 7               # days between historical snapshots (Mondays)
  ), list(...))
}

# A snapshot's Stan data. games: a season's games table (both divisions, completed and scheduled;
# the pilot's D1-only tables work too, with non-D1 games in nd_games). Fits games played before
# snap_date; `upcoming` = D1 games in [snap_date, next_date), predicted by the snapshot.
# prev: data.frame(team_id, prev_dev, prev_sd), the preseason prior (build_prior), or NULL.
prepare_input <- function(games, snap_date, teams, prev = NULL, cfg = model_config(), nd_games = NULL, next_date = NULL) {
  if (!is.null(games$division)) {
    if (is.null(nd_games)) nd_games <- games[games$division == "nond1", ]
    games <- games[games$division == "d1", ]
  }
  played <- function(x) if (is.null(x$played)) rep(TRUE, nrow(x)) else x$played
  g <- games[played(games) & games$game_date < snap_date, ]
  upcoming <- if (is.null(next_date)) games[0, ] else games[games$game_date >= snap_date & games$game_date < next_date, ]
  if (isTRUE(cfg$use_nd) && is.null(nd_games)) message("use_nd = TRUE but no non-D1 games supplied; fitting D1 games only")
  nd <- if (isTRUE(cfg$use_nd) && !is.null(nd_games)) nd_games[played(nd_games) & nd_games$game_date < snap_date, ] else NULL
  if (!is.null(nd)) {
    nd$d1_home <- !is.na(nd$home_conf)
    nd$d1_id <- ifelse(nd$d1_home, nd$home_id, nd$away_id)
    nd <- nd[nd$d1_id %in% teams$team_id, ]
  }
  teams <- teams[order(teams$team_id), ]
  teams$idx <- seq_len(nrow(teams))
  conf_levels <- sort(unique(teams$conf))
  teams$conf_idx <- match(teams$conf, conf_levels)
  pv <- if (is.null(prev)) data.frame(team_id = integer(), prev_dev = numeric(), prev_sd = numeric()) else prev
  teams <- dplyr::left_join(teams, pv, by = "team_id")
  has_prev <- !is.na(teams$prev_dev)
  prev_conf <- vapply(seq_along(conf_levels), \(c) {
    k <- teams$conf_idx == c & has_prev
    if (any(k)) mean(teams$prev_dev[k]) else 0
  }, numeric(1))
  if (isTRUE(cfg$conf_carry)) teams$prev_dev <- teams$prev_dev - prev_conf[teams$conf_idx]
  teams$prev_dev <- dplyr::coalesce(teams$prev_dev, 0)
  teams$prev_sd <- dplyr::coalesce(teams$prev_sd, 0)

  # States: one per (team, period with a game), in period order within a team ("week" = period)
  start <- min(games$game_date)
  wk <- function(d) as.integer(floor(as.numeric(d - start) / cfg$state_days)) + 1L
  g$week <- wk(g$game_date)
  st <- rbind(data.frame(team_id = g$home_id, week = g$week), data.frame(team_id = g$away_id, week = g$week))
  if (!is.null(nd)) { nd$week <- wk(nd$game_date); st <- rbind(st, data.frame(team_id = nd$d1_id, week = nd$week)) }
  st <- unique(st)
  st$idx <- teams$idx[match(st$team_id, teams$team_id)]
  st <- st[order(st$idx, st$week), ]
  st$state <- seq_len(nrow(st))
  first <- !duplicated(st$idx)
  st$first <- st$state[first][cumsum(first)]
  st$gap <- ifelse(first, st$week - 0.5, c(NA, diff(st$week)))      # preseason level sits half a week before week 1
  key <- function(team, week) paste(team, week)
  sidx <- match(key(g$home_id, g$week), key(st$team_id, st$week))
  aidx <- match(key(g$away_id, g$week), key(st$team_id, st$week))
  last <- st[!duplicated(st$idx, fromLast = TRUE), ]
  now_state <- integer(nrow(teams)); now_state[last$idx] <- last$state
  now_week <- wk(snap_date) - 0.5
  now_gap <- rep(0, nrow(teams)); now_gap[last$idx] <- pmax(now_week - last$week, 0)

  eff <- g[[cfg$eff_col]]
  nd_list <- if (is.null(nd) || !nrow(nd)) {
    list(N_nd = 0L, nd_state = integer(), nd_venue = numeric(), nd_margin = numeric(), nd_w = numeric())
  } else {
    sgn <- ifelse(nd$d1_home, 1, -1)
    list(N_nd = nrow(nd), nd_state = match(key(nd$d1_id, nd$week), key(st$team_id, st$week)),
         nd_venue = sgn * (1 - nd$neutral), nd_margin = sgn * nd$margin100, nd_w = nd$poss_reg / cfg$poss_ref)
  }
  list(
    stan = list(
      N_teams = nrow(teams), N_conf = length(conf_levels), team_conf = teams$conf_idx,
      prev_dev = teams$prev_dev, prev_sd = teams$prev_sd,
      prev_conf = prev_conf, conf_carry = as.integer(isTRUE(cfg$conf_carry)),
      N_states = nrow(st), state_team = st$idx, state_first = st$first, state_gap = st$gap,
      now_state = now_state, now_gap = now_gap,
      N_games = nrow(g), home_state = sidx, away_state = aidx, home_adv = 1 - g$neutral,
      margin = g$margin100, w_m = g$poss_reg / cfg$poss_ref,
      has_eff = as.integer(g$has_eff), eff = ifelse(g$has_eff, eff, 0),
      w_e = ifelse(g$has_eff, g$poss_live, cfg$poss_ref) / cfg$poss_ref,
      use_eff = as.integer(cfg$use_eff), dynamic = as.integer(cfg$dynamic),
      conf_centred = as.integer(isTRUE(cfg$conf_centred)),
      sigma_conf_prior = cfg$sigma_conf_prior, sigma_team_prior = cfg$sigma_team_prior, tau_prior = cfg$tau_prior
    ) |> c(nd_list),
    teams = teams, games = g, upcoming = upcoming, snap_date = snap_date, tempo = team_tempo(g, teams, cfg)
  )
}

# Shrunk average possessions per game (for turning per-100 margins into points)
team_tempo <- function(g, teams, cfg) {
  long <- rbind(data.frame(team_id = g$home_id, poss = g$poss_reg), data.frame(team_id = g$away_id, poss = g$poss_reg))
  lg <- if (nrow(long)) mean(long$poss) else 68
  t <- data.frame(team_id = teams$team_id, tempo = lg)
  if (nrow(long)) {
    a <- stats::aggregate(poss ~ team_id, long, \(x) c(s = sum(x), n = length(x)))
    m <- match(a$team_id, t$team_id)
    t$tempo[m] <- (a$poss[, "s"] + cfg$tempo_shrink * lg) / (a$poss[, "n"] + cfg$tempo_shrink)
  }
  attr(t, "league") <- lg
  t
}

fit_snapshot <- function(inp, cfg = model_config()) {
  mod <- cmdstanr::cmdstan_model(cfg$stan_file, quiet = TRUE)
  t0 <- Sys.time()
  fit <- mod$sample(data = inp$stan, chains = cfg$chains, parallel_chains = cfg$chains,
                    iter_warmup = cfg$warmup, iter_sampling = cfg$sampling,
                    adapt_delta = cfg$adapt_delta, seed = cfg$seed, refresh = 0, show_messages = FALSE)
  secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  pars <- c("hca", "sigma_m", "nu", "sigma_team", "sigma_conf", "b_prev", "tau", "lambda", "sigma_eff", "kappa", "sigma_game")
  if (isTRUE(cfg$conf_carry)) pars <- c(pars, "b_conf")
  draws <- posterior::as_draws_matrix(fit$draws(c("r", pars)))
  r <- draws[, grep("^r\\[", colnames(draws)), drop = FALSE]
  r <- r - rowMeans(r)                                  # D1 average = 0 in every draw
  diag <- fit$diagnostic_summary(quiet = TRUE)
  rc <- posterior::as_draws_array(fit$draws("r")); rc <- sweep(rc, 1:2, apply(rc, 1:2, mean))
  summ <- rbind(posterior::summarise_draws(posterior::as_draws_array(rc), "rhat", "ess_bulk"),
                posterior::summarise_draws(fit$draws(setdiff(pars, "sigma_game")), "rhat", "ess_bulk"))
  low <- summ[order(summ$ess_bulk), ]
  list(
    r = unclass(r), par = as.data.frame(unclass(draws[, pars])), secs = secs,
    worst = utils::head(data.frame(variable = low$variable, ess = round(low$ess_bulk), rhat = round(low$rhat, 3)), 5),
    gates = c(max_rhat = max(summ$rhat, na.rm = TRUE), min_ess = min(summ$ess_bulk, na.rm = TRUE),
              divergences = sum(diag$num_divergent), min_ebfmi = min(diag$ebfmi))
  )
}

# Team table at a snapshot: rating mean, 80% interval, rank
summarise_ratings <- function(fit, inp) {
  r <- fit$r
  rk <- t(apply(-r, 1, rank, ties.method = "random"))
  data.frame(inp$teams[, c("team_id", "team", "conf")],
             rating = colMeans(r), sd = apply(r, 2, stats::sd),
             lo = apply(r, 2, stats::quantile, 0.1), hi = apply(r, 2, stats::quantile, 0.9),
             rank = colMeans(rk), rank_lo = apply(rk, 2, stats::quantile, 0.1),
             rank_hi = apply(rk, 2, stats::quantile, 0.9)) |>
    dplyr::arrange(dplyr::desc(rating))
}

# Carry-over input for next season: rating vs. the D1 mean and its posterior sd
final_prior <- function(fit, inp) {
  data.frame(team_id = inp$teams$team_id, prev_dev = colMeans(fit$r), prev_sd = apply(fit$r, 2, stats::sd))
}

# Preseason prior for a season: our final rating last season (prev: team_id, prev_dev, prev_sd),
# blended with Torvik's preseason rating (torvik_pre: team, adj_em; centred on the D1 teams
# matched). Either source alone where the other is missing.
build_prior <- function(prev, torvik_pre, teams, cfg = model_config(), overrides = "data/torvik_names.csv") {
  p <- data.frame(team_id = teams$team_id)
  if (!is.null(prev)) p <- dplyr::left_join(p, prev, by = "team_id")
  else p$prev_dev <- p$prev_sd <- NA_real_
  tv <- if (is.null(torvik_pre) || !nrow(torvik_pre)) NULL else torvik_team_ids(torvik_pre, teams, overrides)
  p$tv <- if (is.null(tv)) NA_real_ else { tv$adj_em <- tv$adj_em - mean(tv$adj_em); tv$adj_em[match(p$team_id, tv$team_id)] }
  w <- cfg$prior_torvik_weight
  p$prev_dev <- ifelse(is.na(p$tv), p$prev_dev, ifelse(is.na(p$prev_dev), p$tv, (1 - w) * p$prev_dev + w * p$tv))
  p$prev_sd <- dplyr::coalesce(p$prev_sd, cfg$prior_sd_default)
  p <- p[!is.na(p$prev_dev), c("team_id", "prev_dev", "prev_sd")]
  attr(p, "sources") <- c(own = sum(!is.na(prev$prev_dev)), torvik = if (is.null(tv)) 0L else nrow(tv), teams = nrow(teams))
  p
}

# Predict games (home perspective): margin in points and P(home wins in regulation-or-OT)
predict_games <- function(fit, inp, new) {
  i <- match(new$home_id, inp$teams$team_id); j <- match(new$away_id, inp$teams$team_id)
  ok <- !is.na(i) & !is.na(j)
  new <- new[ok, ]; i <- i[ok]; j <- j[ok]
  mu <- fit$r[, i, drop = FALSE] - fit$r[, j, drop = FALSE] + outer(fit$par$hca, 1 - new$neutral)
  tp <- inp$tempo
  lg <- attr(tp, "league")
  poss <- tp$tempo[match(new$home_id, tp$team_id)] + tp$tempo[match(new$away_id, tp$team_id)] - lg
  w <- poss / 70
  scale <- outer(fit$par$sigma_game, 1 / sqrt(w))
  p_home <- colMeans(stats::pt(mu / scale, df = matrix(fit$par$nu, nrow(mu), ncol(mu))))
  data.frame(new, pred_margin = colMeans(mu) * poss / 100, pred_poss = poss, p_home = p_home)
}
