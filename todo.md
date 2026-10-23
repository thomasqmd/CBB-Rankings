# TODO

Phases follow `plan.md` §E. The pilot is done and the pipeline is built. Every data target
(sync, data, shot models, games, teams, snapshot dates) is built for 2013-14 to 2026-27; the
model fits (`prior_*` from 2014-15 on, `inputs_*`, `snaps_*`) have not been run.

## Next

- [ ] Full build: `Rscript -e 'targets::tar_make()'` (no CBBD calls needed now; ~1.5–2 h of fits), then `Rscript check_build.R`
- [x] Data coverage 2014–2027: efficiency signal 87–100% of D1 games, closing lines 71–73% before 2018-19 and 93–100% after, Torvik preseason matched for every team 2015–2027 (15 overrides added)
- [ ] Pooled priors (Phase 3, first item), then refit

## 0. Pilot (done 2026-10-23)

- [x] Probe sources: CBBD API (works with `CFBD_API_KEY`), ESPN bulk releases, Torvik CSV/JSON, cbbreadr (gone)
- [x] Fetchers with caching: `R/01_ingest.R` (CBBD date windows under the 3,000-row cap)
- [x] Games table, possessions, regulation margin, closing spread: `R/02_prep.R`
- [x] Shot make model + `eff100` / `lux100` signals; calibration report (`pilot/out/01_audit.md`)
- [x] `stan/power.stan` with `use_eff` / `dynamic` switches; 2024-25 → 2025-26 carry-over
- [x] Selection Sunday fits, 4 variants (`pilot/out/02_fits.md`)
- [x] Rolling backtest, 10 snapshots × 4 variants (`pilot/out/05_backtest.md`)
- [x] WAB vs the 2026 field and Torvik WAB (`pilot/out/04_wab.md`)
- [x] Lineup reconstruction test (`pilot/out/06_lineups.md`)
- [x] Convergence: diagnosis, two-week states, conference carry-over, centring, non-D1 games, informative priors (`pilot/out/07_convergence.md`)
- [x] Preseason prior: own vs Torvik preseason vs mean (`pilot/out/07_convergence.md`)
- [x] Non-D1 games under the converging setup (`pilot/conv/06_nond1.R`)
- [x] Exhibition scrape feasibility (`pilot/07_exhibitions.R`, parked)

## 1. Ingest

- [ ] `renv::init()` and lock packages (pilot installed into the user library)
- [x] DuckDB `data/cbb.duckdb`: `games` (both divisions, lines, venue), `shots`, `free_throws`, `game_live`, `torvik_pre`, `sync_meta` (`R/01_sync.R`)
- [ ] DuckDB, later phases: `player_box`, `rosters`, substitutions (player layer)
- [x] Backfill seasons 2014–2026 (2026-10-23; 2025-26 CBBD refetched in four windows, the old first window was capped at 3,000)
- [x] `sync_all()` with a data fingerprint; final seasons never refetched; `PREP_VERSION` forces a re-sync after parsing changes
- [x] CBBD in four date windows (the 3,000-row cap was hit exactly by 2025-26's first window and exceeded by 2026-27's)
- [x] Torvik ↔ ESPN crosswalk: normalised names + `data/torvik_names.csv` (365 / 365 for 2024-25 and 2025-26)
- [ ] Conference by season checked against 2026-27 realignment (2026-27 has 318 teams with games scheduled so far)
- [ ] D1 membership by season (transitioning teams, West Florida joins, Saint Francis leaves)
- [x] Coverage report by season (`coverage` target, printed by `check_build.R`)
- [x] Live-season rule: snapshots through today, games played before the snapshot date; before opening night a preseason snapshot from Torvik's current ratings
- [ ] Venue: store ESPN + CBBD neutral flags, log the ~0.6% disagreements; recode "neutral" games in a team's own arena as home
- [ ] Rosters: ESPN bulk rosters (2025–2027) + player box (`starter`, `minutes`, `did_not_play`) for every season into DuckDB
- [ ] Injuries: poll the ESPN MBB injuries endpoint daily from opening night (early November 2026) and archive it; decide after two weeks whether it is populated enough to use

## 2. Signals

