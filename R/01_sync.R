# ==============================================================================
# Sync: raw files -> data/cbb.duckdb, one season at a time. Every table carries `season`, and a
# season is replaced whole. A final season that synced after it ended is never touched again.
#
#   games       every game with a D1 team (completed and scheduled), see build_games()
#   shots       field-goal attempts with shot-model features
#   free_throws free-throw attempts (shooter, made, live play or not)
#   game_live   share of regulation before garbage time
#   torvik_pre  Torvik's preseason ratings (adj_em = adjoe - adjde, per 100)
#   polls       AP and Coaches polls by release (rank NA = receiving votes), ESPN team ids
#   champions   conference tournament champions (conf, game_date of the final, team_id)
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
    DBI::dbAppendTable(con, table, df)
  } else {
    DBI::dbWriteTable(con, table, df)
  }
  invisible(nrow(df))
}

sync_season <- function(con, season, today = Sys.Date()) {
  message("sync ", season_label(season))
  files <- fetch_espn(season, c("schedule", "team_box", "pbp"))
  fetch_cbbd(season, today = today)
  games <- build_games(season)
  db_replace_season(con, "games", games, season)

  if (!is.na(files[["pbp"]])) {
    p <- annotate_plays(read_plays(season))
    p <- p[p$game_id %in% games$game_id, ]
    db_replace_season(con, "shots", shot_table(p), season)
    db_replace_season(con, "free_throws", ft_table(p), season)
    db_replace_season(con, "game_live", live_table(p), season)
    rm(p); gc()
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
  q <-function(sql) DBI::dbGetQuery(con, sprintf(sql, paste(seasons, collapse = ",")))
  fp <- q("SELECT season, COUNT(*) AS games, SUM(CASE WHEN played THEN 1 ELSE 0 END) AS played,
                  COUNT(spread) AS lines, MAX(CASE WHEN played THEN game_date END) AS last_played
           FROM games WHERE season IN (%s) GROUP BY season ORDER BY season")
  if (DBI::dbExistsTable(con, "shots")) fp <- merge(fp, q("SELECT season, COUNT(*) AS shots FROM shots WHERE season IN (%s) GROUP BY season"), all.x = TRUE)
  if (DBI::dbExistsTable(con, "torvik_pre")) fp <- merge(fp, q("SELECT season, COUNT(*) AS torvik_pre FROM torvik_pre WHERE season IN (%s) GROUP BY season"), all.x = TRUE)
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
    fetch_cbbd_rankings(s, today = today)
    db_replace_season(con, "polls", cbbd_polls(s, games[[as.character(s)]], ids), s)
  }
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
  out <- lapply(c(games = "games", shots = "shots", free_throws = "free_throws", game_live = "game_live",
                  torvik_pre = "torvik_pre"), \(t) read_table_season(con, t, season))
  out$season <- as.integer(season)
  out
}
