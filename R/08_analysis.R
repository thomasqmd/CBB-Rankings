# ==============================================================================
# Analyses for the methods paper (paper/cbb-paper.qmd), beyond the published pipeline. Each is a
# target in _targets.R, built only with CBB_PAPER=1 (the daily build skips them):
#   final_fits         every complete season's final snapshot refit four ways (published, margin
#                      only, Student-t and contaminated-normal margins) with each game's log
#                      density: posterior predictive checks, power-scaling sensitivity, PSIS-LOO
#   prior_refits       the same snapshots under vague priors: the evidence the pooled priors rest on
#   loso_backtest      the first snapshots of each season under priors pooled without that season
#   ablation           rolling backtest of model variants on the same games (short chains)
#   baselines          least-squares (Massey) ratings on the same snapshots
#   selection_refits   Selection Monday refits: benchmark choice, per-draw SOR, Monte Carlo errors
#   margin_leakage     how far one blowout's margin reaches the resume
#   sbc                simulation-based calibration on a real snapshot
#   supplement         full-draw fits (an early snapshot and the final one) for the appendix
#   prior_sensitivity  refits under widened and shifted priors
#   induced_prior      what the priors imply about games before any data
# and cheap summaries of the published snapshots (resume validation, preseason sources,
# schedule graph, backtest uncertainty, data fingerprint).
#
# A season "kit" (season_kit()) carries what snapshot_input() needs to rebuild any snapshot's
# input under another configuration: games, snapshot dates, teams, preseason prior, champions,
# conference-tournament sizes.
# ==============================================================================

season_kit <- function(season, games, dates, teams, prior, champs = NULL, tourney = NULL) {
  list(season = as.integer(season), games = games, dates = dates, teams = teams, prior = prior,
       champs = champs, tourney = tourney)
}

# The input of a kit's i-th snapshot under cfg (prior: the kit's unless given; NULL for none)
kit_input <- function(kit, i, cfg = model_config(), prior = kit$prior) {
  snapshot_input(kit$games, kit$dates[i, ], kit$teams, prior, cfg, kit$champs, kit$tourney)
}

kit_index <- function(kit, kind) which(kit$dates$kind %in% kind)

# Short chains for point predictions (ablations, SBC)
fast_config <- function(cfg = model_config(), chains = 2L, warmup = 400L, sampling = 400L) {
  cfg$chains <- chains; cfg$warmup <- warmup; cfg$sampling <- sampling
  cfg
}

gates_pass <- function(g) g[["max_rhat"]] <= 1.01 && g[["min_ess"]] >= 400 && g[["divergences"]] == 0 && g[["min_ebfmi"]] > 0.2

# The structural parameters a fit samples (for summaries and priorsense; sigma_game is derived,
# nu fixed unless the margin is Student-t)
struct_vars <- function(cfg) setdiff(model_pars(cfg), c("sigma_game", if (cfg$margin_family != 1) "nu"))

# One fit kept whole: fit_snapshot()'s summaries plus the CmdStan object (delete its files with
# drop_fit() when done; CSVs of a full season run to hundreds of MB)
fit_keep <- function(inp, cfg = model_config(), seed = cfg$seed) {
  fit <- suppressWarnings(sample_power(inp, cfg, seed))
  out <- fit_snapshot(inp, cfg, fit = fit)
  out$pass <- gates_pass(out$gates)
  out$fit <- fit
  out
}
drop_fit <- function(f) { unlink(f$fit$output_files()); f$fit <- NULL; f }

par_summary <- function(fit, vars) {
  posterior::summarise_draws(fit$draws(vars), "mean", "sd", "rhat", "ess_bulk")
}

mclapply_safe <- function(X, FUN, workers) {
  res <- parallel::mclapply(X, FUN, mc.cores = workers, mc.preschedule = FALSE)
  bad <- vapply(res, inherits, logical(1), "try-error")
  if (any(bad)) stop(sum(bad), " of ", length(res), " jobs failed: ", as.character(res[bad][[1]]))
  res
}

# ---- Game-level draws -------------------------------------------------------------

# Expected margin per 100 possessions of each fitted D1 game in each draw (rows: draws `pick`),
# at the state the game was played in
game_mu <- function(fit, sd, pick = NULL) {
  rs <- unclass(posterior::as_draws_matrix(fit$draws("r_state")))
  hca <- as.vector(posterior::as_draws_matrix(fit$draws("hca")))
  if (!is.null(pick)) { rs <- rs[pick, , drop = FALSE]; hca <- hca[pick] }
  rs[, sd$home_state, drop = FALSE] - rs[, sd$away_state, drop = FALSE] + outer(hca, sd$home_adv)
}

# Marginal sd of each game's margin per 100 (efficiency integrated out), draws x games
margin_scale <- function(par, sd) {
  sqrt(outer(par$sigma_m^2, 1 / sd$w_m) + outer((par$kappa * par$sigma_eff)^2, 1 / sd$w_e))
}

# Draws from the margin family around mu with the given scales (matrices); par rows match
rmargin <- function(mu, scale, par, family) {
  n <- length(mu)
  e <- switch(as.character(family),
    "1" = stats::rt(n, df = rep(par$nu, length.out = n)),
    "2" = stats::rnorm(n),
    "3" = stats::rnorm(n) * ifelse(stats::runif(n) < rep(par$p_out, length.out = n), rep(par$k_out, length.out = n), 1))
  mu + scale * e
}

# CDF of the margin family at y (matrices)
pmargin <- function(y, mu, scale, par, family) {
  z <- (y - mu) / scale
  switch(as.character(family),
    "1" = stats::pt(z, df = matrix(par$nu, nrow(z), ncol(z))),
    "2" = stats::pnorm(z),
    "3" = { p <- matrix(par$p_out, nrow(z), ncol(z)); k <- matrix(par$k_out, nrow(z), ncol(z))
            (1 - p) * stats::pnorm(z) + p * stats::pnorm(z / k) })
}

# ---- Posterior predictive checks ----------------------------------------------------

# Statistics of regulation margins in points (integers; overtime games are ties) and of the
# efficiency margin per 100
# (source references removed: tar_source() keeps them, and they would carry the text of this
# whole file into the object's hash, so that any edit here would refit run_final_fits())
PPC_STATS <- lapply(list(
  "SD of margin" = function(m, site) stats::sd(m),
  "Share within 3 pts" = function(m, site) mean(abs(m) <= 3),
  "Share within 10 pts" = function(m, site) mean(abs(m) <= 10),
  "Share decided by 20+" = function(m, site) mean(abs(m) >= 20),
  "Share tied after regulation" = function(m, site) mean(m == 0),
  "Home win rate (true home games)" = function(m, site) mean(m[site == 1] > 0)
), utils::removeSource)

# Observed statistics against their 90% replicate intervals, from n_rep draws. Replicated
# regulation margins follow the marginal law (efficiency integrated out), are turned into points
# with each game's regulation possessions and rounded.
posterior_predictive_check <- function(fit, inp, cfg, n_rep = 400L, seed = 1) {
  set.seed(seed)
  sd <- inp$stan
  N <- nrow(inp$games)
  sd$home_state <- sd$home_state[seq_len(N)]; sd$away_state <- sd$away_state[seq_len(N)]
  sd$home_adv <- sd$home_adv[seq_len(N)]; sd$w_m <- sd$w_m[seq_len(N)]; sd$w_e <- sd$w_e[seq_len(N)]
  par_all <- as.data.frame(unclass(posterior::as_draws_matrix(fit$draws(model_pars(cfg)))))
  pick <- sort(sample.int(nrow(par_all), min(n_rep, nrow(par_all))))
  par <- par_all[pick, ]
  mu <- game_mu(fit, sd, pick)
  pts <- inp$games$poss_reg / 100
  rep <- round(rmargin(mu, margin_scale(par, sd), par, cfg$margin_family) * matrix(pts, nrow(mu), N, byrow = TRUE))
  obs <- round(sd$margin[seq_len(N)] * pts)
  site <- sd$home_adv
  one <- function(nm, stat, reps, ob) {
    v <- apply(reps, 1, stat, site = site)
    o <- stat(ob, site)
    data.frame(statistic = nm, observed = o, rep_lo = stats::quantile(v, 0.05, names = FALSE),
               rep_hi = stats::quantile(v, 0.95, names = FALSE), rep_mean = mean(v), p_value = mean(v >= o))
  }
  out <- do.call(rbind, lapply(names(PPC_STATS), \(nm) one(nm, PPC_STATS[[nm]], rep, obs)))
  if (isTRUE(cfg$use_eff)) {
    he <- sd$has_eff[seq_len(N)] == 1
    erep <- outer(par$lambda, rep(1, sum(he))) * mu[, he, drop = FALSE] +
      outer(par$sigma_eff, 1 / sqrt(sd$w_e[he])) * matrix(stats::rnorm(nrow(mu) * sum(he)), nrow(mu))
    out <- rbind(out, one("SD of efficiency margin (per 100)", \(m, site) stats::sd(m), erep, sd$eff[seq_len(N)][he]))
  }
  out
}

