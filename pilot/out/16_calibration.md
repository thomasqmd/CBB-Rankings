# Calibration, coverage and the market (2026-10-30, revised 2026-11-13)

`pilot/16_calibration.R` (results in `16_calibration.rds`), from the 2026-11-13 rebuild's
backtest: 65,783 games 2015–2027, each predicted by the latest snapshot before it. Out of
sample means fitted on earlier seasons only.

**Revision (2026-11-13).** The first version of this report used closing spreads that were
reversed on some neutral-court games (the provider quoted the game from the other side), which
made the line look worse than it is and the model look better against it. The lines are now
sided by an odds archive and ESPN's sportsbooks (`resolve_lines()`, `R/02_prep.R`), and about
1,400 more games have a line. Three claims from the first version do not hold on the corrected lines:
the 60.8% against the spread at 6+ points of disagreement in Nov–Dec (now 51.2%), the Nov–Dec
blend gain over the line (0.05 points, now 0.006 with se 0.005), and the model matching the
line on Brier in Nov–Dec (now 0.1540 / 0.1516).

## Against the closing line (60,291 games with one)

| | Model | Line |
| :--- | ---: | ---: |
| MAE | 8.820 | 8.721 |
| RMSE | 11.21 | 11.08 |
| Brier | 0.1770 | 0.1752 |
| Log loss | 0.5250 | 0.5202 |
| CRPS | 6.276 | 6.210 |

The line's win probability and CRPS use the spread with the sd of the line's errors in the
season before (no moneylines are stored). By period, the model trails by 0.069 MAE in Jan–Apr
(8.628 / 8.559) and by 0.149 in Nov–Dec (9.148 / 9.000). These come out of `run_backtest()`
(`vs_line`, `vs_line_period`, `ats_edge`), and `check_build.R` prints them.

## Calibration and coverage

- **Spread of the predictions**: slope of the actual margin on the prediction 0.998 in Jan–Apr,
  1.05 in Nov–Dec (the line: 1.01 / 1.01). Early-season predictions are slightly
  over-shrunk.
- **Out-of-sample recalibration**: a margin scale (k ≈ 1.02) and a logit scale (c ≈ 1.05) fitted
  on earlier seasons move MAE 8.844 → 8.844, log loss 0.5225 → 0.5220 and Brier 0.17608 →
  0.17598. That is noise-sized, so not adopted.
- **Predictive intervals** (an out-of-sample posterior predictive check): the 50 / 80 / 95%
  margin intervals cover 51.1 / 80.5 / 94.7% in Jan–Apr and 51.0 / 80.0 / 94.3% in Nov–Dec.
  The predictive sd (10.8 / 11.4) matches the residual sd (10.9 / 11.6).
  `check_build.R` warns if 80% coverage leaves 77–83%.

## Blending with the line

Weights from earlier seasons, by period, actual ≈ a × model + b × line:

| Period | Model weight | Model | Line | Blend | se (blend − line) |
| :--- | ---: | ---: | ---: | ---: | ---: |
| Nov–Dec | 0.20 | 9.166 | 9.029 | 9.023 | 0.005 |
| Jan–Apr | 0.31 | 8.669 | 8.600 | 8.598 | 0.003 |

The blend improves on the line by 0.006 points in Nov–Dec and 0.002 in Jan–Apr, both within
about one standard error. The model adds little that the closing line doesn't already hold, in
either period.

## Against the spread by disagreement

| \|model − line\| | Nov–Dec games | ATS | Jan–Apr games | ATS |
| :--- | ---: | ---: | ---: | ---: |
| 0–2 | 12,918 | 51.6% | 28,559 | 50.8% |
| 2–4 | 6,360 | 52.5% | 7,956 | 52.2% |
| 4–6 | 1,875 | 54.5% | 1,008 | 55.1% |
| 6+ | 787 | 51.2% (se 1.8) | 126 | 52.4% (se 4.4) |

The 6+ bucket no longer stands out: off neutral courts it is 49.6% in Nov–Dec (688 games). On
neutral courts it is 62.6%, on 99 games; a few reversed lines may remain there. The lines are
closing lines and the predictions come from the Monday before, so this is not a betting
record: the line moves during the week and the prediction doesn't.

Decision: no recalibration. Market information is tested as data inside the model (the `lines`
variant, `pilot/12_variants.R`).
