# ==============================================================================
# Roster prior: how a team's preseason level moves with the players it kept, lost and added.
#
# Players come from Torvik's player tables (getadvstats.php, no key): minutes share (% of team
# minutes, 500 per team), box plus-minus (opponent-adjusted, per 100), recruit rating (0-100) and a
# player id that follows a player across teams. Season s's table names who was on each roster;
# season s-1's gives each player's last-season value, value = BPM (capped at +-15) x minutes / 100,
# which sums to roughly the team's net rating per 100. Torvik's live-season table, before games
# start, lists returning players and transfers on their new teams with last season's numbers, and
# no freshmen: the live season's freshmen come from CBBD's recruiting class instead (rank -> Torvik
# scale, rec = 100 - 0.19 rank, r = -0.99 on 2024-25). A season's roster file is fetched once and never
# refreshed, so the prior does not move once the season starts.
#
# Features per team: ret_val / ret_min (returning players' value and minutes share), tr_val /
# tr_min (incoming transfers, at their old team), fr_top (freshmen above rec 80, scaled 0-1 each),
# lost_val (value of last season's players who left). The prior regresses each past season's final
# rating on our last-season rating, Torvik's preseason rating and these, fit on earlier seasons only.
# ==============================================================================

TORVIK_PLAYER_COLS <- c(name = 1, team = 2, conf = 3, gp = 4, min = 5, yr = 26, ht = 27, pid = 33, rec = 35, bpm = 51)
RECRUIT_REC <- c(intercept = 100, slope = -0.19)   # CBBD recruit rank -> Torvik recruit rating
ROSTER_MIN_TRAIN <- 300                             # team-seasons needed before the regression is used
ROSTER_TERMS <- c("own", "tv", "ret_val", "tr_val", "fr_top", "lost_val", "ret_min", "tr_min")

fetch_torvik_players <- function(season) {
  dir.create(raw_path("torvik", "players"), recursive = TRUE, showWarnings = FALSE)
  dest <- raw_path("torvik", "players", sprintf("adv_%d.csv", season))
  if (!file.exists(dest)) torvik_get(sprintf("https://barttorvik.com/getadvstats.php?year=%d&csv=1", season), dest)
  if (file.exists(dest) && file.size(dest) > 0) dest else NA_character_
}

read_torvik_players <- function(season) {
  f <- fetch_torvik_players(season)
  if (is.na(f)) return(NULL)
  x <- utils::read.csv(f, header = FALSE, stringsAsFactors = FALSE)
  out <- as.data.frame(lapply(TORVIK_PLAYER_COLS, \(i) x[[i]]), stringsAsFactors = FALSE)
  out$bpm <- pmax(pmin(as.numeric(out$bpm), 15), -15)
  out$min <- as.numeric(out$min)
  out$rec <- suppressWarnings(as.numeric(out$rec))
  out[!duplicated(out$pid), ]
}

# The live season's recruiting class from CBBD (one call, cached for good): ESPN team id and the
# recruit rating on Torvik's scale. cbbd_ids: cbbd_team_ids() output.
fetch_cbbd_recruits <- function(season) {
  dest <- raw_path("cbbd", sprintf("recruits_%d.json", season - 1))
  if (!file.exists(dest)) writeLines(cbbd_get("recruiting/players", list(year = season - 1)), dest)
  dest
}

read_cbbd_recruits <- function(season, cbbd_ids) {
  x <- jsonlite::fromJSON(fetch_cbbd_recruits(season))
  if (!NROW(x)) return(data.frame(team_id = integer(), rec = numeric()))
  data.frame(team_id = cbbd_ids$team_id[match(x$committedTo$id, cbbd_ids$cbbd_team_id)],
             rec = RECRUIT_REC[["intercept"]] + RECRUIT_REC[["slope"]] * x$ranking)
}

# Roster features for season s. teams / teams_prev: the D1 teams of s and s-1; recruits: the live
# season's freshmen (team_id, rec) when Torvik's table has none.
roster_features <- function(season, teams, teams_prev, overrides = "data/torvik_names.csv", recruits = NULL) {
  a <- read_torvik_players(season - 1); b <- read_torvik_players(season)
  empty <- data.frame(team_id = teams$team_id)
  if (is.null(a) || is.null(b)) return(empty)
  a <- torvik_team_ids(a, teams_prev, overrides); b <- torvik_team_ids(b, teams, overrides)
  a$val <- a$bpm * a$min / 100
  k <- match(b$pid, a$pid)
  b$prev_team <- a$team_id[k]; b$prev_val <- a$val[k]; b$prev_min <- a$min[k]
  stay <- !is.na(b$prev_team) & b$prev_team == b$team_id
  tr <- !is.na(b$prev_team) & b$prev_team != b$team_id
  a$gone <- !(paste(a$pid, a$team_id) %in% paste(b$pid, b$team_id))
  fr <- if (any(b$yr == "Fr") || is.null(recruits)) b[b$yr == "Fr", c("team_id", "rec")] else recruits
  top <- function(rec) sum(pmax(dplyr::coalesce(rec, 0) - 80, 0) / 20)
  f <- empty |>
    dplyr::left_join(dplyr::summarise(dplyr::group_by(b[stay, ], team_id), ret_val = sum(prev_val), ret_min = sum(prev_min) / 500), by = "team_id") |>
    dplyr::left_join(dplyr::summarise(dplyr::group_by(b[tr, ], team_id), tr_val = sum(prev_val), tr_min = sum(prev_min) / 500, tr_n = dplyr::n()), by = "team_id") |>
    dplyr::left_join(dplyr::summarise(dplyr::group_by(fr[!is.na(fr$team_id), ], team_id), fr_top = top(rec), fr_n = dplyr::n()), by = "team_id") |>
    dplyr::left_join(dplyr::summarise(dplyr::group_by(a, team_id), lost_val = sum(val[gone])), by = "team_id")
  f[is.na(f)] <- 0
  f$season <- as.integer(season)
  f
}

# A past season's features with its final rating (the regression's target)
roster_history <- function(prior, snaps) {
  f <- attr(prior, "features")
  if (is.null(f) || !all(ROSTER_TERMS %in% names(f))) return(NULL)
  fin <- season_final_prior(snaps)
  f$final <- fin$prev_dev[match(f$team_id, fin$team_id)]
  f[!is.na(f$final), ]
}

# The regression prior: fit on `history` (earlier seasons), predicted for this season's features
roster_prior <- function(features, history) {
  if (is.null(history) || nrow(history) < ROSTER_MIN_TRAIN) return(NULL)
  fit <- stats::lm(stats::reformulate(ROSTER_TERMS, "final"), history)
  stats::predict(fit, features)
}