# ---- Final snapshots: checks, LOO, margin families ------------------------------------

FINAL_MODELS <- list(
  published = list(),
  margin_only = list(use_eff = FALSE),
  student_t = list(margin_family = 1L),
  contaminated = list(margin_family = 3L)
)

# Each complete season's final snapshot under each of FINAL_MODELS, with every game's log
# density. The published fit adds priorsense's power-scaling sensitivity; every fit but the
# margin-only one adds posterior predictive checks. Returns compact summaries, not draws.
# kits: list of season kits (complete seasons)
run_final_fits <- function(kits, cfg = model_config(), workers = 4L, models = FINAL_MODELS) {
  jobs <- expand.grid(k = seq_along(kits), model = names(models), stringsAsFactors = FALSE)
  # biggest seasons first, so the long fits do not finish last
  res <- mclapply_safe(seq_len(nrow(jobs)), function(j) {
    kit <- kits[[jobs$k[j]]]
    mcfg <- utils::modifyList(cfg, c(models[[jobs$model[j]]], list(save_loglik = TRUE)))
    inp <- kit_input(kit, nrow(kit$dates), mcfg)
    f <- fit_keep(inp, mcfg)
    l <- f$fit$loo(variables = "log_lik", r_eff = TRUE)
    lm <- f$fit$loo(variables = "log_lik_margin", r_eff = TRUE)
    vars <- struct_vars(mcfg)
    out <- list(season = kit$season, model = jobs$model[j], snap_date = inp$snap_date, n_games = nrow(inp$games),
                n_nd = inp$stan$N_nd, gates = f$gates, pass = f$pass, secs = f$secs,
                par = par_summary(f$fit, vars),
                elpd = l$pointwise[, "elpd_loo"], elpd_margin = lm$pointwise[, "elpd_loo"],
                loo = l$estimates, loo_margin = lm$estimates,
                pareto_k = loo::pareto_k_values(l), pareto_k_margin = loo::pareto_k_values(lm))
    if (jobs$model[j] != "margin_only") out$ppc <- posterior_predictive_check(f$fit, inp, mcfg)
    if (jobs$model[j] == "published") {
      out$sensitivity <- tryCatch(
        as.data.frame(priorsense::powerscale_sensitivity(f$fit$draws(c(vars, "lprior", "log_lik")), variable = vars)),
        error = function(e) data.frame(variable = NA_character_, error = conditionMessage(e)))
    }
    drop_fit(f)
    out
  }, workers)
  res
}

# LOO comparisons from run_final_fits(): the efficiency signal (published vs margin only, on the
# margin's marginal density) and the margin families (on each game's joint density), per season
# and pooled (seasons independent: summed differences, se = sqrt(sum se^2))
compare_final_fits <- function(ff) {
  get <- function(s, m) Filter(\(x) x$season == s && x$model == m, ff)[[1]]
  seasons <- sort(unique(vapply(ff, `[[`, integer(1), "season")))
  diff_row <- function(s, a, b, field, what) {
    d <- get(s, a)[[field]] - get(s, b)[[field]]
    data.frame(season = s, comparison = what, model = a, reference = b, diff = sum(d), se = sqrt(length(d) * stats::var(d)))
  }
  per_season <- do.call(rbind, lapply(seasons, function(s) rbind(
    diff_row(s, "published", "margin_only", "elpd_margin", "efficiency signal (margin density)"),
    diff_row(s, "student_t", "published", "elpd", "margin family (joint density)"),
    diff_row(s, "contaminated", "published", "elpd", "margin family (joint density)"))))
  pooled <- per_season |>
    dplyr::group_by(comparison, model, reference) |>
    dplyr::summarise(seasons_better = sum(diff > 0), seasons = dplyr::n(), median_diff = stats::median(diff),
                     diff = sum(diff), se = sqrt(sum(se^2)), .groups = "drop")
  list(per_season = per_season, pooled = pooled)
}

# ---- Priors -----------------------------------------------------------------------------

# Vague priors on every structural parameter, on the scale of the sport but wide enough that a
# full season decides. tau stays centred away from 0 (a prior with its mode at 0 sends the
# sampler into the random walk's funnel); 2021 loses its own home-court prior.
vague_config <- function(cfg = model_config()) {
  utils::modifyList(cfg, list(
    sigma_conf_prior = c(0, 10), sigma_team_prior = c(0, 10), tau_prior = c(0.5, 0.5),
    hca_prior = c(0, 10), b_prev_prior = c(0.5, 1), b_prev2_prior = c(0, 1),
    sigma_m_prior = c(0, 50), lambda_prior = c(0, 2), sigma_eff_prior = c(0, 50), kappa_prior = c(0, 2),
    r_nd_prior = c(0, 50), sigma_nd_prior = c(0, 25))) |>
    (\(x) { x$hca_prior_season <- list(); x })()
}

# Longer chains for the vague-prior refits: the tails of the step size mix slowly
long_chains <- function(cfg) { cfg$warmup <- 1000L; cfg$sampling <- 2000L; cfg }

PRIOR_PARS <- c("hca", "sigma_m", "sigma_team", "sigma_conf", "b_prev", "b_prev2", "tau", "lambda", "sigma_eff", "kappa",
                "r_nd_raw[1]", "sigma_nd_raw[1]")

# Each complete season's final snapshot under the vague priors
run_prior_refits <- function(kits, cfg = model_config(), workers = 4L) {
  vcfg <- long_chains(vague_config(cfg))
  res <- mclapply_safe(kits, function(kit) {
    inp <- kit_input(kit, nrow(kit$dates), vcfg)
    f <- fit_keep(inp, vcfg)
    d <- par_summary(f$fit, PRIOR_PARS)
    drop_fit(f)
    data.frame(season = kit$season, n_games = nrow(inp$games), pass = f$pass, max_rhat = f$gates[["max_rhat"]],
               min_ess = f$gates[["min_ess"]], as.data.frame(d))
  }, workers)
  do.call(rbind, res)
}

# Random-effects pooling (DerSimonian-Laird) of the vague-prior posterior means, per parameter:
# centre = the pooled mean, predictive sd for a new season = sqrt(between-season variance + the
# mean's variance). Home court leaves out 2021 (limited attendance; it has its own prior). drop:
# seasons to leave out (leave-one-season-out).
pool_priors <- function(refits, drop = integer(0), hca_exclude = 2021L) {
  x <- refits[!refits$season %in% drop & !(refits$variable == "hca" & refits$season %in% hca_exclude), ]
  do.call(rbind, lapply(split(x, x$variable), function(d) {
    w <- 1 / d$sd^2; mu <- sum(w * d$mean) / sum(w); Q <- sum(w * (d$mean - mu)^2)
    t2 <- max(0, (Q - (nrow(d) - 1)) / (sum(w) - sum(w^2) / sum(w)))
    ws <- 1 / (d$sd^2 + t2)
    data.frame(variable = d$variable[1], pooled_mean = sum(ws * d$mean) / sum(ws), between_sd = sqrt(t2), Q = Q,
               df = nrow(d) - 1, typical_post_sd = sqrt(mean(d$sd^2)), predictive_sd = sqrt(t2 + 1 / sum(ws)),
               min = min(d$mean), max = max(d$mean), n_seasons = nrow(d))
  }))
}

