# ==============================================================================
# PARKED (2026-10-23): exhibitions are only used if one or two sources carry them; today that
# means ~365 school sites, so this scraper is kept as pilot evidence, not part of the pipeline.
#
# Exhibition games. No structured feed carries them (ESPN, CBBD `seasonType=preseason`, NCAA.com
# all start at opening night), so they come from each school's athletics site:
#
#   ncaa-api /schools-index (slug, name) -> ncaa.com/schools/<slug> ("school-links": the official
#   athletics site) -> <site>/sports/mens-basketball/schedule/<YYYY-YY> -> game cards marked
#   "(Exh)" / "Exhibition" with a result "W, 71-52" (this school's score first).
#
# Parsed for Sidearm's current game cards; other platforms (WMT, PrestoSports, ...) are reported
# as unparsed. Every page is cached under data/raw/sites/ and fetched at most once a second.
# ==============================================================================

SITES_DIR <- raw_path("sites")

polite_get <- function(url, dest) {
  if (file.exists(dest)) return(dest)
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  Sys.sleep(1)
  resp <- tryCatch(
    httr2::request(url) |> httr2::req_user_agent("Mozilla/5.0 (cbb-rankings research)") |>
      httr2::req_timeout(30) |> httr2::req_error(is_error = \(r) FALSE) |> httr2::req_perform(),
    error = \(e) NULL)
  if (is.null(resp) || httr2::resp_status(resp) >= 400) return(NA_character_)
  writeLines(httr2::resp_body_string(resp), dest)
  dest
}

ncaa_schools <- function() {
  f <- polite_get("https://ncaa-api.henrygd.me/schools-index", file.path(SITES_DIR, "schools_index.json"))
  jsonlite::fromJSON(f)
}

# Official athletics site from the school's ncaa.com page
school_site <- function(slug) {
  f <- polite_get(sprintf("https://www.ncaa.com/schools/%s", slug), file.path(SITES_DIR, "ncaa", paste0(slug, ".html")))
  if (is.na(f)) return(NA_character_)
  h <- paste(readLines(f, warn = FALSE), collapse = "\n")
  i <- regexpr('class="school-links"', h, fixed = TRUE)
  if (i < 0) return(NA_character_)
  m <- regmatches(substring(h, i), regexpr('href="https?://[^"]+"', substring(h, i)))
  if (!length(m)) NA_character_ else sub("/$", "", gsub('^href="|"$', "", m))
}

name_key <- function(x) {
  x <- tolower(x)
  x <- gsub("\\bst\\.?$|\\bst\\.?(?= )", "state", x, perl = TRUE)
  x <- gsub("&", "and", x)
  gsub("\\s+", " ", trimws(gsub("[^a-z ]", " ", x)))
}

season_label <- function(season) sprintf("%d-%02d", season - 1, season %% 100)

# Text of each Sidearm game card ("|"-separated fields)
sidearm_cards <- function(h) {
  parts <- strsplit(h, '(?=<div[^>]*class="[^"]*s-game-card-standard[ "])', perl = TRUE)[[1]][-1]
  vapply(parts, function(p) {
    t <- gsub("<!--.*?-->", "", p, perl = TRUE)
    t <- gsub("<[^>]+>", " | ", t)
    t <- gsub("(\\s*\\|\\s*)+", " | ", t)
    xml2::xml_text(xml2::read_html(paste0("<p>", gsub("<", "&lt;", t), "</p>")))
  }, character(1), USE.NAMES = FALSE)
}

parse_exhibitions <- function(cards, season) {
  ex <- cards[grepl("\\(Exh\\)|Exhibition", cards)]
  if (!length(ex)) return(NULL)
  do.call(rbind, lapply(ex, function(t) {
    f <- trimws(strsplit(t, "|", fixed = TRUE)[[1]]); f <- f[nzchar(f)]
    loc <- match(TRUE, f %in% c("vs", "at", "vs.", "at."))
    res <- regmatches(t, regexec("\\b([WLT]),\\s*(\\d{2,3})-(\\d{2,3})", t))[[1]]
    dt <- regmatches(t, regexec("\\b(Oct|Nov|Sep)\\s+(\\d{1,2})\\b", t))[[1]]
    data.frame(
      opponent = if (is.na(loc)) NA_character_ else sub("\\s*\\(Exh\\)$", "", f[loc + 1]),
      venue = if (is.na(loc)) NA_character_ else sub("\\.$", "", f[loc]),
      result = if (length(res)) res[2] else NA_character_,
      pts = if (length(res)) as.integer(res[3]) else NA_integer_,
      opp_pts = if (length(res)) as.integer(res[4]) else NA_integer_,
      date = if (length(dt)) as.Date(sprintf("%d-%s-%s", season - 1, match(dt[2], month.abb), dt[3])) else as.Date(NA)
    )
  }))
}

# One school's exhibitions for a season, with a platform/status note
school_exhibitions <- function(site, season) {
  url <- sprintf("%s/sports/mens-basketball/schedule/%s", site, season_label(season))
  key <- gsub("[^a-z0-9]+", "_", tolower(sub("^https?://", "", site)))
  f <- polite_get(url, file.path(SITES_DIR, "schedules", sprintf("%s_%d.html", key, season)))
  if (is.na(f)) return(list(status = "fetch_failed", ex = NULL))
  h <- paste(readLines(f, warn = FALSE), collapse = "\n")
  # a redirect to another season's page would put the wrong year in the dates
  if (!grepl(season_label(season), h, fixed = TRUE)) return(list(status = "wrong_season", ex = NULL))
  if (!grepl("s-game-card", h, fixed = TRUE)) {
    platform <- if (grepl("wmt", h, ignore.case = TRUE)) "wmt" else if (grepl("presto", h, ignore.case = TRUE)) "presto" else "other"
    return(list(status = paste0("unparsed_", platform), ex = NULL))
  }
  list(status = "sidearm", ex = parse_exhibitions(sidearm_cards(h), season))
}
