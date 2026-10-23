# ==============================================================================
# Ingest: raw files cached under data/raw/, never re-downloaded once a season is final.
#
#   ESPN bulk (sportsdataverse-data GitHub releases, no key): schedule, team box, play-by-play.
#     History and the daily refresh both come from here.
#   CBBD API (collegebasketballdata.com, CFBD_API_KEY, quota shared with CFB): games (ESPN id <->
#     CBBD id, conferences, period scores, seeds, tournament) and closing lines. Responses are
#     capped at 3,000 rows, so a season is fetched in date windows (4 calls per endpoint). In a
#     live season only the windows covering the last LIVE_LOOKBACK days are refetched, at most
#     once per MIN_REFRESH_HOURS.
#   Torvik (barttorvik.com, no key): preseason ratings (time machine, the day before opening
#     night) for the carry-over prior; season-end team results as a benchmark.
# ==============================================================================

`%||%` <- function(a, b) if (is.null(a)) b else a

ESPN_RELEASE <- "https://github.com/sportsdataverse/sportsdataverse-data/releases/download"
ESPN_FILES <- c(
  schedule   = "espn_mens_college_basketball_schedules/mbb_schedule_%d.parquet",
  team_box   = "espn_mens_college_basketball_team_boxscores/team_box_%d.parquet",
  player_box = "espn_mens_college_basketball_player_boxscores/player_box_%d.parquet",
  pbp        = "espn_mens_college_basketball_pbp/play_by_play_%d.parquet"
)
CBBD_URL <- "https://api.collegebasketballdata.com"
MIN_REFRESH_HOURS <- 20
LIVE_LOOKBACK <- 10

# Season s = the season ending in spring of year s (2026 = 2025-26)
current_cbb_season <- function(today = Sys.Date()) {
  y <- as.integer(format(today, "%Y"))
  if (as.integer(format(today, "%m")) >= 7) y + 1L else y
}
season_final <- function(s, today = Sys.Date()) today >= as.Date(sprintf("%d-05-01", s))
season_label <- function(s) sprintf("%d-%02d", s - 1, s %% 100)

raw_path <- function(...) file.path("data", "raw", ...)
stale <- function(f, hours = MIN_REFRESH_HOURS) {
  !file.exists(f) || difftime(Sys.time(), file.mtime(f), units = "hours") > hours
}

fetch_espn <- function(season, what = names(ESPN_FILES), live = !season_final(season)) {
  dir.create(raw_path("espn"), recursive = TRUE, showWarnings = FALSE)
  vapply(what, function(w) {
    dest <- raw_path("espn", sprintf("%s_%d.parquet", w, season))
    if (!file.exists(dest) || (live && stale(dest))) {
      tmp <- paste0(dest, ".part")
      ok <- tryCatch(suppressWarnings(utils::download.file(file.path(ESPN_RELEASE, sprintf(ESPN_FILES[[w]], season)), tmp,
                                                           mode = "wb", quiet = TRUE)) == 0, error = \(e) FALSE)
      # A live season may not have every file yet (no play-by-play before opening night)
      if (ok) file.rename(tmp, dest) else { unlink(tmp); if (!live) stop("ESPN ", w, " ", season, " not available") }
    }
    if (file.exists(dest)) dest else NA_character_
  }, character(1))
}

cbbd_get <- function(endpoint, query) {
  key <- Sys.getenv("CFBD_API_KEY")
  if (!nzchar(key)) stop("CFBD_API_KEY not set (the CFBD key also works for CBBD)")
  resp <- httr2::request(CBBD_URL) |>
    httr2::req_url_path_append(endpoint) |>
    httr2::req_url_query(!!!query) |>
    httr2::req_auth_bearer_token(key) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_perform()
  message(sprintf("CBBD %s %s: %s calls left this month", endpoint, paste(unlist(query), collapse = " "),
                  httr2::resp_header(resp, "x-calllimit-remaining")))
  httr2::resp_body_string(resp)
}