# The published rounding of pooled priors: means to 2 decimals, sds rounded up to the next 0.05
# and at least 0.1
POOLED_PRIORS <- c(sigma_conf_prior = "sigma_conf", sigma_team_prior = "sigma_team", tau_prior = "tau", hca_prior = "hca")
pooled_prior_values <- function(pooled) {
  lapply(POOLED_PRIORS, function(v) {
    p <- pooled[pooled$variable == v, ]
    c(round(p$pooled_mean, 2), max(0.1, ceiling(p$predictive_sd * 20 - 1e-9) / 20))
  })
}

# cfg with the pooled priors replaced (the others keep cfg's)
priors_from_pool <- function(cfg, pooled) utils::modifyList(cfg, pooled_prior_values(pooled))

# Each season's vague-prior estimate against the prior pooled from the other seasons: z is its
# distance from that prior's centre in units of sqrt(prior sd^2 + its own posterior sd^2)
loso_prior_check <- function(refits, hca_exclude = 2021L) {
  do.call(rbind, lapply(sort(unique(refits$season)), function(s0) {
    p <- pool_priors(refits, drop = s0, hca_exclude = hca_exclude)
    x <- refits[refits$season == s0 & !(refits$variable == "hca" & s0 %in% hca_exclude), ]
    x <- merge(x, p[, c("variable", "pooled_mean", "predictive_sd")], by = "variable")
    data.frame(season = s0, variable = x$variable, z = (x$mean - x$pooled_mean) / sqrt(x$predictive_sd^2 + x$sd^2))
  }))
}

# The first snapshots of each season (opening night and the first n_weekly Mondays) refit with
# the pooled priors computed without that season; each predicts the games until the next one
run_loso_backtest <- function(kits, refits, cfg = model_config(), n_weekly = 3L, workers = 4L) {
  jobs <- do.call(rbind, lapply(seq_along(kits), function(k) {
    d <- kits[[k]]$dates
    i <- c(kit_index(kits[[k]], "preseason"), utils::head(kit_index(kits[[k]], c("weekly", "selection")), n_weekly))
    data.frame(k = k, i = i)
  }))
  res <- mclapply_safe(seq_len(nrow(jobs)), function(j) {
    kit <- kits[[jobs$k[j]]]
    lcfg <- priors_from_pool(cfg, pool_priors(refits, drop = kit$season))
    inp <- kit_input(kit, jobs$i[j], lcfg)
    if (!nrow(inp$upcoming)) return(NULL)
    f <- suppressWarnings(fit_snapshot(inp, lcfg))
    data.frame(season = kit$season, snap_date = inp$snap_date, kind = inp$kind, pass = gates_pass(f$gates),
               predict_games(f, inp, inp$upcoming)[, c("game_id", "pred_margin", "p_home")])
  }, workers)
  do.call(rbind, res)
}

# ---- Ablations and baselines ------------------------------------------------------------

# The published model and one change at a time. "prior" = NULL drops the preseason information
# (and then the hierarchy scales get vague priors: without carry-over they hold all of a
# team's preseason spread).
ablation_variants <- function(cfg = model_config()) {
  list(
    "Published model" = list(),
    "Margin only" = list(use_eff = FALSE),
    "Shot-quality efficiency" = list(eff_col = "eff100"),
    "No preseason information" = list(no_prior = TRUE, sigma_conf_prior = c(0, 10), sigma_team_prior = c(0, 10)),
    "No two-season carry-over" = list(use_prev2 = FALSE),
    "No conference level" = list(sigma_conf_prior = c(0, 0.01)),
    "Static ratings" = list(dynamic = FALSE),
    "No non-D1 games" = list(use_nd = FALSE),
    "Student-t margin" = list(margin_family = 1L),
    "Contaminated-normal margin" = list(margin_family = 3L)
  )
}

# Rolling backtest of each variant: every snapshot but the last refit with short chains under the
# variant, predicting the games until the next snapshot, as the published one does. Every variant
# predicts the same games.
run_ablation <- function(kits, cfg = model_config(), workers = 8L, variants = ablation_variants(cfg)) {
  tasks <- do.call(rbind, lapply(seq_along(kits), function(k) {
    i <- which(kits[[k]]$dates$kind != "final")
    expand.grid(variant = names(variants), k = k, i = i, stringsAsFactors = FALSE)
  }))
  res <- mclapply_safe(seq_len(nrow(tasks)), function(j) {
    tk <- tasks[j, ]; kit <- kits[[tk$k]]
    v <- variants[[tk$variant]]
    vcfg <- fast_config(utils::modifyList(cfg, v[setdiff(names(v), "no_prior")]))
    inp <- kit_input(kit, tk$i, vcfg, prior = if (isTRUE(v$no_prior)) NULL else kit$prior)
    if (!nrow(inp$upcoming)) return(NULL)
    f <- suppressWarnings(fit_snapshot(inp, vcfg, seed = 2026 + tk$i))
    data.frame(variant = tk$variant, season = kit$season, snap_date = inp$snap_date, pass = gates_pass(f$gates),
               predict_games(f, inp, inp$upcoming)[, c("game_id", "pred_margin", "p_home")])
  }, workers)
  do.call(rbind, res)
}

# Ridge least-squares ratings (Massey) on a snapshot's games: margin per 100 = r_home - r_away +
# h x site, weighted by possessions; a weak ridge on the teams
massey_fit <- function(g, teams, lambda = 1) {
  n <- nrow(teams)
  hi <- match(g$home_id, teams$team_id); ai <- match(g$away_id, teams$team_id)
  X <- Matrix::sparseMatrix(i = rep(seq_len(nrow(g)), 3), j = c(hi, ai, rep(n + 1L, nrow(g))),
                            x = c(rep(1, nrow(g)), rep(-1, nrow(g)), game_site(g)), dims = c(nrow(g), n + 1))
  w <- g$poss_reg / 70
  XtW <- Matrix::t(X * w)
  P <- Matrix::Diagonal(n + 1, c(rep(lambda, n), 1e-3))
  b <- as.vector(Matrix::solve(XtW %*% X + P, XtW %*% g$margin100))
  list(r = b[seq_len(n)], hca = b[n + 1])
}

# Least-squares predictions of the games each published snapshot predicts (from the first weekly
# snapshot on), in points with the snapshot's expected possessions. Win probabilities: normal with
# the RMSE of earlier seasons, so the first season is fitted and not scored.
run_baselines <- function(kits, cfg = model_config()) {
  ms <- do.call(rbind, lapply(kits, function(kit) {
    do.call(rbind, lapply(which(!kit$dates$kind %in% c("preseason", "final")), function(i) {
      inp <- kit_input(kit, i, cfg)
      up <- inp$upcoming
      if (!nrow(up) || !nrow(inp$games)) return(NULL)
      m <- massey_fit(inp$games, inp$teams)
      tp <- inp$tempo
      hi <- match(up$home_id, inp$teams$team_id); ai <- match(up$away_id, inp$teams$team_id)
      poss <- tp$mu_p[1] + tp$t[match(up$home_id, tp$team_id)] + tp$t[match(up$away_id, tp$team_id)]
      ok <- !is.na(hi) & !is.na(ai)
      data.frame(season = kit$season, snap_date = inp$snap_date, game_id = up$game_id[ok],
                 pred_margin = ((m$r[hi] - m$r[ai] + m$hca * game_site(up)) * poss / 100)[ok])
    }))
  }))
  ms$method <- "Least squares (Massey)"
  ms
}

