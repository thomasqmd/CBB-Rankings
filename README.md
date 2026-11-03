# CBB Bayesian Rankings

Two Division I men's basketball rankings, the CFB-Rankings method ported to basketball:

| | Question | Unit |
| :--- | :--- | :--- |
| **Power** | How good is a team right now? | Points per 100 possessions vs. an average D1 team on a neutral floor |
| **Resume** | What has a team earned? | Wins Above Bubble (WAB): wins beyond what the bubble team would have managed with the same schedule |

Status (2026-10-30): **pilot done; the full 2015–2027 pipeline is built, rebuilt under the
re-chosen defaults (2026-10-25) and backtested; Phases 1–6 are coded and tested.** Backtest
2015–2026: MAE 8.80 (8.81 vs the closing line's 8.75 on games with a line), log loss 0.5230,
ahead of Torvik (8.85 vs 8.98 on shared games). Pilot results are in `pilot/out/`, the plan in
`plan.md`, tasks in `todo.md` (Up next).

## Method

**Power model** (`stan/power.stan`). Each team has one latent strength *r* (per 100 possessions),
moving week to week as a random walk. Every D1-vs-D1 game informs it through two signals:

- *luck-adjusted margin*: actual 2-point makes, expected 3-point makes (shot model) and expected
  free throws (shooter FT%, shrunk), per 100 possessions outside garbage time
  ~ Normal(λ·μ, σₑ/√w)
- *regulation margin* per 100 regulation possessions (OT games count as ties)
  ~ Normal(μ + κ·(eff − λμ), σₘ/√w)

with μ = r_home − r_away + hca·site and w = possessions / 70. hca ~ N(4.5, 0.4) per season
(N(3, 0.5) in 2020-21's near-empty arenas). `site` is +1 on the home team's
floor, −1 on the away team's, 0 neutral: ESPN's neutral flag, except that a "neutral" game on one
team's floor (a venue where it played ≥ 2 non-neutral home games this season or last) counts as
that team's home game. Games against non-D1
teams use the margin only, against one pooled non-D1 level with extra spread. Exhibitions are
not used (no single feed carries them). Hierarchy:
r₀ = μ_conference + b·(preseason prior) + b₂·(rating two seasons back) + σ·z, the prior being
a regression of the final rating on last season's final rating, Torvik's preseason rating and
roster terms: returning and transferring
players' value (Torvik BPM × minutes), minutes shares, departed value and recruit ranks
(`prior_method = "roster"`, `R/06_roster.R`; `"blend"`, the mean of the two ratings, where no
roster history exists). A tempo model (ridge team effects on possessions and total
points, carried over from last season) gives expected possessions and totals; spreads are μ ×
expected possessions / 100.

**Resume.** In each posterior draw the benchmark is the last team in: the automatic bids
(conference tournament champions, else the standings leader) and the teams still moving up to D1
leave the power ranking, and the benchmark is the (field − automatic bids)-th best remaining team
(68-team field; 76 from 2027). A win adds 1 − P(benchmark wins that game at
that venue); a loss subtracts P(benchmark wins). Snapshots report WAB, its rank interval, the
chance WAB is positive, and schedule strength (the benchmark's expected loss rate).

In season, all 4,000 posterior draws simulate the rest of the regular season and each conference tournament
(bracket sizes from last season's), giving projected WAB, P(regular-season title), P(automatic
bid), P(at-large: top n by projected WAB among the rest) and P(in the field). The team sheet adds
quadrant records (NET's cut-offs applied to our power ranks), SOR, luck (wins − expected wins)
and Colley. Teams under a postseason ban (`data/postseason_bans.csv`) or still moving up to D1
can't take a bid.

## Data

| Source | Use | Access |
| :--- | :--- | :--- |
| ESPN bulk files ([sportsdataverse-data releases](https://github.com/sportsdataverse/sportsdataverse-data/releases)) | Schedule, team box, play-by-play (shots with coordinates, free throws) | Free, no key; refreshed daily in season |
| [CollegeBasketballData](https://collegebasketballdata.com/) API | ESPN↔CBBD id map, conferences, period scores, seeds, closing lines, polls (final seasons), recruit ranks | `CFBD_API_KEY` (same key as CFB; quota shared, 1,000 calls/month): 8 calls per past season, ≤ 2 a day in season |
| [Torvik](https://barttorvik.com/) CSV / JSON | Preseason ratings (time machine, day before opening night) and player tables (BPM, minutes) for the prior; benchmarks | Free, no key |
| ESPN APIs (core, site) | D1 membership by season; box scores of the ~60 completed games missing from the bulk files; daily injury report; live-season polls; team abbreviations for the dashboard | Free, no key |
| `data/d1_transitions.csv` | Teams moving up to D1 and their first NCAA-tournament-eligible season (from school and NCAA announcements) | Hand-kept |

Raw files are cached in `data/raw/` and never re-fetched once a season is final (after May 1).
Torvik team names map to ESPN ids by normalised name plus `data/torvik_names.csv`.

DuckDB tables (`data/cbb.duckdb`): `games` (both divisions, lines, both neutral flags, `site`),
`d1_teams` (membership, conference, eligibility), `shots`, `free_throws`, `game_live`,
`torvik_pre`, `polls`, `champions`, `player_box` (every game), `rosters` (ESPN, 2024-25 on),
`substitutions` (ESPN play-by-play carries them only from part of 2024-25 on), `injuries`
(archived daily reports), `sync_meta`.

ESPN keeps no injury history, so `scripts/poll_injuries.sh` archives the report once a day. To
schedule it (launchd, 15:00 and 21:00):

```bash
cp scripts/com.cbb-rankings.injuries.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cbb-rankings.injuries.plist
```

## Layout

| File | Contents |
| :--- | :--- |
| `_targets.R` | The pipeline (below) |
| `R/01_ingest.R` | ESPN, CBBD (date-windowed under the 3,000-row cap) and Torvik fetchers, readers, team names |
| `R/01_sync.R` | Raw files → `data/cbb.duckdb` (tables above) |
| `R/02_prep.R` | Games table, possessions, play parsing for every ESPN format, shot model, luck-adjusted margins |
| `R/03_model.R` | `model_config()`, Stan inputs per snapshot, fitting with gates, ratings, predictions, preseason prior |
| `R/04_resume.R` | WAB per draw, the season simulation (rest of the regular season, conference tournaments, field odds), team sheet (quadrants, SOR, luck, Colley) |
| `R/05_snapshot.R` | Snapshot dates, one snapshot's outputs, backtest (margins, win probabilities, totals), coverage report |
| `R/06_roster.R` | Torvik player tables and CBBD recruits → roster features (returning, transfers, freshmen) and the roster prior regression |
| `R/07_dashboard.R` | `build_dashboard_data()`: compact tables for the dashboard |
| `docs/dashboard.qmd` | Quarto + Observable JS dashboard → `docs/index.html` (styles in `docs/styles/cbb.css`) |
| `docs/reports/` | `season_retro.qmd`, `model_diagnostics.qmd` (rendered by the pipeline) |
| `data/postseason_bans.csv` | NCAA postseason bans (team, season), hand-kept |
| `check_build.R` | Post-build checks (gates, coverage, membership, venues, missing games, player tables, injury archive, backtest and totals, shot calibration, prior sources, field odds, dashboard freshness) |
| `scripts/daily_build.sh` | In-season daily build: `tar_make`, checks, run time and CBBD call count in `logs/daily_<date>.log` (launchd: `scripts/com.cbb-rankings.daily.plist`) |
| `scripts/publish_pages.sh` | Publishes the dashboard (`docs/index.html`, not the reports) to GitHub Pages (`gh-pages`, one force-pushed commit); run by the daily build after passing checks |
| `scripts/poll_injuries.sh` | Daily ESPN injury report archive (launchd: `scripts/com.cbb-rankings.injuries.plist`) |
| `renv.lock` | Package versions, restored into the user library (the project is not renv-activated) |
| `tests/testthat/` | Unit tests (`Rscript -e 'testthat::test_dir("tests/testthat")'`) |
| `stan/power.stan` | Power model (switches: `use_eff`, `dynamic`, `conf_carry`, `conf_centred`, non-D1 games via `N_nd`) |
| `pilot/0*.R` | Pilot scripts, run in order; each writes a report to `pilot/out/` |
| `pilot/conv/*.R` | Convergence, non-D1 and preseason-prior experiments (report: `pilot/out/07_convergence.md`) |
| `pilot/exh_scraper.R`, `pilot/07_exhibitions.R` | Parked exhibition scraper (school sites; report: `pilot/out/08_exhibitions.md`) |
| `pilot/11_signals.R` | Shot calibration, possessions, semi-home edge, non-D1 ids, absences (`pilot/out/11_signals.md`) |
| `pilot/12_variants.R` | Model-variant backtest on a fixed subset of snapshots (`pilot/out/12_variants.md`) |
| `pilot/13_roster_prior.R` | Roster prior evaluation (`pilot/out/roster_eval.rds`) |
| `pilot/14_resume_validation.R` | At-large overlap, seed correlation, Torvik WAB (`pilot/out/14_resume_validation.md`) |

## Pipeline (`targets`)

```
sync (ESPN + CBBD + Torvik → data/cbb.duckdb)
  └ per season s: data_s → shotmodel_s (trained on s−2, s−1) → games_s (signals, venue) → teams_s (D1 membership, bans)
                  roster_s (Torvik players, recruits) → prior_s (final ratings of s−1 + Torvik preseason + roster) → dates_s
                  tourney_s (conference-tournament sizes) → inputs_s[date] → snaps_s[date]   (opening night, Mondays, day after the final)
  → snapshots → backtest, coverage, venues, shot_calibration
  → dashboard_data → docs/index.html, docs/reports/*.html
```

```bash
CBB_FIRST_SEASON=2026 CBB_MAX_SNAPS=3 Rscript -e 'targets::tar_make()'   # quick test build (~10 min)
Rscript -e 'targets::tar_make()'                                          # full build, 2014 (prior only) to the current season
Rscript check_build.R
```

- `CBB_FIRST_SEASON` (default 2015; the season before it is fit once, at its end, for the
  carry-over), `CBB_LAST_SEASON` (default current), `CBB_MAX_SNAPS` (development: opening night
  plus the last n − 1 snapshots), `CBB_CORES`.
- A full build fits ~280 snapshots (~75 s each on average, 4 at a time on 16 cores: ~1.5–2 h) and
  makes ~90 CBBD calls on a cold cache. Later runs refit only new snapshots.
- Parsing changes: bump `PREP_VERSION` (`R/02_prep.R`) so final seasons re-sync.

In season, `scripts/daily_build.sh` runs the build, the checks and the render once a day and logs
the run time and CBBD calls. When the build and checks pass it publishes the dashboard (`docs/index.html`, not the reports) to GitHub Pages
(`scripts/publish_pages.sh`: one force-pushed orphan commit on `gh-pages`, so the rendered
output never builds up in the history) → <https://thomasqmd.github.io/CBB-Rankings/>. To
schedule it (launchd, 07:00), from the repo root:

```bash
cp scripts/com.cbb-rankings.daily.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cbb-rankings.daily.plist
```

To render the dashboard without the pipeline: `CBB_DASH_DATA=<rds of build_dashboard_data()> quarto render docs/dashboard.qmd`.

## Running the pilot

```bash
# once: R packages at the locked versions (cmdstanr from GitHub; CmdStan itself via cmdstanr::install_cmdstan())
Rscript -e 'renv::restore(library = .libPaths()[1], prompt = FALSE)'   # into the user library
# CFBD_API_KEY=... in ~/.Renviron

Rscript pilot/01_data.R       # fetch + build games, shot model, audit      (~3 min, 3-6 CBBD calls on a cold cache)
Rscript pilot/02_fit.R        # 2024-25 prior fit + 4 variants at Selection Sunday   (~5 min)
Rscript pilot/03_backtest.R   # 10 snapshots x 4 variants                    (~40 min)
Rscript pilot/05_eval.R       # score the backtest
Rscript pilot/04_wab.R        # WAB vs the real 2026 field and Torvik       (~4 min)
Rscript pilot/06_lineups.R    # lineup reconstruction test
```
