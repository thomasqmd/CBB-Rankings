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

# Torvik's ratings as they stood after day `date` (a time-machine file dated D includes games played
# on D; records count non-D1 games). Walks back up to 3 days if a file is missing. Final dates
# never change, so a cached file is never refetched.
fetch_torvik_tm <- function(date) {
  dir.create(raw_path("torvik", "tm"), recursive = TRUE, showWarnings = FALSE)
  for (k in 0:3) {
    d <- format(as.Date(date) - k, "%Y%m%d")
    dest <- raw_path("torvik", "tm", sprintf("tm_%s.json.gz", d))
    if (file.exists(dest)) return(dest)
    Sys.sleep(0.5)
    if (torvik_get(sprintf("https://barttorvik.com/timemachine/team_results/%s_team_results.json.gz", d), dest)) return(dest)
  }
  NA_character_
}

read_torvik_tm <- function(f) {
  x <- jsonlite::fromJSON(gzcon(file(f, "rb")))
  data.frame(team = x[, 2], record = x[, 4], adj_o = as.numeric(x[, 5]), adj_d = as.numeric(x[, 7]), adj_t = as.numeric(x[, 45]))
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

# ---- Polls ------------------------------------------------------------------------

# CBBD rankings (AP Top 25, Coaches Poll; one call returns the whole season). Final seasons:
# fetched once. Live season: refetched once the cached copy is older than MIN_REFRESH_HOURS.
fetch_cbbd_rankings <- function(season, today = Sys.Date()) {
  dir.create(raw_path("cbbd"), recursive = TRUE, showWarnings = FALSE)
  dest <- raw_path("cbbd", sprintf("rankings_%d.json", season))
  if (!file.exists(dest) || (!season_final(season, today) && stale(dest))) writeLines(cbbd_get("rankings", list(season = season)), dest)
  dest
}

# CBBD team ids -> ESPN team ids, from the games both sources share (home with home, away with
# away; the rare swapped neutral-site game is outvoted)
cbbd_team_ids <- function(season, games) {
  g <- read_cbbd(season, "games")
  if (!length(g)) return(data.frame(cbbd_team_id = integer(), team_id = integer()))
  int <- function(f) vapply(g, \(x) as.integer(f(x) %||% NA_integer_), integer(1))
  cb <- data.frame(game_id = int(\(x) x$sourceId), cb_home = int(\(x) x$homeTeamId), cb_away = int(\(x) x$awayTeamId))
  m <- merge(cb, games[, c("game_id", "home_id", "away_id")], by = "game_id")
  pairs <- rbind(data.frame(cbbd_team_id = m$cb_home, team_id = m$home_id),
                 data.frame(cbbd_team_id = m$cb_away, team_id = m$away_id))
  n <- dplyr::count(stats::na.omit(pairs), cbbd_team_id, team_id)
  n <- n[order(n$cbbd_team_id, -n$n), ]
  n[!duplicated(n$cbbd_team_id), c("cbbd_team_id", "team_id")]
}

# One row per (poll, release, team). rank is NA for teams only receiving votes. CBBD has no
# release date for most polls before 2016-17; those are filled from the week: week 1 is the
# preseason poll (the day before opening night), week k >= 2 the Monday k - 2 weeks after the
# first Monday after opening night (exact for every dated release since 2016-17), postseason
# the day after the last game. `ids` is cbbd_team_ids() output.
cbbd_polls <- function(season, games, ids) {
  f <- raw_path("cbbd", sprintf("rankings_%d.json", season))
  x <- if (file.exists(f)) jsonlite::fromJSON(f) else list()
  if (!length(x) || !NROW(x)) {
    return(data.frame(poll = character(), poll_date = as.Date(character()), week = integer(), season_type = character(),
                      team_id = integer(), team = character(), rank = integer(), points = integer(), first_place = integer()))
  }
  opening <- min(games$game_date[games$season_type == "regular"])
  monday1 <- opening + 1:7
  monday1 <- monday1[format(monday1, "%u") == "1"]
  week_date <- ifelse(x$seasonType == "postseason", max(games$game_date) + 1,
                      ifelse(x$week <= 1, opening - 1, monday1 + 7 * (x$week - 2)))
  data.frame(
    poll = ifelse(grepl("^AP", x$pollType), "AP", ifelse(grepl("^Coaches", x$pollType), "Coaches", x$pollType)),
    poll_date = dplyr::coalesce(as.Date(substr(x$pollDate, 1, 10)), as.Date(week_date)),
    week = as.integer(x$week), season_type = x$seasonType,
    team_id = ids$team_id[match(x$teamId, ids$cbbd_team_id)], team = x$team,
    rank = as.integer(x$ranking), points = as.integer(x$points), first_place = as.integer(x$firstPlaceVotes)
  )
}

# ---- Conference champions -----------------------------------------------------------

# Conference tournament champions: the winner of each conference's tournament final (CBBD game
# notes "... - Final" / "... Championship"). A conference with no final on record (Ivy before
# 2016-17, the tournaments cancelled in 2020) has no row; its automatic bid falls back to the
# standings leader (wab_draws()). games: the season's games table (game_id, home_id, away_id).
cbbd_champions <- function(season, games) {
  g <- read_cbbd(season, "games")
  empty <- data.frame(conf = character(), game_date = as.Date(character()), team_id = integer(), notes = character())
  if (!length(g)) return(empty)
  chr <- function(f) vapply(g, \(x) as.character(f(x) %||% NA_character_), character(1))
  x <- data.frame(game_id = vapply(g, \(x) as.integer(x$sourceId %||% NA_integer_), integer(1)),
                  notes = chr(\(x) x$gameNotes), type = chr(\(x) x$gameType), st = chr(\(x) x$seasonType),
                  hc = chr(\(x) x$homeConference), ac = chr(\(x) x$awayConference),
                  conf_game = vapply(g, \(x) isTRUE(x$conferenceGame), logical(1)),
                  home_won = vapply(g, \(x) isTRUE(x$homeWinner), logical(1)),
                  played = vapply(g, \(x) !is.null(x$homeWinner) && !is.null(x$homePoints), logical(1)),
                  game_date = as.Date(substr(chr(\(x) x$startDate), 1, 10)))
  n <- tolower(x$notes)
  final <- grepl("(championship|final|title)( game)?$", n) & !grepl("semi|quarter|consolation|third|3rd", n)
  x <- x[x$type %in% "TRNMNT" & x$st %in% "regular" & (x$conf_game | x$hc %in% x$ac) & final %in% TRUE & x$played, ]
  if (!nrow(x)) return(empty)
  m <- merge(x, games[, c("game_id", "home_id", "away_id")], by = "game_id")
  out <- data.frame(conf = dplyr::coalesce(m$hc, m$ac), game_date = m$game_date,
                    team_id = ifelse(m$home_won, m$home_id, m$away_id), notes = m$notes)
  out <- out[order(out$conf, out$game_date, decreasing = TRUE), ]
  out[!duplicated(out$conf), ]
}
