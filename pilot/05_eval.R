# Pilot step 5: score the backtest. Final margin (home - away) vs model and closing line.
suppressMessages(library(dplyr))
bt <- readRDS("data/derived/pilot_backtest.rds")
bad <- vapply(bt, inherits, logical(1), "try-error")
if (any(bad)) stop(sum(bad), " backtest jobs failed: ", conditionMessage(attr(bt[[which(bad)[1]]], "condition")))
pred <- bind_rows(lapply(bt, `[[`, "pred"))
gates <- bind_rows(lapply(bt, `[[`, "gates"))
pred <- pred |> mutate(actual = home_score - away_score, line = -spread, home_win = as.integer(actual > 0),
                       period = ifelse(snap < as.Date("2026-01-01"), "Nov-Dec", "Jan-Apr"))
# Score every variant on the same games: those with a closing line
common <- pred |> filter(!is.na(line))
score <- function(d) d |> summarise(
  games = n(),
  mae_model = mean(abs(actual - pred_margin)), mae_line = mean(abs(actual - line)),
  rmse_model = sqrt(mean((actual - pred_margin)^2)), rmse_line = sqrt(mean((actual - line)^2)),
  bias = mean(actual - pred_margin),
  ats = mean((sign(actual - line) == sign(pred_margin - line))[actual != line & pred_margin != line]),
  brier = mean((p_home - home_win)^2),
  logloss = -mean(home_win * log(p_home) + (1 - home_win) * log(1 - p_home)),
  .groups = "drop")
overall <- common |> group_by(variant) |> score()
by_period <- common |> group_by(variant, period) |> score()
by_snap <- common |> group_by(variant, snap) |> summarise(mae_model = mean(abs(actual - pred_margin)),
                                                          mae_line = mean(abs(actual - line)), n = n(), .groups = "drop")
print(as.data.frame(overall), digits = 4); print(as.data.frame(by_period), digits = 4)
gate_fail <- gates |> filter(max_rhat > 1.01 | min_ess < 400 | divergences > 0 | min_ebfmi < 0.2)
cat("fit time by variant (s):\n"); print(gates |> group_by(variant) |> summarise(mean_secs = mean(secs), max_rhat = max(max_rhat), min_ess = min(min_ess), div = sum(divergences)))
writeLines(c("# Pilot backtest, 2025-26", "",
             "Snapshots every 14 days from 2025-11-10 to 2026-03-16; each predicts games until the next snapshot (the last runs through the title game). Scored on games with a closing spread. Margins in points (final score, OT included).", "",
             "## Overall", "", knitr::kable(overall, digits = 3), "",
             "## By period", "", knitr::kable(by_period, digits = 3), "",
             "## By snapshot", "", knitr::kable(by_snap, digits = 2), "",
             "## Convergence", "", knitr::kable(gates |> group_by(variant) |> summarise(mean_secs = mean(secs), max_rhat = max(max_rhat), min_ess = min(min_ess), divergences = sum(divergences)), digits = 2),
             "", sprintf("%d of %d fits miss a gate (R-hat <= 1.01, ESS >= 400, no divergences, E-BFMI > 0.2).", nrow(gate_fail), nrow(gates))),
           "pilot/out/05_backtest.md")
