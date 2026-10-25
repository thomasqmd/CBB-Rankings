# TODO

Phases follow `plan.md` §E. The pilot is done, the pipeline is built and backtested for 2013-14 to
2026-27, and Phase 1 (ingest) is complete (2026-10-24). Phases 2–6 are coded and tested; the
store still holds the Phase 1 build (2026-10-24 evening).

## Up next

1. **Full rebuild** (held while other jobs run; ~2–3 h, every snapshot refits under the new
   defaults: prev2, pooled HCA prior, normal margins, roster prior):
   `Rscript -e 'targets::tar_make()'`, then `Rscript check_build.R`. Check:
   - backtest vs Phase 1 (MAE 8.87, log loss 0.5259) and vs the line; Nov–Dec gap to the line
   - gates with `b_prev2` and the normal margins
   - new checks: totals vs closing total, shot calibration, prior sources (`prev2`, `roster`),
     field-odds sums
   - `docs/index.html`, `docs/reports/season_retro.html` and `model_diagnostics.html` render
     (first `tar_quarto` run); look through the dashboard tabs again
   - whether prev2 and the roster prior overlap: compare `b_prev2` with the variant run and the
     Nov–Dec gain with the two variants' separate gains
2. After the rebuild: rerun `pilot/14_resume_validation.R` (bans now applied) and
   `pilot/11_signals.R`; update the numbers in their reports and in `README.md` / `plan.md`.
3. Install the daily build yourself (`README.md`), then measure it against the Phase 6 exit check
   (< 10 min, ≤ 2 CBBD calls; `logs/daily_<date>.log`).

Waiting on the season or outside input:
- Injuries: decide around 2026-11-16 whether ESPN's report is filled enough to use (absences are
  worth ~0.7 pts per 10% of minutes missing, `pilot/out/11_signals.md`)
- Live availability adjustment: depends on the injuries decision
- 2026-27 daily runs from opening night (2026-11-02); 2027 season retro after the final
- NET quadrants and NET rank comparison: need a cbbdata account (`CBD_USER` / `CBD_PW`)
- Methods paper: later

## Done

