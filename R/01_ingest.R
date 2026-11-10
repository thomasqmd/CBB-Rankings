# ==============================================================================
# Ingest: raw files cached under data/raw/, never re-downloaded once a season is final.
#
#   ESPN bulk (sportsdataverse-data GitHub releases, no key): schedule, team box, play-by-play.
#     History and the daily refresh both come from here.
#   CBBD API (collegebasketballdata.com, CFBD_API_KEY, quota shared with CFB): games (ESPN id <->
#     CBBD id, conferences, period scores, seeds, tournament) and closing lines. Responses are
#     capped at 3,000 rows, so a season is fetched in date windows (4 calls per endpoint). In a
#     live season each window is fetched once (the schedule); after that one call per endpoint, at
#     most once per MIN_REFRESH_HOURS, fetches the last LIVE_LOOKBACK days into a dated file that
#     takes precedence over the windows (2 calls a day).
#   Torvik (barttorvik.com, no key): preseason ratings (time machine, the day before opening
#     night) for the carry-over prior; season-end team results as a benchmark.
#   ESPN APIs (no key): D1 conference membership by season (core API), box scores of the few
#     completed games missing from the bulk files (summary API), the daily injury report, and the
#     live season's AP and Coaches polls (archived daily; CBBD's polls once a season is final).
# ==============================================================================

`%||%` <- function(a, b) if (is.null(a)) b else a

ESPN_RELEASE <- "https://github.com/sportsdataverse/sportsdataverse-data/releases/download"
ESPN_FILES <- c(
  schedule   = "espn_mens_college_basketball_schedules/mbb_schedule_%d.parquet",
  team_box   = "espn_mens_college_basketball_team_boxscores/team_box_%d.parquet",
  player_box = "espn_mens_college_basketball_player_boxscores/player_box_%d.parquet",
  pbp        = "espn_mens_college_basketball_pbp/play_by_play_%d.parquet",
  rosters    = "espn_mens_college_basketball_rosters/rosters_%d.parquet"     # 2025 on only
)
ROSTERS_FROM <- 2025L
ESPN_CORE <- "https://sports.core.api.espn.com/v2/sports/basketball/leagues/mens-college-basketball"
ESPN_SITE <- "https://site.api.espn.com/apis/site/v2/sports/basketball/mens-college-basketball"
CBBD_URL <- "https://api.collegebasketballdata.com"
MIN_REFRESH_HOURS <- 8   # an evening build by hand still leaves the 07:00 run a fresh fetch
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
  line <- sprintf("CBBD %s %s: %s calls left this month", endpoint, paste(unlist(query), collapse = " "),
                  httr2::resp_header(resp, "x-calllimit-remaining"))
  message(line)
  # every call is logged, so scripts/daily_build.sh can count a build's calls (the quota is shared with CFBD)
  try(cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S "), line, "\n", sep = "", file = "logs/cbbd_calls.log", append = TRUE), silent = TRUE)
  httr2::resp_body_string(resp)
}

# Date windows sized well under the 3,000-row cap (2025-26: at most ~2,000 games per window)
cbbd_windows <- function(season) {
  b <- as.Date(sprintf(c("%d-10-01", "%d-12-01", "%d-01-15", "%d-02-15", "%d-05-01"), c(season - 1, season - 1, season, season, season)))
  data.frame(start = b[-length(b)], end = b[-1])
}

