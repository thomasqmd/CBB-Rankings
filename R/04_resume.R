# ==============================================================================
# Resume: Wins Above Bubble (WAB) per posterior draw, the rest of the season simulated from the
# same draws, and the team sheet.
#
# In draw s the benchmark is the last team in: the automatic bids and the teams not yet eligible
# for the NCAA tournament leave the power ranking and the benchmark is the n_at_large-th best
# remaining team by rating. Each D1 game adds W - P(benchmark wins that game at that venue);
# summing gives WAB.
#
# season_sim() plays out the rest of the season in each draw: the remaining regular-season games,
# then each conference tournament (champion fixed once its final is played; otherwise the alive
# teams in a seeded single-elimination bracket the size of last season's tournament, seeds from
# the simulated conference standings; the standings leader where the conference has no
# tournament). Its champions are the automatic bids, and the projected WAB (WAB so far plus the
# simulated games) picks the at-large teams, so P(auto bid), P(at-large) and P(in field) come
# out jointly.
# ==============================================================================

SIM_DRAWS <- 1000      # posterior draws used for WAB and the season simulation

team_eligible <- function(teams) if (is.null(teams$eligible)) rep(TRUE, nrow(teams)) else teams$eligible %in% TRUE

# Conference-tournament sizes from a season's games (teams that played in it; 0 = the conference
# played no tournament that season, as the Ivy League before 2016-17)
tourney_sizes <- function(games) {
  if (is.null(games)) return(NULL)
  d1 <- games[games$division %in% "d1" & games$played, ]
  t <- d1[d1$game_type %in% "TRNMNT" & d1$season_type %in% "regular" & d1$home_conf %in% d1$away_conf & d1$home_conf == d1$away_conf, ]
  long <- unique(rbind(data.frame(conf = t$home_conf, team_id = t$home_id), data.frame(conf = t$away_conf, team_id = t$away_id)))
  confs <- unique(stats::na.omit(c(d1$home_conf, d1$away_conf)))
  data.frame(conf = confs, size = vapply(confs, \(cf) sum(long$conf == cf), integer(1)))
}

# Slot order of a single-elimination bracket with B slots (a power of 2): seed numbers by position
bracket_order <- function(B) {
  o <- 1L
  while (length(o) < B) { n <- 2L * length(o); o <- as.vector(rbind(o, n + 1L - o)) }
  o
}

# Conference-regular-season games (not tournament games) among games
conf_regular <- function(g) {
  g[!is.na(g$home_conf) & g$home_conf %in% g$away_conf & g$home_conf == g$away_conf &
      !(g$game_type %in% "TRNMNT") & g$season_type %in% "regular", ]
}

