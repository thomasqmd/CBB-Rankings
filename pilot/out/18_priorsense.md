# Prior sensitivity (2026-10-30)

`pilot/18_priorsense.R` (results in `18_priorsense.rds`): priorsense power-scaling on six
pipeline snapshots, the second Monday (500–660 games) and Selection Monday (5,300–5,650 games)
of 2017-18, 2021-22 and 2025-26, with `pilot/stan/power_ps.stan` (the model plus `lprior`, the
hyperpriors' joint log density). Sensitivity is the cumulative Jensen-Shannon distance under
power-scaling; priorsense flags values above 0.05.

| Parameter | Prior, Nov | Prior, Selection | Likelihood, Nov | Likelihood, Selection |
| :--- | ---: | ---: | ---: | ---: |
| hca | 0.08–0.14 | 0.04–0.08 | 0.04–0.08 | 0.04–0.12 |
| sigma_team | 0.10–0.13 | 0.06–0.11 | 0.12–0.19 | 0.05–0.08 |
| sigma_conf | 0.08–0.11 | 0.08–0.13 | 0.03–0.07 | 0.06–0.07 |
| tau | 0.08–0.10 | 0.06–0.10 | 0.03–0.04 | 0.31–0.37 |
| b_prev | 0.07–0.09 | 0.06–0.07 | 0.08–0.19 | 0.07–0.12 |
| b_prev2 | 0.07–0.08 | 0.04–0.06 | 0.04–0.07 | 0.05–0.07 |
| sigma_m, sigma_eff, lambda, kappa | ≤ 0.014 | ≤ 0.013 | 0.02–0.43 | 0.13–0.47 |

- **The game-level parameters** (margin and efficiency noise, λ, κ) are set by the data; their
  priors don't matter.
- **The hierarchy scales, the drift and the carry-over** (σ_team, σ_conf, τ, b_prev, b_prev2)
  stay prior-sensitive through Selection Monday, often flagged as prior-likelihood
  "conflict". This is by design: one season identifies them weakly, which is why the
  unregularised fits failed the convergence gates (`pilot/out/07_convergence.md`). Their priors
  are pooled from vague-prior refits of every final snapshot 2015–2026, so the prior is these
  seasons' data. The fitted values stay inside the pooled ranges (σ_team 3.95–4.40, σ_conf
  1.38–1.51, τ 0.53–0.58 for the 10th–90th percentile of snapshots).
- **HCA** is prior-driven in November (a few hundred games, few true road games) and mostly
  data-driven by March. The pooled prior N(4.5, 0.4) was worth 0.012 MAE in the variant backtest
  for exactly this reason.

Decision: no change. Re-derive the pooled priors (`pilot/conv/07_pooled_priors.R`) after each
season, so they keep tracking the data.
