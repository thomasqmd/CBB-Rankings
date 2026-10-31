# ==============================================================================
# Totals pilot (2026-10-30). The tempo / total submodel (tempo_model(), R/03_model.R) is a pair of
# ridge regressions refit at every snapshot, so variants need no Stan refits. Every weekly
# snapshot 2016-2026 predicts the games until the next one; scored against the actual total and
# the closing total on the same games.
#   prod   : as the pipeline runs it. build_prior() keeps only the rating columns, so last
#            season's tempo / total effects (prev_t, prev_s) and league levels never reach
#            tempo_model(): every team starts at the default levels
#   carry  : last season's final effects and levels carried (what TEMPO was tuned for)
#   lux    : carry, with the scoring signal luck-adjusted (expected threes and free throws, live
#            possessions) where the game has it
#   decay* : carry, with games weighted by recency (half-life in days)
#   lam*   : carry, with other ridge penalties (lambda_t / lambda_s)
#   combo* : carry with a recency half-life and lower penalties together
#   Rscript pilot/15_totals.R      -> pilot/out/15_totals.rds
# ==============================================================================

suppressMessages({ library(targets); library(dplyr) })
tar_source("R")
SEASONS <- 2016:2026
snaps <- tar_read(snapshots)

tempo_variant <- function(g, teams, snap_date, carry = TRUE, lux = FALSE, half_life = Inf, lambda_t = TEMPO$lambda_t, lambda_s = TEMPO$lambda_s) {
  pv <- function(col, default) if (!carry || is.null(teams[[col]])) rep(default, nrow(teams)) else dplyr::coalesce(teams[[col]], default)
  m_t <- TEMPO$carry_t * pv("prev_t", 0); m_s <- TEMPO$carry_s * pv("prev_s", 0)
  mu_p0 <- pv("prev_mu_p", TEMPO$mu_p)[1]; mu_t0 <- pv("prev_mu_t", TEMPO$mu_t)[1]
  g <- g[!is.na(g$poss) & !is.na(g$home_score) & g$poss > 0, ]
  out <- data.frame(team_id = teams$team_id, t = m_t, s = m_s, mu_p = mu_p0, mu_t = mu_t0, ot_pts = TEMPO$ot_pts)
  if (!nrow(g)) return(out)
  hi <- match(g$home_id, teams$team_id); ai <- match(g$away_id, teams$team_id)
  ok <- !is.na(hi) & !is.na(ai); g <- g[ok, ]; hi <- hi[ok]; ai <- ai[ok]
  rw <- if (is.finite(half_life)) 0.5^(as.numeric(snap_date - g$game_date) / half_life) else rep(1, nrow(g))
  preg <- dplyr::coalesce(g$poss_reg, g$poss)
  y_s <- 100 * (g$home_score + g$away_score) / g$poss; w_s <- g$poss / 70
  if (lux) {
    k <- g$has_eff %in% TRUE
    y_s[k] <- 100 * (g$l_home[k] + g$l_away[k]) / g$poss_live[k]; w_s[k] <- g$poss_live[k] / 70
  }
  tp <- ridge_effects(preg, hi, ai, nrow(teams), rw, lambda_t, m_t, mu_p0, TEMPO$lambda_mu)
  tt <- ridge_effects(y_s, hi, ai, nrow(teams), w_s * rw, lambda_s, m_s, mu_t0, TEMPO$lambda_mu)
  extra <- (g$home_score + g$away_score) - (g$home_score + g$away_score) * preg / g$poss
  out$t <- tp$eff; out$s <- tt$eff; out$mu_p <- tp$mu; out$mu_t <- tt$mu
  out$ot_pts <- (sum(extra, na.rm = TRUE) + 20 * TEMPO$ot_pts) / (sum(!is.na(extra)) + 20)
  out
}

VARIANTS <- list(
  prod = list(carry = FALSE), carry = list(), lux = list(lux = TRUE),
  decay30 = list(half_life = 30), decay60 = list(half_life = 60), decay120 = list(half_life = 120),
  lam_t3 = list(lambda_t = 3), lam_t10 = list(lambda_t = 10), lam_s6 = list(lambda_s = 6), lam_s20 = list(lambda_s = 20),
  combo = list(half_life = 60, lambda_t = 3), combo2 = list(half_life = 90, lambda_t = 3, lambda_s = 15)
)