# Date windows sized well under the 3,000-row cap (2025-26: at most ~2,000 games per window)
cbbd_windows <- function(season) {
  b <- as.Date(sprintf(c("%d-10-01", "%d-12-01", "%d-01-15", "%d-02-15", "%d-05-01"), c(season - 1, season - 1, season, season, season)))
  data.frame(start = b[-length(b)], end = b[-1])
}

# One JSON file per (endpoint, season, window). Final seasons: fetched once. Live season:
# windows that have started are refetched when they overlap the last LIVE_LOOKBACK days and the
# cached copy is older than MIN_REFRESH_HOURS; future windows are fetched once (the schedule).
fetch_cbbd <- function(season, endpoint = c("games", "lines"), today = Sys.Date()) {
  dir.create(raw_path("cbbd"), recursive = TRUE, showWarnings = FALSE)
  live <- !season_final(season, today)
  w <- cbbd_windows(season)
  unlist(lapply(endpoint, function(ep) {
    have <- Sys.glob(raw_path("cbbd", sprintf("%s_%d_*.json", ep, season)))
    if (!live && length(have)) return(have)       # a final season cached under any window scheme
    vapply(seq_len(nrow(w)), function(i) {
      dest <- raw_path("cbbd", sprintf("%s_%d_%d.json", ep, season, i))
      recent <- live && w$start[i] <= today && w$end[i] >= today - LIVE_LOOKBACK
      if (!file.exists(dest) || (recent && stale(dest))) {
        txt <- cbbd_get(ep, list(season = season, startDateRange = format(w$start[i]),
                                 endDateRange = format(w$end[i])))
        n <- length(jsonlite::fromJSON(txt, simplifyVector = FALSE))
        if (n >= 3000) stop(sprintf("%s %d window %d hit the 3,000-row cap; split it", ep, season, i))
        writeLines(txt, dest)
      }
      dest
    }, character(1))
  }))
}

torvik_get <- function(url, dest) {
  r <- httr2::request(url) |> httr2::req_user_agent("Mozilla/5.0") |>
    httr2::req_error(is_error = \(r) FALSE) |> httr2::req_perform(path = dest)
  if (httr2::resp_status(r) >= 400) { unlink(dest); return(FALSE) }
  TRUE
}

# Torvik's preseason ratings: the time-machine snapshot the day before opening night (walking
# back a few days if that day is missing); before opening night his current ratings are the
# preseason ones (team_results.csv, every record 0-0). Team results also serve as a benchmark.
fetch_torvik <- function(season, opening_night, today = Sys.Date()) {
  live <- !season_final(season, today)
  dir.create(raw_path("torvik"), recursive = TRUE, showWarnings = FALSE)
  pre <- raw_path("torvik", sprintf("preseason_%d.json.gz", season))
  if (!file.exists(pre) && opening_night - 1 <= today) {
    for (k in 1:7) {
      d <- format(opening_night - k, "%Y%m%d")
      if (torvik_get(sprintf("https://barttorvik.com/timemachine/team_results/%s_team_results.json.gz", d), pre)) break
    }
  }
  res <- raw_path("torvik", sprintf("team_results_%d.csv", season))
  if (!file.exists(res) || (live && stale(res))) torvik_get(sprintf("https://barttorvik.com/%d_team_results.csv", season), res)
  c(preseason = if (file.exists(pre)) pre else NA_character_, team_results = if (file.exists(res)) res else NA_character_)
}

# Torvik's time-machine files have no header; columns follow team_results.csv (team 2, conf 3,
# adjoe 5, adjde 7). The csv is used before opening night, when every record is 0-0.
read_torvik_preseason <- function(files) {
  empty <- data.frame(team = character(), conf = character(), adj_em = numeric())
  if (!is.na(files[["preseason"]])) {
    x <- jsonlite::fromJSON(gzcon(file(files[["preseason"]], "rb")))
    return(data.frame(team = x[, 2], conf = x[, 3], adj_em = as.numeric(x[, 5]) - as.numeric(x[, 7])))
  }
  if (is.na(files[["team_results"]])) return(empty)
  x <- utils::read.csv(files[["team_results"]], check.names = FALSE)
  if (!all(x$record %in% c("0-0", ""))) return(empty)       # season under way: not a preseason rating
  data.frame(team = x$team, conf = x$conf, adj_em = x$adjoe - x$adjde)
}