# One draw-matrix pass of the rest of the season. r: draws x teams; par: hca, sigma_game, nu per draw.
# Returns the automatic bids (draws x teams), the remaining games and their simulated home wins,
# and every simulated conference-tournament game (draw, two team indices, whether the first won).
season_sim <- function(r, par, inp, champs = NULL, tourney = NULL) {
  teams <- inp$teams; nt <- nrow(teams); nd <- nrow(r)
  elig <- team_eligible(teams)
  sg <- par$sigma_game; nu <- par$nu
  idx <- function(id) match(id, teams$team_id)
  rem <- inp$remaining
  if (is.null(rem)) rem <- inp$games[0, ]
  rem <- rem[!is.na(idx(rem$home_id)) & !is.na(idx(rem$away_id)), ]
  hi <- idx(rem$home_id); ai <- idx(rem$away_id)
  hw <- if (nrow(rem)) {
    mu <- r[, hi, drop = FALSE] - r[, ai, drop = FALSE] + outer(par$hca, game_site(rem))
    matrix(stats::runif(length(mu)) < stats::pt(mu / sg, df = nu), nd)
  } else matrix(FALSE, nd, 0)

  # conference standings at the end of the regular season, ties to the higher rating in the draw
  cg <- conf_regular(inp$games)
  won <- function(h, a, hs, as) c(h[hs > as], a[as > hs])
  w0 <- as.vector(table(factor(idx(won(cg$home_id, cg$away_id, cg$home_score, cg$away_score)), seq_len(nt))))
  n0 <- as.vector(table(factor(idx(c(cg$home_id, cg$away_id)), seq_len(nt))))
  W <- matrix(w0, nd, nt, byrow = TRUE); N <- matrix(n0, nd, nt, byrow = TRUE)
  cr <- which(!is.na(rem$home_conf) & rem$home_conf %in% rem$away_conf & rem$home_conf == rem$away_conf & !(rem$game_type %in% "TRNMNT"))
  if (length(cr)) {
    H <- Matrix::sparseMatrix(i = seq_along(cr), j = hi[cr], x = 1, dims = c(length(cr), nt))
    A <- Matrix::sparseMatrix(i = seq_along(cr), j = ai[cr], x = 1, dims = c(length(cr), nt))
    W <- W + as.matrix(hw[, cr, drop = FALSE] %*% H + (!hw[, cr, drop = FALSE]) %*% A)
    N <- N + matrix(Matrix::colSums(H + A), nd, nt, byrow = TRUE)
  }
  score <- ifelse(N > 0, W / pmax(N, 1), 0.5) + 1e-6 * r

  done <- if (is.null(champs)) integer() else champs$team_id[champs$game_date < inp$snap_date]
  tg <- inp$games[inp$games$game_type %in% "TRNMNT" & inp$games$season_type %in% "regular" &
                    inp$games$home_conf %in% inp$games$away_conf & inp$games$home_conf == inp$games$away_conf, ]
  lost <- c(tg$away_id[tg$home_score > tg$away_score], tg$home_id[tg$away_score > tg$home_score])
  auto <- matrix(FALSE, nd, nt)
  reg <- matrix(FALSE, nd, nt)          # regular-season title (best conference record, any team)
  recs <- list()
  for (cf in setdiff(unique(teams$conf), c(NA, "Indep.", "Independent"))) {
    ka <- which(teams$conf == cf)
    reg[cbind(seq_len(nd), ka[max.col(score[, ka, drop = FALSE], ties.method = "first")])] <- TRUE
    k <- which(teams$conf == cf & elig)
    if (!length(k)) next
    leader <- function() auto[cbind(seq_len(nd), k[max.col(score[, k, drop = FALSE], ties.method = "first")])] <<- TRUE
    ch <- intersect(teams$team_id[teams$conf %in% cf], done)
    # a champion still moving up to D1 (Bellarmine 2022, Merrimack 2023) leaves the bid to the
    # eligible standings leader, as those conferences did
    if (length(ch)) { if (elig[idx(ch[1])]) auto[, idx(ch[1])] <- TRUE else leader(); next }
    size <- if (is.null(tourney) || !cf %in% tourney$conf) length(k) else tourney$size[tourney$conf == cf]
    if (size == 0) { leader(); next }
    n <- min(size, length(k))
    started <- any(tg$home_conf == cf)
    if (started) {
      # alive: last season's number of teams by final standings, plus any team that has played in
      # it, less the teams that lost; seeded by standings
      m <- colMeans(score[, k, drop = FALSE])
      alive <- union(k[order(-m)][seq_len(n)], intersect(k, idx(c(tg$home_id, tg$away_id)[tg$home_conf == cf])))
      alive <- setdiff(alive, idx(lost))
      if (!length(alive)) next
      alive <- alive[order(-colMeans(score[, alive, drop = FALSE]))]
      P <- matrix(alive, nd, length(alive), byrow = TRUE)
    } else {
      ord <- t(apply(score[, k, drop = FALSE], 1, order, decreasing = TRUE))
      P <- matrix(k[ord], nd)[, seq_len(n), drop = FALSE]
    }
    b <- sim_bracket(P, r, sg, nu)
    auto[cbind(seq_len(nd), b$winner)] <- TRUE
    recs <- c(recs, list(b$games))
  }
  list(auto = auto, reg = reg, rem = rem, hi = hi, ai = ai, hw = hw, tourney = do.call(rbind, recs))
}

# A seeded single-elimination bracket in every draw (P: draws x n team indices in seed order;
# byes to the top seeds); neutral floor
sim_bracket <- function(P, r, sg, nu) {
  nd <- nrow(P); n <- ncol(P)
  if (n == 1) return(list(winner = P[, 1], games = NULL))
  B <- 2^ceiling(log2(n)); ord <- bracket_order(B)
  S <- matrix(NA_integer_, nd, B)
  S[, ord <= n] <- P[, ord[ord <= n]]
  recs <- list()
  while (ncol(S) > 1) {
    a <- S[, c(TRUE, FALSE), drop = FALSE]; b <- S[, c(FALSE, TRUE), drop = FALSE]
    win <- a
    win[is.na(a)] <- b[is.na(a)]
    both <- !is.na(a) & !is.na(b)
    if (any(both)) {
      d <- row(a)[both]; ia <- a[both]; ib <- b[both]
      aw <- stats::runif(length(d)) < stats::pt((r[cbind(d, ia)] - r[cbind(d, ib)]) / sg[d], df = nu[d])
      win[both] <- ifelse(aw, ia, ib)
      recs[[length(recs) + 1]] <- data.frame(d = d, a = ia, b = ib, aw = aw)
    }
    S <- win
  }
  list(winner = S[, 1], games = do.call(rbind, recs))
}

