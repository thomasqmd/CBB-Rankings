# Pooled scale priors (2026-10-24)

The build's priors on `sigma_conf`, `sigma_team` and `tau` were centred on 2025-26 pilot
posterior means (in-sample, and fitted with our own last-season rating as the only preseason
prior). They are now pooled from the full build. Scripts: `pilot/conv/07_pooled_priors.R`,
`pilot/conv/08_pooled_check.R`.

## Vague-prior refits

Each season's final snapshot (2015-2026), priors N+(0, 10) on the two scales and N+(0, 2) on `tau`.
None passes the gates (R-hat 1.01-1.06, ESS 93-305, mostly `tau`); the means and sds are good
enough to pool.

| Season | sigma_conf | sigma_team | tau |
| ---: | ---: | ---: | ---: |
| 2015 | 0.76 (0.53) | 4.41 (0.35) | 0.42 (0.21) |
| 2016 | 1.41 (0.67) | 4.45 (0.33) | 0.57 (0.19) |
| 2017 | 1.84 (0.66) | 4.04 (0.33) | 0.55 (0.20) |
| 2018 | 0.97 (0.56) | 4.19 (0.32) | 0.52 (0.20) |
| 2019 | 2.12 (0.53) | 3.98 (0.34) | 0.42 (0.20) |
| 2020 | 2.07 (0.57) | 3.45 (0.34) | 0.35 (0.20) |
| 2021 | 0.85 (0.61) | 4.05 (0.42) | 0.57 (0.25) |
| 2022 | 1.97 (0.60) | 3.77 (0.37) | 0.80 (0.14) |
| 2023 | 1.07 (0.59) | 4.30 (0.33) | 0.44 (0.21) |
| 2024 | 1.11 (0.64) | 4.72 (0.35) | 0.59 (0.20) |
| 2025 | 2.30 (0.63) | 4.68 (0.35) | 0.59 (0.18) |
| 2026 | 1.36 (0.82) | 5.15 (0.36) | 0.56 (0.19) |

Posterior mean (sd).

## Pooling

Random-effects meta-analysis (DerSimonian-Laird) per parameter:

| | Pooled mean | Between-season sd | Predictive sd | Prior used | Old prior |
| :--- | ---: | ---: | ---: | :--- | :--- |
| sigma_conf | 1.48 | 0 (Q = 9.8, df 11) | 0.17 | N(1.48, 0.2) | N(4.5, 0.7) |
| sigma_team | 4.27 | 0.29 (Q = 18.5) | 0.31 | N(4.27, 0.35) | N(6.4, 0.6) |
| tau | 0.56 | 0 (Q = 5.4) | 0.055 | N(0.56, 0.1) | N(0.6, 0.1) |

Predictive sds are rounded up; `tau` keeps the pilot's 0.1 because its vague fits did not fully
converge. A first pooling that added the mean posterior variance to the between-season variance
(N(1.49, 0.83), N(4.27, 0.58), N(0.53, 0.23)) dropped the 2026-02-16 snapshot to ESS 336.

The big change is `sigma_conf`: once last season's rating (blended with Torvik's preseason) is
carried over, conference strength moves about 1.5 points, not 4.5.

## Check on six 2026 snapshots (Nov 10 - Feb 16), next week's games

| | Min ESS | Max R-hat | Divergences | MAE | Log loss |
| :--- | ---: | ---: | ---: | ---: | ---: |
| Old priors (build) | 603-1648 | 1.013 | 0 | 9.007 | 0.5226 |
| Pooled priors | 892-4159 | 1.01 | 0 | 9.015 | 0.5227 |

1,855 games. Predictions are the same to within 0.01 points; every snapshot passes the gates,
and fits are faster.
