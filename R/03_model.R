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
    # home edge per 100 possessions: pooled from the final fits (pilot/out/12_variants.md); 2021's
    # limited-attendance season has its own
    hca_prior = c(4.5, 0.4), hca_prior_season = list("2021" = c(3, 0.5)),
    # weakly informative priors on the rest, on the scale of the sport: (mean, sd) of a normal;
    # nu ~ Gamma(shape, rate), p_out ~ Beta(a, b)
    b_prev_prior = c(0.7, 0.2), b_conf_prior = c(0.8, 0.3), b_prev2_prior = c(0.2, 0.2),
    sigma_m_prior = c(14, 5), nu_prior = c(2, 0.1), p_out_prior = c(2, 20), k_out_prior = c(2.5, 1),
    sigma_hca_prior = c(0, 1), lambda_prior = c(0.7, 0.3), sigma_eff_prior = c(12, 5), kappa_prior = c(0.5, 0.5),
    r_nd_prior = c(-25, 10), sigma_nd_prior = c(10, 5),
    use_prev2 = TRUE,            # add the rating two seasons back to the preseason level (b_prev2)
    team_hca = FALSE,            # each team's own home edge, shrunk to the season's
    margin_family = 2L,          # 1 Student-t, 2 normal (backtest: better than t), 3 contaminated normal
    ot_weight = 0,               # OT periods as extra margin observations at this weight (0 = OT is a tie)
    save_loglik = FALSE,         # keep each game's margin log density (LOO)
    chains = 4, warmup = 1000, sampling = 1000, adapt_delta = 0.9, seed = 2026,
    poss_ref = 70,               # possessions at which a per-100 rate has unit weight
    prior_method = "roster",     # preseason prior: "blend" (ours and Torvik's) or "roster" (regression with roster terms, R/06_roster.R)
    prior_torvik_weight = 0.5,   # blend: weight on Torvik's preseason rating vs our final rating (pilot A8)
    prior_sd_default = 3,        # carry-over sd for a team with no rating of ours last season
    field76_from = 2027L,         # first season of the 76-team field
    snap_every = 7               # days between historical snapshots (Mondays)
  ), list(...))
}

# The prior settings model_config() passes to Stan as they are (the hierarchy scales, the drift
# and home court are listed in prepare_input())
PRIOR_FIELDS <- c("b_prev_prior", "b_conf_prior", "b_prev2_prior", "sigma_m_prior", "nu_prior", "p_out_prior", "k_out_prior",
                  "sigma_hca_prior", "lambda_prior", "sigma_eff_prior", "kappa_prior", "r_nd_prior", "sigma_nd_prior")

season_hca_prior <- function(games, cfg) {
  s <- if (is.null(games$season)) NULL else as.character(games$season[1])
  if (!is.null(s) && !is.null(cfg$hca_prior_season[[s]])) cfg$hca_prior_season[[s]] else cfg$hca_prior
}