- [x] Phase 1 rebuild 2026-10-24 (1 h 36 m, 659 targets, no errors): every completed CBBD D1 game now in `games` (47 more D1 games in 2015-16), 141 own-floor "neutral" games recoded to home across 2014–2026, ESPN/CBBD neutral flags disagree on 44 (35 in 2026, `tar_read(venues)`), 0 conference disagreements, ineligible teams 0–11 by season. Backtest unchanged: 65,268 games (was 65,217), MAE 8.87, log loss 0.5259, ATS 51.3%; vs Torvik 8.914 / 8.980 / line 8.791. Gates 273 / 277 (was 274; still only `tau`, R-hat ≤ 1.017, now different snapshots, so MCMC noise)
- [x] Full build 2026-10-24: 571 targets, 3 h 43 m, no errors; `check_build.R` run (274 / 277 snapshots pass the gates, the 3 misses are `tau` at R-hat ≤ 1.0125)
- [x] Data coverage 2014–2027: efficiency signal 87–100% of D1 games, closing lines 71–73% before 2018-19 and 93–100% after, Torvik preseason matched for every team 2015–2027 (15 overrides added)
- [x] Pooled priors (2026-10-24): vague-prior refits of each final snapshot 2015–2026, random-effects pooling → sigma_conf N(1.48, 0.2), sigma_team N(4.27, 0.35), tau N(0.56, 0.1) (`pilot/out/09_pooled_priors.md`). Rebuilt 2026-10-24 with these and the moving WAB benchmark (1 h 34 m, half the old fit time): 274 / 277 snapshots pass the gates (was 272; the 3 misses are `tau` at R-hat ≤ 1.0125), backtest MAE 8.87 (was 8.88), log loss 0.5259 (was 0.5271). Benchmark on Selection Sunday: #42.8–46.6 by season, #44.5 in 2026
- [x] Polls in the pipeline (2026-10-24): CBBD `/rankings` cached as `data/raw/cbbd/rankings_<s>.json` → `polls` table (AP + Coaches, every release, receiving-votes rows with rank NA; CBBD team ids → ESPN via shared games, pooled over seasons). Release dates missing before 2016-17 are filled from the week number. `polls_db` (reread every run, outside the sync fingerprint) → `polls_<s>` matched to the snapshot on or just before each release → `snapshots$polls`
- [x] WAB benchmark = the last team in (2026-10-24): per draw, the automatic bids leave the power ranking and the benchmark is the (field − automatic bids)-th best remaining team (`auto_bids()` / `wab_draws()` in `R/04_resume.R`, `field_size()` in `R/03_model.R`). Automatic bids: conference tournament champions once the final is played (`champions` table from CBBD game notes; every final 2014–2026 found, Ivy before 2016-17 and 2020's cancelled tournaments fall back), otherwise the conference standings leader, ties to the higher rating in that draw. The benchmark's mean power rank is stored as `params$bench_rank`, P(automatic bid) as `resume$p_auto`. 2026 check with approximate draws: #45.7 in mid-November, #44.4 on Selection Sunday. Still to do: replace the standings leader with the conference-tournament simulation (Phase 5). The three champions not in the field are explained: Bellarmine (2022) and Merrimack (2023) were ineligible transitioning schools (now skipped, `data/d1_transitions.csv`); New Orleans (2017) did play, in a First Four game missing from both ESPN and CBBD

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

- [x] Lock packages: `renv.lock` (92 packages; cmdstanr from GitHub), restored into the user library. Not renv-activated, by choice: activation would skip `~/.Rprofile` (Positron / mcptools registration)
- [x] DuckDB `data/cbb.duckdb`: `games` (both divisions, lines, venue), `shots`, `free_throws`, `game_live`, `torvik_pre`, `sync_meta` (`R/01_sync.R`)
- [x] DuckDB player tables (2026-10-24): `player_box` every season (~190k rows a season: starter, minutes, `did_not_play`, box stats), `rosters` 2025–2027 (ESPN bulk: class, height, weight, hometown), `substitutions` from play-by-play. ESPN's bulk play-by-play has substitutions only in 1,586 games of 2024-25 and all of 2025-26 (`plan.md` B3); 2014–2024 lineups would need CBBD `/substitutions` or stats.ncaa.org
- [x] Backfill seasons 2014–2026 (2026-10-23; 2025-26 CBBD refetched in four windows, the old first window was capped at 3,000)
- [x] `sync_all()` with a data fingerprint; final seasons never refetched; `PREP_VERSION` forces a re-sync after parsing changes
- [x] CBBD in four date windows (the 3,000-row cap was hit exactly by 2025-26's first window and exceeded by 2026-27's)
- [x] Torvik ↔ ESPN crosswalk: normalised names + `data/torvik_names.csv` (365 / 365 for 2024-25 and 2025-26)
- [x] D1 membership by season (2026-10-24): `d1_teams` from ESPN's core API (conference per season, CBBD names), `teams_<s>` built from it. Matches the CBBD-conference teams in every season 2014–2026 (ESPN lists Bellarmine and UC San Diego a year early and the Ivy League in 2020-21; teams without a game in a final season are dropped). 2026-27: 365 teams, West Florida in (ASUN), Saint Francis out; the live season keeps teams with no game scheduled yet (47 of them on 2026-10-24)
- [x] Conferences checked against the 2026-27 realignment: ESPN's membership and CBBD's scheduled games agree for every team (rebuilt Pac-12, UAC, Mountain West, Big West moves); `coverage$conf_differs` = 0 every season
- [x] NCAA-tournament eligibility: `data/d1_transitions.csv` (24 transitions overlapping 2014–2030, dates from school / NCAA announcements, January 2025 one-year cut applied); ineligible teams can't take an automatic bid or count in the at-large pool
- [x] Every D1 game has a row: 58 games with a D1 team on 2015-11-20 and 4 on 2017-03-13/14 are in CBBD but no ESPN bulk file; filled from the ESPN summary API (box score, no play-by-play). The 2017 First Four games are in neither source. `check_build.R` reports any completed CBBD D1 game missing from `games`
- [x] Coverage report by season (`coverage` target, printed by `check_build.R`)
- [x] Live-season rule: snapshots through today, games played before the snapshot date; before opening night a preseason snapshot from Torvik's current ratings
- [x] Venue (2026-10-24): both neutral flags stored; `site` = +1 / −1 / 0 replaces "not neutral" everywhere (Stan `home_adv` now in [−1, 1]). A "neutral" game on one team's floor (≥ 2 non-neutral home games there, this season or last) is that team's home game, and a non-neutral game on the away team's floor only is the away team's (7–10 games a season: conference tournaments on campus, Dayton's First Four, mislabelled NIT hosts). `venues` target lists recodes and ESPN/CBBD disagreements
- [x] Rosters: ESPN bulk rosters (2025–2027) + player box for every season into DuckDB (above)
- [x] Injuries: `scripts/poll_injuries.sh` archives the ESPN report daily to `data/raw/espn/injuries/` (first file 2026-10-24, empty in preseason); every build also archives it and rebuilds the `injuries` table; `check_build.R` warns when the archive is > 1 day old. Poller scheduled with launchd 2026-10-24 (15:00 and 21:00)
- [ ] Injuries: decide around 2026-11-16 (two weeks after opening night) whether the report is populated enough to use

## 2. Signals

- [x] Shot model per season on the two earlier seasons only; families missing from training fold into jumpers (2014-15 has no hook descriptor)
- [x] Twos and threes fit as separate GLMs, each with its own distance spline (one `three × ns(dist)` spline was ill-conditioned and failed to converge in 5 seasons)
- [x] Shot model calibration by family and season, out of sample (`shot_calibration` target, `pilot/out/11_signals.md`): threes within ±0.6 pp except 2020 (+1.3, line moved back); two-point families drift with ESPN's coding (tips 2019 / 2022, layups 2026 −3.4 pp), which `lux100` doesn't use. `check_build.R` warns past 2 pp
- [x] FT% shrinkage on attempts before each game (this season + the previous one)
- [x] Play parsing for every ESPN format: derived `points_attempted`, free-throw trips without "1 of 2", elapsed time from the displayed clock (2014-15's `start_game_seconds_remaining` is wrong), shot type from the description not the player's name
- [x] Possession counting from PBP vs the box-score estimate: ratio 0.987–0.998, median per-game error 1.1–1.2%; box estimate kept (exists for every game)
- [x] Garbage-time thresholds and late intentional-foul trips tested (`pilot/out/12_variants.md`): no cut, tighter, looser and IFT removal all within noise; current rules kept
- [x] `eff100` vs `lux100`: `lux100` better (Δ MAE +0.013 for `eff100`, worse in Jan–Apr); both still computed

## 3. Team model

- [x] Re-derive the σ_conf / σ_team / τ prior centres from pooled vague-prior refits (`pilot/out/09_pooled_priors.md`); gates re-checked by `check_build.R` after the rebuild
- [x] Variant backtest under the converging setup, 91 snapshots × 16 variants (`pilot/12_variants.R`, `pilot/out/12_variants.md`); the full rolling backtest reruns with every rebuild
- [x] Tempo + total submodel (`TEMPO`, `tempo_model()` in `R/03_model.R`: ridge team effects with carry-over) → spreads and totals in points, off / def ratings. Weekly backtest 2016–2026: possessions MAE 3.68 Jan–Apr / 4.02 Nov–Dec (old shrunk averages 3.76 / 4.21); totals MAE 13.3 / 13.6 vs closing total 13.1 / 13.2
- [x] HCA per season with pooled prior N(4.5, 0.4), 2020-21 N(3, 0.5) (`hca_prior_season`): Δ MAE −0.012 (se 0.002). Shrunk team HCA (`team_hca`) within noise, off
- [x] OT handling: OT margin at weight 0.5 or 1 within noise; OT stays a tie (`ot_weight = 0`)
- [x] Semi-home edge: own-arena "neutral" games recoded to home (Phase 1); home-state neutral games +0.21 pts (se 0.31) regular season, +1.04 (se 1.29) postseason: not modelled
- [x] Non-D1 games: pooled non-D1 level, passes gates, neutral/slightly better; included by default
- [x] Non-D1 games in the ingest for every season; ids stable (927 ids, none missing, 271 with spelling variants; 11 names map to two ids, irrelevant while non-D1 teams share one level)
- [x] Exhibitions: no single or two-source feed; school-site scraper parked (`pilot/out/08_exhibitions.md`)
- [x] Margin family by predictive backtest (in place of LOO): normal beats Student-t (Δ MAE −0.006, se 0.002; log loss −0.0010); mixture ties normal on log loss, no MAE gain, slower. Default now normal (`margin_family = 2L`)
- [x] Vague-prior refits 2015–2026 → pooled priors in `model_config()`
- [x] Two-seasons-back term (`use_prev2`): Δ MAE −0.080 (se 0.006), −0.165 in Nov–Dec; on by default, `prior_<s>` carries `prev2_dev`
- [x] `targets` pipeline: per-season targets, snapshot branches (opening night, Mondays, final), gates; `check_build.R` fails on an errored target or a failing live snapshot
- [x] Full rolling backtest 2016–2026 vs closing line and Torvik; Nov–Dec vs Jan–Apr (2026-10-24, `pilot/out/10_backtest.md`): 54,388 games, MAE 8.913 vs Torvik 8.981 vs line 8.791; ahead of Torvik in all 11 seasons; Jan–Apr 8.677 / 8.785 / 8.596, Nov–Dec 9.325 / 9.320 / 9.130 (the early-season gap is the preseason prior → Phase 4). Torvik time-machine ratings the day before each snapshot (`torvik_<s>` targets), reported by `check_build.R`

## 4. Roster prior

- [x] Player value: Torvik player tables per season (`data/raw/torvik/players/`, 2013–2027; pid stable across seasons), value = BPM (capped ±15) × minutes %. Lineup RAPM not pursued (substitutions only from 2024-25)
- [x] Returning minutes and value by team (`roster_features()`, `R/06_roster.R`)
- [x] Transfers from Torvik pid moves between teams (~54% of minutes moved in 2026), valued at last season's BPM; the regression coefficient (0.36 vs 0.20 for returners) does the translation. CBBD portal not needed
- [x] Freshmen: recruiting rank (CBBD `/recruiting/players`, 1 call a season; value ≈ 100 − 0.19 × rank)
- [x] Absences from box scores (`add_absences()`: ≥ 20 mpg over the last 5, absent when DNP or playing later): 22–31% of team-games short-handed; residual −0.70 pts per 10% of minutes missing (se 0.04). Flag only, not pregame information
- [ ] Live availability adjustment, only if the ESPN injuries endpoint proves usable; NCAA availability reports in March
- [x] Phase 1 preseason prior: mean of own last-season rating and Torvik preseason (time machine), crosswalk done
- [x] Roster regression prior (`prior_method = "roster"`, `roster_prior()`), now the default: prior-only MAE over the first two weeks 9.56 → 9.47, better in 10 of 11 seasons (2020 worse); LOSO RMSE of the final rating 5.18 → 4.91; fitted variant Δ MAE −0.030 (se 0.006), −0.059 in Nov–Dec (`pilot/out/12_variants.md`). Phase 4 exit check (Nov–Dec improves) met in the variant backtest; the rebuild confirms it jointly with prev2

## 5. Resume

- [x] Bubble rank per season: replaced by the moving benchmark, the last team in per draw (see Next)
- [x] Automatic bids: champions historically (`champions`); conference tournaments simulated in season (`season_sim()`, brackets from `tourney_sizes()`, ineligible champions fall back to the standings leader)
- [x] P(auto bid), P(at-large), P(in field), P(regular-season title) jointly from the simulation (1,000 draws); `check_build.R` checks the field-odds sums
- [x] Team sheet: quadrant records from our own ranks, SOR, SOS, luck, Colley (`team_sheet()`); NET needs cbbdata (Up next, waiting)
- [x] Validation 2016–2026 (`pilot/out/14_resume_validation.md`): at-large overlap 33.3 / 36.3 (33.5 with bans), power 29.3; quadrant features add nothing out of season (33.6 at best); seed Spearman 0.95–0.98; Torvik WAB rank correlation 0.997–0.999. **Exit check (≥ 35 / 37) not met**: the gap is committee vs resume (NET quadrants); WAB kept

## 6. Live season and outputs

- [x] Daily build script `scripts/daily_build.sh` + launchd plist (07:00; you install it); CBBD calls logged to `logs/cbbd_calls.log`
- [ ] Daily `targets` run during 2026-27 (opening night 2026-11-02); exit check < 10 min, ≤ 2 CBBD calls
- [x] Dashboard sketch with pilot numbers (`plan.md` §F; https://claude.ai/artifact/FhRJURvGT7ZSnMssjH4bwS)
- [x] Quarto + Observable JS dashboard (`docs/dashboard.qmd` → `docs/index.html`, `dashboard_data` + `tar_quarto` targets): all nine tabs checked in headless Chrome on dev data (2026-27 preseason, 2025-26 final); first pipeline render at the rebuild
- [x] `check_build.R` (errored targets, gates, freshness, coverage, membership, venues, missing games, player tables, injury archive, backtest vs line and Torvik, totals, shot calibration, prior sources, field odds, dashboard freshness)
- [x] Reports: `docs/reports/season_retro.qmd`, `model_diagnostics.qmd` (`tar_quarto` targets; first render at the rebuild)
- [ ] Methods paper (later)
