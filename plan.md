# CBB Bayesian Rankings — Build Plan

Status: pilot completed 2026-10-23 on 2025-26 (prior from 2024-25). Full 2014–2027 pipeline
built and backtested 2026-10-24; Phase 1 (ingest) complete and rebuilt the same day (backtest
unchanged: MAE 8.87, log loss 0.5259). Phases 2–6 coded and tested the same day; model defaults
re-chosen by the variant backtest (`pilot/out/12_variants.md`). The full rebuild under them is
pending (`todo.md`, Up next).
Design source: the doc "CBB Rankings: Plan & Public Data Sources"
(<https://claude.ai/artifact/EDkNP5Qx1V8eWT13XRVtbS>); this file supersedes it where they
disagree (section B).

Decisions carried over from CFB-Rankings: two strictly separate products (Power, Resume); one
joint Bayesian model of margin + an efficiency signal; resume = wins above a benchmark, per
posterior draw; `targets` pipeline, DuckDB cache, Quarto + Observable JS dashboard; convergence
gates; backtest against closing lines drives every tuning choice.

| Product | Question | Built from |
| :--- | :--- | :--- |
| **Power rating** (pts / 100 poss) | Who wins on a neutral floor tonight, by how much? | One Stan model of regulation margin + luck-adjusted efficiency, weekly random walk |
| **Resume (WAB)** | Given what happened, what did each team earn? | Actual W/L valued against the bubble team, from the Power posterior |

---

## A. Pilot results (2025-26)

All reports are in `pilot/out/`. Numbers below are from those files.

**A1. Data.** 6,300 completed games; 5,752 D1-vs-D1 (365 teams) after dropping non-D1
opponents. 5,740 have play-by-play efficiency, 5,748 a closing spread, 325 went to OT, 700 were
neutral-site. ESPN and CBBD agree on all 6,318 scheduled games (joined on ESPN id = CBBD
`sourceId`). Box-score possessions average 68.9 per game.

**A2. Efficiency signal.** Two candidates, both built from a shot make model (logistic:
3PT × spline(distance) + family + putback + transition) fit on 2024-25 and scored on 2025-26:

| Signal | Definition | cor with margin / 100 |
| :--- | :--- | ---: |
| Shot quality (`eff100`) | Σ value × P(make) + FTA × shrunk shooter FT% | 0.53 |
| Luck-adjusted (`lux100`) | actual 2-pt points + expected 3-pt points + expected FT points | 0.76 |

Make model log loss 0.647 vs 0.672 for the 2/3 base rate; calibrated within 1 pt by family
except hooks (57.7% predicted, 46.8% actual) and 2-pt jumpers (40.2 vs 38.0).
ESPN added finer shot descriptors (driving, floater, step-back, pull-up, turnaround) only in
2025-26, so the model uses five coarse families that exist in every season.

**A3. Fits.** (First pass; see A7 for the converging setup.) 4 chains × 500 draws. Static fits take ~35 s, the weekly random walk ~110–140 s.
No divergences. The dynamic fit's bulk ESS (156–255) misses the 400 gate, so it needs longer
chains or a reparameterisation. Posterior means at Selection Sunday 2026 (per 100 possessions):
HCA 3.9 (≈ 2.7 pts at 69 possessions), σ_team 6.3, σ_conf 4.6, carry-over b 0.72, weekly drift
τ 0.59, λ 0.94, κ 0.58, ν ≈ 17. Top 5: Duke, Michigan, Florida, Arizona, Houston.

**A4. Backtest.** Snapshots every 14 days from 2025-11-10 to 2026-03-16, each predicting games
until the next one (5,437 games with a closing spread). Final margin in points:

| Variant | MAE | RMSE | ATS | Brier | Log loss |
| :--- | ---: | ---: | ---: | ---: | ---: |
| Closing line | 8.974 | 11.37 | | | |
| Luck-adjusted, weekly random walk | 9.047 | 11.50 | 51.6% | 0.1821 | 0.5355 |
| Luck-adjusted, static | 9.050 | 11.50 | 51.6% | 0.1822 | 0.5358 |
| Shot quality, static | 9.074 | 11.54 | 52.5% | 0.1827 | 0.5373 |
| Margin only, static | 9.138 | 11.62 | 50.6% | 0.1845 | 0.5415 |

- The efficiency signal earns its place: luck-adjusted beats margin-only by 0.09 pts MAE and
  0.006 log loss, and lands 0.07 pts behind the closing line.
- Most of the gap to the line is early: the 2025-11-10 snapshot (prior + ~1 game each) is
  9.65 vs 9.19; after December the model is within 0.0–0.2 of the line. That is the roster
  prior's job (Phase 4).
- The random walk barely matters within one season (τ ≈ 0.6 per week); keep it for the
  structure, decide on the multi-season backtest.
- Shot quality's 52.5% ATS is one season (SE ≈ 0.7 percentage points), so it can't be told
  apart from the 52.4% break-even; re-check on 2016–2026, not a finding yet.
- **Gates: 37 of 40 backtest fits missed one** (ESS < 400 with 4 × 500 draws). Fixed in A7.

**A5. Resume.** WAB at Selection Sunday 2026, top-37 non-champions vs the committee's 37
at-large teams (31 automatic bids detected correctly from conference-tournament finals):

| Ranking | At-large teams matched |
| :--- | ---: |
| WAB, bubble = #35 | 36 / 37 |
| WAB, bubble = #45 | 36 / 37 |
| WAB, bubble = #55 | 35 / 37 |
| Torvik WAB (Selection Monday snapshot) | 35 / 37 |
| Power rating | 33 / 37 |

WAB correlates 0.998 with Torvik's WAB (334 of 365 teams name-matched). The one miss at
bubble #45: Auburn in at #36, SMU (selected) out at #39. The result barely depends on the
bubble rank between 35 and 45, so the 2027 change (44 at-large bids) is a recalibration, not a
redesign.

**A6. Lineups.** Starting from box-score starters and applying ESPN substitution events in
play order, both teams have exactly five on court for 98.9% of game time; 97.5% of games are
≥ 95% clean (400 random games). A lineup-level player layer is feasible from free data, but only
from 2024-25: the bulk play-by-play has no substitution events before part of that season (B3).

**A7. Convergence** (`pilot/out/07_convergence.md`). The failing parameters were hyperparameters,
not ratings: σ_conf, τ, σ_team (week 1) and b_prev. Two-week states, a separate conference
carry-over, centred conference means (worse: up to 90 divergences) and adding non-D1 games did
not fix it. Informative priors on σ_conf, σ_team, τ plus 4 × 1000 draws pass every gate on 7
of 7 snapshots (min ESS 751, max R̂ 1.008, no divergences, ~75 s per fit) with unchanged
predictions. These are now the `model_config()` defaults; their centres are in-sample and must
come from pooled refits in the full build. Non-D1 games (547 a season, one pooled non-D1 level)
also pass every gate and are neutral to slightly better (Nov–Dec MAE 9.317 vs 9.327), so they are
included by default.

**A9. Exhibitions: not used.** Rule: preseason/exhibition games only if one or two sources carry
them. ESPN (bulk and site API), CBBD (`seasonType=preseason` is empty) and NCAA.com all start at
opening night. The only public record is ~365 school athletics sites; a scrape pilot reached 17
of 40 sampled schools (`pilot/out/08_exhibitions.md`). Revisit only if a single feed appears.

**A8. Preseason prior source.** Torvik's public preseason ratings (time machine, 2025-11-02)
correlate 0.92 with our last-season rating. Nov–Dec MAE: own 9.33, Torvik 9.30, mean of both
9.28, closing line 9.26. Use the mean as the Phase 1 prior; the roster prior (Phase 4) must beat it.

**A10. Rosters, availability, venues** (checked 2026-10-23).

| Need | What exists | Gap |
| :--- | :--- | :--- |
| Rosters | ESPN bulk rosters for 2024-25 to 2026-27 (2026-27: 354 teams, 5,461 players, posted now); player box for every game since 2003 (minutes, starter, `did_not_play`, athlete id); CBBD `/teams/roster`, `/recruiting/portal` | Pre-2025 rosters only as "who played" from box scores |
| Injuries | None historical. ESPN has an MBB injuries endpoint (`site.api.espn.com/.../mens-college-basketball/injuries`), empty in preseason; NCAA availability reports for March Madness only | Live regular-season availability unknown until the season starts; past absences inferable from box scores (rotation player with no minutes) |
| Home / away / neutral | ESPN `neutral_site` and CBBD `neutralSite` agree on 6,264 of 6,300 games (29 neutral only in ESPN, 7 only in CBBD); ESPN venue id, city, state per game | 7 "neutral" games were in one team's own arena (conference tournaments on campus, e.g. MWC at Thomas & Mack); 52 home games were at a second arena (UConn in Hartford, still home) |

Implemented (Phase 1): the model's `site` is ESPN's flag, except that a "neutral" game on exactly
one team's floor (≥ 2 non-neutral home games there this season or last) is that team's home game,
and a non-neutral game on the away team's floor only is the away team's home game (7–10 games a
season). Both neutral flags are stored; the `venues` target lists recodes and disagreements.

Neutral-site residuals from the 2025-26 fit, oriented to the team with the local tie (per 100;
home court 3.9): own arena +3.9 (6 games, se 7.4), team's home state −1.3 / −1.1 (86 / 50
games, se ≈ 2), truly neutral −0.7 (476). One season shows no semi-home edge; own-arena games
look like home games but are too few to say. Pool across seasons before modelling either.

