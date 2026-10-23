# ==============================================================================
# Resume: Wins Above Bubble (WAB), per posterior draw.
#
# In draw s the benchmark is the team ranked `bubble` by rating. Each D1 game adds
# W - P(benchmark wins that game at that venue). Summing gives WAB; ranking every draw gives
# rank intervals and P(at-large) (rank among teams without an automatic bid <= n_at_large).
# ==============================================================================

wab_draws <- function(fit, inp, games = inp$games, bubble = 45) {
  r <- fit$r
  rb <- apply(r, 1, \(x) sort(x, decreasing = TRUE)[bubble])
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
             p_pos = colMeans(wab > 0), sos = ifelse(n > 0, attr(wab, "bench_losses") / n, NA_real_))
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
