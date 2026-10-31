# Totals pilot (2026-10-30)

`pilot/15_totals.R` (results in `15_totals.rds`). The tempo / total submodel (`tempo_model()`,
`R/03_model.R`) is a pair of ridge regressions refit at every snapshot, so its variants need no
Stan refits. Every weekly snapshot 2016–2026 predicts the games until the next one; 54,447 games
with a closing total. Δ is against `carry`, paired.

| Variant | Change | MAE | Nov–Dec | Jan–Apr | Δ | se |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| **combo** | carry + half-life 60 days + λ_t 3 | **13.37** | **13.60** | **13.23** | **−0.055** | 0.005 |
| combo2 | carry + half-life 90 + λ_t 3 + λ_s 15 | 13.38 | 13.61 | 13.24 | −0.046 | 0.005 |
| decay60 | carry + half-life 60 days | 13.40 | 13.65 | 13.25 | −0.022 | 0.005 |
| decay120 | carry + half-life 120 days | 13.40 | 13.65 | 13.26 | −0.019 | 0.003 |
| lam_t3 | carry + λ_t 3 (was 5) | 13.41 | 13.60 | 13.29 | −0.016 | 0.003 |
| **carry** | last season's effects and levels carried | 13.42 | 13.64 | 13.29 | 0 | |
| lam_s20 | carry + λ_s 20 (was 11) | 13.42 | 13.66 | 13.28 | +0.001 | 0.004 |
| decay30 | carry + half-life 30 days | 13.43 | 13.67 | 13.29 | +0.008 | 0.008 |
| lam_s6 | carry + λ_s 6 | 13.46 | 13.68 | 13.34 | +0.039 | 0.004 |
| lam_t10 | carry + λ_t 10 | 13.48 | 13.74 | 13.33 | +0.055 | 0.004 |
| lux | carry + luck-adjusted scoring signal | 13.58 | 13.87 | 13.41 | +0.154 | 0.012 |
| prod | the 2026-10-25 pipeline | 13.59 | 14.02 | 13.34 | +0.168 | 0.009 |
| *closing total* | | *13.13* | *13.19* | *13.09* | | |

- **Bug: the carry-over never reached the pipeline.** `season_final_prior()` passes last season's
  tempo and scoring effects and league levels, but `build_prior()` kept only the rating columns,
  so every team started each season at the default levels (68.5 possessions, 206 points per
  100). Carrying them is worth 0.17 overall and 0.38 in Nov–Dec. Fixed: `build_prior()` keeps
  `prev_t`, `prev_s`, `prev_mu_p`, `prev_mu_t`.
- **Recency weights** (half-life 60 days) and a **looser tempo penalty** (λ_t 3) add 0.055
  together. Faster decay (30 days) overreacts. Scoring's penalty stays at 11.
- **Luck-adjusted scoring** (expected threes and free throws over live possessions) is worse.
  Totals need the garbage-time points the signal leaves out, and the margin model's luck
  adjustment doesn't carry over to totals.
- **Gap to the line**: 0.24 after the changes (was 0.46). A blend with the closing total, with
  weights from earlier seasons, scores 13.106 against the line's 13.098: the model's total
  adds nothing to the closing total.

Adopted in `R/03_model.R`: `TEMPO$lambda_t = 3`, `TEMPO$half_life = 60`, `tempo_model(g, teams,
snap_date)`, the carry-over columns in `build_prior()`. The same code path on the same snapshots
gives 13.366 against the line's 13.129. Takes effect at the next full rebuild (the priors and
every snapshot input change).
