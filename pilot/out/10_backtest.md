# Rolling backtest vs the closing line and Torvik (2026-10-24)

`backtest` target (`run_backtest()` in `R/05_snapshot.R`), build with pooled priors and the moving
WAB benchmark. Each weekly snapshot predicts the D1 games until the next snapshot from games
played before it.

Torvik: his time-machine ratings for the day before each snapshot (a file dated D includes D's
games, checked against every team's record), so he sees the same games. His margin uses his
formula (tempo = t_h t_a / avg; points per 100 = own offence x opponent defence / avg); home
court and the win-probability sd are fitted on earlier seasons only, so 2015 is the warm-up.
Scored on the 54,388 games 2016-2026 that all three predicted.

| | Games | MAE | RMSE | Log loss | Model closer than Torvik |
| :--- | ---: | ---: | ---: | ---: | ---: |
| **Model** | 54,388 | **8.913** | **11.34** | **0.5290** | 51.7% |
| Torvik | | 8.981 | 11.40 | 0.5324 | |
| Closing line | | 8.791 | 11.17 | | |
| Model, Nov-Dec | 19,846 | 9.325 | 11.92 | 0.4735 | 50.8% |
| Torvik, Nov-Dec | | 9.320 | 11.87 | 0.4729 | |
| Line, Nov-Dec | | 9.130 | 11.63 | | |
| Model, Jan-Apr | 34,542 | **8.677** | **10.99** | **0.5608** | 52.2% |
| Torvik, Jan-Apr | | 8.785 | 11.12 | 0.5666 | |
| Line, Jan-Apr | | 8.596 | 10.90 | | |

By season (MAE, model / Torvik / line): the model beats Torvik's MAE in all 11 seasons
(by 0.02-0.14) and his log loss in 10 (2020: 0.5314 vs 0.5304; 2025 ties at 0.5164 / 0.5165).

| Season | Model | Torvik | Line |
| ---: | ---: | ---: | ---: |
| 2016 | 8.504 | 8.586 | 8.368 |
| 2017 | 8.840 | 8.856 | 8.739 |
| 2018 | 8.730 | 8.867 | 8.720 |
| 2019 | 8.874 | 8.927 | 8.787 |
| 2020 | 8.939 | 9.004 | 8.768 |
| 2021 | 9.266 | 9.390 | 9.047 |
| 2022 | 8.771 | 8.838 | 8.710 |
| 2023 | 8.936 | 8.970 | 8.831 |
| 2024 | 9.018 | 9.117 | 8.875 |
| 2025 | 8.936 | 8.979 | 8.749 |
| 2026 | 9.142 | 9.189 | 9.014 |

What it says:

- From January on the model is clearly better than Torvik (0.11 pts MAE) and 0.08 behind the line.
- November-December is a tie with Torvik and 0.20 behind the line: the gap is the preseason
  prior, so the roster prior (Phase 4) is where the next gain is.
- Caveat: this is Torvik's ratings put through his published formula, not his site's game
  predictions, which may add adjustments.