# Home edge per game from the home team's side (+1 / -1 / 0, build_games() `site`); tables
# without `site` (the pilot's) use ESPN's neutral flag
game_site <- function(g) if (is.null(g$site)) 1 - g$neutral else g$site

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
  # Games after the snapshot carry schedule columns only, so a result coming in does not change a
  # past snapshot's input (and refit it)
  sched <- intersect(c("game_id", "game_date", "home_id", "away_id", "home", "away", "home_conf", "away_conf", "neutral", "site",
                       "season_type", "game_type", "tournament"), names(games))
  upcoming <- if (is.null(next_date)) games[0, sched] else games[games$game_date >= snap_date & games$game_date < next_date, sched]
  # the rest of the regular season (not conference tournaments, which the resume simulates)
  remaining <- games[games$game_date >= snap_date & games$season_type %in% "regular" & !(games$game_type %in% "TRNMNT"), sched]
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
  teams$prev2_dev <- if (is.null(teams$prev2_dev)) 0 else dplyr::coalesce(teams$prev2_dev, 0)

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
  ot <- ot_rows(g, cfg)
  nd_list <- if (is.null(nd) || !nrow(nd)) {
    list(N_nd = 0L, nd_state = integer(), nd_venue = numeric(), nd_margin = numeric(), nd_w = numeric())
  } else {
    sgn <- ifelse(nd$d1_home, 1, -1)
    list(N_nd = nrow(nd), nd_state = match(key(nd$d1_id, nd$week), key(st$team_id, st$week)),
         nd_venue = sgn * game_site(nd), nd_margin = sgn * nd$margin100, nd_w = nd$poss_reg / cfg$poss_ref)
  }
  list(
    stan = list(
      N_teams = nrow(teams), N_conf = length(conf_levels), team_conf = teams$conf_idx,
      prev_dev = teams$prev_dev, prev_sd = teams$prev_sd,
      prev_conf = prev_conf, conf_carry = as.integer(isTRUE(cfg$conf_carry)),
      N_states = nrow(st), state_team = st$idx, state_first = st$first, state_gap = st$gap,
      now_state = now_state, now_gap = now_gap,
      N_games = nrow(g) + nrow(ot), home_state = c(sidx, sidx[ot$i]), away_state = c(aidx, aidx[ot$i]),
      home_adv = c(game_site(g), game_site(g)[ot$i]),
      margin = c(g$margin100, ot$margin100), w_m = c(g$poss_reg, ot$w_poss) / cfg$poss_ref,
      has_eff = c(as.integer(g$has_eff), integer(nrow(ot))), eff = c(ifelse(g$has_eff, eff, 0), numeric(nrow(ot))),
      w_e = c(ifelse(g$has_eff, g$poss_live, cfg$poss_ref), rep(cfg$poss_ref, nrow(ot))) / cfg$poss_ref,
      use_eff = as.integer(cfg$use_eff), dynamic = as.integer(cfg$dynamic),
      conf_centred = as.integer(isTRUE(cfg$conf_centred)),
      sigma_conf_prior = cfg$sigma_conf_prior, sigma_team_prior = cfg$sigma_team_prior, tau_prior = cfg$tau_prior,
      hca_prior = season_hca_prior(games, cfg),
      use_prev2 = as.integer(isTRUE(cfg$use_prev2)), prev2_dev = teams$prev2_dev,
      team_hca = as.integer(isTRUE(cfg$team_hca)), margin_family = as.integer(cfg$margin_family),
      save_loglik = as.integer(isTRUE(cfg$save_loglik))
    ) |> c(cfg[PRIOR_FIELDS], nd_list),
    teams = teams, games = g, upcoming = upcoming, remaining = remaining, snap_date = snap_date, tempo = tempo_model(g, teams, snap_date)
  )
}

# OT periods as extra margin observations (cfg$ot_weight > 0): the OT margin per 100 OT possessions,
# weighted by OT possessions x ot_weight; no efficiency signal. i = the game's row in g.
ot_rows <- function(g, cfg) {
  if (!(cfg$ot_weight > 0) || !nrow(g) || is.null(g$home_score)) return(data.frame(i = integer(), margin100 = numeric(), w_poss = numeric()))
  i <- which(g$ot & !is.na(g$home_score) & !is.na(g$poss))
  m <- (g$home_score[i] - g$away_score[i]) - (g$home_reg[i] - g$away_reg[i])
  p <- g$poss[i] - g$poss_reg[i]
  ok <- p > 2
  data.frame(i = i[ok], margin100 = 100 * m[ok] / p[ok], w_poss = cfg$ot_weight * p[ok])
}

# Tempo and total submodel: regulation possessions = mu_p + t_home + t_away and points per 100
# possessions (both teams) = mu_t + s_home + s_away, w = possessions / 70, each a ridge regression
# (Gaussian random effects with fixed variance ratios) whose team effects shrink toward
# carry_* x last season's final effect. With the net rating r: offence o = (r + s) / 2 and
# defence (points allowed above average) d = (s - r) / 2. Scales from 2014-2026 (game sd 4.6
# possessions and 19 points per 100; season-to-season carry-over 0.58 and 0.38 with residual sd
# 2.1 and 5.7): lambda = game variance / prior variance. Games are weighted by recency (half-life
# in days before the snapshot). A total adds the average OT points per game (ot_pts, shrunk
# toward 1 point with 20 games). lambda_t and half_life from pilot/15_totals.R: weekly 2016-2026,
# totals MAE 13.37 (Nov-Dec 13.60, Jan-Apr 13.23) against the closing total's 13.13.
TEMPO <- list(carry_t = 0.58, carry_s = 0.38, lambda_t = 3, lambda_s = 11, lambda_mu = 1, half_life = 60, mu_p = 68.5, mu_t = 206, ot_pts = 1)