# Score predictions (one row per prediction: season, game_id, pred_margin, p_home) against
# results; for baselines without p_home, a normal win probability with earlier seasons' RMSE
score_predictions <- function(preds, outcomes) {
  out <- merge(preds, outcomes[outcomes$played %in% TRUE, c("season", "game_id", "home_score", "away_score", "spread")],
               by = c("season", "game_id"))
  out$actual <- out$home_score - out$away_score
  out$home_win <- as.integer(out$actual > 0)
  out$err <- out$pred_margin - out$actual
  if (is.null(out$p_home)) {
    key <- if (is.null(out$method)) rep("", nrow(out)) else out$method
    out$p_home <- NA_real_
    for (s in sort(unique(out$season))) {
      past <- out$season < s
      if (!any(past)) next
      sig <- sqrt(mean(out$err[past]^2))
      out$p_home[out$season == s] <- stats::pnorm(out$pred_margin[out$season == s] / sig)
    }
    out <- out[!is.na(out$p_home), ]
  }
  out$brier <- (out$p_home - out$home_win)^2
  out$logloss <- -(out$home_win * log(pmax(out$p_home, 1e-6)) + (1 - out$home_win) * log(pmax(1 - out$p_home, 1e-6)))
  out
}

# ---- Selection Monday refits: the benchmark, SOR, Monte Carlo error ------------------------

# Field teams missing from the game data: the 2017 First Four losers (in neither ESPN nor CBBD)
# and VCU in 2021 (selected, withdrew before playing)
FIELD_EXTRA <- data.frame(season = c(2017L, 2017L, 2021L), team_id = c(2443L, 154L, 2670L), seed = c(16L, 11L, 10L))

# The NCAA tournament field of a season: team, seed, automatic bid (the conference champion if in
# the field, else the conference's only field team)
ncaa_field <- function(games, teams, champs, season) {
  x <- games[games$ncaa %in% TRUE, ]
  if (!nrow(x)) return(NULL)
  field <- unique(rbind(data.frame(team_id = x$home_id, seed = x$home_seed), data.frame(team_id = x$away_id, seed = x$away_seed),
                        FIELD_EXTRA[FIELD_EXTRA$season == season, c("team_id", "seed")]))
  field <- field[!duplicated(field$team_id), ]
  field$conf <- teams$conf[match(field$team_id, teams$team_id)]
  field$auto <- FALSE
  for (cf in unique(field$conf)) {
    k <- which(field$conf == cf)
    c1 <- intersect(champs$team_id[champs$conf == cf], field$team_id[k])
    if (length(c1)) field$auto[field$team_id == c1[1]] <- TRUE
    else if (length(k) == 1) field$auto[k] <- TRUE
  }
  field
}

# WAB per draw (draws x teams) against a benchmark rating per draw (rb), as wab_draws() does
wab_given_bench <- function(r, par, inp, rb) {
  g <- inp$games; nt <- ncol(r)
  long <- rbind(
    data.frame(team_id = g$home_id, opp_id = g$away_id, venue = game_site(g), win = as.integer(g$home_score > g$away_score), w = g$poss_reg / 70),
    data.frame(team_id = g$away_id, opp_id = g$home_id, venue = -game_site(g), win = as.integer(g$away_score > g$home_score), w = g$poss_reg / 70))
  oi <- match(long$opp_id, inp$teams$team_id); ti <- match(long$team_id, inp$teams$team_id)
  pb <- stats::pt((rb - r[, oi, drop = FALSE] + outer(par$hca, long$venue)) / outer(par$sigma_game, 1 / sqrt(long$w)),
                  df = matrix(par$nu, nrow(r), nrow(long)))
  M <- Matrix::sparseMatrix(i = seq_along(ti), j = ti, x = 1, dims = c(length(ti), nt))
  list(wab = as.matrix(sweep(-pb, 2, long$win, `+`) %*% M), p_bench = pb, ti = ti, win = long$win)
}

# Benchmarks compared: the published last team in (offset 0 in the at-large order), four places
# either side, and two that ignore the bids: a fixed power rank and the top-25 team SOR uses
BENCHMARKS <- list("Last team in (published)" = list(offset = 0L), "Last four byes" = list(offset = -4L),
                   "First four out" = list(offset = 4L), "Power rank 45" = list(rank = 45L), "Power rank 25" = list(rank = 25L))

# Refit each season's Selection Monday snapshot and compute, from every draw: WAB under each
# benchmark and the at-large teams it picks against the committee's, SOR from the posterior-mean
# benchmark probabilities (published) and averaged per draw, and Monte Carlo standard errors of
# the published resume quantities
run_selection_refits <- function(kits, cfg = model_config(), workers = 4L) {
  kits <- Filter(\(k) any(k$dates$kind == "selection"), kits)
  res <- mclapply_safe(kits, function(kit) {
    inp <- kit_input(kit, kit_index(kit, "selection")[1], cfg)
    f <- fit_keep(inp, cfg)
    arr <- f$fit$draws("r")
    n_iter <- posterior::niterations(arr); n_ch <- posterior::nchains(arr)
    drop_fit(f)
    r <- f$r; par <- f$par; teams <- inp$teams; nt <- nrow(teams)
    elig <- team_eligible(teams)
    field <- ncaa_field(kit$games, teams, kit$champs, kit$season)
    sim <- season_sim(r, par, inp, inp$champs, inp$tourney)
    n_al <- field_size(kit$season, cfg) - rowSums(sim$auto)
    ord <- lapply(seq_len(nrow(r)), \(d) sort(r[d, !sim$auto[d, ] & elig], decreasing = TRUE))
    auto_ids <- field$team_id[field$auto]
    pool <- teams$team_id %in% teams$team_id[elig] & !teams$team_id %in% auto_ids
    al <- field$team_id[!field$auto]
    bench <- do.call(rbind, lapply(names(BENCHMARKS), function(nm) {
      b <- BENCHMARKS[[nm]]
      rb <- if (!is.null(b$rank)) apply(r, 1, \(x) sort(x, decreasing = TRUE)[b$rank])
            else vapply(seq_along(ord), \(d) ord[[d]][n_al[d] + b$offset], numeric(1))
      w <- wab_given_bench(r, par, inp, rb)$wab
      wm <- colMeans(w)
      pick <- teams$team_id[pool][order(-wm[pool])][seq_len(length(al))]
      data.frame(season = kit$season, benchmark = nm, team_id = teams$team_id, wab = wm,
                 wab_rank = rank(-wm, ties.method = "first"), bench_rank = mean(rowSums(r > rb) + 1),
                 picked = teams$team_id %in% pick, at_large = teams$team_id %in% al, pool = pool)
    }))
    # SOR: P(the draw's 25th-best team wins at least as many of this schedule's games)
    rb0 <- vapply(seq_along(ord), \(d) ord[[d]][n_al[d]], numeric(1))
    r25 <- apply(r, 1, \(x) sort(x, decreasing = TRUE)[25])
    w25 <- wab_given_bench(r, par, inp, r25)
    thin <- round(seq(1, nrow(r), length.out = 400))
    at_least <- function(p, k) { d <- 1; for (pj in p) d <- c(d * (1 - pj), 0) + c(0, d * pj); sum(d[(k + 1):length(d)]) }
    sor <- do.call(rbind, lapply(seq_len(nt), function(i) {
      rows <- which(w25$ti == i)
      if (!length(rows)) return(NULL)
      k <- sum(w25$win[rows]); pb <- w25$p_bench[, rows, drop = FALSE]
      data.frame(season = kit$season, team_id = teams$team_id[i], sor_mean_pi = at_least(colMeans(pb), k),
                 sor_per_draw = mean(apply(pb[thin, , drop = FALSE], 1, at_least, k = k)))
    }))
    # Monte Carlo standard errors of the published quantities (every draw is used)
    w0 <- wab_given_bench(r, par, inp, rb0)$wab
    rk <- t(apply(-w0, 1, rank, ties.method = "random"))
    as_arr <- function(m) posterior::as_draws_array(array(m, c(n_iter, n_ch, ncol(m))))
    mcse <- data.frame(season = kit$season, team_id = teams$team_id,
      wab = colMeans(w0), wab_mcse = posterior::summarise_draws(as_arr(w0), "mcse_mean")$mcse_mean,
      rating_mcse = posterior::summarise_draws(as_arr(r), "mcse_mean")$mcse_mean,
      rank_q10_mcse = posterior::summarise_draws(as_arr(rk), \(x) posterior::mcse_quantile(x, 0.1))[[2]],
      rank_q90_mcse = posterior::summarise_draws(as_arr(rk), \(x) posterior::mcse_quantile(x, 0.9))[[2]],
      p_pos_mcse = posterior::summarise_draws(as_arr((w0 > 0) * 1), "mcse_mean")$mcse_mean)
    # every team-game at the published benchmark: the benchmark's and the team's own win
    # probability (posterior means), for worked examples
    wb <- wab_given_bench(r, par, inp, rb0)
    g <- inp$games
    opp <- c(g$away_id, g$home_id)
    p_win <- colMeans(stats::pt((r[, wb$ti, drop = FALSE] - r[, match(opp, teams$team_id), drop = FALSE] +
                                   outer(par$hca, c(game_site(g), -game_site(g)))) /
                                  outer(par$sigma_game, 1 / sqrt(rep(g$poss_reg / 70, 2))), df = matrix(par$nu, nrow(r), 2 * nrow(g))))
    games <- data.frame(season = kit$season, team_id = teams$team_id[wb$ti], opp_id = opp, game_id = rep(g$game_id, 2),
                        game_date = rep(g$game_date, 2), venue = c(game_site(g), -game_site(g)),
                        pts_for = c(g$home_score, g$away_score), pts_against = c(g$away_score, g$home_score),
                        win = wb$win, p_bench = colMeans(wb$p_bench), p_win = p_win)
    list(season = kit$season, snap_date = inp$snap_date, pass = f$pass, gates = f$gates, field = field,
         bench = bench, sor = sor, mcse = mcse, games = games, n_at_large = mean(n_al))
  }, workers)
  res
}

