# ==============================================================================
# Resume: Wins Above Bubble (WAB), per posterior draw.
#
# In draw s the benchmark is the last team in: the automatic bids (auto_bids()) leave the power
# ranking and the benchmark is the n_at_large-th best remaining team by rating. Each D1 game adds
# W - P(benchmark wins that game at that venue). Summing gives WAB; ranking every draw gives
# rank intervals and P(at-large) (rank among teams without an automatic bid <= n_at_large).
# ==============================================================================

# Automatic bids per draw (draws x teams, logical), one per conference. A conference whose
# tournament final was played before the snapshot gets its champion; otherwise its standings
# leader (best conference win share, ties to the higher rating in that draw; before conference
# play that is the best-rated team). Until the conference-tournament simulation, that is the
# in-season stand-in. champs: data.frame(team_id, game_date) or NULL.
auto_bids <- function(r, inp, champs = NULL) {
  teams <- inp$teams
  g <- inp$games
  cg <- g[!is.na(g$home_conf) & g$home_conf == g$away_conf & !(g$game_type %in% "TRNMNT") & g$season_type %in% "regular", ]
  w <- table(factor(c(cg$home_id[cg$home_score > cg$away_score], cg$away_id[cg$away_score > cg$home_score]), teams$team_id))
  n <- table(factor(c(cg$home_id, cg$away_id), teams$team_id))
  pct <- ifelse(n > 0, w / pmax(n, 1), 0.5)
  done <- if (is.null(champs)) integer() else champs$team_id[champs$game_date < inp$snap_date]
  auto <- matrix(FALSE, nrow(r), ncol(r))
  for (cf in setdiff(unique(teams$conf), c(NA, "Indep.", "Independent"))) {
    k <- which(teams$conf == cf)
    ch <- intersect(teams$team_id[k], done)
    if (length(ch)) { auto[, match(ch[1], teams$team_id)] <- TRUE; next }
    lead <- k[pct[k] == max(pct[k])]
    pick <- if (length(lead) == 1) rep(lead, nrow(r)) else lead[max.col(r[, lead, drop = FALSE], ties.method = "first")]
    auto[cbind(seq_len(nrow(r)), pick)] <- TRUE
  }
  auto
}

wab_draws <- function(fit, inp, games = inp$games, field = 68L, champs = NULL) {
  r <- fit$r
  auto <- auto_bids(r, inp, champs)
  n_at_large <- field - sum(auto[1, ])
  rb <- vapply(seq_len(nrow(r)), \(d) sort(r[d, !auto[d, ]], decreasing = TRUE)[n_at_large], numeric(1))
  long <- rbind(
    data.frame(team_id = games$home_id, opp_id = games$away_id, venue = 1 - games$neutral,
               win = as.integer(games$home_score > games$away_score), w = games$poss_reg / 70),
    data.frame(team_id = games$away_id, opp_id = games$home_id, venue = -(1 - games$neutral),
               win = as.integer(games$away_score > games$home_score), w = games$poss_reg / 70))
  oi <- match(long$opp_id, inp$teams$team_id)
  # benchmark margin per 100 in that game: (bubble - opponent) +/- home court
  mu <- rb - r[, oi, drop = FALSE] + outer(fit$par$hca, long$venue)
  scale <- outer(fit$par$sigma_game, 1 / sqrt(long$w))
  p_bench <- stats::pt(mu / scale, df = matrix(fit$par$nu, nrow(mu), ncol(mu)))
  contrib <- sweep(-p_bench, 2, long$win, `+`)                     # draws x team-games
  ti <- match(long$team_id, inp$teams$team_id)
  # sum team-games into teams: (draws x games) %*% (games x teams)
  M <- Matrix::sparseMatrix(i = seq_along(ti), j = ti, x = 1, dims = c(length(ti), nrow(inp$teams)))
  wab <- as.matrix(contrib %*% M)
  colnames(wab) <- inp$teams$team_id
  # schedule strength: the bubble team's expected losses against each schedule, and the record
  attr(wab, "bench_losses") <- as.vector(Matrix::colSums(M * (1 - colMeans(p_bench))))
  attr(wab, "wins") <- as.vector(Matrix::colSums(M * long$win))
  attr(wab, "games") <- as.vector(Matrix::colSums(M))
  # the benchmark's power rank in each draw, and the automatic bids
  attr(wab, "bench_rank") <- rowSums(r > rb) + 1
  attr(wab, "p_auto") <- colMeans(auto)
  wab
}

# Resume table at a snapshot (no automatic bids yet: those need the conference-tournament
# simulation). p_pos = share of draws in which the team's WAB is positive.
summarise_resume <- function(wab, inp) {
  rk <- t(apply(-wab, 1, rank, ties.method = "random"))
  n <- attr(wab, "games")
  data.frame(team_id = inp$teams$team_id, wins = attr(wab, "wins"), losses = n - attr(wab, "wins"),
             wab = colMeans(wab), wab_lo = apply(wab, 2, stats::quantile, 0.1), wab_hi = apply(wab, 2, stats::quantile, 0.9),
             wab_rank = colMeans(rk), wab_rank_lo = apply(rk, 2, stats::quantile, 0.1), wab_rank_hi = apply(rk, 2, stats::quantile, 0.9),
             p_pos = colMeans(wab > 0), sos = ifelse(n > 0, attr(wab, "bench_losses") / n, NA_real_),
             p_auto = attr(wab, "p_auto"))
}

summarise_wab <- function(wab, inp, auto_bids = integer(), n_at_large = 37) {
  rk <- t(apply(-wab, 1, rank, ties.method = "random"))
  elig <- !(inp$teams$team_id %in% auto_bids)
  rk_al <- t(apply(-wab[, elig, drop = FALSE], 1, rank, ties.method = "random"))
  p_al <- rep(NA_real_, ncol(wab)); p_al[elig] <- colMeans(rk_al <= n_at_large)
  data.frame(inp$teams[, c("team_id", "team", "conf")],
             wab = colMeans(wab), wab_lo = apply(wab, 2, stats::quantile, 0.1),
             wab_hi = apply(wab, 2, stats::quantile, 0.9),
             wab_rank = colMeans(rk), wab_rank_lo = apply(rk, 2, stats::quantile, 0.1),
             wab_rank_hi = apply(rk, 2, stats::quantile, 0.9),
             auto_bid = !elig, p_at_large = p_al) |>
    dplyr::arrange(dplyr::desc(wab))
}