ridge_effects <- function(y, hi, ai, n, w, lambda, m, mu0, lambda_mu) {
  G <- length(y)
  X <- Matrix::sparseMatrix(i = rep(seq_len(G), 3), j = c(rep(1L, G), hi + 1L, ai + 1L), x = 1, dims = c(G, n + 1))
  XtW <- Matrix::t(X * w)
  P <- Matrix::Diagonal(n + 1, c(lambda_mu, rep(lambda, n)))
  b <- as.vector(Matrix::solve(XtW %*% X + P, XtW %*% y + c(lambda_mu * mu0, lambda * m)))
  list(mu = b[1], eff = b[-1])
}

# teams: with prev_t, prev_s (last season's final effects) and prev_mu_p, prev_mu_t where known
# (build_prior() carries them); snap_date: the recency weights' reference (NULL: equal weights)
tempo_model <- function(g, teams, snap_date = NULL) {
  pv <- function(col, default) if (is.null(teams[[col]])) rep(default, nrow(teams)) else dplyr::coalesce(teams[[col]], default)
  m_t <- TEMPO$carry_t * pv("prev_t", 0); m_s <- TEMPO$carry_s * pv("prev_s", 0)
  mu_p0 <- pv("prev_mu_p", TEMPO$mu_p)[1]; mu_t0 <- pv("prev_mu_t", TEMPO$mu_t)[1]
  g <- g[!is.na(g$poss) & !is.na(g$home_score) & g$poss > 0, ]
  out <- data.frame(team_id = teams$team_id, t = m_t, s = m_s)
  mu_p <- mu_p0; mu_t <- mu_t0; ot_pts <- TEMPO$ot_pts
  if (nrow(g)) {
    hi <- match(g$home_id, teams$team_id); ai <- match(g$away_id, teams$team_id)
    preg <- dplyr::coalesce(g$poss_reg, g$poss)
    rw <- if (is.null(snap_date)) rep(1, nrow(g)) else 0.5^(as.numeric(snap_date - g$game_date) / TEMPO$half_life)
    tp <- ridge_effects(preg, hi, ai, nrow(teams), rw, TEMPO$lambda_t, m_t, mu_p0, TEMPO$lambda_mu)
    tt <- ridge_effects(100 * (g$home_score + g$away_score) / g$poss, hi, ai, nrow(teams), rw * g$poss / 70, TEMPO$lambda_s, m_s, mu_t0, TEMPO$lambda_mu)
    out$t <- tp$eff; out$s <- tt$eff; mu_p <- tp$mu; mu_t <- tt$mu
    extra <- (g$home_score + g$away_score) - (g$home_score + g$away_score) * preg / g$poss
    ot_pts <- (sum(extra, na.rm = TRUE) + 20 * TEMPO$ot_pts) / (sum(!is.na(extra)) + 20)
  }
  out$mu_p <- mu_p; out$mu_t <- mu_t; out$ot_pts <- ot_pts
  out
}

# The CmdStan fit of one input (sample_power) and its summaries (fit_snapshot). seed: cfg$seed
# unless given.
sample_power <- function(inp, cfg = model_config(), seed = cfg$seed) {
  mod <- cmdstanr::cmdstan_model(cfg$stan_file, quiet = TRUE)
  mod$sample(data = inp$stan, chains = cfg$chains, parallel_chains = cfg$chains,
             iter_warmup = cfg$warmup, iter_sampling = cfg$sampling,
             adapt_delta = cfg$adapt_delta, seed = seed, refresh = 0, show_messages = FALSE)
}