# ---- How margin reaches the resume ------------------------------------------------------

# Refit the last complete season's final snapshot with one blowout's margin replaced by a
# one-point win (same winner, efficiency signal dropped), for the n_games largest D1 margins,
# and record how the two teams' WAB and power move, and how far the change spreads
run_margin_leakage <- function(kit, cfg = model_config(), n_games = 6L, workers = 4L) {
  inp <- kit_input(kit, nrow(kit$dates), cfg)
  g <- inp$games
  pts <- g$home_score - g$away_score
  picks <- order(-abs(pts))[seq_len(n_games)]
  res <- mclapply_safe(c(list(NULL), as.list(picks)), function(k) {
    x <- inp
    if (!is.null(k)) {
      x$stan$margin[k] <- sign(pts[k]) * 100 / g$poss_reg[k]
      x$stan$has_eff[k] <- 0L; x$stan$eff[k] <- 0
    }
    f <- suppressWarnings(fit_snapshot(x, cfg))
    w <- wab_draws(f, inp, field = field_size(kit$season, cfg), champs = inp$champs, tourney = inp$tourney)
    data.frame(changed = if (is.null(k)) NA_integer_ else k, team_id = inp$teams$team_id, wab = colMeans(w), power = colMeans(f$r))
  }, workers)
  base <- res[[1]]
  do.call(rbind, lapply(res[-1], function(x) {
    k <- x$changed[1]
    ids <- if (pts[k] > 0) c(winner = g$home_id[k], loser = g$away_id[k]) else c(winner = g$away_id[k], loser = g$home_id[k])
    i <- match(ids, base$team_id)
    data.frame(game_id = g$game_id[k], game_date = g$game_date[k], margin = abs(pts[k]), role = names(ids),
               team = inp$teams$team[i], wab_base = base$wab[i], wab_new = x$wab[i],
               power_base = base$power[i], power_new = x$power[i],
               others_wab = mean(abs(x$wab - base$wab)[-i]), others_power = mean(abs(x$power - base$power)[-i]))
  }))
}

# ---- Prior draws: SBC and induced priors --------------------------------------------------

# One draw of every parameter and team state from the priors, through the hierarchy, for an input's
# Stan data sd (normal margins unless sd$margin_family says otherwise)
draw_prior <- function(sd) {
  hn <- function(p) { repeat { x <- stats::rnorm(1, p[1], p[2]); if (x > 0) return(x) } }
  tn <- function(p, lo, hi) { repeat { x <- stats::rnorm(1, p[1], p[2]); if (x > lo && x < hi) return(x) } }
  p <- list(sigma_conf = hn(sd$sigma_conf_prior), sigma_team = hn(sd$sigma_team_prior), b_prev = tn(sd$b_prev_prior, 0, 1.2),
            b_prev2 = if (sd$use_prev2 == 1) stats::rnorm(1, sd$b_prev2_prior[1], sd$b_prev2_prior[2]) else 0,
            hca = stats::rnorm(1, sd$hca_prior[1], sd$hca_prior[2]), sigma_m = hn(sd$sigma_m_prior),
            tau = if (sd$dynamic == 1) hn(sd$tau_prior) else 0,
            lambda = if (sd$use_eff == 1) hn(sd$lambda_prior) else 0, sigma_eff = if (sd$use_eff == 1) hn(sd$sigma_eff_prior) else 0,
            kappa = if (sd$use_eff == 1) stats::rnorm(1, sd$kappa_prior[1], sd$kappa_prior[2]) else 0,
            r_nd = stats::rnorm(1, sd$r_nd_prior[1], sd$r_nd_prior[2]), sigma_nd = hn(sd$sigma_nd_prior),
            nu = if (sd$margin_family == 1) { repeat { x <- stats::rgamma(1, sd$nu_prior[1], sd$nu_prior[2]); if (x > 2) break }; x } else 1e4,
            p_out = if (sd$margin_family == 3) { repeat { x <- stats::rbeta(1, sd$p_out_prior[1], sd$p_out_prior[2]); if (x < 0.5) break }; x } else 0,
            k_out = if (sd$margin_family == 3) tn(sd$k_out_prior, 1, Inf) else 1)
  p$sigma_game <- sqrt(p$sigma_m^2 + (p$kappa * p$sigma_eff)^2)
  mu_conf <- p$sigma_conf * stats::rnorm(sd$N_conf)
  p$r0 <- mu_conf[sd$team_conf] + p$b_prev * sd$prev_dev + p$b_prev2 * sd$prev2_dev +
    sqrt(p$sigma_team^2 + (p$b_prev * sd$prev_sd)^2) * stats::rnorm(sd$N_teams)
  step <- sqrt(sd$state_gap) * stats::rnorm(sd$N_states)
  p$r_state <- p$r0[sd$state_team] + p$tau * stats::ave(step, sd$state_team, FUN = cumsum)   # states run in order within a team
  last <- ifelse(sd$now_state == 0, p$r0, p$r_state[pmax(sd$now_state, 1)])
  p$r_now <- last + p$tau * sqrt(sd$now_gap) * stats::rnorm(sd$N_teams)
  p
}

# Simulated efficiency signals and margins (per 100) for the games of sd under prior draw p
simulate_games <- function(sd, p) {
  par <- as.data.frame(p[c("nu", "p_out", "k_out")])
  mu <- p$r_state[sd$home_state] - p$r_state[sd$away_state] + p$hca * sd$home_adv
  sw_m <- sqrt(sd$w_m); sw_e <- sqrt(sd$w_e); e <- sd$has_eff == 1 & sd$use_eff == 1
  eff <- ifelse(e, stats::rnorm(sd$N_games, p$lambda * mu, p$sigma_eff / sw_e), 0)
  scale <- ifelse(e, p$sigma_m / sw_m, sqrt((p$sigma_m / sw_m)^2 + (p$kappa * p$sigma_eff / sw_e)^2))
  loc <- ifelse(e, mu + p$kappa * (eff - p$lambda * mu), mu)
  margin <- as.vector(rmargin(matrix(loc, 1), matrix(scale, 1), par, sd$margin_family))
  nd <- if (sd$N_nd) as.vector(rmargin(matrix(p$r_state[sd$nd_state] - p$r_nd + p$hca * sd$nd_venue, 1),
                                       matrix(sqrt(p$sigma_game^2 / sd$nd_w + p$sigma_nd^2), 1), par, sd$margin_family)) else numeric()
  list(mu = mu, eff = eff, margin = margin, nd = nd)
}