# ---- CBBD readers --------------------------------------------------------------

read_cbbd <- function(season, endpoint) {
  files <- sort(Sys.glob(raw_path("cbbd", sprintf("%s_%d_*.json", endpoint, season))))
  rows <- unlist(lapply(files, \(f) jsonlite::fromJSON(f, simplifyVector = FALSE)), recursive = FALSE)
  if (!length(rows)) return(list())
  id <- vapply(rows, \(x) as.integer(x$id %||% x$gameId), integer(1))
  rows[!duplicated(id)]                     # windows share their boundary date
}

# CBBD games -> one row per game: ESPN id, conferences, regulation scores, seeds, tournament
cbbd_games <- function(season) {
  g <- read_cbbd(season, "games")
  reg <- function(p) if (length(p) >= 2) sum(unlist(p[1:2])) else NA_real_
  chr <- function(f) vapply(g, \(x) as.character(f(x) %||% NA_character_), character(1))
  int <- function(f) vapply(g, \(x) as.integer(f(x) %||% NA_integer_), integer(1))
  data.frame(
    cbbd_id = int(\(x) x$id), game_id = int(\(x) x$sourceId),
    season_type = chr(\(x) x$seasonType), tournament = chr(\(x) x$tournament), game_type = chr(\(x) x$gameType),
    home_conf = chr(\(x) x$homeConference), away_conf = chr(\(x) x$awayConference),
    cbbd_neutral = vapply(g, \(x) isTRUE(x$neutralSite), logical(1)),
    home_seed = int(\(x) x$homeSeed), away_seed = int(\(x) x$awaySeed),
    n_periods = vapply(g, \(x) length(x$homePeriodPoints), integer(1)),
    home_reg = vapply(g, \(x) reg(x$homePeriodPoints), numeric(1)),
    away_reg = vapply(g, \(x) reg(x$awayPeriodPoints), numeric(1))
  )
}

# Closing spread (home perspective, negative = home favoured), median over providers
cbbd_lines <- function(season) {
  l <- read_cbbd(season, "lines")
  if (!length(l)) return(data.frame(cbbd_id = integer(), spread = numeric(), total_line = numeric()))
  med <- function(v) { v <- unlist(v); if (length(v)) stats::median(v) else NA_real_ }
  data.frame(
    cbbd_id = vapply(l, \(x) x$gameId, integer(1)),
    spread = vapply(l, \(x) med(lapply(x$lines, `[[`, "spread")), numeric(1)),
    total_line = vapply(l, \(x) med(lapply(x$lines, `[[`, "overUnder")), numeric(1))
  )
}

# ---- Team names ---------------------------------------------------------------------

name_key <- function(x) {
  x <- tolower(x)
  x <- gsub("\\bst\\.?$|\\bst\\.?(?= )", "state", x, perl = TRUE)
  x <- gsub("&", " and ", x)
  gsub("\\s+", " ", trimws(gsub("[^a-z ]", " ", x)))
}

# Torvik team names -> ESPN team ids: normalised names, then data/torvik_names.csv for the rest
# (columns torvik, espn_team_id). Returns the rows of `torvik` that matched, with team_id.
torvik_team_ids <- function(torvik, teams, overrides = "data/torvik_names.csv") {
  ov <- if (file.exists(overrides)) utils::read.csv(overrides, stringsAsFactors = FALSE) else data.frame(torvik = character(), espn_team_id = integer())
  id <- teams$team_id[match(name_key(torvik$team), name_key(teams$team))]
  manual <- ov$espn_team_id[match(torvik$team, ov$torvik)]
  torvik$team_id <- dplyr::coalesce(as.integer(manual), id)
  torvik[!is.na(torvik$team_id) & torvik$team_id %in% teams$team_id, ]
}
