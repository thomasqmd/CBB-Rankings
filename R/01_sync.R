# ==============================================================================
# Sync: raw files -> data/cbb.duckdb, one season at a time. Every table carries `season`, and a
# season is replaced whole. A final season that synced after it ended is never touched again.
#
#   games       every game with a D1 team (completed and scheduled), see build_games()
#   d1_teams    ESPN's D1 membership: team, conference (CBBD names), NCAA-tournament eligibility
#   shots       field-goal attempts with shot-model features
#   free_throws free-throw attempts (shooter, made, live play or not)
#   game_live   share of regulation before garbage time
#   torvik_pre  Torvik's preseason ratings (adj_em = adjoe - adjde, per 100)
#   polls       AP and Coaches polls by release (rank NA = receiving votes), ESPN team ids
#   champions   conference tournament champions (conf, game_date of the final, team_id)
#   player_box  player box scores, every game with a D1 team (starter, minutes, did_not_play)
#   rosters     ESPN season rosters (2024-25 on: class, height, weight, hometown)
#   substitutions  players in and out, from play-by-play (part of 2024-25, then every game)
#   injuries    ESPN's daily injury report, one row per day archived and player listed
#   sync_meta   season, synced_at, final, prep_version (PREP_VERSION when synced)
# ==============================================================================

db_connect <- function(db_path = "data/cbb.duckdb", read_only = FALSE) {
  dir.create(dirname(db_path), recursive = TRUE, showWarnings = FALSE)
  DBI::dbConnect(duckdb::duckdb(dbdir = db_path, read_only = read_only, shared_home = FALSE))
}

db_replace_season <- function(con, table, df, season) {
  df$season <- rep(as.integer(season), nrow(df))
  if (DBI::dbExistsTable(con, table)) {
    DBI::dbExecute(con, sprintf("DELETE FROM %s WHERE season = %d", table, as.integer(season)))
    old <- DBI::dbListFields(con, table)
    if (setequal(old, names(df))) {
      DBI::dbAppendTable(con, table, df[old])
    } else {
      # columns changed (a new PREP_VERSION): rewrite the table, other seasons' rows padded with NA
      rest <- DBI::dbReadTable(con, table)
      DBI::dbWriteTable(con, table, dplyr::bind_rows(rest[intersect(names(rest), names(df))], df), overwrite = TRUE)
    }
  } else {
    DBI::dbWriteTable(con, table, df)
  }
  invisible(nrow(df))
}

sync_season <- function(con, season, today = Sys.Date()) {
  message("sync ", season_label(season))
  files <- fetch_espn(season, c("schedule", "team_box", "player_box", "pbp", if (season >= ROSTERS_FROM) "rosters"))
  fetch_cbbd(season, today = today)
  games <- build_games(season)
  gt <- team_conferences(games)
  d1 <- d1_teams_table(season, fetch_espn_d1(season, today), gt[, c("team_id", "team")], gt)
  nm <- rbind(data.frame(team_id = games$home_id, team = games$home), data.frame(team_id = games$away_id, team = games$away))
  d1$team <- dplyr::coalesce(d1$team, nm$team[match(d1$team_id, nm$team_id)])
  if (anyNA(d1$team)) d1$team[is.na(d1$team)] <- espn_team_name(season, d1$team_id[is.na(d1$team)])
  db_replace_season(con, "d1_teams", d1, season)
  db_replace_season(con, "games", conf_from_d1(games, d1), season)   # conferences by team, not by CBBD record

  if (!is.na(files[["player_box"]])) db_replace_season(con, "player_box", player_box_table(season, games$game_id), season)
  if (!is.na(files["rosters"])) db_replace_season(con, "rosters", rosters_table(season), season)
  if (!is.na(files[["pbp"]])) {
    p <- annotate_plays(read_plays(season))
    p <- p[p$game_id %in% games$game_id, ]
    db_replace_season(con, "shots", shot_table(p), season)
    db_replace_season(con, "free_throws", ft_table(p), season)
    db_replace_season(con, "game_live", live_table(p), season)
    rm(p); gc()
    subs <- read_subs(season)
    db_replace_season(con, "substitutions", subs[subs$game_id %in% games$game_id, ], season)
  }

  opening <- suppressWarnings(min(games$game_date[games$season_type == "regular"], na.rm = TRUE))
  if (is.finite(opening)) {
    tv <- fetch_torvik(season, opening, today = today)
    db_replace_season(con, "torvik_pre", read_torvik_preseason(tv), season)
  }
  db_replace_season(con, "sync_meta", data.frame(synced_at = Sys.time(), final = season_final(season, today),
                                                 prep_version = PREP_VERSION), season)
}