# One JSON file per (endpoint, season, window), fetched once. Live season: once the season has
# started, one call per endpoint (when the newest recent file is older than MIN_REFRESH_HOURS)
# fetches the last LIVE_LOOKBACK days into <ep>_<s>_rYYYYMMDD.json; read_cbbd() takes each game
# from the newest file that has it.
fetch_cbbd <- function(season, endpoint = c("games", "lines"), today = Sys.Date()) {
  dir.create(raw_path("cbbd"), recursive = TRUE, showWarnings = FALSE)
  live <- !season_final(season, today)
  w <- cbbd_windows(season)
  get <- function(ep, from, to) {
    txt <- cbbd_get(ep, list(season = season, startDateRange = format(from), endDateRange = format(to)))
    if (length(jsonlite::fromJSON(txt, simplifyVector = FALSE)) >= 3000) stop(sprintf("%s %d %s to %s hit the 3,000-row cap; split it", ep, season, from, to))
    txt
  }
  unlist(lapply(endpoint, function(ep) {
    have <- Sys.glob(raw_path("cbbd", sprintf("%s_%d_*.json", ep, season)))
    if (!live && length(have)) return(have)       # a final season cached under any window scheme
    win <- vapply(seq_len(nrow(w)), function(i) {
      dest <- raw_path("cbbd", sprintf("%s_%d_%d.json", ep, season, i))
      if (!file.exists(dest)) writeLines(get(ep, w$start[i], w$end[i]), dest)
      dest
    }, character(1))
    rec <- sort(Sys.glob(raw_path("cbbd", sprintf("%s_%d_r*.json", ep, season))))
    if (live && today > w$start[1] && (!length(rec) || stale(utils::tail(rec, 1)))) {
      dest <- raw_path("cbbd", sprintf("%s_%d_r%s.json", ep, season, format(today, "%Y%m%d")))
      writeLines(get(ep, today - LIVE_LOOKBACK, today + 1), dest)
      rec <- c(rec, dest)
    }
    c(rec, win)
  }))
}

torvik_get <- function(url, dest) {
  r <- httr2::request(url) |> httr2::req_user_agent("Mozilla/5.0") |>
    httr2::req_error(is_error = \(r) FALSE) |> httr2::req_perform(path = dest)
  if (httr2::resp_status(r) >= 400) { unlink(dest); return(FALSE) }
  # A missing file can come back as a 200 HTML redirect. Time-machine files arrive as plain JSON
  # despite the .gz name (gzcon() reads both), so data starts with gzip's magic byte or "["
  if (grepl("\\.json\\.gz$", url) && !(readBin(dest, "raw", 1L) %in% as.raw(c(0x1f, 0x5b)))) { unlink(dest); return(FALSE) }
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
    if (as.Date(date) - k > Sys.Date()) next          # no file for a day that hasn't happened
    d <- format(as.Date(date) - k, "%Y%m%d")
    dest <- raw_path("torvik", "tm", sprintf("tm_%s.json.gz", d))
    if (file.exists(dest)) return(dest)
    Sys.sleep(0.5)
    if (torvik_get(sprintf("https://barttorvik.com/timemachine/team_results/%s_team_results.json.gz", d), dest)) return(dest)
  }
  NA_character_
}

