# Calibration, coverage and the market (2026-10-30)

`pilot/16_calibration.R` (results in `16_calibration.rds`), from the 2026-10-25 rebuild's
backtest: 65,268 games 2015–2026, each predicted by the latest snapshot before it. Out of
sample means fitted on earlier seasons only.

## Against the closing line (58,416 games with one)

| | Model | Line |
| :--- | ---: | ---: |
| MAE | 8.812 | 8.750 |
| RMSE | 11.19 | 11.12 |
| Brier | 0.1775 | 0.1766 |
| Log loss | 0.5262 | 0.5236 |
| CRPS | 6.269 | 6.231 |

The line's win probability and CRPS use the spread with the sd of the line's errors in the
season before (no moneylines are stored). By period, the model trails by 0.067 MAE in Jan–Apr
and by 0.052 in Nov–Dec, where it matches the line on Brier (0.1549 / 0.1550). These now
come out of `run_backtest()` (`vs_line`, `vs_line_period`, `ats_edge`), and `check_build.R`
prints them.

## Calibration and coverage

- **Spread of the predictions**: slope of the actual margin on the prediction 0.994 in Jan–Apr,
  1.04 in Nov–Dec (the line: 1.01 / 1.00). Early-season predictions are slightly
  over-shrunk.
- **Out-of-sample recalibration**: a margin scale (k ≈ 1.02) and a logit scale (c ≈ 1.05) fitted
  on earlier seasons move MAE 8.837 → 8.838, log loss 0.5235 → 0.5231 and Brier 0.17647 →
  0.17638. That is noise-sized, so not adopted.
- **Predictive intervals** (an out-of-sample posterior predictive check): the 50 / 80 / 95%
  margin intervals cover 51.2 / 80.5 / 94.7% in Jan–Apr and 51.1 / 80.0 / 94.3% in Nov–Dec.
  The predictive sd (10.9 / 11.4) matches the residual sd (10.9 / 11.6).
  `check_build.R` now warns if 80% coverage leaves 77–83%.

## Blending with the line

Weights from earlier seasons, by period, actual ≈ a × model + b × line:

| Period | Model weight | Model | Line | Blend | se (blend − line) |
| :--- | ---: | ---: | ---: | ---: | ---: |
| Nov–Dec | 0.39 | 9.165 | 9.130 | **9.080** | 0.009 |
| Jan–Apr | 0.32 | 8.663 | 8.596 | 8.593 | 0.003 |

In Nov–Dec the model holds information the line doesn't, about 0.05 points, mostly from the
preseason prior and the roster terms. By January the line has absorbed it.

## Against the spread by disagreement

| \|model − line\| | Nov–Dec games | ATS | Jan–Apr games | ATS |
| :--- | ---: | ---: | ---: | ---: |
| 0–2 | 12,216 | 51.9% | 27,961 | 50.8% |
| 2–4 | 6,048 | 53.0% | 7,728 | 52.1% |
| 4–6 | 1,743 | 54.9% | 981 | 55.1% |
| 6+ | 926 | **60.8%** (se 1.6) | 126 | 54.8% (se 4.4) |

The large disagreements are early-season games, consistent with the blend result. The lines
are closing lines and the predictions come from the Monday before, so this is not a betting
record: the line moves during the week and the prediction doesn't.

Decision: no recalibration. Market information is tested as data inside the model (the `lines`
variant, `pilot/12_variants.R`).
