# Pilot backtest, 2025-26

Snapshots every 14 days from 2025-11-10 to 2026-03-16; each predicts games until the next snapshot (the last runs through the title game). Scored on games with a closing spread. Margins in points (final score, OT included).

## Overall

|variant       | games| mae_model| mae_line| rmse_model| rmse_line|   bias|   ats| brier| logloss|
|:-------------|-----:|---------:|--------:|----------:|---------:|------:|-----:|-----:|-------:|
|lux_dynamic   |  5437|     9.047|    8.974|     11.497|    11.373| -0.170| 0.516| 0.182|   0.536|
|lux_static    |  5437|     9.050|    8.974|     11.499|    11.373| -0.164| 0.516| 0.182|   0.536|
|margin_static |  5437|     9.138|    8.974|     11.622|    11.373| -0.359| 0.506| 0.184|   0.542|
|shotq_static  |  5437|     9.074|    8.974|     11.536|    11.373| -0.338| 0.525| 0.183|   0.537|

## By period

|variant       |period  | games| mae_model| mae_line| rmse_model| rmse_line|   bias|   ats| brier| logloss|
|:-------------|:-------|-----:|---------:|--------:|----------:|---------:|------:|-----:|-----:|-------:|
|lux_dynamic   |Jan-Apr |  3313|     8.861|    8.803|     11.159|    11.028| -0.324| 0.511| 0.199|   0.579|
|lux_dynamic   |Nov-Dec |  2124|     9.337|    9.240|     12.006|    11.892|  0.070| 0.524| 0.155|   0.467|
|lux_static    |Jan-Apr |  3313|     8.872|    8.803|     11.169|    11.028| -0.313| 0.511| 0.199|   0.580|
|lux_static    |Nov-Dec |  2124|     9.327|    9.240|     11.997|    11.892|  0.069| 0.523| 0.155|   0.467|
|margin_static |Jan-Apr |  3313|     8.920|    8.803|     11.251|    11.028| -0.458| 0.503| 0.201|   0.584|
|margin_static |Nov-Dec |  2124|     9.478|    9.240|     12.177|    11.892| -0.204| 0.509| 0.159|   0.475|
|shotq_static  |Jan-Apr |  3313|     8.881|    8.803|     11.202|    11.028| -0.490| 0.529| 0.200|   0.582|
|shotq_static  |Nov-Dec |  2124|     9.375|    9.240|     12.039|    11.892| -0.100| 0.519| 0.156|   0.468|

## By snapshot

|variant       |snap       | mae_model| mae_line|   n|
|:-------------|:----------|---------:|--------:|---:|
|lux_dynamic   |2025-11-10 |      9.65|     9.19| 600|
|lux_dynamic   |2025-11-24 |      9.71|    10.08| 634|
|lux_dynamic   |2025-12-08 |      9.25|     8.95| 449|
|lux_dynamic   |2025-12-22 |      8.46|     8.40| 441|
|lux_dynamic   |2026-01-05 |      8.99|     8.98| 667|
|lux_dynamic   |2026-01-19 |      9.11|     8.93| 677|
|lux_dynamic   |2026-02-02 |      8.61|     8.52| 675|
|lux_dynamic   |2026-02-16 |      8.86|     8.88| 691|
|lux_dynamic   |2026-03-02 |      8.62|     8.61| 498|
|lux_dynamic   |2026-03-16 |      9.21|     9.12| 105|
|lux_static    |2025-11-10 |      9.65|     9.19| 600|
|lux_static    |2025-11-24 |      9.69|    10.08| 634|
|lux_static    |2025-12-08 |      9.24|     8.95| 449|
|lux_static    |2025-12-22 |      8.45|     8.40| 441|
|lux_static    |2026-01-05 |      8.98|     8.98| 667|
|lux_static    |2026-01-19 |      9.12|     8.93| 677|
|lux_static    |2026-02-02 |      8.61|     8.52| 675|
|lux_static    |2026-02-16 |      8.89|     8.88| 691|
|lux_static    |2026-03-02 |      8.66|     8.61| 498|
|lux_static    |2026-03-16 |      9.21|     9.12| 105|
|margin_static |2025-11-10 |      9.74|     9.19| 600|
|margin_static |2025-11-24 |      9.97|    10.08| 634|
|margin_static |2025-12-08 |      9.39|     8.95| 449|
|margin_static |2025-12-22 |      8.51|     8.40| 441|
|margin_static |2026-01-05 |      9.10|     8.98| 667|
|margin_static |2026-01-19 |      9.05|     8.93| 677|
|margin_static |2026-02-02 |      8.62|     8.52| 675|
|margin_static |2026-02-16 |      8.94|     8.88| 691|
|margin_static |2026-03-02 |      8.79|     8.61| 498|
|margin_static |2026-03-16 |      9.29|     9.12| 105|
|shotq_static  |2025-11-10 |      9.66|     9.19| 600|
|shotq_static  |2025-11-24 |      9.83|    10.08| 634|
|shotq_static  |2025-12-08 |      9.21|     8.95| 449|
|shotq_static  |2025-12-22 |      8.50|     8.40| 441|
|shotq_static  |2026-01-05 |      9.01|     8.98| 667|
|shotq_static  |2026-01-19 |      9.11|     8.93| 677|
|shotq_static  |2026-02-02 |      8.68|     8.52| 675|
|shotq_static  |2026-02-16 |      8.85|     8.88| 691|
|shotq_static  |2026-03-02 |      8.65|     8.61| 498|
|shotq_static  |2026-03-16 |      9.18|     9.12| 105|

## Convergence

|variant       | mean_secs| max_rhat| min_ess| divergences|
|:-------------|---------:|--------:|-------:|-----------:|
|lux_dynamic   |     59.08|     1.07|   68.80|           0|
|lux_static    |     25.26|     1.04|  173.33|           0|
|margin_static |     19.92|     1.02|  269.10|           1|
|shotq_static  |     20.84|     1.03|  186.57|           0|

37 of 40 fits miss a gate (R-hat <= 1.01, ESS >= 400, no divergences, E-BFMI > 0.2).