- [x] Shot model per season on the two earlier seasons only; families missing from training fold into jumpers (2014-15 has no hook descriptor)
- [x] Twos and threes fit as separate GLMs, each with its own distance spline (one `three × ns(dist)` spline was ill-conditioned and failed to converge in 5 seasons)
- [ ] Shot model calibration report by family and season (hooks over-predicted in the pilot; 2025-26 layups under-predicted, 0.520 vs 0.554)
- [x] FT% shrinkage on attempts before each game (this season + the previous one)
- [x] Play parsing for every ESPN format: derived `points_attempted`, free-throw trips without "1 of 2", elapsed time from the displayed clock (2014-15's `start_game_seconds_remaining` is wrong), shot type from the description not the player's name
- [ ] Possession counting from PBP; compare with the box-score estimate
- [ ] Tune garbage-time thresholds and test removing late intentional-foul trips
- [ ] Keep `eff100` and `lux100`; pick by backtest at each rebuild

## 3. Team model

- [ ] Re-derive the σ_conf / σ_team / τ prior centres from pooled vague-prior refits (pilot used in-sample 2025-26 means) and re-check gates on every snapshot
- [ ] Rerun the full pilot backtest with the converging defaults (4 × 1000, informative priors)
- [ ] Tempo + total submodel (CFB `t` / total model) → spreads and totals in points
- [ ] HCA per season with pooled prior; 2020-21 separate; test shrunk team HCA
- [ ] OT handling test: tie vs. OT margin with its own weight
- [ ] Semi-home edge: neutral games in a team's home state / own arena, pooled 2015–2026
- [x] Non-D1 games: pooled non-D1 level, passes gates, neutral/slightly better; included by default
- [ ] Non-D1 games in the ingest: `build_games(division = "nond1")` for every season; check non-D1 team ids are stable across seasons
- [x] Exhibitions: no single or two-source feed; school-site scraper parked (`pilot/out/08_exhibitions.md`)
- [ ] Margin family comparison (normal / t / mixture / scale-t) by pooled LOO (CFB `margin_comparison`)
- [ ] Vague-prior refits 2015–2026 → pooled priors in `model_config()`
- [ ] Add two-seasons-back term (`use_prev2`)
- [x] `targets` pipeline: per-season targets, snapshot branches (opening night, Mondays, final), gates; `check_build.R` fails on an errored target or a failing live snapshot
- [ ] Full rolling backtest 2016–2026 vs closing line and Torvik; Nov–Dec vs Jan–Apr

## 4. Roster prior

- [ ] Player value: Torvik PRPG!/BPM per player-season; optional lineup RAPM from rebuilt stints
- [ ] Returning-minutes share by team
- [ ] Transfers: CBBD `/recruiting/portal` + roster diffs by athlete id; conference-translation factors
- [ ] Freshmen: recruiting rank (CBBD `/recruiting/players`)
- [ ] Absences: infer from box scores (rotation player, 0 minutes / `did_not_play`); use to fit the player layer and flag short-handed games, not as pregame information
- [ ] Live availability adjustment, only if the ESPN injuries endpoint proves usable; NCAA availability reports in March
- [ ] Phase 1 preseason prior: mean of own last-season rating and Torvik preseason (time machine, day before opening night); Torvik name crosswalk needed
- [ ] Enter `r0` as `use_ret` / `use_tal`-style terms; keep only what improves Nov–Dec MAE over the Torvik blend

## 5. Resume

- [ ] Bubble rank per season from past fields (rank of the last at-large team in each draw); shift for 44 at-large bids in 2027
- [ ] Automatic bids: detect conference champions historically; simulate conference tournaments in season
- [ ] P(at-large), P(auto bid), P(in field) jointly from the simulation
- [ ] Team sheet: quadrant records (own ranks; NET via `cbbdata` for comparison), SOR, SOS, luck, Colley
- [ ] Validate 2016–2026: at-large overlap, seed-line correlation, Torvik WAB / NET rank correlation

## 6. Live season and outputs

- [ ] Daily `targets` run during 2026-27 (season opens early November 2026)
- [x] Dashboard sketch with pilot numbers (`plan.md` §F; https://claude.ai/artifact/FhRJURvGT7ZSnMssjH4bwS)
- [ ] Quarto + Observable JS dashboard from the sketch: Rankings, Team sheet, Matchup, Games, Bracketology, Trends, Resume vs. Power, Conference, Polls
- [ ] `check_build.R` (errored targets, gates, freshness, coverage, backtest vs line)
- [ ] Reports: season retro, model diagnostics; methods paper later