# WAB per draw against the b-th best team by rating (no bids), from Stan data and given results:
# r draws x teams; par: hca, sigma_game, nu; win: home team won each game
wab_fixed <- function(r, par, sd, win, b) {
  N <- length(win)
  hi <- sd$state_team[sd$home_state[seq_len(N)]]; ai <- sd$state_team[sd$away_state[seq_len(N)]]
  v <- sd$home_adv[seq_len(N)]; sc <- outer(par$sigma_game, 1 / sqrt(sd$w_m[seq_len(N)]))
  df <- matrix(par$nu, nrow(r), N)
  rb <- apply(r, 1, \(x) sort(x, decreasing = TRUE)[b])
  ph <- stats::pt((rb - r[, ai, drop = FALSE] + outer(par$hca, v)) / sc, df = df)
  pa <- stats::pt((rb - r[, hi, drop = FALSE] - outer(par$hca, v)) / sc, df = df)
  H <- Matrix::sparseMatrix(i = seq_len(N), j = hi, x = 1, dims = c(N, ncol(r)))
  A <- Matrix::sparseMatrix(i = seq_len(N), j = ai, x = 1, dims = c(N, ncol(r)))
  as.matrix(sweep(-ph, 2, win, `+`) %*% H + sweep(-pa, 2, 1 - win, `+`) %*% A)
}

# Simulation-based calibration: a real snapshot's structure (teams, conferences, carry-over,
# schedule, weights, non-D1 games), every parameter and team state drawn from the priors, the
# signals simulated as the model specifies, refit with short chains; each true value is ranked
# among n_rank thinned posterior draws. Quantities: the structural parameters, each team's rating
# at the snapshot, its power rank and its WAB against a fixed benchmark rank (bench).
run_sbc <- function(inp, cfg = model_config(), n_sims = 200L, workers = 8L, n_rank = 99L, bench = 45L, seed = 2026) {
  scfg <- fast_config(cfg, chains = 2L, warmup = 500L, sampling = 500L)
  sd0 <- inp$stan
  N <- sd0$N_games
  vars <- setdiff(struct_vars(cfg), "nu")
  res <- mclapply_safe(seq_len(n_sims), function(i) {
    set.seed(seed + i)
    p <- draw_prior(sd0)
    sim <- simulate_games(sd0, p)
    x <- inp
    x$stan$eff <- sim$eff; x$stan$margin <- sim$margin; x$stan$nd_margin <- sim$nd
    f <- suppressWarnings(fit_snapshot(x, scfg, seed = i))
    keep <- round(seq(1, nrow(f$r), length.out = n_rank))
    rstat <- function(post, truth) vapply(seq_along(truth), function(j) {
      v <- post[keep, j]; sum(v < truth[j]) + sum(stats::runif(sum(v == truth[j])) < 0.5)
    }, numeric(1))
    cover <- function(post, truth) {
      truth >= apply(post, 2, stats::quantile, 0.1, names = FALSE) & truth <= apply(post, 2, stats::quantile, 0.9, names = FALSE)
    }
    r0 <- p$r_now - mean(p$r_now)
    win <- as.numeric(sim$margin > 0)
    tp <- data.frame(hca = p$hca, sigma_game = p$sigma_game, nu = p$nu)
    w0 <- wab_fixed(matrix(r0, 1), tp, x$stan, win, bench)[1, ]
    w <- wab_fixed(f$r, f$par, x$stan, win, bench)
    rk <- t(apply(-f$r, 1, rank, ties.method = "min")); rk0 <- rank(-r0, ties.method = "min")
    sp <- as.matrix(f$par[, vars]); st <- unlist(p[vars])
    rbind(
      data.frame(sim = i, quantity = vars, team = NA_integer_, rank = rstat(sp, st), covered = cover(sp, st)),
      data.frame(sim = i, quantity = "Power rating", team = seq_along(r0), rank = rstat(f$r, r0), covered = cover(f$r, r0)),
      data.frame(sim = i, quantity = "Power rank", team = seq_along(r0), rank = rstat(rk, rk0), covered = cover(rk, rk0)),
      data.frame(sim = i, quantity = "WAB", team = seq_along(r0), rank = rstat(w, w0), covered = cover(w, w0))
    ) |> transform(pass = gates_pass(f$gates), divergences = f$gates[["divergences"]])
  }, workers)
  list(snap_date = inp$snap_date, n_games = N, n_teams = sd0$N_teams, n_rank = n_rank, bench = bench, ranks = do.call(rbind, res))
}

# Prior predictive simulation on a snapshot's teams and games: the quantities the priors induce on
# things with an intuitive scale, against what the data show
induced_priors <- function(inp, cfg = model_config(), n = 4000L, seed = 1) {
  set.seed(seed)
  sd <- inp$stan; N <- nrow(inp$games)
  pts <- inp$games$poss_reg / 100
  site <- sd$home_adv[seq_len(N)]
  draws <- do.call(rbind, lapply(seq_len(n), function(s) {
    p <- draw_prior(sd)
    y <- round(simulate_games(sd, p)$margin[seq_len(N)] * pts)
    r <- sort(p$r_now - mean(p$r_now), decreasing = TRUE)
    data.frame(hca = p$hca, sigma_game = p$sigma_game, r2 = (p$kappa * p$sigma_eff)^2 / p$sigma_game^2, tau = p$tau,
               sd_rating = stats::sd(r), top_minus_45 = r[1] - r[45], p_home_even = stats::pnorm(p$hca / p$sigma_game),
               p_top_vs_avg = stats::pnorm(r[1] / p$sigma_game), sd_margin = stats::sd(y), within3 = mean(abs(y) <= 3),
               home_win = mean(y[site == 1] > 0))
  }))
  obs <- round(sd$margin[seq_len(N)] * pts)
  list(draws = draws, observed = c(sd_margin = stats::sd(obs), within3 = mean(abs(obs) <= 3), home_win = mean(obs[site == 1] > 0)))
}

# ---- Full-draw fits for the supplement ------------------------------------------------------

# The first weekly snapshot (about two games a team; the prior dominates) and the final one of
# the last complete season, with what the appendix needs: draws, sampler diagnostics, PSIS-LOO
# with LOO-PIT, replicated margins and a power-scaling sequence
run_supplement <- function(kit, cfg = model_config(), workers = 2L) {
  picks <- c(first = kit_index(kit, "weekly")[1], final = nrow(kit$dates))
  scfg <- utils::modifyList(cfg, list(save_loglik = TRUE))
  mclapply_safe(as.list(picks), function(i) {
    inp <- kit_input(kit, i, scfg)
    f <- fit_keep(inp, scfg)
    fit <- f$fit
    vars <- struct_vars(scfg)
    sd <- inp$stan; N <- nrow(inp$games)
    l <- fit$loo(variables = "log_lik", r_eff = TRUE, save_psis = TRUE)
    w <- stats::weights(l$psis_object, log = FALSE, normalize = TRUE)
    par <- as.data.frame(unclass(posterior::as_draws_matrix(fit$draws(model_pars(scfg)))))
    mu <- game_mu(fit, sd)
    S <- nrow(mu)
    pit_margin <- unname(colSums(w * pmargin(matrix(sd$margin, S, N, byrow = TRUE), mu, margin_scale(par, sd), par, scfg$margin_family)))
    pit_eff <- colSums(w * stats::pnorm((matrix(sd$eff, S, N, byrow = TRUE) - par$lambda * mu) / outer(par$sigma_eff, 1 / sqrt(sd$w_e))))
    pit_eff[sd$has_eff == 0] <- NA_real_
    set.seed(2026)
    pick <- sort(sample.int(S, min(400L, S)))
    pts <- inp$games$poss_reg / 100
    yrep <- round(rmargin(mu[pick, ], margin_scale(par[pick, ], sd), par[pick, ], scfg$margin_family) *
                    matrix(pts, length(pick), N, byrow = TRUE))
    he <- which(sd$has_eff[seq_len(N)] == 1)
    erep <- par$lambda[pick] * mu[pick, he, drop = FALSE] +
      outer(par$sigma_eff[pick], 1 / sqrt(sd$w_e[he])) * matrix(stats::rnorm(length(pick) * length(he)), length(pick))
    ps <- tryCatch(priorsense::powerscale_sequence(fit$draws(c(vars, "lprior", "log_lik")), variable = vars), error = function(e) NULL)
    out <- list(season = kit$season, snap_date = inp$snap_date, kind = inp$kind, n_games = N, n_teams = sd$N_teams,
                n_states = sd$N_states, gates = f$gates, pass = f$pass, time = fit$time(),
                metadata = fit$metadata()[c("max_treedepth", "adapt_delta", "iter_warmup", "iter_sampling")],
                par = fit$draws(vars), r = fit$draws("r"), z = fit$draws("z"), conf_raw = fit$draws("conf_raw"),
                diag = fit$sampler_diagnostics(), loo = l[c("estimates", "pointwise", "diagnostics")],
                pit_margin = pit_margin, pit_eff = pit_eff, mu_mean = unname(colMeans(mu)) * inp$games$poss_reg / 100, yrep = yrep,
                erep = erep, eff = sd$eff[he], has_eff = sd$has_eff[seq_len(N)] == 1, w_m = sd$w_m[seq_len(N)],
                obs = round(sd$margin[seq_len(N)] * pts), site = sd$home_adv[seq_len(N)], games = inp$games[, c("game_id", "game_date", "home_id", "away_id", "home", "away", "home_conf", "away_conf",
                                                                      "home_score", "away_score", "poss_reg", "site")],
                teams = inp$teams[, c("team_id", "team", "conf")], powerscale = ps)
    drop_fit(f)
    out
  }, workers)
}