prev_effects <- function(s) {
  r <- snaps$ratings[snaps$ratings$season == s & snaps$ratings$kind == "final", ]
  p <- snaps$params[snaps$params$season == s & snaps$params$kind == "final", ]
  data.frame(team_id = r$team_id, prev_t = r$tempo_eff, prev_s = r$total_eff, prev_mu_p = p$mu_p, prev_mu_t = p$mu_t)
}

out <- bind_rows(lapply(SEASONS, function(s) {
  g <- tar_read_raw(paste0("games_", s)); g <- g[g$division == "d1", ]
  tm <- tar_read_raw(paste0("teams_", s)); tm <- tm[order(tm$team_id), ]
  tm <- left_join(tm, prev_effects(s - 1), by = "team_id")
  d <- tar_read_raw(paste0("dates_", s)); d <- d[!is.na(d$next_date), ]
  bind_rows(lapply(seq_len(nrow(d)), function(i) {
    fit_g <- g[g$played & g$game_date < d$snap_date[i], ]
    up <- g[g$played & g$game_date >= d$snap_date[i] & g$game_date < d$next_date[i], ]
    if (!nrow(up)) return(NULL)
    bind_rows(lapply(names(VARIANTS), function(v) {
      tp <- do.call(tempo_variant, c(list(fit_g, tm, d$snap_date[i]), VARIANTS[[v]]))
      th <- match(up$home_id, tp$team_id); ta <- match(up$away_id, tp$team_id)
      poss <- tp$mu_p[1] + tp$t[th] + tp$t[ta]
      data.frame(variant = v, season = s, snap_date = d$snap_date[i], game_id = up$game_id, game_date = up$game_date,
                 pred_total = poss * (tp$mu_t[1] + tp$s[th] + tp$s[ta]) / 100 + tp$ot_pts[1], pred_poss = poss,
                 actual = up$home_score + up$away_score, poss = up$poss, total_line = up$total_line)
    }))
  }))
}))
out <- out[!is.na(out$pred_total), ]
out$period <- ifelse(as.integer(format(out$game_date, "%m")) %in% c(11, 12), "Nov-Dec", "Jan-Apr")
saveRDS(out, "pilot/out/15_totals.rds")

lined <- out[!is.na(out$total_line), ]
tab <- lined |> group_by(variant) |> summarise(games = n(), mae = mean(abs(actual - pred_total)), mae_line = mean(abs(actual - total_line)),
  novdec = mean(abs(actual - pred_total)[period == "Nov-Dec"]), janapr = mean(abs(actual - pred_total)[period == "Jan-Apr"]),
  line_novdec = mean(abs(actual - total_line)[period == "Nov-Dec"]), line_janapr = mean(abs(actual - total_line)[period == "Jan-Apr"]),
  poss_mae = mean(abs(poss - pred_poss), na.rm = TRUE), bias = mean(pred_total - actual), .groups = "drop") |> arrange(mae)
print(as.data.frame(tab), digits = 4)
# paired se against carry
b <- lined[lined$variant == "carry", ]
for (v in setdiff(unique(lined$variant), "carry")) {
  x <- lined[lined$variant == v, ]; x <- x[match(paste(b$season, b$game_id), paste(x$season, x$game_id)), ]
  dd <- abs(x$actual - x$pred_total) - abs(b$actual - b$pred_total)
  cat(sprintf("%-9s vs carry: %+.3f (se %.3f)\n", v, mean(dd), sd(dd) / sqrt(length(dd))))
}
# Blend with the closing total, weights from earlier seasons only
x <- lined[lined$variant == "carry", ]
bl <- bind_rows(lapply(SEASONS[-1], function(s) {
  w <- coef(lm(actual ~ pred_total + total_line, x[x$season < s, ])); d <- x[x$season == s, ]
  d$blend <- w[1] + w[2] * d$pred_total + w[3] * d$total_line; d }))
cat(sprintf("OOS blend with the closing total: %.3f vs line %.3f (%d games)\n", mean(abs(bl$actual - bl$blend)), mean(abs(bl$actual - bl$total_line)), nrow(bl)))