wab_draws <- function(fit, inp, games = inp$games, field = 68L, champs = NULL, tourney = NULL) {
  keep <- unique(round(seq(1, nrow(fit$r), length.out = min(SIM_DRAWS, nrow(fit$r)))))
  r <- fit$r[keep, , drop = FALSE]
  par <- fit$par[keep, , drop = FALSE]
  nd <- nrow(r); nt <- ncol(r)
  sim <- season_sim(r, par, inp, champs, tourney)
  auto <- sim$auto
  n_at_large <- field - rowSums(auto)
  elig <- team_eligible(inp$teams)               # ineligible teams are not at-large candidates either
  rb <- vapply(seq_len(nd), \(d) sort(r[d, !auto[d, ] & elig], decreasing = TRUE)[n_at_large[d]], numeric(1))
  bench <- function(opp, venue, w = rep(1, length(opp))) {
    stats::pt((rb - r[, opp, drop = FALSE] + outer(par$hca, venue)) / outer(par$sigma_game, 1 / sqrt(w)),
              df = matrix(par$nu, nd, length(opp)))
  }
  long <- rbind(
    data.frame(team_id = games$home_id, opp_id = games$away_id, venue = game_site(games),
               win = as.integer(games$home_score > games$away_score), w = games$poss_reg / 70),
    data.frame(team_id = games$away_id, opp_id = games$home_id, venue = -game_site(games),
               win = as.integer(games$away_score > games$home_score), w = games$poss_reg / 70))
  oi <- match(long$opp_id, inp$teams$team_id)
  ti <- match(long$team_id, inp$teams$team_id)
  # benchmark's chance in each game: (bubble - opponent) +/- home court
  p_bench <- bench(oi, long$venue, long$w)
  contrib <- sweep(-p_bench, 2, long$win, `+`)                     # draws x team-games
  # sum team-games into teams: (draws x games) %*% (games x teams)
  M <- Matrix::sparseMatrix(i = seq_along(ti), j = ti, x = 1, dims = c(length(ti), nt))
  wab <- as.matrix(contrib %*% M)
  colnames(wab) <- inp$teams$team_id

  # projected WAB: WAB so far plus the simulated rest of the season
  proj <- wab
  if (length(sim$hi)) {
    site <- game_site(sim$rem)
    H <- Matrix::sparseMatrix(i = seq_along(sim$hi), j = sim$hi, x = 1, dims = c(length(sim$hi), nt))
    A <- Matrix::sparseMatrix(i = seq_along(sim$ai), j = sim$ai, x = 1, dims = c(length(sim$ai), nt))
    proj <- proj + as.matrix((sim$hw - bench(sim$ai, site)) %*% H + ((!sim$hw) - bench(sim$hi, -site)) %*% A)
  }
  t <- sim$tourney
  if (!is.null(t) && nrow(t)) {
    pb <- function(opp) stats::pt((rb[t$d] - r[cbind(t$d, opp)]) / par$sigma_game[t$d], df = par$nu[t$d])
    add <- Matrix::sparseMatrix(i = c(t$d, t$d), j = c(t$a, t$b), x = c(t$aw - pb(t$b), (!t$aw) - pb(t$a)), dims = c(nd, nt))
    proj <- proj + as.matrix(add)
  }
  cand <- !auto & matrix(elig, nd, nt, byrow = TRUE)
  rk <- t(apply(ifelse(cand, proj, -Inf), 1, rank, ties.method = "random"))
  rk <- nt + 1 - rk                                                  # 1 = best projected WAB
  at_large <- cand & rk <= n_at_large

  # schedule strength: the bubble team's expected losses against each schedule, and the record
  attr(wab, "bench_losses") <- as.vector(Matrix::colSums(M * (1 - colMeans(p_bench))))
  attr(wab, "wins") <- as.vector(Matrix::colSums(M * long$win))
  attr(wab, "games") <- as.vector(Matrix::colSums(M))
  # the benchmark's power rank in each draw, and the field
  attr(wab, "bench_rank") <- rowSums(r > rb) + 1
  attr(wab, "p_auto") <- colMeans(auto)
  attr(wab, "p_at_large") <- colMeans(at_large)
  attr(wab, "p_conf_reg") <- colMeans(sim$reg)
  attr(wab, "proj_wab") <- colMeans(proj)
  wab
}

