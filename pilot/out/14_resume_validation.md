# Resume validation 2016-2026 (2026-10-24)

`pilot/14_resume_validation.R` (results in `14_resume_validation.rds`), Phase 1 build's Selection
Monday snapshots. The 2020 tournament was not played.

At-large picks: the committee's actual automatic bids are given; our pick is the top n by WAB
among the remaining eligible teams (n = 36 or 37). NET is left out: it needs a cbbdata account
(`CBD_USER` / `CBD_PW`).

| Season | At-large | WAB picks in | Power picks in | Seed ~ WAB (Spearman) | Seed ~ power | Our WAB ~ Torvik's WAB |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2016 | 36 | 30 (32*) | 28 | 0.950 | 0.887 | 0.998 |
| 2017 | 36 | 34 | 30 | 0.959 | 0.918 | 0.997 |
| 2018 | 36 | 31 | 28 | 0.967 | 0.952 | 0.997 |
| 2019 | 36 | 33 | 28 | 0.971 | 0.959 | 0.997 |
| 2021 | 37 | 36 | 29 | 0.959 | 0.935 | 0.997 |
| 2022 | 36 | 33 | 28 | 0.972 | 0.907 | 0.998 |
| 2023 | 36 | 33 | 28 | 0.951 | 0.925 | 0.998 |
| 2024 | 36 | 32 | 29 | 0.948 | 0.947 | 0.999 |
| 2025 | 37 | 35 | 33 | 0.981 | 0.921 | 0.998 |
| 2026 | 37 | 36 | 32 | 0.977 | 0.975 | 0.997 |
| **Mean** | 36.3 | **33.3** (33.5*) | 29.3 | 0.964 | 0.933 | 0.998 |

\* 2016 picked Louisville and SMU, both under postseason bans that season. The Phase 1 build
predates `data/postseason_bans.csv`; with the bans the next two WAB teams come in.

- **Exit check (≥ 35 of 37) not met.** WAB alone gets ~92% of the at-large field. The misses are
  the usual committee-vs-resume disagreements: power-conference teams with many Quadrant 1 games
  and mediocre records (2018 UCLA / Syracuse / Arizona State, 2024 Mississippi State / Michigan
  State) left out, mid-majors with strong records (2024 Princeton / Indiana State, 2022 North
  Texas) put in.
- **Power rating alone** does worse (29.3); a blend wab + c × rating peaks at c = 0.1 (33.6) and
  falls after.
- **Quadrant features** (our own quadrants from power ranks): leave-one-season-out logistic
  selection on the top 80 by WAB.

  | Features | Mean picks in |
  | :--- | ---: |
  | WAB | 33.3 |
  | WAB + Q1 wins + Q1 losses | 33.3 |
  | WAB + Q1 W/L + Q3-4 losses | 33.3 |
  | WAB + rating + Q1 W/L + Q2 W + Q3-4 L + road wins + SOS | 33.6 |

  Q1 wins are significant in the pooled fit (+0.32 per win, se 0.10) but the out-of-season gain
  is within noise. Our quadrants come from our power ranks, not NET's, which is the likely
  limit: the committee sorts by NET quadrants. Revisit if a cbbdata account becomes available.
- **Seeding** follows WAB closely (Spearman 0.95-0.98 among field teams), better than power.
- **Torvik's WAB**: rank correlation 0.997-0.999 with ours, so the resume metric itself agrees
  with the reference implementation; the gap to the committee is the committee.

Decision: keep WAB as the resume ranking and the at-large rule in the season simulation;
quadrant records are shown on the team sheet but not used for selection.