# The structural parameters a fit reports under cfg's switches (sigma_game derived)
model_pars <- function(cfg) {
  pars <- c("hca", "sigma_m", "nu", "sigma_team", "sigma_conf", "b_prev", "tau", "lambda", "sigma_eff", "kappa", "sigma_game")
  if (isTRUE(cfg$conf_carry)) pars <- c(pars, "b_conf")
  if (isTRUE(cfg$use_prev2)) pars <- c(pars, "b_prev2")
  if (isTRUE(cfg$team_hca)) pars <- c(pars, "sigma_hca")
  if (cfg$margin_family == 3) pars <- c(pars, "p_out", "k_out")
  pars
}

fit_snapshot <- function(inp, cfg = model_config(), fit = NULL, seed = cfg$seed) {
  t0 <- Sys.time()
  if (is.null(fit)) fit <- sample_power(inp, cfg, seed)
  secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  pars <- model_pars(cfg)
  draws <- posterior::as_draws_matrix(fit$draws(c("r", pars)))
  r <- draws[, grep("^r\\[", colnames(draws)), drop = FALSE]
  r <- r - rowMeans(r)                                  # D1 average = 0 in every draw
  diag <- fit$diagnostic_summary(quiet = TRUE)
  rc <- posterior::as_draws_array(fit$draws("r")); rc <- sweep(rc, 1:2, apply(rc, 1:2, mean))
  summ <- rbind(posterior::summarise_draws(posterior::as_draws_array(rc), "rhat", "ess_bulk"),
                posterior::summarise_draws(fit$draws(setdiff(pars, c("sigma_game", if (cfg$margin_family != 1) "nu"))), "rhat", "ess_bulk"))
  low <- summ[order(summ$ess_bulk), ]
  list(
    r = unclass(r), par = as.data.frame(unclass(draws[, pars])), secs = secs,
    hca_team = if (isTRUE(cfg$team_hca)) unclass(posterior::as_draws_matrix(fit$draws("hca_team"))),
    log_lik = if (isTRUE(cfg$save_loglik)) unclass(posterior::as_draws_matrix(fit$draws("log_lik"))),
    worst = utils::head(data.frame(variable = low$variable, ess = round(low$ess_bulk), rhat = round(low$rhat, 3)), 5),
    gates = c(max_rhat = max(summ$rhat, na.rm = TRUE), min_ess = min(summ$ess_bulk, na.rm = TRUE),
              divergences = sum(diag$num_divergent), min_ebfmi = min(diag$ebfmi))
  )
}

# Team table at a snapshot: rating mean, 80% interval, rank; adjusted tempo (possessions against
# an average opponent), offence and defence in points per 100 (tempo_model())
summarise_ratings <- function(fit, inp) {
  r <- fit$r
  rk <- t(apply(-r, 1, rank, ties.method = "random"))
  tp <- inp$tempo[match(inp$teams$team_id, inp$tempo$team_id), ]
  rating <- colMeans(r)
  data.frame(inp$teams[, c("team_id", "team", "conf")],
             rating = rating, sd = apply(r, 2, stats::sd),
             lo = apply(r, 2, stats::quantile, 0.1), hi = apply(r, 2, stats::quantile, 0.9),
             rank = colMeans(rk), rank_lo = apply(rk, 2, stats::quantile, 0.1),
             rank_hi = apply(rk, 2, stats::quantile, 0.9),
             tempo = tp$mu_p + tp$t, off = tp$mu_t / 2 + (rating + tp$s) / 2, def = tp$mu_t / 2 + (tp$s - rating) / 2,
             tempo_eff = tp$t, total_eff = tp$s) |>
    dplyr::arrange(dplyr::desc(rating))
}


