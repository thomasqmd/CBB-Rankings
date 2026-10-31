# Simulation-based calibration (2026-10-30)

`pilot/17_sbc.R` (results in `17_sbc.rds`). The structure of a real snapshot (2024-25, fourth
Monday: 365 teams, 1,500-odd D1 games, the non-D1 games, priors, weights, venues) with every
hyperparameter and team effect drawn from the model's priors. Efficiency signal and margins are
simulated as `stan/power.stan` specifies (normal margins), then refit (2 × 500 draws). 200
replicates; each true value is ranked among 99 thinned posterior draws.

| Parameter | p (uniform ranks) | Mean rank | z bias | 80% coverage |
| :--- | ---: | ---: | ---: | ---: |
| hca | 0.90 | 0.48 | +0.05 | 81.0% |
| sigma_m | 0.33 | 0.48 | +0.07 | 80.0% |
| sigma_eff | 0.88 | 0.51 | −0.04 | 78.5% |
| lambda | 0.13 | 0.53 | −0.07 | 83.5% |
| kappa | 0.35 | 0.45 | +0.17 | 81.5% |
| sigma_team | 0.91 | 0.49 | +0.02 | 77.5% |
| sigma_conf | 0.48 | 0.50 | +0.03 | 78.5% |
| tau | 0.71 | 0.50 | +0.03 | 81.5% |
| b_prev | 0.07 | 0.55 | −0.16 | 77.0% |
| b_prev2 | 0.38 | 0.47 | +0.08 | 80.0% |
| team states (5 per rep) | 0.82 | 0.50 | −0.01 | 79.2% |

No fit diverged. Every parameter's ranks are consistent with uniform (chi-square over 10 bins,
all p > 0.05), and 80% intervals cover 77–84% (binomial se 2.8 pp). b_prev is the closest
call (p = 0.07, posterior means slightly low), within what 11 parameters' worth of tests
produce by chance. The model and sampler recover their own parameters; the remaining
questions are about the model being right, which the backtest answers.
