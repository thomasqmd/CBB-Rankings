# Model variants (2026-10-24)

`pilot/12_variants.R` (results in `pilot/out/variants/`, table in `summary_table.rds`). Each variant
refits 91 snapshots: 2016–2026, opening night plus every third Monday, 4 × 500 draws. Each
snapshot predicts the D1 games of the following week, 22,309 games in all, the same games for
every variant. Δ = variant − base on the same games; se is the paired standard error. Negative is
better. The base is the Phase 1 configuration (`lux100`, weekly random walk, HCA prior N(4, 2),
Student-t margins, OT = tie, current garbage-time rules, blend prior). It scores MAE 9.105 and
log loss 0.5097.

| Variant | Change | Δ MAE | se | Δ Nov–Dec | Δ Jan–Apr | Δ log loss | Gates* |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **prev2** | + b_prev2 × rating two seasons back | **−0.080** | 0.006 | −0.165 | −0.001 | **−0.0017** | 13% |
| **roster** | roster-regression prior (`pilot/13_roster_prior.R`) | **−0.030** | 0.006 | −0.059 | −0.004 | **−0.0015** | 18% |
| **hca_pooled** | HCA prior N(4.5, 0.4); 2021 N(3, 0.5) | **−0.012** | 0.002 | −0.021 | −0.004 | −0.0004 | 15% |
| **normal** | normal margins instead of Student-t | **−0.006** | 0.002 | −0.009 | −0.002 | **−0.0010** | 19% |
| team_hca | each team's own HCA, shrunk | −0.001 | 0.001 | −0.001 | −0.002 | −0.0001 | 11% |
| gt_none | no garbage-time cut | −0.001 | 0.003 | −0.007 | +0.005 | +0.0003 | 19% |
| ot50 | OT margin at weight 0.5 | −0.001 | 0.001 | −0.003 | +0.002 | −0.0000 | 20% |
| ift | drop late intentional-foul trips (≤ 60 s, lead ≤ 8) | −0.000 | 0.002 | −0.003 | +0.002 | −0.0001 | 19% |
| mixture | contaminated-normal margins | −0.000 | 0.001 | −0.000 | −0.000 | −0.0009 | 21% |
| gt_loose | garbage time from ≤ 12 min & ≥ 16, ≤ 6 min & ≥ 12 | +0.000 | 0.003 | +0.005 | −0.004 | −0.0003 | 19% |
| gt_tight | garbage time from ≤ 10 min & ≥ 25, ≤ 5 min & ≥ 20 | +0.001 | 0.002 | +0.003 | −0.001 | +0.0002 | 23% |
| ot100 | OT margin at weight 1 | +0.001 | 0.002 | −0.004 | +0.005 | +0.0003 | 20% |
| static | no random walk | +0.001 | 0.002 | −0.001 | +0.004 | +0.0003 | 36% |
| eff100 | shot-quality signal instead of luck-adjusted | +0.013 | 0.007 | −0.003 | +0.028 | +0.0008 | 15% |
| margin_only | no efficiency signal | +0.036 | 0.007 | +0.029 | +0.043 | −0.0003 | 13% |

\* Share of fits passing the production gates. These are short runs (4 × 500); the base passes 23%.
This is about precision, not the model: production fits use 4 × 1000.

- **roster**: the regression prior (own and Torvik's ratings plus returning / transfer value,
  minutes shares, departed value, recruit ranks) gains half as much as prev2, again mostly in
  Nov–Dec. Its fits took 88 s against ~41 s for the others, most likely because other jobs were
  running on the machine at the time. The roster prior and prev2 both target the opening level,
  so their gains may overlap.
- **prev2** is the largest gain, and nearly all of it comes in Nov–Dec. Carrying two seasons
  steadies the opening level for teams whose last season was unusual.
- **hca_pooled**: the final fits put HCA at 4.3–5.0 per 100 every season except 2021 (2.99). The
  vague prior let early snapshots overstate it (5.4–7.2 in week 1).
- **normal** beats Student-t on both metrics. The efficiency term already absorbs the blowouts the
  t was meant for. The mixture matches normal's log loss, does nothing for MAE and is 1.5× slower.
- **Efficiency signal**: `lux100` beats both `eff100` and margin only, so it stays.
- No change for team HCA, OT, intentional fouls, garbage-time rules or static ratings. Each sits
  within one se of zero, so the simpler current settings stay.

Adopted in `model_config()`: `use_prev2 = TRUE` (`build_prior()` gets `prev2`, the final ratings
two seasons back, from `_targets.R`); `hca_prior = c(4.5, 0.4)` with
`hca_prior_season = list("2021" = c(3, 0.5))`; `margin_family = 2L`; `prior_method = "roster"`
(2015 has no earlier roster history and keeps the blend). The four changes are tested one at a
time against the base, not together. The next full rebuild's backtest is their joint
test against the Phase 1 numbers (MAE 8.87, log loss 0.5259).

The harness pins the base configuration (`BASE_CFG`), so later variants stay comparable with
these results after the defaults change.
