# CBB Bayesian Rankings

Two Division I men's basketball rankings, the CFB-Rankings method ported to basketball:

| | Question | Unit |
| :--- | :--- | :--- |
| **Power** | How good is a team right now? | Points per 100 possessions vs. an average D1 team on a neutral floor |
| **Resume** | What has a team earned? | Wins Above Bubble (WAB): wins beyond what the bubble team would have managed with the same schedule |

Status (2026-10-23): **pilot done; the `targets` pipeline is built and tested on 2024-25 to
2026-27, the full 2015–2027 fit not yet run.** Pilot results are in `pilot/out/`, the plan in
`plan.md`, tasks in `todo.md`.

## Method

**Power model** (`stan/power.stan`). Each team has one latent strength *r* (per 100 possessions),
moving week to week as a random walk. Every D1-vs-D1 game informs it through two signals:

- *luck-adjusted margin*: actual 2-point makes, expected 3-point makes (shot model) and expected
  free throws (shooter FT%, shrunk), per 100 possessions outside garbage time
  ~ Normal(λ·μ, σₑ/√w)
- *regulation margin* per 100 regulation possessions (OT games count as ties)
  ~ Student-t(ν, μ + κ·(eff − λμ), σₘ/√w)

with μ = r_home − r_away + hca·(not neutral) and w = possessions / 70. Games against non-D1
teams use the margin only, against one pooled non-D1 level with extra spread. Exhibitions are
not used (no single feed carries them). Hierarchy:
r₀ = μ_conference + b·(preseason prior) + σ·z, the prior being the mean of last season's final
rating and Torvik's preseason rating. Points spreads multiply μ by expected possessions (each
team's shrunk average pace).

**Resume.** In each posterior draw the benchmark is that draw's #45 team (the 68-team-era bubble;
a provisional #52 for the 76-team field from 2027). A win adds 1 − P(benchmark wins that game at
that venue); a loss subtracts P(benchmark wins). Snapshots report WAB, its rank interval, the
chance WAB is positive, and schedule strength (the benchmark's expected loss rate).

## Data

| Source | Use | Access |
| :--- | :--- | :--- |
| ESPN bulk files ([sportsdataverse-data releases](https://github.com/sportsdataverse/sportsdataverse-data/releases)) | Schedule, team box, play-by-play (shots with coordinates, free throws) | Free, no key; refreshed daily in season |
| [CollegeBasketballData](https://collegebasketballdata.com/) API | ESPN↔CBBD id map, conferences, period scores, seeds, closing lines | `CFBD_API_KEY` (same key as CFB; quota shared, 1,000 calls/month): 8 calls per past season, ≤ 2 a day in season |
| [Torvik](https://barttorvik.com/) CSV / JSON | Preseason ratings (time machine, day before opening night) for the prior; benchmarks | Free, no key |

Raw files are cached in `data/raw/` and never re-fetched once a season is final (after May 1).
Torvik team names map to ESPN ids by normalised name plus `data/torvik_names.csv`.

## Layout

| File | Contents |
| :--- | :--- |
| `_targets.R` | The pipeline (below) |
| `R/01_ingest.R` | ESPN, CBBD (date-windowed under the 3,000-row cap) and Torvik fetchers, readers, team names |
| `R/01_sync.R` | Raw files → `data/cbb.duckdb` (games, shots, free throws, garbage time, Torvik preseason) |
| `R/02_prep.R` | Games table, possessions, play parsing for every ESPN format, shot model, luck-adjusted margins |
| `R/03_model.R` | `model_config()`, Stan inputs per snapshot, fitting with gates, ratings, predictions, preseason prior |
| `R/04_resume.R` | WAB per draw and its summary |
| `R/05_snapshot.R` | Snapshot dates, one snapshot's outputs, backtest, coverage report |
| `check_build.R` | Post-build checks |
| `tests/testthat/` | Unit tests (`Rscript -e 'testthat::test_dir("tests/testthat")'`) |
| `stan/power.stan` | Power model (switches: `use_eff`, `dynamic`, `conf_carry`, `conf_centred`, non-D1 games via `N_nd`) |
| `pilot/0*.R` | Pilot scripts, run in order; each writes a report to `pilot/out/` |
| `pilot/conv/*.R` | Convergence, non-D1 and preseason-prior experiments (report: `pilot/out/07_convergence.md`) |
| `pilot/exh_scraper.R`, `pilot/07_exhibitions.R` | Parked exhibition scraper (school sites; report: `pilot/out/08_exhibitions.md`) |

## Pipeline (`targets`)

```
sync (ESPN + CBBD + Torvik → data/cbb.duckdb)
  └ per season s: data_s → shotmodel_s (trained on s−2, s−1) → games_s (signals) → teams_s
                  prior_s (final ratings of s−1 + Torvik preseason) → dates_s
                  → inputs_s[date] → snaps_s[date]        (opening night, Mondays, day after the final)
  → snapshots → backtest, coverage
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

## Running the pilot

```bash
# once: R packages
Rscript -e 'pak::pkg_install(c("cmdstanr","duckdb","dplyr","tidyr","httr2","jsonlite","posterior","Matrix","knitr","hoopR","nanoparquet"))'
# CFBD_API_KEY=... in ~/.Renviron

Rscript pilot/01_data.R       # fetch + build games, shot model, audit      (~3 min, 3-6 CBBD calls on a cold cache)
Rscript pilot/02_fit.R        # 2024-25 prior fit + 4 variants at Selection Sunday   (~5 min)
Rscript pilot/03_backtest.R   # 10 snapshots x 4 variants                    (~40 min)
Rscript pilot/05_eval.R       # score the backtest
Rscript pilot/04_wab.R        # WAB vs the real 2026 field and Torvik       (~4 min)
Rscript pilot/06_lineups.R    # lineup reconstruction test
```