# ---- Prior perturbation ---------------------------------------------------------------------

PRIOR_GROUPS <- list(hierarchy = c("sigma_conf_prior", "sigma_team_prior"), drift = "tau_prior", home = "hca_prior",
                     carry = c("b_prev_prior", "b_prev2_prior"), margin = "sigma_m_prior",
                     efficiency = c("lambda_prior", "sigma_eff_prior", "kappa_prior"), nond1 = c("r_nd_prior", "sigma_nd_prior"))

# cfg with the chosen priors widened (sd x sd_mult) and/or shifted (mean + shift x sd, before
# widening); b_prev's mean stays inside its bounds
perturb_priors <- function(cfg, sd_mult = 1, shift = 0, groups = names(PRIOR_GROUPS)) {
  move <- function(p) c(p[1] + shift * p[2], p[2] * sd_mult)
  for (f in unlist(PRIOR_GROUPS[groups])) {
    cfg[[f]] <- move(cfg[[f]])
    if (f == "hca_prior") cfg$hca_prior_season <- lapply(cfg$hca_prior_season, move)
  }
  cfg$b_prev_prior[1] <- min(max(cfg$b_prev_prior[1], 0.05), 1.15)
  cfg
}

prior_scenarios <- function() {
  rbind(data.frame(scenario = c("Baseline", "SD x 2", "SD x 5", "Means + 1 SD", "Means - 1 SD"),
                   sd_mult = c(1, 2, 5, 1, 1), shift = c(0, 0, 0, 1, -1), group = "all"),
        data.frame(scenario = paste0("SD x 5: ", names(PRIOR_GROUPS)), sd_mult = 5, shift = 0, group = names(PRIOR_GROUPS)))
}

# The first weekly snapshot and the final one of a season refit under each scenario; the
# structural parameters and the published products (rating, rank, WAB, WAB rank)
run_prior_sensitivity <- function(kit, cfg = model_config(), workers = 4L) {
  picks <- c(first = kit_index(kit, "weekly")[1], final = nrow(kit$dates))
  sc <- prior_scenarios()
  jobs <- expand.grid(fit = names(picks), i = seq_len(nrow(sc)), stringsAsFactors = FALSE)
  mclapply_safe(seq_len(nrow(jobs)), function(j) {
    s <- sc[jobs$i[j], ]
    pcfg <- perturb_priors(cfg, s$sd_mult, s$shift, if (s$group == "all") names(PRIOR_GROUPS) else s$group)
    inp <- kit_input(kit, picks[[jobs$fit[j]]], pcfg)
    f <- fit_keep(inp, pcfg)
    par <- par_summary(f$fit, struct_vars(pcfg))
    drop_fit(f)
    rt <- summarise_ratings(f, inp)
    w <- wab_draws(f, inp, field = field_size(kit$season, pcfg), champs = inp$champs, tourney = inp$tourney)
    rs <- summarise_resume(w, inp)
    list(season = kit$season, fit = jobs$fit[j], snap_date = inp$snap_date, scenario = s$scenario, pass = f$pass,
         gates = f$gates, par = par,
         ratings = merge(rt[, c("team_id", "team", "rating", "sd", "rank")], rs[, c("team_id", "wab", "wab_rank")], by = "team_id"))
  }, workers)
}

# ---- Summaries of the published snapshots -------------------------------------------------

# The resume against the selection committee, by season: at Selection Monday, how many of the
# committee's at-large teams our WAB picks (the actual automatic bids given) and how many our
# power ranking would, Spearman correlations of each with the seed lines, against Torvik's WAB
# that day; and at the final snapshot, the share of the season's decided D1 games the higher-
# ranked team won under each ranking (retrodictive accuracy)
resume_validation <- function(snapshots, kits, overrides = "data/torvik_names.csv") {
  out <- lapply(kits, function(kit) {
    s <- kit$season; tm <- kit$teams
    res <- snapshots$resume[snapshots$resume$season == s, ]
    rat <- snapshots$ratings[snapshots$ratings$season == s, ]
    sel <- res[res$kind == "selection", ]; selr <- rat[rat$kind == "selection", ]
    committee <- NULL
    field <- ncaa_field(kit$games, tm, kit$champs, s)
    if (nrow(sel) && !is.null(field)) {
      elig <- tm$team_id[team_eligible(tm)]
      al <- field$team_id[!field$auto]
      pool <- sel[sel$team_id %in% elig & !(sel$team_id %in% field$team_id[field$auto]), ]
      pick <- pool$team_id[order(-pool$wab)][seq_along(al)]
      pr <- selr[selr$team_id %in% pool$team_id, ]
      pick_pow <- pr$team_id[order(-pr$rating)][seq_along(al)]
      ps <- sel[sel$team_id %in% pool$team_id & !is.na(sel$sor), ]
      pick_sor <- ps$team_id[order(ps$sor)][seq_along(al)]
      fs <- merge(merge(field, sel[, c("team_id", "wab")], by = "team_id"), selr[, c("team_id", "rating")], by = "team_id")
      tv_cor <- NA_real_
      f <- tryCatch(fetch_torvik_tm(unique(sel$snap_date) - 1), error = function(e) NA)
      if (!is.na(f)) {
        z <- jsonlite::fromJSON(gzcon(file(f, "rb")))
        tv <- torvik_team_ids(data.frame(team = z[, 2], wab = as.numeric(z[, 42])), tm, overrides)
        m <- merge(sel[, c("team_id", "wab")], tv[, c("team_id", "wab")], by = "team_id", suffixes = c("", "_torvik"))
        tv_cor <- stats::cor(m$wab, m$wab_torvik, method = "spearman")
      }
      committee <- data.frame(season = s, snap_date = unique(sel$snap_date), field = nrow(field), at_large = length(al),
        overlap_wab = sum(pick %in% al), overlap_power = sum(pick_pow %in% al), overlap_sor = sum(pick_sor %in% al),
        missed = paste(tm$team[match(setdiff(al, pick), tm$team_id)], collapse = "; "),
        instead = paste(tm$team[match(setdiff(pick, al), tm$team_id)], collapse = "; "),
        seed_cor_wab = stats::cor(fs$seed, -fs$wab, method = "spearman"),
        seed_cor_power = stats::cor(fs$seed, -fs$rating, method = "spearman"), torvik_wab_cor = tv_cor)
    }
    fin <- res[res$kind == "final", ]; finr <- rat[rat$kind == "final", ]
    g <- kit$games[kit$games$division %in% "d1" & kit$games$played %in% TRUE & kit$games$home_score != kit$games$away_score, ]
    sys <- list(Power = setNames(finr$rank, finr$team_id), WAB = setNames(fin$wab_rank, fin$team_id),
                SOR = setNames(rank(fin$sor, ties.method = "first", na.last = "keep"), fin$team_id),
                Colley = setNames(rank(-fin$colley, ties.method = "first", na.last = "keep"), fin$team_id))
    retro <- do.call(rbind, lapply(names(sys), function(nm) {
      rh <- sys[[nm]][as.character(g$home_id)]; ra <- sys[[nm]][as.character(g$away_id)]
      ok <- !is.na(rh) & !is.na(ra)
      data.frame(season = s, system = nm, games = sum(ok), retro_acc = mean(((rh < ra) == (g$home_score > g$away_score))[ok]))
    }))
    list(committee = committee, retro = retro)
  })
  list(committee = do.call(rbind, lapply(out, `[[`, "committee")), retro = do.call(rbind, lapply(out, `[[`, "retro")))
}

