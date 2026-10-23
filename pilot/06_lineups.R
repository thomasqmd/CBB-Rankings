# Pilot step 6: can 5-man lineups be rebuilt from ESPN substitution events?
# Start from box-score starters, apply subs in order, and count how often each team has exactly 5 on court.
source("R/01_ingest.R"); source("R/02_prep.R")
suppressMessages(library(dplyr))
con <- duck()
set.seed(1)
ids <- DBI::dbGetQuery(con, sprintf("select distinct game_id from %s", pq("pbp", 2026)))$game_id
ids <- sample(ids, 400)
idl <- paste(ids, collapse = ",")
ev <- DBI::dbGetQuery(con, sprintf("select game_id, game_play_number, team_id, athlete_id_1, type_text, lower(text) txt,
  case when period_number <= 2 then 2400 - start_game_seconds_remaining else 2400 + 300 * (period_number - 3) + (300 - start_game_seconds_remaining) end elapsed
  from %s where game_id in (%s) order by game_id, game_play_number", pq("pbp", 2026), idl))
pb <- DBI::dbGetQuery(con, sprintf("select game_id, team_id, athlete_id, starter, minutes from %s where game_id in (%s)", pq("player_box", 2026), idl))
DBI::dbDisconnect(con, shutdown = TRUE)

check_game <- function(gid) {
  e <- ev[ev$game_id == gid, ]; b <- pb[pb$game_id == gid, ]
  on <- split(b$athlete_id[b$starter %in% TRUE], b$team_id[b$starter %in% TRUE])
  if (length(on) != 2 || any(lengths(on) != 5)) return(data.frame(game_id = gid, ok_start = FALSE, share5 = NA, secs5 = NA))
  sizes <- matrix(NA_integer_, nrow(e), 2); tids <- names(on)
  for (k in seq_len(nrow(e))) {
    if (e$type_text[k] == "Substitution") {
      t <- as.character(e$team_id[k]); a <- e$athlete_id_1[k]
      if (grepl("subbing in", e$txt[k])) on[[t]] <- union(on[[t]], a) else on[[t]] <- setdiff(on[[t]], a)
    }
    sizes[k, ] <- lengths(on[tids])
  }
  # judge at non-substitution events (mid-batch states during a sub sequence are transient)
  keep <- e$type_text != "Substitution"
  dt <- c(diff(e$elapsed), 0)
  good <- rowSums(sizes == 5) == 2
  data.frame(game_id = gid, ok_start = TRUE, share5 = mean(good[keep]), secs5 = sum(dt[good]) / max(sum(dt), 1))
}
res <- bind_rows(lapply(ids, check_game))
out <- c(games = nrow(res), starters_ok = mean(res$ok_start), median_share5 = median(res$share5, na.rm = TRUE),
         games_95pct_clean = mean(res$share5 >= 0.95, na.rm = TRUE), time_clean = mean(res$secs5, na.rm = TRUE))
print(round(out, 3))
writeLines(c("# Lineup reconstruction test (400 random 2025-26 games)", "",
             "Starters from ESPN player box, substitutions applied in play order; a state is clean when both teams have exactly five on court.", "",
             paste0("- ", names(out), ": ", round(out, 3))), "pilot/out/06_lineups.md")