## B. Corrections to the design doc

- **B1. cbbreadr bulk files are gone.** The package was archived on CRAN (2025-07-25) and its
  data taken down at CBBD's request. History comes from the ESPN bulk files instead (2006 on;
  play-by-play for ~85–90% of games from 2014-15, ~99% since 2021-22).
- **B2. CBBD is narrow by necessity.** Responses are capped at 3,000 rows, so a season is
  3 calls per endpoint (games, lines). The 1,000-call monthly quota is shared with CFB. A full
  2015–2026 backfill of games + lines is ~72 calls; the live season needs 2 calls a day at most
  (games + lines for the current window). ESPN play-by-play has no spreads in 2025-26.
- **B3. Lineups and transfers do exist, but ESPN's substitutions start in 2024-25.** CBBD has
  `/lineups`, `/substitutions` and `/recruiting/portal`. ESPN's bulk play-by-play has substitution
  events with athlete ids in 1,586 games of 2024-25 and every game of 2025-26 (A6), and none
  before (checked 2026-10-24; the pilot had tested 2025-26 only). Lineups for 2014–2024 would need
  CBBD `/substitutions` (quota) or stats.ncaa.org (`ncaaparticipatr`); player box scores
  (starter, minutes, did-not-play) exist for every season.
- **B4. Torvik is directly downloadable.** `YYYY_team_results.csv`, `YYYY_super_sked.csv`,
  `getadvstats.php?year=YYYY&csv=1` and the daily time machine
  (`timemachine/team_results/YYYYMMDD_team_results.json.gz`) need no key. `cbbdata` (installed)
  needs a free key and adds NET and team sheets.
