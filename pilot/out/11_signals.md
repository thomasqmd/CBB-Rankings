# Signal checks without refits (2026-10-30)

`pilot/11_signals.R` (results in `pilot/out/11_signals.rds`). Residuals are from the
2026-10-25 full rebuild's backtest (`backtest` target): actual margin minus the latest pregame snapshot's prediction.

## 1. Shot model calibration (out of sample)

Each season's make model is fit on the seasons before it and scored on that season's attempts
(`shot_model_calibration()`, now the `shot_calibration` target; `check_build.R` warns past 2 pp).
Predicted minus actual make rate, percentage points:

| Season | Three | Jumper | Layup | Dunk | Tip | Hook |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2015 | +0.2 | +0.3 | +1.0 | +0.3 | +0.1 | – |
| 2016 | −0.2 | −0.3 | −0.6 | −0.8 | −0.2 | – |
| 2017 | −0.5 | −0.9 | −0.9 | +0.1 | −1.1 | – |
| 2018 | −0.2 | −0.8 | −0.6 | +0.1 | −1.3 | – |
| 2019 | +0.6 | +0.4 | −0.1 | +1.0 | −3.6 | – |
| 2020 | +1.3 | −0.3 | +1.1 | +1.4 | −2.8 | – |
| 2021 | +0.0 | −1.7 | +0.5 | +0.3 | −0.5 | – |
| 2022 | −0.1 | −0.3 | +0.6 | −0.2 | +6.3 | – |
| 2023 | −0.3 | −0.4 | +0.4 | +0.2 | −0.9 | – |
| 2024 | +0.0 | −1.5 | +0.6 | +0.2 | +1.8 | (−57.9, n = 121) |
| 2025 | +0.2 | −1.2 | −0.5 | −0.7 | +0.2 | (−60.9, n = 24) |
| 2026 | −0.2 | +1.2 | −3.4 | −1.6 | +0.3 | −6.1 |

Threes are within ±0.6 pp except 2020 (+1.3: the men's line moved back to 22'1¾" in 2019-20,
so a model trained on the old line over-predicts that season). Two-point families drift with ESPN's shot-type coding (tips 2019 and
2022; layups 2026). The default signal `lux100` uses only the three-point model (it replaces
made threes with expected threes), so the two-point drift doesn't touch it; `eff100` would.
Hooks fold into jumpers in the model (< 500 in training every season so far). ESPN coded a handful
in 2024-25 (almost all makes, so tiny-n noise; `check_build.R` skips small cells) and 8,806 in
2025-26, which the jumper fold over-predicts by 6.1 pp. From 2026-27 the training seasons hold
> 500 hooks, so the family gets its own fit; again irrelevant to `lux100`.

## 2. Possessions

Possession changes counted from play-by-play (runs of the gaining team in regulation, plus one
per half start), regulation games only, against the box-score estimate the model uses:

| Season | PBP / box | Median abs. error per game |
| ---: | ---: | ---: |
| 2016 | 0.998 | 1.1% |
| 2020 | 0.987 | 1.2% |
| 2023 | 0.992 | 1.1% |
| 2026 | 0.992 | 1.2% |

The box estimate is within ~1% on average and per game; kept (it exists for every game,
including those without play-by-play).

## 3. Semi-home edge

Neutral-site games in one team's home state (state of its most-used home venue), residual
oriented to that team:

| Games | n | Mean residual | se |
| :--- | ---: | ---: | ---: |
| Regular season | 1,349 | +0.20 | 0.31 |
| Postseason | 80 | +1.00 | 1.29 |
| Neither / both in state, regular | 5,463 | +0.31 | 0.15 |

Against a full home edge of ~3 pts, a home-state crowd adds nothing measurable; not modelled.

## 4. Non-D1 opponents

927 ESPN ids, none missing; 271 ids appear under more than one spelling (stable ids), 11 names
map to two ids (e.g. Carver College). 731 of 927 appear in two or more seasons. Irrelevant
while non-D1 teams share one pooled level; a per-team non-D1 effect would need the duplicate
names merged.

## 5. Absences

`add_absences()` (R/02_prep.R): a player with ≥ 3 games played and ≥ 20 mpg over his last 5
games is absent from a game when he is listed DNP or plays later in the season; `home_missing` /
`away_missing` = his share of the team's 200 minutes. 22-31% of team-games are short-handed
(rising after 2020 with the transfer era). Backtest residual on the missing-minutes difference:
**−7.02 (se 0.41)**, i.e. about −0.7 pts per 10% of minutes missing. This is the size of
adjustment a live availability feed would buy; whether ESPN's injury report can supply it in
season is the 2026-11-16 decision.