# Preseason sources compared on each season's games before its second Monday, predicted from the
# prior alone (plus home court at the season's final estimate): our last final rating, Torvik's
# preseason rating, their even blend, and the published prior (the roster regression where it has
# a prediction); and each source's correlation with the season's final rating
preseason_eval <- function(kits, snapshots) {
  do.call(rbind, lapply(kits, function(kit) {
    s <- kit$season
    feats <- attr(kit$prior, "features")
    if (is.null(feats)) return(NULL)
    src <- data.frame(team_id = feats$team_id, own = feats$own, torvik = feats$tv, blend = (feats$own + feats$tv) / 2)
    src$published <- kit$prior$prev_dev[match(src$team_id, kit$prior$team_id)]
    hca <- snapshots$params$hca[snapshots$params$season == s & snapshots$params$kind == "final"]
    g <- kit$games[kit$games$division %in% "d1" & kit$games$played %in% TRUE, ]
    mon <- kit$dates$snap_date[kit$dates$kind %in% c("weekly", "selection")][2]
    g <- g[g$game_date < mon, ]
    fin <- snapshots$ratings[snapshots$ratings$season == s & snapshots$ratings$kind == "final", ]
    do.call(rbind, lapply(c("own", "torvik", "blend", "published"), function(k) {
      d <- src[[k]][match(g$home_id, src$team_id)] - src[[k]][match(g$away_id, src$team_id)]
      pred <- (dplyr::coalesce(d, 0) + hca * game_site(g)) * g$poss / 100
      f <- fin$rating[match(src$team_id, fin$team_id)]
      data.frame(season = s, source = k, games = nrow(g), mae = mean(abs(g$home_score - g$away_score - pred)),
                 cor_final = stats::cor(src[[k]], f, use = "complete.obs"), teams = sum(!is.na(src[[k]])))
    }))
  }))
}

# Connected components of the D1 schedule graph at each snapshot of each season
schedule_components <- function(kits) {
  do.call(rbind, lapply(kits, function(kit) {
    g <- kit$games[kit$games$division %in% "d1" & kit$games$played %in% TRUE, ]
    do.call(rbind, lapply(seq_len(nrow(kit$dates)), function(i) {
      gw <- g[g$game_date < kit$dates$snap_date[i], ]
      if (!nrow(gw)) return(data.frame(season = kit$season, snap_date = kit$dates$snap_date[i], teams = 0L, components = NA_integer_, largest = NA_integer_))
      gr <- igraph::graph_from_data_frame(data.frame(from = gw$home_id, to = gw$away_id), directed = FALSE)
      comp <- igraph::components(gr)
      data.frame(season = kit$season, snap_date = kit$dates$snap_date[i], teams = igraph::vcount(gr),
                 components = comp$no, largest = max(comp$csize))
    }))
  }))
}

# Uncertainty of the headline backtest comparisons (complete seasons). Games predicted by the same
# snapshot share information, so standard errors and the bootstrap resample snapshots (season x
# snapshot date), not games.
backtest_stats <- function(bt, seasons, B = 2000L, seed = 1) {
  set.seed(seed)
  g <- bt$games[bt$games$season %in% seasons, ]
  cl <- paste(g$season, g$snap_date)
  dm <- function(d, cl) { m <- mean(d); u <- tapply(d - m, cl, sum); se <- sqrt(sum(u^2)) / length(d); c(mean = m, se = se, z = m / se) }
  lined <- !is.na(g$line)
  ll <- function(p, y) -(y * log(pmax(p, 1e-6)) + (1 - y) * log(pmax(1 - p, 1e-6)))
  tv <- !is.na(g$pred_torvik) & lined
  clusters <- split(seq_len(nrow(g)), cl)
  boot <- replicate(B, {
    i <- unlist(clusters[sample.int(length(clusters), replace = TRUE)], use.names = FALSE)
    c(mae = mean(abs(g$actual[i] - g$pred_margin[i])), logloss = mean(ll(g$p_home[i], g$home_win[i])),
      brier = mean((g$p_home[i] - g$home_win[i])^2))
  })
  ats <- g[lined & g$actual != g$line & g$pred_margin != g$line, ]
  ats_w <- sign(ats$actual - ats$line) == sign(ats$pred_margin - ats$line)
  bt_ <- stats::binom.test(sum(ats_w), length(ats_w))
  q <- function(level) { z <- stats::qnorm(0.5 + level / 2); abs(g$actual - g$pred_margin) <= z * g$pred_sd }
  bins <- cut(g$p_home, seq(0, 1, 0.1), include.lowest = TRUE)
  spieg <- function(p, y) sum((y - p) * (1 - 2 * p)) / sqrt(sum((1 - 2 * p)^2 * p * (1 - p)))
  list(
    n = nrow(g), n_lined = sum(lined),
    dm_mae_line = dm(abs(g$actual - g$pred_margin)[lined] - abs(g$actual - g$line)[lined], cl[lined]),
    dm_brier_line = dm(((g$p_home - g$home_win)^2 - (g$p_line - g$home_win)^2)[lined], cl[lined]),
    dm_mae_torvik = dm(abs(g$actual - g$pred_margin)[tv] - abs(g$actual - g$pred_torvik)[tv], cl[tv]),
    dm_logloss_torvik = dm((ll(g$p_home, g$home_win) - ll(g$p_torvik, g$home_win))[tv], cl[tv]),
    score_ci = data.frame(metric = rownames(boot), lo = apply(boot, 1, stats::quantile, 0.025), hi = apply(boot, 1, stats::quantile, 0.975)),
    ats = c(rate = unname(bt_$estimate), lo = bt_$conf.int[1], hi = bt_$conf.int[2], n = length(ats_w)),
    coverage = data.frame(level = c(0.5, 0.8, 0.95), cover = vapply(c(0.5, 0.8, 0.95), \(a) mean(q(a)), numeric(1))),
    coverage_period = do.call(rbind, lapply(split(seq_len(nrow(g)), g$period), function(i)
      data.frame(period = g$period[i[1]], level = c(0.5, 0.8, 0.95), cover = vapply(c(0.5, 0.8, 0.95), \(a) mean(q(a)[i]), numeric(1))))),
    calibration = data.frame(bin = levels(bins), pred = as.vector(tapply(g$p_home, bins, mean)), obs = as.vector(tapply(g$home_win, bins, mean)),
                             n = as.vector(table(bins))),
    calibration_tests = data.frame(ece = sum(tapply(g$p_home - g$home_win, bins, \(x) abs(sum(x))), na.rm = TRUE) / nrow(g),
                                   spiegelhalter_z = spieg(g$p_home, g$home_win)),
    slope = stats::coef(stats::lm(actual ~ pred_margin, g))[["pred_margin"]],
    slope_line = stats::coef(stats::lm(actual ~ line, g[lined, ]))[["line"]]
  )
}

# The data behind a build: per season, row counts and a hash of the games table
data_fingerprint <- function(kits) {
  do.call(rbind, lapply(kits, function(kit) {
    g <- kit$games
    d1 <- g$division %in% "d1" & g$played %in% TRUE
    data.frame(season = kit$season, d1_teams = nrow(kit$teams), d1_games = sum(d1), nond1_games = sum(g$division %in% "nond1" & g$played %in% TRUE),
               with_eff = sum(g$has_eff[d1] %in% TRUE), with_line = sum(!is.na(g$spread[d1])), snapshots = nrow(kit$dates),
               hash = digest::digest(g, algo = "xxhash64"))
  })) |> transform(built = Sys.time())
}
