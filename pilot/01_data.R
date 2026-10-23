# Pilot step 1: fetch (cached), build games + shot-quality signal for 2025 and 2026, audit coverage.
# The make model is fit on 2025 shots and applied to 2026 (out of sample); 2025 uses its own fit.
source("R/01_ingest.R"); source("R/02_prep.R")
suppressMessages(library(dplyr))

for (s in 2025:2026) { fetch_espn(s, c("schedule", "team_box", "pbp")); fetch_cbbd(s, if (s == 2026) c("games", "lines") else "games") }

plays <- lapply(c(`2025` = 2025, `2026` = 2026), \(s) annotate_plays(read_plays(s)))
shots <- lapply(plays, shot_table)
shots$`2025` <- prep_shots(shots$`2025`)
shots$`2026` <- prep_shots(shots$`2026`, dist_medians(shots$`2025`))
mm25 <- fit_make_model(shots$`2025`)

# Out-of-sample calibration of the make model by shot family (2026)
shots$`2026`$p <- predict(mm25, shots$`2026`, type = "response")
calib <- shots$`2026` |> group_by(family, three) |>
  summarise(n = n(), actual = mean(made), predicted = mean(p), .groups = "drop") |> arrange(desc(n))
dist_check <- with(shots$`2026`, c(share_dist = mean(!is.na(dist)), share_putback = mean(putback), share_transition = mean(transition)))
ll <- function(y, p) -mean(y * log(p) + (1 - y) * log(1 - p))
base <- shots$`2026` |> mutate(p0 = ifelse(three == 1, mean(shots$`2025`$made[shots$`2025`$three == 1]), mean(shots$`2025`$made[shots$`2025`$three == 0])))

games <- list()
for (s in c("2025", "2026")) {
  fts <- ft_rates_to_date(ft_table(plays[[s]]))
  xp <- game_xpts(shots[[s]], fts, live_table(plays[[s]]), mm25)
  games[[s]] <- add_eff(build_games(as.integer(s), "d1"), xp)
}
saveRDS(games, "data/derived/pilot_games.rds")
saveRDS(lapply(c(`2025` = 2025, `2026` = 2026), build_games, division = "nond1"), "data/derived/pilot_nd_games.rds")
saveRDS(list(make_model = mm25, calib = calib), "data/derived/pilot_make_model.rds")

g <- games$`2026`
sched_n <- nrow(DBI::dbGetQuery(d <- duck(), sprintf("select 1 from %s where status_type_completed", pq("schedule", 2026)))); DBI::dbDisconnect(d, shutdown = TRUE)
audit <- c(
  espn_completed_games = sched_n,
  d1_vs_d1_games = nrow(g),
  d1_teams = length(unique(c(g$home_id, g$away_id))),
  with_eff = sum(g$has_eff),
  with_spread = sum(!is.na(g$spread)),
  ot_games = sum(g$ot),
  neutral = sum(g$neutral),
  ncaa_games = sum(g$ncaa),
  mean_poss = round(mean(g$poss), 1),
  cor_eff_margin = round(cor(g$eff100[g$has_eff], g$margin100[g$has_eff]), 3),
  cor_lux_margin = round(cor(g$lux100[g$has_eff], g$margin100[g$has_eff]), 3),
  sd_margin100 = round(sd(g$margin100), 2),
  sd_eff100 = round(sd(g$eff100[g$has_eff]), 2),
  logloss_make_model = round(ll(base$made, base$p), 4),
  logloss_base_rate = round(ll(base$made, base$p0), 4)
)
print(audit); print(dist_check); print(as.data.frame(calib), digits = 3)
writeLines(c("# Pilot data audit (2025-26)", "", paste0("- ", names(audit), ": ", audit), "",
             paste0("- ", names(dist_check), ": ", round(dist_check, 3)), "",
             "## Make model calibration (fit on 2024-25, scored on 2025-26)", "",
             knitr::kable(calib, digits = 3)), "pilot/out/01_audit.md")