# Syncs every season that is not final-and-synced; returns a per-season fingerprint so downstream
# targets rerun only when a season's data changed
sync_all <- function(seasons, db_path = "data/cbb.duckdb", today = Sys.Date()) {
  con <- db_connect(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  meta <- if (DBI::dbExistsTable(con, "sync_meta")) DBI::dbReadTable(con, "sync_meta") else data.frame(season = integer(), final = logical())
  if (is.null(meta$prep_version)) meta$prep_version <- rep(0L, nrow(meta))
  for (s in seasons) {
    if (any(meta$season == s & meta$final & meta$prep_version == PREP_VERSION)) next
    sync_season(con, s, today = today)
  }
  sync_polls(con, seasons, today = today)     # left out of the fingerprint: these feed only polls_<s>
  sync_champions(con, seasons)                # and champs_<s>
  if (!season_final(max(seasons), today)) sync_injuries(con, today)
  q <-function(sql) DBI::dbGetQuery(con, sprintf(sql, paste(seasons, collapse = ",")))
  fp <- q("SELECT season, COUNT(*) AS games, SUM(CASE WHEN played THEN 1 ELSE 0 END) AS played,
                  COUNT(spread) AS lines, MAX(CASE WHEN played THEN game_date END) AS last_played
           FROM games WHERE season IN (%s) GROUP BY season ORDER BY season")
  if (DBI::dbExistsTable(con, "shots")) fp <- merge(fp, q("SELECT season, COUNT(*) AS shots FROM shots WHERE season IN (%s) GROUP BY season"), all.x = TRUE)
  if (DBI::dbExistsTable(con, "d1_teams")) fp <- merge(fp, q("SELECT season, COUNT(*) AS d1_teams, SUM(CASE WHEN eligible THEN 0 ELSE 1 END) AS ineligible FROM d1_teams WHERE season IN (%s) GROUP BY season"), all.x = TRUE)
  if (DBI::dbExistsTable(con, "torvik_pre")) fp <- merge(fp, q("SELECT season, COUNT(*) AS torvik_pre FROM torvik_pre WHERE season IN (%s) GROUP BY season"), all.x = TRUE)
  # when each season was last written: a re-sync (a new PREP_VERSION) can change values without
  # changing a count, and data_<s> must reread it (an unchanged read still skips everything after)
  fp <- merge(fp, q("SELECT season, synced_at, prep_version FROM sync_meta WHERE season IN (%s)"), all.x = TRUE)
  fp
}

# Polls for every season, rewritten from the cached rankings files (a final season makes one
# request ever; the live season refreshes with the other live files). CBBD team ids are stable,
# so the crosswalk is pooled over seasons, the latest mapping first (a new season has few games).
sync_polls <- function(con, seasons, today = Sys.Date()) {
  games <- lapply(setNames(seasons, seasons), \(s) DBI::dbGetQuery(con, sprintf(
    "SELECT game_id, game_date, season_type, home_id, away_id FROM games WHERE season = %d", as.integer(s))))
  ids <- do.call(rbind, lapply(rev(seasons), \(s) cbbd_team_ids(s, games[[as.character(s)]])))
  ids <- ids[!duplicated(ids$cbbd_team_id), ]
  for (s in seasons) {
    if (season_final(s, today)) {
      fetch_cbbd_rankings(s, today = today)
      db_replace_season(con, "polls", cbbd_polls(s, games[[as.character(s)]], ids), s)
    } else {
      fetch_espn_rankings(today)
      p <- read_espn_rankings(Sys.glob(raw_path("espn", "rankings", "rankings_*.json")), s)
      if (!is.null(p)) db_replace_season(con, "polls", p, s)
    }
  }
}

# Today's injury report archived, then the injuries table rebuilt from every archived day (the
# poller, scripts/poll_injuries.sh, archives the days no build runs)
sync_injuries <- function(con, today = Sys.Date()) {
  fetch_espn_injuries(today)
  files <- sort(Sys.glob(raw_path("espn", "injuries", "injuries_*.json")))
  DBI::dbWriteTable(con, "injuries", read_espn_injuries(files), overwrite = TRUE)
}

# Conference champions for every season, from the cached CBBD games files (no requests)
sync_champions <- function(con, seasons) {
  for (s in seasons) {
    games <- DBI::dbGetQuery(con, sprintf("SELECT game_id, home_id, away_id FROM games WHERE season = %d", as.integer(s)))
    db_replace_season(con, "champions", cbbd_champions(s, games), s)
  }
}

read_champions <- function(seasons, db_path = "data/cbb.duckdb") {
  con <- db_connect(db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  if (!DBI::dbExistsTable(con, "champions")) return(NULL)
  DBI::dbGetQuery(con, sprintf("SELECT * FROM champions WHERE season IN (%s) ORDER BY season, conf", paste(seasons, collapse = ",")))
}

read_polls <- function(seasons, db_path = "data/cbb.duckdb") {
  con <- db_connect(db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  if (!DBI::dbExistsTable(con, "polls")) return(NULL)
  DBI::dbGetQuery(con, sprintf("SELECT * FROM polls WHERE season IN (%s) ORDER BY season, poll, poll_date, rank",
                               paste(seasons, collapse = ",")))
}

read_table_season <- function(con, table, season) {
  if (!DBI::dbExistsTable(con, table)) return(NULL)
  DBI::dbGetQuery(con, sprintf("SELECT * FROM %s WHERE season = %d", table, as.integer(season)))
}

# Everything a season's model targets need
read_season <- function(season, db_path = "data/cbb.duckdb") {
  con <- db_connect(db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- lapply(c(games = "games", d1_teams = "d1_teams", shots = "shots", free_throws = "free_throws",
                  game_live = "game_live", torvik_pre = "torvik_pre"), \(t) read_table_season(con, t, season))
  out$player_box <- if (DBI::dbExistsTable(con, "player_box"))
    DBI::dbGetQuery(con, sprintf("SELECT game_id, team_id, athlete_id, did_not_play, minutes FROM player_box WHERE season = %d", as.integer(season)))
  out$season <- as.integer(season)
  out
}