# Preseason prior for a season: our final rating last season (prev: team_id, prev_dev, prev_sd),
# blended with Torvik's preseason rating (torvik_pre: team, adj_em; centred on the D1 teams
# matched). Either source alone where the other is missing. With cfg$prior_method = "roster",
# roster features (roster_features()) and earlier seasons' features with final ratings (history,
# roster_history()) replace the blend by the roster regression wherever it has a prediction. The
# features are kept as attr "features" for later seasons' regressions. prev2 (the final ratings
# two seasons back, same columns as prev) adds prev2_dev for cfg$use_prev2.
build_prior <- function(prev, torvik_pre, teams, cfg = model_config(), overrides = "data/torvik_names.csv",
                        roster = NULL, history = NULL, prev2 = NULL) {
  p <- data.frame(team_id = teams$team_id)
  if (!is.null(prev)) p <- dplyr::left_join(p, prev, by = "team_id")
  else p$prev_dev <- p$prev_sd <- NA_real_
  tv <- if (is.null(torvik_pre) || !nrow(torvik_pre)) NULL else torvik_team_ids(torvik_pre, teams, overrides)
  p$tv <- if (is.null(tv)) NA_real_ else { tv$adj_em <- tv$adj_em - mean(tv$adj_em); tv$adj_em[match(p$team_id, tv$team_id)] }
  w <- cfg$prior_torvik_weight
  feats <- data.frame(team_id = p$team_id, own = dplyr::coalesce(p$prev_dev, p$tv), tv = dplyr::coalesce(p$tv, p$prev_dev))
  if (!is.null(roster)) feats <- dplyr::left_join(feats, roster, by = "team_id")
  p$prev_dev <- ifelse(is.na(p$tv), p$prev_dev, ifelse(is.na(p$prev_dev), p$tv, (1 - w) * p$prev_dev + w * p$tv))
  n_roster <- 0L
  if (identical(cfg$prior_method, "roster") && !is.null(roster)) {
    rp <- roster_prior(feats, history)
    if (!is.null(rp)) { n_roster <- sum(!is.na(rp)); p$prev_dev <- dplyr::coalesce(rp, p$prev_dev) }
  }
  p$prev_sd <- dplyr::coalesce(p$prev_sd, cfg$prior_sd_default)
  p$prev2_dev <- if (is.null(prev2)) NA_real_ else prev2$prev_dev[match(p$team_id, prev2$team_id)]
  # last season's tempo / total effects and league levels ride along for tempo_model()
  p <- p[!is.na(p$prev_dev), intersect(c("team_id", "prev_dev", "prev_sd", "prev2_dev", "prev_t", "prev_s", "prev_mu_p", "prev_mu_t"), names(p))]
  attr(p, "sources") <- c(own = sum(!is.na(prev$prev_dev)), torvik = if (is.null(tv)) 0L else nrow(tv), roster = n_roster, prev2 = sum(!is.na(p$prev2_dev)), teams = nrow(teams))
  attr(p, "features") <- feats
  p
}

# Predict games (home perspective): margin in points and P(home wins in regulation-or-OT)
predict_games <- function(fit, inp, new) {
  i <- match(new$home_id, inp$teams$team_id); j <- match(new$away_id, inp$teams$team_id)
  ok <- !is.na(i) & !is.na(j)
  new <- new[ok, ]; i <- i[ok]; j <- j[ok]
  site <- game_site(new)
  hca <- if (is.null(fit$hca_team)) outer(fit$par$hca, rep(1, length(i))) else fit$hca_team[, ifelse(site < 0, j, i), drop = FALSE]
  mu <- fit$r[, i, drop = FALSE] - fit$r[, j, drop = FALSE] + sweep(hca, 2, site, `*`)
  tp <- inp$tempo
  th <- match(new$home_id, tp$team_id); ta <- match(new$away_id, tp$team_id)
  poss <- tp$mu_p[1] + tp$t[th] + tp$t[ta]
  total <- poss * (tp$mu_t[1] + tp$s[th] + tp$s[ta]) / 100 + tp$ot_pts[1]
  w <- poss / 70
  scale <- outer(fit$par$sigma_game, 1 / sqrt(w))
  p_home <- colMeans(stats::pt(mu / scale, df = matrix(fit$par$nu, nrow(mu), ncol(mu))))
  data.frame(new, pred_margin = colMeans(mu) * poss / 100, pred_poss = poss, pred_total = total, p_home = p_home)
}
