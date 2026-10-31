# ==============================================================================
# Calibration, coverage and the market (2026-10-30), from the pipeline's backtest (no refits).
#   1. Spread of the predictions: slope of the actual margin on the predicted one
#   2. Win probabilities: logit scale fitted on earlier seasons only, applied to the next
#   3. Predictive intervals (out-of-sample PPC): coverage of the 50 / 80 / 95% margin intervals
#      implied by p_home and pred_margin (normal margins)
#   4. Blend with the closing line: weights from earlier seasons, by period
#   5. Against the spread by the size of the model-line disagreement
#   Rscript pilot/16_calibration.R      -> pilot/out/16_calibration.rds
# ==============================================================================

suppressMessages({ library(targets); library(dplyr) })
g <- tar_read(backtest)$games |> filter(played)
SEASONS <- sort(unique(g$season))
ll <- function(p, y) -mean(y * log(p) + (1 - y) * log(1 - p))
sd_of <- function(m, p) { s <- abs(m / qnorm(pmin(pmax(p, 1e-6), 1 - 1e-6))); ifelse(abs(m) > 2 & is.finite(s), s, NA) }
g$sd <- sd_of(g$pred_margin, g$p_home)
g$sd[is.na(g$sd)] <- ave(g$sd, g$season, FUN = \(x) median(x, na.rm = TRUE))[is.na(g$sd)]
out <- list()

# 1. Slope
out$slope <- g |> group_by(period) |> summarise(games = n(), slope = coef(lm(actual ~ pred_margin))[2],
                                                slope_line = coef(lm(actual ~ line))[2], .groups = "drop")
print(out$slope)

# 2. Out-of-sample recalibration: margin scale k (actual ~ k pred) and logit scale c (p = plogis(c logit p))
oos <- bind_rows(lapply(SEASONS[-1], function(s) {
  past <- g[g$season < s, ]; now <- g[g$season == s, ]
  k <- coef(lm(actual ~ 0 + pred_margin, past))[1]
  c <- optimize(\(c) ll(plogis(c * qlogis(past$p_home)), past$home_win), c(0.7, 1.5))$minimum
  now$m_k <- k * now$pred_margin; now$p_c <- plogis(c * qlogis(now$p_home)); now$k <- k; now$c <- c
  now
}))
out$recal <- oos |> group_by(period) |> summarise(games = n(), k = mean(k), c = mean(c),
  mae = mean(abs(actual - pred_margin)), mae_k = mean(abs(actual - m_k)),
  logloss = ll(p_home, home_win), logloss_c = ll(p_c, home_win),
  brier = mean((p_home - home_win)^2), brier_c = mean((p_c - home_win)^2), .groups = "drop")
print(as.data.frame(out$recal), digits = 4)
out$recal_all <- oos |> summarise(mae = mean(abs(actual - pred_margin)), mae_k = mean(abs(actual - m_k)),
  logloss = ll(p_home, home_win), logloss_c = ll(p_c, home_win), brier = mean((p_home - home_win)^2), brier_c = mean((p_c - home_win)^2))
print(as.data.frame(out$recal_all), digits = 5)

# 3. Interval coverage
z <- (g$actual - g$pred_margin) / g$sd
out$coverage <- g |> mutate(z = z) |> group_by(period) |> summarise(games = n(),
  cov50 = mean(abs(z) <= qnorm(0.75)), cov80 = mean(abs(z) <= qnorm(0.9)), cov95 = mean(abs(z) <= qnorm(0.975)),
  sd_pred = mean(sd), sd_resid = sd(actual - pred_margin), .groups = "drop")
print(as.data.frame(out$coverage), digits = 3)

# 4. Blend with the closing line (lined games), weights from earlier seasons by period
gl <- g[!is.na(g$line), ]
bl <- bind_rows(lapply(SEASONS[-1], function(s) bind_rows(lapply(c("Nov-Dec", "Jan-Apr"), function(pd) {
  past <- gl[gl$season < s & gl$period == pd, ]; now <- gl[gl$season == s & gl$period == pd, ]
  w <- coef(lm(actual ~ 0 + pred_margin + line, past))
  now$blend <- w[1] * now$pred_margin + w[2] * now$line; now$w_model <- w[1]; now
}))))
out$blend <- bl |> group_by(period) |> summarise(games = n(), w_model = mean(w_model),
  mae_model = mean(abs(actual - pred_margin)), mae_line = mean(abs(actual - line)), mae_blend = mean(abs(actual - blend)),
  se_blend_vs_line = sd(abs(actual - blend) - abs(actual - line)) / sqrt(n()), .groups = "drop")
print(as.data.frame(out$blend), digits = 4)

# 5. ATS by disagreement, with a binomial se
out$ats <- gl |> filter(actual != line) |> mutate(edge = cut(abs(pred_margin - line), c(0, 1, 2, 3, 4, 6, Inf), include.lowest = TRUE)) |>
  group_by(period, edge) |> summarise(n = n(), ats = mean(sign(actual - line) == sign(pred_margin - line)), .groups = "drop") |>
  mutate(se = sqrt(ats * (1 - ats) / n))
print(as.data.frame(out$ats), digits = 3)

saveRDS(out, "pilot/out/16_calibration.rds")