read_torvik_tm <- function(f) {
  con <- gzcon(file(f, "rb"))
  on.exit(close(con))                     # fromJSON leaves a connection open; a season's snapshots would exhaust R's 128
  x <- jsonlite::fromJSON(con)
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
  files <- Sys.glob(raw_path("cbbd", sprintf("%s_%d_*.json", endpoint, season)))
  rec <- grepl("_r[0-9]{8}\\.json$", files)
  files <- c(sort(files[rec], decreasing = TRUE), sort(files[!rec]))     # newest recent file first
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
    cbbd_id = int(\(x) x$id), game_id = int(\(x) x$sourceId), cbbd_status = chr(\(x) x$status),
    season_type = chr(\(x) x$seasonType), tournament = chr(\(x) x$tournament), game_type = chr(\(x) x$gameType),
    home_conf = chr(\(x) x$homeConference), away_conf = chr(\(x) x$awayConference),
    cb_home_id = int(\(x) x$homeTeamId), cb_away_id = int(\(x) x$awayTeamId),
    cb_home_pts = int(\(x) x$homePoints), cb_away_pts = int(\(x) x$awayPoints),
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
  if (!length(l)) return(data.frame(cbbd_id = integer(), line_home_id = integer(), spread = numeric(), total_line = numeric()))
  med <- function(v) { v <- unlist(v); if (length(v)) stats::median(v) else NA_real_ }
  data.frame(
    cbbd_id = vapply(l, \(x) x$gameId, integer(1)),
    line_home_id = vapply(l, \(x) as.integer(x$homeTeamId %||% NA_integer_), integer(1)),
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

# CBBD rankings (AP Top 25, Coaches Poll; one call returns the whole season), for final seasons
# only: fetched once after the season ends (a copy from before then is replaced once). The live
# season's polls come from ESPN (fetch_espn_rankings()).
fetch_cbbd_rankings <- function(season, today = Sys.Date()) {
  dir.create(raw_path("cbbd"), recursive = TRUE, showWarnings = FALSE)
  dest <- raw_path("cbbd", sprintf("rankings_%d.json", season))
  end <- as.Date(sprintf("%d-05-01", season))
  if (season_final(season, today) && (!file.exists(dest) || as.Date(file.mtime(dest)) < end)) writeLines(cbbd_get("rankings", list(season = season)), dest)
  dest
}

# ESPN's current AP and Coaches polls, archived once a day (data/raw/espn/rankings/)
fetch_espn_rankings <- function(today = Sys.Date()) {
  dir.create(raw_path("espn", "rankings"), recursive = TRUE, showWarnings = FALSE)
  dest <- raw_path("espn", "rankings", sprintf("rankings_%s.json", format(today, "%Y%m%d")))
  if (!file.exists(dest)) {
    ok <- tryCatch({ utils::download.file(sprintf("%s/rankings", ESPN_SITE), dest, quiet = TRUE); TRUE }, error = \(e) FALSE)
    if (!ok) unlink(dest)
  }
  if (file.exists(dest)) dest else NA_character_
}

# Archived ESPN polls for a season -> the polls table's columns (one row per poll, release, team;
# rank NA = receiving votes); each release from the newest archive that has it
read_espn_rankings <- function(files, season) {
  rows <- lapply(sort(files, decreasing = TRUE), function(f) {
    x <- jsonlite::fromJSON(f, simplifyVector = FALSE)
    do.call(rbind, lapply(x$rankings, function(r) {
      if (!identical(as.integer(r$season$year), as.integer(season))) return(NULL)
      poll <- if (identical(r$type, "ap")) "AP" else if (identical(r$type, "usa")) "Coaches" else r$name
      tm <- c(r$ranks, r$others)
      if (!length(tm)) return(NULL)
      data.frame(poll = poll, poll_date = as.Date(substr(r$date, 1, 10)), week = as.integer(r$occurrence$number),
                 season_type = if (isTRUE(r$occurrence$last)) "postseason" else "regular",
                 team_id = vapply(tm, \(t) as.integer(t$team$id), integer(1)), team = vapply(tm, \(t) t$team$location %||% NA_character_, character(1)),
                 rank = vapply(tm, \(t) if (isTRUE(t$current > 0)) as.integer(t$current) else NA_integer_, integer(1)),
                 points = vapply(tm, \(t) as.integer(t$points %||% NA), integer(1)),
                 first_place = vapply(tm, \(t) as.integer(t$firstPlaceVotes %||% NA), integer(1)))
    }))
  })
  out <- do.call(rbind, rows)
  if (is.null(out)) return(NULL)
  key <- paste(out$poll, out$week, out$season_type)
  # every row of the newest archive per release
  src <- rep(seq_along(rows), vapply(rows, \(r) if (is.null(r)) 0L else nrow(r), integer(1)))
  best <- tapply(src, key, min)
  out[src == best[key], ]
}

# CBBD team ids -> ESPN team ids, from the games both sources share (home with home, away with
# away; swapped games are outvoted)
cbbd_team_ids <- function(season, games) {
  g <- read_cbbd(season, "games")
  if (!length(g)) return(data.frame(cbbd_team_id = integer(), team_id = integer()))
  int <- function(f) vapply(g, \(x) as.integer(f(x) %||% NA_integer_), integer(1))
  cb <- data.frame(game_id = int(\(x) x$sourceId), cb_home = int(\(x) x$homeTeamId), cb_away = int(\(x) x$awayTeamId))
  m <- merge(cb, games[, c("game_id", "home_id", "away_id")], by = "game_id")
  pairs <- rbind(data.frame(cbbd_team_id = m$cb_home, team_id = m$home_id),
                 data.frame(cbbd_team_id = m$cb_away, team_id = m$away_id))
  n <- dplyr::count(stats::na.omit(pairs), cbbd_team_id, team_id)
  # one to one, the most votes first: a non-D1 team whose only game is swapped would otherwise
  # take its D1 opponent's id
  n <- n[order(-n$n, n$cbbd_team_id), ]
  n <- n[!duplicated(n$cbbd_team_id), ]
  n <- n[!duplicated(n$team_id), ]
  n[order(n$cbbd_team_id), c("cbbd_team_id", "team_id")]
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
                  ch = vapply(g, \(x) as.integer(x$homeTeamId %||% NA_integer_), integer(1)),
                  ca = vapply(g, \(x) as.integer(x$awayTeamId %||% NA_integer_), integer(1)),
                  conf_game = vapply(g, \(x) isTRUE(x$conferenceGame), logical(1)),
                  home_won = vapply(g, \(x) isTRUE(x$homeWinner), logical(1)),
                  played = vapply(g, \(x) !is.null(x$homeWinner) && !is.null(x$homePoints), logical(1)),
                  game_date = as.Date(substr(chr(\(x) x$startDate), 1, 10)))
  n <- tolower(x$notes)
  final <- grepl("(championship|final|title)( game)?$", n) & !grepl("semi|quarter|consolation|third|3rd", n)
  x <- x[x$type %in% "TRNMNT" & x$st %in% "regular" & (x$conf_game | x$hc %in% x$ac) & final %in% TRUE & x$played, ]
  if (!nrow(x)) return(empty)
  m <- merge(x, games[, c("game_id", "home_id", "away_id")], by = "game_id")
  # the winner by team, not by side (CBBD's home team is not always ESPN's)
  ids <- cbbd_team_ids(season, games)
  won <- ids$team_id[match(ifelse(m$home_won, m$ch, m$ca), ids$cbbd_team_id)]
  won[!is.na(won) & won != m$home_id & won != m$away_id] <- NA
  out <- data.frame(conf = dplyr::coalesce(m$hc, m$ac), game_date = m$game_date,
                    team_id = dplyr::coalesce(won, ifelse(m$home_won, m$home_id, m$away_id)), notes = m$notes)
  out <- out[order(out$conf, out$game_date, decreasing = TRUE), ]
  out[!duplicated(out$conf), ]
}

# ---- D1 membership ----------------------------------------------------------------

espn_json <- function(url) jsonlite::fromJSON(sub("^http:", "https:", url), simplifyVector = FALSE)

# D1 conferences and their members for a season (ESPN core API, group 50 = Division I; one request
# per conference). Final seasons are fetched once; the live season is refreshed when stale.
fetch_espn_d1 <- function(season, today = Sys.Date()) {
  dir.create(raw_path("espn"), recursive = TRUE, showWarnings = FALSE)
  dest <- raw_path("espn", sprintf("d1_teams_%d.json", season))
  if (file.exists(dest) && (season_final(season, today) || !stale(dest))) return(dest)
  confs <- espn_json(sprintf("%s/seasons/%d/types/2/groups/50/children?limit=100", ESPN_CORE, season))$items
  out <- do.call(rbind, lapply(confs, function(ref) {
    g <- espn_json(ref[["$ref"]])
    t <- espn_json(paste0(sub("\\?.*$", "", g$teams[["$ref"]]), "?limit=100"))$items
    data.frame(espn_conf_id = as.integer(g$id), espn_conf = g$shortName %||% g$name,
               team_id = vapply(t, \(i) as.integer(sub(".*/teams/([0-9]+).*", "\\1", i[["$ref"]])), integer(1)))
  }))
  if (is.null(out) || !nrow(out)) stop("ESPN lists no D1 teams for ", season_label(season))
  jsonlite::write_json(out, dest)
  dest
}

# Teams moving up to D1 are members (they play D1 schedules and count as D1 opponents) but cannot
# play in the NCAA tournament until their reclassification ends: data/d1_transitions.csv lists
# first_d1 and first_eligible seasons for every transition that overlaps 2014 on.
read_transitions <- function(path = "data/d1_transitions.csv") {
  if (!file.exists(path)) return(data.frame(team_id = integer(), first_d1 = integer(), first_eligible = integer()))
  utils::read.csv(path, stringsAsFactors = FALSE)
}

# A season's D1 teams: ESPN's membership with CBBD's conference names (each ESPN conference takes
# the name most of its teams carry in this season's CBBD games, so names match the champions
# table; ESPN's own short name where no game says), the team name most used in this season's
# games, and NCAA-tournament eligibility. names: data.frame(team_id, team) from the season's games.
d1_teams_table <- function(season, file, names, games_conf, transitions = read_transitions()) {
  m <- jsonlite::fromJSON(file)
  m <- m[!duplicated(m$team_id), ]
  gc <- games_conf[match(m$team_id, games_conf$team_id), "conf"]
  vote <- stats::aggregate(gc, list(id = m$espn_conf_id), \(x) { x <- stats::na.omit(x); if (length(x)) names(which.max(table(x))) else NA_character_ })
  fixed <- c("Atlantic Sun" = "ASUN")                        # the one name the two sources spell differently
  conf <- vote$x[match(m$espn_conf_id, vote$id)]
  conf <- dplyr::coalesce(conf, unname(fixed[m$espn_conf]), m$espn_conf)
  tr <- transitions[match(m$team_id, transitions$team_id), ]
  data.frame(team_id = m$team_id, team = names$team[match(m$team_id, names$team_id)], conf = conf,
             espn_conf = m$espn_conf, eligible = is.na(tr$first_eligible) | season >= tr$first_eligible)
}

# Display name for teams with no game yet this season (ESPN core API, one request per team)
espn_team_name <- function(season, team_id) {
  vapply(team_id, \(id) tryCatch(espn_json(sprintf("%s/seasons/%d/teams/%d", ESPN_CORE, season, id))$location,
                                 error = \(e) NA_character_), character(1))
}

# ---- Completed games missing from the ESPN bulk files -------------------------------

# A few completed games are in CBBD (with their ESPN id) but not in ESPN's bulk schedule, box score
# or play-by-play files (2015-11-20 and 2017-03-13/14, a lagging live day). Their box score comes
# from the ESPN summary API, one cached request per game; no play-by-play, so no efficiency signal.
fetch_espn_summary <- function(game_id) {
  dir.create(raw_path("espn", "summary"), recursive = TRUE, showWarnings = FALSE)
  dest <- raw_path("espn", "summary", sprintf("%d.json", game_id))
  if (!file.exists(dest)) {
    ok <- tryCatch({ utils::download.file(sprintf("%s/summary?event=%d", ESPN_SITE, game_id), dest, quiet = TRUE); TRUE },
                   error = \(e) FALSE)
    if (!ok) { unlink(dest); return(NA_character_) }
  }
  dest
}

# Summary files -> rows shaped like the schedule query in build_games(), with box-score possessions
read_espn_summaries <- function(files) {
  rows <- lapply(stats::na.omit(files), function(f) {
    x <- jsonlite::fromJSON(f, simplifyVector = FALSE)
    comp <- x$header$competitions[[1]]
    side <- function(ha) Filter(\(t) identical(t$homeAway, ha), comp$competitors)[[1]]
    h <- side("home"); a <- side("away")
    stat <- function(t, nm) {
      s <- Filter(\(z) identical(z$name, nm), t$statistics)
      if (length(s)) s[[1]]$displayValue else NA_character_
    }
    poss <- vapply(x$boxscore$teams, function(t) {
      att <- \(nm) as.numeric(sub(".*-", "", stat(t, nm)))
      att("fieldGoalsMade-fieldGoalsAttempted") - as.numeric(stat(t, "offensiveRebounds")) +
        as.numeric(stat(t, "totalTurnovers")) + 0.475 * att("freeThrowsMade-freeThrowsAttempted")
    }, numeric(1))
    v <- x$gameInfo$venue
    data.frame(game_id = as.integer(comp$id),
               game_date = as.Date(as.POSIXct(comp$date, format = "%Y-%m-%dT%H:%MZ", tz = "UTC"), tz = "America/New_York"),
               neutral_site = isTRUE(comp$neutralSite), venue_id = as.integer(v$id %||% NA), venue = v$fullName %||% NA_character_,
               city = v$address$city %||% NA_character_, state = v$address$state %||% NA_character_,
               home_id = as.integer(h$id), home = h$team$location, away_id = as.integer(a$id), away = a$team$location,
               home_score = as.integer(h$score), away_score = as.integer(a$score),
               completed = isTRUE(comp$status$type$completed), poss = if (length(poss) == 2) mean(poss) else NA_real_)
  })
  do.call(rbind, rows)
}

# ---- Injuries ----------------------------------------------------------------------

# ESPN's injury report has no history: one copy is archived per day the poller or a build runs
# (data/raw/espn/injuries/injuries_YYYYMMDD.json). Empty in the preseason.
fetch_espn_injuries <- function(today = Sys.Date()) {
  dir.create(raw_path("espn", "injuries"), recursive = TRUE, showWarnings = FALSE)
  dest <- raw_path("espn", "injuries", sprintf("injuries_%s.json", format(today, "%Y%m%d")))
  if (!file.exists(dest)) {
    ok <- tryCatch({ utils::download.file(sprintf("%s/injuries", ESPN_SITE), dest, quiet = TRUE); TRUE }, error = \(e) FALSE)
    if (!ok) unlink(dest)
  }
  if (file.exists(dest)) dest else NA_character_
}

# Archived injury files -> one row per (report date, player listed)
read_espn_injuries <- function(files) {
  empty <- data.frame(report_date = as.Date(character()), team_id = integer(), athlete_id = integer(), athlete = character(),
                      status = character(), type = character(), detail = character(), return_date = as.Date(character()),
                      updated = as.POSIXct(character()), comment = character())
  rows <- lapply(files, function(f) {
    x <- jsonlite::fromJSON(f, simplifyVector = FALSE)
    d <- as.Date(sub(".*injuries_([0-9]{8}).*", "\\1", f), "%Y%m%d")
    inj <- unlist(lapply(x$injuries, \(team) lapply(team$injuries, \(i) c(i, list(list_team = team$id)))), recursive = FALSE)
    do.call(rbind, lapply(inj, function(i) {
      a <- i$athlete
      href <- vapply(a$links %||% list(), \(l) l$href %||% "", character(1))
      id <- suppressWarnings(as.integer(sub(".*/id/([0-9]+).*", "\\1", grep("/id/[0-9]+", href, value = TRUE)[1])))
      data.frame(report_date = d, team_id = as.integer(a$team$id %||% i$list_team), athlete_id = id,
                 athlete = a$displayName %||% NA_character_, status = i$status %||% NA_character_,
                 type = i$details$type %||% NA_character_, detail = i$details$detail %||% NA_character_,
                 return_date = as.Date(i$details$returnDate %||% NA_character_),
                 updated = as.POSIXct(i$date %||% NA_character_, format = "%Y-%m-%dT%H:%MZ", tz = "UTC"),
                 comment = i$shortComment %||% NA_character_)
    }))
  })
  rbind(empty, do.call(rbind, rows))
}
