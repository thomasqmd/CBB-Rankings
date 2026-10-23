# Convergence pilot (2025-26, dynamic luck-adjusted model)

Gates: R-hat <= 1.01, bulk ESS >= 400, no divergences, E-BFMI > 0.2, on centred ratings and
structural parameters. Snapshots 2025-11-10 to 2026-03-02; predictions scored on the next 14 days.
Scripts: `pilot/conv/01_diagnose.R` ... `05_priors.R`.

## What was failing

Centred ratings were fine in every fit (min ESS >= 990). The failures were hyperparameters:
the conference spread `sigma_conf` (ESS 170-330), the weekly drift `tau` (ESS ~105 mid-season),
`sigma_team` in week 1 (ESS ~250) and `b_prev`, which trades off with conference strength.

## What was tried (all four chains)

| Setup | Fits passing | Min ESS | Max R-hat | Divergences | Mean s/fit | MAE | Log loss |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Pilot default (weekly states, 4 x 500) | 0 / 7 | 105 | 1.044 | 0 | 59 | 8.996* | |
| Two-week states | 0 / 4 | 98 | 1.042 | 0 | 51 | 8.994* | |
| Separate conference carry-over | 0 / 4 | 69 | 1.047 | 2 | 67 | 8.991* | |
| Conference carry-over + two-week states | 0 / 4 | 102 | 1.031 | 1 | 51 | 8.993* | |
| ... + 4 x 1000 draws | 1 / 4 | 291 | 1.018 | 4 | 81 | 8.994* | |
| Centred conference means | 0 / 7 | 39 | 1.090 | 15 | 61 | | |
| Centred + two-week states | 0 / 7 | 38 | 1.076 | 44 | 85 | | |
| Centred + non-D1 games | 0 / 7 | 28 | 1.110 | 90 | 67 | | |
| **Informative scale priors** | 1 / 7 | 398 | 1.015 | 0 | 53 | 9.059 | 0.5189 |
| **Informative scale priors + 4 x 1000** | **7 / 7** | **751** | **1.008** | **0** | **75** | **9.059** | **0.5189** |

\* scored on the 4-snapshot grid (2025-11-24, 2026-01-05, 2026-02-02, 2026-03-02); not comparable with
the 7-snapshot rows. Within each grid every setup predicts the same to within 0.01 pts.

Priors: sigma_conf ~ N(4.5, 0.7), sigma_team ~ N(6.4, 0.6), tau ~ N(0.6, 0.1), centred on this
season's posterior means (in-sample). The full build must take them from pooled vague-prior refits
of earlier seasons (CFB's `prior_refits` -> `pool_priors()`), then re-check the gates.

## Non-D1 games (`06_nond1.R`)

547 games against non-D1 teams in 2025-26 (325 before December), added as one pooled non-D1 level
with extra spread (margin signal only). Under the converging setup:

| | Fits passing | Min ESS | Nov-Dec MAE | Jan-Mar MAE | Nov-Dec log loss | Jan-Mar log loss |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| D1 games only | 7 / 7 | 751 | 9.327 | 8.749 | 0.4665 | 0.5793 |
| + non-D1 games | 7 / 7 | 732 | 9.317 | 8.745 | 0.4669 | 0.5785 |

Neutral to slightly better, and they are in the same feeds, so they are included by default
(`use_nd = TRUE`).

## Exhibitions

Only used if one or two sources carry them. None does (ESPN, CBBD, NCAA.com start at opening
night); the only record is ~365 school sites. Parked: `pilot/out/08_exhibitions.md`.

## Preseason prior source (informative priors, Nov 10 - Dec 22 snapshots, 2,124 games)

| Carry-over prior | Nov 10 | Nov 24 | Dec 8 | Dec 22 | Weighted MAE | b_prev |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| Closing line | 9.19 | 10.08 | 8.95 | 8.40 | 9.26 | |
| Own 2024-25 final rating | 9.65 | 9.69 | 9.25 | 8.45 | 9.33 | 0.78-0.82 |
| Torvik preseason (2025-11-02) | 9.70 | 9.67 | 9.09 | 8.45 | 9.30 | 1.06-1.09 |
| Mean of the two | 9.59 | 9.66 | 9.17 | 8.43 | 9.28 | 0.99-1.01 |

Torvik's preseason ratings (roster-aware, public, no key) correlate 0.92 with our last-season
rating; averaging the two cuts early MAE by 0.05 and log loss by ~0.003. b_prev > 1 on Torvik
alone means his preseason ratings are more compressed than in-season ratings. The week-1 gap to
the line (9.59 vs 9.19) remains: a roster prior has more to find.