# Resume table at a snapshot. p_pos = share of draws in which the team's WAB is positive;
# p_field = P(auto bid) + P(at-large), from the season simulation.
summarise_resume <- function(wab, inp) {
  rk <- t(apply(-wab, 1, rank, ties.method = "random"))
  n <- attr(wab, "games")
  data.frame(team_id = inp$teams$team_id, wins = attr(wab, "wins"), losses = n - attr(wab, "wins"),
             wab = colMeans(wab), wab_lo = apply(wab, 2, stats::quantile, 0.1), wab_hi = apply(wab, 2, stats::quantile, 0.9),
             wab_rank = colMeans(rk), wab_rank_lo = apply(rk, 2, stats::quantile, 0.1), wab_rank_hi = apply(rk, 2, stats::quantile, 0.9),
             p_pos = colMeans(wab > 0), sos = ifelse(n > 0, attr(wab, "bench_losses") / n, NA_real_),
             proj_wab = attr(wab, "proj_wab"), p_auto = attr(wab, "p_auto"), p_at_large = attr(wab, "p_at_large"),
             p_field = attr(wab, "p_auto") + attr(wab, "p_at_large"), p_conf_reg = attr(wab, "p_conf_reg"))
}

# ---- Team sheet ------------------------------------------------------------------------

# NET-style quadrants from our own power ranks: opponent rank cut-offs by venue (home / neutral / away)
QUADRANTS <- list(home = c(30, 75, 160), neutral = c(50, 100, 200), away = c(75, 135, 240))

# Per team at a snapshot: quadrant records (D1 games), luck (wins - expected wins from the
# current ratings), strength of record (P(a top-25 team in that draw would do at least as well
# against this schedule), small = strong) and Colley rating
team_sheet <- function(fit, inp, ratings) {
  teams <- inp$teams; g <- inp$games; nt <- nrow(teams)
  out <- data.frame(team_id = teams$team_id)
  if (!nrow(g)) return(out)
  long <- rbind(data.frame(team_id = g$home_id, opp_id = g$away_id, venue = game_site(g), win = g$home_score > g$away_score, w = g$poss_reg / 70),
                data.frame(team_id = g$away_id, opp_id = g$home_id, venue = -game_site(g), win = g$away_score > g$home_score, w = g$poss_reg / 70))
  long <- long[!is.na(match(long$team_id, teams$team_id)) & !is.na(match(long$opp_id, teams$team_id)), ]
  ti <- match(long$team_id, teams$team_id); oi <- match(long$opp_id, teams$team_id)
  opp_rank <- ratings$rank[match(long$opp_id, ratings$team_id)]
  cut <- do.call(rbind, QUADRANTS[ifelse(long$venue > 0, "home", ifelse(long$venue < 0, "away", "neutral"))])
  long$q <- 1L + (opp_rank > cut[, 1]) + (opp_rank > cut[, 2]) + (opp_rank > cut[, 3])
  for (q in 1:4) {
    out[[paste0("q", q, "_w")]] <- as.vector(table(factor(ti[long$q == q & long$win], seq_len(nt))))
    out[[paste0("q", q, "_l")]] <- as.vector(table(factor(ti[long$q == q & !long$win], seq_len(nt))))
  }
  keep <- unique(round(seq(1, nrow(fit$r), length.out = min(SIM_DRAWS, nrow(fit$r)))))
  r <- fit$r[keep, , drop = FALSE]; par <- fit$par[keep, , drop = FALSE]
  scale <- outer(par$sigma_game, 1 / sqrt(long$w))
  df <- matrix(par$nu, nrow(r), nrow(long))
  hca <- outer(par$hca, long$venue)
  p_win <- colMeans(stats::pt((r[, ti, drop = FALSE] - r[, oi, drop = FALSE] + hca) / scale, df = df))
  out$luck <- as.vector(tapply(long$win - p_win, factor(ti, seq_len(nt)), sum, default = 0))
  r25 <- apply(r, 1, \(x) sort(x, decreasing = TRUE)[25])
  p25 <- colMeans(stats::pt((r25 - r[, oi, drop = FALSE] + hca) / scale, df = df))
  out$sor <- vapply(seq_len(nt), function(i) {
    p <- p25[ti == i]; w <- sum(long$win[ti == i])
    if (!length(p)) return(NA_real_)
    dist <- 1                                  # Poisson-binomial distribution of the top-25 team's wins
    for (pj in p) dist <- c(dist * (1 - pj), 0) + c(0, dist * pj)
    sum(dist[(w + 1):length(dist)])
  }, numeric(1))
  out$colley <- colley(ti, oi, long$win, nt)
  out
}

# Colley matrix ratings from D1 wins and losses (each game listed once per team)
colley <- function(ti, oi, win, nt) {
  C <- diag(2, nt)
  n <- tabulate(ti, nt)
  diag(C) <- diag(C) + n
  pair <- table(factor(ti, seq_len(nt)), factor(oi, seq_len(nt)))
  C <- C - unclass(pair)
  b <- 1 + (tabulate(ti[win], nt) - tabulate(ti[!win], nt)) / 2
  as.vector(solve(C, b))
}