- **B5. Efficiency = luck-adjusted by default, not pure shot quality.** Pure xPts throws away
  real shooting-talent signal (cor 0.53 vs 0.76, MAE 9.074 vs 9.050). Keep both in the code
  and choose by the multi-season backtest.
- **B6. Field size is confirmed.** 76 teams from 2027, at-large bids 37 → 44
  ([ESPN via ABC7](https://abc7news.com/post/ncaa-basketball-tournaments-set-move-76-teams-espn-sources-say/18995864/)).
- **B7. The ESPN bulk files miss a few completed games.** 58 games with a D1 team on 2015-11-20 and 4 CIT/CBI
  games on 2017-03-13/14 are in CBBD (with their ESPN ids) but in no ESPN bulk file; they come
  from the ESPN summary API (box score, no play-by-play). The two 2017 First Four games
  (Mount St. Mary's–New Orleans, Kansas State–Wake Forest) are in neither source.
- **B8. D1 membership comes from ESPN, eligibility from a hand-kept table.** ESPN's core API lists
  each season's D1 conferences and members; it matches the teams with a CBBD conference in every
  season 2014–2026, except that it lists Bellarmine and UC San Diego a year early (2019-20) and
  keeps the Ivy League in 2020-21 (no games). Teams without a game in a completed season are
  dropped. Teams moving up from D2/D3 are D1 opponents but cannot play in the NCAA tournament:
  `data/d1_transitions.csv` (first D1 and first eligible season, from school and NCAA
  announcements; the January 2025 rule cut transitions by a year) keeps them out of the automatic
  bids and the at-large pool (Bellarmine won the 2022 ASUN tournament, Merrimack the 2023 NEC
  tournament, both ineligible).

## C. Target methodology

### C1. Power model (`stan/power.stan`)
- Latent strength per team in points per 100 possessions, D1 mean = 0 in every draw.
- Signals: regulation margin per 100 regulation possessions (normal, OT → 0; normal beat
  Student-t and a contaminated normal in the variant backtest) conditioned on the luck-adjusted
  efficiency residual, as in CFB. `lux100` beat `eff100` and margin only. Precision weights w = possessions / 70.
- Hierarchy: `r0 = mu_conf + b·prev_dev + s·z`; `mu_conf ~ N(0, σ_conf)`; one D1 tier.
- Dynamics: weekly random walk (CFB's τ); weekly states (two-week states did not help, A7).
- Sampling: 4 × 1000 draws with informative priors on σ_conf, σ_team, τ from pooled refits (A7).
- Non-D1 games: included as one pooled non-D1 level with extra spread (A7), margin signal only.
- Exhibitions: excluded (A9).
- **Tempo/total submodel** (done; `tempo_model()`): ridge team pace and total-points effects with
  carry-over, so spreads and totals come from the model. Possessions MAE 3.68 / 4.02 (Jan–Apr /
  Nov–Dec), totals 13.3 / 13.6 vs the closing total's 13.1 / 13.2.
- **HCA**: one per season, prior N(4.5, 0.4) pooled from the final fits; 2020-21 N(3, 0.5).
  Team-level HCA tested, no gain.
- **OT**: a tie; OT margin at weight 0.5 or 1 tested, no gain.
- **Venue**: home / away / neutral from ESPN, flagged where ESPN and CBBD disagree. "Neutral"
  games in one team's own arena count as home games. Test a partial edge for neutral games in
  a team's home state (or within driving distance) on the pooled 2015–2026 data (A10): +0.2 pts
  (se 0.3), not modelled.
- **Availability** (Phase 4, with the player layer): ratings describe the usual rotation;
  forecasts adjust for known absences only where a feed exists (ESPN injuries endpoint if it is
  populated in season; NCAA availability reports in March). Past absences, inferred from box
  scores, are used to fit the player layer and to flag games played short-handed, never as
  pregame information in the backtest.
- Priors: centred on vague-prior full-season refits 2015–2026, same pooling rule as CFB
  (`prior_refits` → `pool_priors()` → `priors_from_pool()`).

### C2. Preseason prior
1. Phase 1: mean of last season's final rating and Torvik's preseason rating (A8), plus
   two-seasons-back (CFB `use_prev2`; adopted: Δ MAE −0.08 overall, −0.17 in Nov–Dec).
2. Phase 2: **roster prior** (coded, `R/06_roster.R`; Torvik BPM × minutes for returners and
   transfers, CBBD recruit ranks for freshmen, one regression on earlier seasons). Prior-only
   first-two-weeks MAE 9.56 → 9.47; fitted variant Δ MAE −0.03, −0.06 in Nov–Dec. Default
   since 2026-10-24. Player value from Torvik player stats (BPM / PRPG!) or a
   lineup-based RAPM from A6; returning-minutes share; transfers from CBBD `/recruiting/portal`
   + roster diffs by athlete id, scaled by a conference-translation factor; freshmen from
   recruiting rank. Enters `r0` as CFB's `use_ret` / `use_tal` terms. Exit: Nov–Dec MAE improves.

### C3. Resume
- WAB per draw against the last team in (moving benchmark, done), 76-team field from 2027.
- Validation 2016–2026: 33.3 of 36.3 at-large teams on average, below the 35 / 37 exit check;
  quadrant features don't close the gap without NET (`pilot/out/14_resume_validation.md`).
- P(at-large) needs automatic bids. In season, simulate conference tournaments from the power
  posterior (CFB `08_season_sim.R` pattern) so P(auto bid) and P(at-large) are joint.
- Team-sheet extras: quadrant records using our own power ranks (and NET via cbbdata as a
  comparison), SOR probability, schedule strength (bubble team's expected losses), luck
  (wins − expected wins), Colley.

### C4. Validation
- Rolling backtest 2016–2026: weekly snapshots, each game predicted from the last snapshot
  before it. Metrics: MAE/RMSE vs closing spread, ATS, Brier, log loss, CRPS, calibration,
  coverage; split Nov–Dec vs Jan–Apr. Baselines: closing line, Torvik (super_sked / time
  machine), margin-only model.
- Resume: at-large overlap and seed-line correlation with each committee 2016–2026 (no 2020
  tournament); rank correlation with Torvik WAB and NET.
- PPC, `priorsense`, PSIS-LOO, SBC, gates (R̂ ≤ 1.01, ESS ≥ 400, no divergences, E-BFMI > 0.2).

## D. Pipeline (`targets`, mirrors CFB)

```
sync (ESPN bulk + CBBD games/lines + Torvik → data/raw → data/cbb.duckdb)
  └ per season s: data_s → snaps_dates_s → inputs_s[date] → snaps_s[date]   (dynamic branches)
                   shot_model_s (fit on seasons < s)   ↑ prior = final ratings of s−1 (+ roster prior)
                                                       → checks_s (PPC, sensitivity, LOO)
  → snapshots → ratings → backtest → resume (WAB, P(at-large)) → dashboard_data → dashboard
  → analysis targets (prior_refits, ablations, baselines, sbc) → paper
```

- Snapshot cadence: weekly (Mondays) for past seasons (~20 per season, ~240 fits), daily for the
  live season. At ~75 s average per converging fit (up to ~165 s in March) and 3–4 fits at once
  on 16 cores, a full rebuild is ~1.5–2 h before the analysis targets.
- Shot model per season trained on earlier seasons only (no leakage); the FT% shrinkage uses
  career-to-date attempts.

## E. Phases and exit checks

| Phase | Work | Exit check |
| :--- | :--- | :--- |
| 1. Ingest | DuckDB tables for 2015–2027: games, plays (filtered columns), team/player box, lines, Torvik; team crosswalk ESPN↔CBBD↔Torvik | Every D1 game has a row; coverage report by season (PBP, lines, OT, neutral); no unmatched Torvik names |
| 2. Signals | Possessions, garbage time, shot model per season, `lux100`/`eff100` | Shot model calibrated by family each season; possession counts within 1% of box estimate |
| 3. Team model | `power.stan` with tempo/total, HCA by season, pooled priors | Dynamic fits pass gates; backtest beats margin-only and is within 0.1 pt MAE of the closing line |
| 4. Roster prior | Player values, transfers, minutes, conference translation | Nov–Dec MAE improves on Phase 3 |
| 5. Resume | WAB, bubble calibration, conference-tournament sim, team sheet | ≥ 35/37 at-large overlap on average 2016–2026 |
| 6. Live + dashboard | Daily `targets` run, Quarto dashboard, reports | Daily build < 10 min, ≤ 2 CBBD calls |

Status 2026-10-24: 1 done. 2 done (shot calibration within ±0.6 pp for threes, possessions
within ~1%). 3 done in code; the rebuild decides the line check (Phase 1: 8.91 vs the line's 8.79 on the
games with a line, gap 0.12). 4 done (roster prior adopted; Nov–Dec improves in the variant backtest). 5 done; exit check not met (33.3 / 36.3).
6 built (dashboard, reports, daily script); measured once the season starts.

## F. Dashboard

Same build as CFB (`docs/dashboard.qmd`, Quarto + Observable JS, `styles/cfb.css` tokens, light and
dark), sketched with pilot numbers at <https://claude.ai/artifact/FhRJURvGT7ZSnMssjH4bwS>
(`pilot/08_dashboard_data.R`). Tabs, CFB → CBB:

| CFB tab | CBB tab | Changes |
| :--- | :--- | :--- |
| Rankings | Rankings | Benchmark #12 → bubble #45; "Top 12" → at-large chance (Auto for champions); AP/CFP → committee seed; off/def once the tempo submodel exists |
| Team | Team sheet | Adds quadrant record (own power ranks; NET alongside) and per-game WAB earned |
| Matchup | Matchup | Spread = per-100 margin × expected possessions |
| Games | Games | Daily slate instead of weekly |
| Postseason (CFP) | Bracketology | Bubble board, at-large line, automatic bids, seed lines |
| Trends, Resume vs. Power, Polls, Conference | same | Polls = AP/Coaches from CBBD; Conference = regular-season title + conference-tournament odds |

## G. Open questions

- ~~Should OT stay a tie?~~ Yes: OT margin at weight 0.5 / 1 gave nothing (`pilot/out/12_variants.md`).
- ~~Garbage-time thresholds and late intentional fouls~~: tighter, looser, none and IFT removal
  all within noise; rules kept.
- ~~Torvik name crosswalk~~: done (`data/torvik_names.csv`).
- Injuries: is ESPN's in-season report complete enough for a pregame availability adjustment?
  Decide around 2026-11-16.
- NET: a cbbdata account would allow NET quadrants on the team sheet and a NET-based selection
  test.
