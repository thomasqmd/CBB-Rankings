# Pilot data audit (2025-26)

- espn_completed_games: 6300
- d1_vs_d1_games: 5752
- d1_teams: 365
- with_eff: 5740
- with_spread: 5748
- ot_games: 325
- neutral: 700
- ncaa_games: 67
- mean_poss: 68.9
- cor_eff_margin: 0.533
- cor_lux_margin: 0.762
- sd_margin100: 21.72
- sd_eff100: 15.72
- logloss_make_model: 0.647
- logloss_base_rate: 0.6716

- share_dist: 1
- share_putback: 0.088
- share_transition: 0.193

## Make model calibration (fit on 2024-25, scored on 2025-26)

|family | three|      n| actual| predicted|
|:------|-----:|------:|------:|---------:|
|jumper |     1| 290284|  0.338|     0.337|
|layup  |     0| 235778|  0.554|     0.548|
|jumper |     0| 150185|  0.380|     0.402|
|dunk   |     0|  28361|  0.875|     0.873|
|tip    |     0|  19373|  0.663|     0.667|
|hook   |     0|   8795|  0.468|     0.577|
|dunk   |     1|     62|  0.565|     0.767|
|tip    |     1|      6|  0.500|     0.371|
|hook   |     1|      3|  0.333|     0.483|
