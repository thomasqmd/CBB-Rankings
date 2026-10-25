# ==============================================================================
# Prep: games and the two per-game signals the power model reads.
#
#   margin100 : regulation margin per 100 regulation possessions (OT games -> 0)
#   lux100    : luck-adjusted margin per 100 live possessions: actual 2-point makes, expected
#               3-point makes (shot model) and expected free throws (shooter FT%, shrunk)
#   eff100    : pure shot-quality margin (every field goal at its expected value), kept for
#               comparison
#
# Possessions come from the box score (FGA - OREB + TOV + 0.475 FTA, averaged over the two
# teams), scaled to regulation for OT games. "Live" play = regulation outside garbage time.
# ESPN team ids are canonical; CBBD rows join on the ESPN game id (CBBD `sourceId`).
#
# ESPN's play-by-play changes format across seasons (e.g. 2014-15 has no `points_attempted`,
# "made Free Throw." with no "1 of 2", no substitutions, and a wrong `start_game_seconds_remaining`);
# everything here reads every era. Time comes from the displayed clock, which is right in all.
# ==============================================================================

duck <- function() DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
pq <- function(what, season) sprintf("read_parquet('%s')", raw_path("espn", sprintf("%s_%d.parquet", what, season)))

GT_RULES <- list(c(secs_left = 600, lead = 20), c(secs_left = 300, lead = 15))  # garbage time
IFT_RULE <- NULL      # late intentional-foul trips left out of the signal: c(secs_left, lead), NULL = kept
FT_SHRINK <- 40                                                                   # FTA of league-average prior
SHOT_MODEL_SEASONS <- 2                                                           # earlier seasons per shot model
MIN_FAMILY_SHOTS <- 500                                                           # rarer families fold into "jumper"
# Bump when parsing changes what sync writes: final seasons synced by an older version re-sync
PREP_VERSION <- 4L
FLOOR_MIN_GAMES <- 2       # non-neutral home games at a venue that make it a team's floor

# ---- Games ------------------------------------------------------------------------

schedule_sql <- function(season) sprintf(
  "select game_id, game_date::date game_date, neutral_site, venue_id, venue_full_name as venue,
          venue_address_city as city, venue_address_state as state,
          home_id, home_location as home, away_id, away_location as away,
          home_score, away_score, status_type_completed as completed
   from %s", pq("schedule", season))

# Every game of a season with a D1 team in it (completed or scheduled): possessions, regulation
# margin, closing spread, venue. division: "d1" = both teams D1 (conference in CBBD), "nond1" =
# one team D1. division = "all" keeps both. Completed games CBBD has and the ESPN bulk files lack
# come from the ESPN summary API (box score, no play-by-play).
build_games <- function(season, division = c("all", "d1", "nond1")) {
  division <- match.arg(division)
  con <- duck(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  sched <- DBI::dbGetQuery(con, schedule_sql(season))
  tb <- raw_path("espn", sprintf("team_box_%d.parquet", season))
  poss <- if (file.exists(tb)) {
    DBI::dbGetQuery(con, sprintf(
      "select game_id, avg(field_goals_attempted - offensive_rebounds + total_turnovers + 0.475 * free_throws_attempted) poss
       from %s group by game_id", pq("team_box", season)))
  } else data.frame(game_id = integer(), poss = numeric())
  cb <- cbbd_games(season)
  gone <- cb$game_id[cb$cbbd_status %in% "final" & !(is.na(cb$home_conf) & is.na(cb$away_conf)) & !cb$game_id %in% sched$game_id]
  extra <- if (length(gone)) read_espn_summaries(vapply(gone, fetch_espn_summary, character(1)))
  if (!is.null(extra)) {
    sched <- dplyr::bind_rows(sched, extra[extra$completed, names(sched)])
    poss <- dplyr::bind_rows(poss, extra[extra$completed, c("game_id", "poss")])
  }
  # each team's floors from this season's and last season's schedules
  prev <- raw_path("espn", sprintf("schedule_%d.parquet", season - 1))
  floors <- team_floors(rbind(sched[, c("venue_id", "home_id", "neutral_site")],
                              if (file.exists(prev)) DBI::dbGetQuery(con, sprintf("select venue_id, home_id, neutral_site from %s", pq("schedule", season - 1)))))

  g <- sched |>
    dplyr::inner_join(cb, by = "game_id") |>
    dplyr::left_join(cbbd_lines(season), by = "cbbd_id") |>
    dplyr::left_join(poss, by = "game_id") |>
    dplyr::filter(!(is.na(home_conf) & is.na(away_conf)))
  g <- cbind(g, venue_site(g, floors)) |>
    dplyr::mutate(
      season = as.integer(season),
      division = ifelse(!is.na(home_conf) & !is.na(away_conf), "d1", "nond1"),
      game_date = as.Date(game_date),
      neutral = as.integer(neutral_site),          # ESPN's flag; the model reads `site`
      ot = n_periods > 2,
      poss_reg = poss * 2400 / (2400 + 300 * pmax(n_periods - 2, 0)),
      margin_reg = ifelse(ot, 0, home_reg - away_reg),
      margin100 = 100 * margin_reg / poss_reg,
      ncaa = !is.na(tournament) & tournament == "NCAA",
      # usable as a model observation: completed, with possessions and period scores
      played = completed & !is.na(poss) & !is.na(home_reg) & !is.na(away_reg)
    )
  if (division != "all") g <- g[g$division == division, ]
  g
}

read_bans <- function(path = "data/postseason_bans.csv") {
  if (file.exists(path)) utils::read.csv(path, stringsAsFactors = FALSE) else NULL
}

# A team's floors: venues where it played at least FLOOR_MIN_GAMES non-neutral home games
team_floors <- function(sched) {
  h <- sched[!(sched$neutral_site %in% TRUE) & !is.na(sched$venue_id), ]
  n <- dplyr::count(h, team_id = home_id, venue_id)
  as.data.frame(n[n$n >= FLOOR_MIN_GAMES, c("team_id", "venue_id")])
}

# Home edge from the listed home team's side: +1 on its floor, -1 on the away team's, 0 neutral.
# ESPN's neutral flag, except where the venue says otherwise: a "neutral" game on exactly one
# team's floor (a conference tournament on campus, the First Four in Dayton) is a home game for
# that team, and a non-neutral game on the away team's floor and not the home team's is the away
# team's home game. site_note says why a game differs from ESPN's flag.
venue_site <- function(g, floors) {
  key <- paste(floors$team_id, floors$venue_id)
  h <- !is.na(g$venue_id) & paste(g$home_id, g$venue_id) %in% key
  a <- !is.na(g$venue_id) & paste(g$away_id, g$venue_id) %in% key
  neutral <- g$neutral_site %in% TRUE
  site <- ifelse(neutral, 0L, 1L)
  note <- rep(NA_character_, nrow(g))
  recode <- function(i, s, why) { site[i] <<- s; note[i] <<- why }
  recode(neutral & h & !a, 1L, "neutral, home team's floor")
  recode(neutral & a & !h, -1L, "neutral, away team's floor")
  recode(!neutral & a & !h, -1L, "away team's floor")
  data.frame(site = site, site_note = note)
}

# Games where the venue was recoded or ESPN and CBBD disagree on neutral, for the venue report
venue_report <- function(games) {
  g <- games[games$division == "d1" & games$played, ]
  g$disagree <- (g$neutral == 1) != g$cbbd_neutral
  g[!is.na(g$site_note) | g$disagree %in% TRUE,
    c("season", "game_id", "game_date", "home", "away", "venue", "city", "state", "neutral", "cbbd_neutral", "site", "site_note", "tournament")]
}

# The season's D1 teams for the model: ESPN's membership (d1_teams: team_id, team, conf, eligible)
# less listed teams with no game this season (the 2020-21 Ivy League; ESPN lists two 2020-21
# arrivals in 2019-20), plus any team in a D1 game that ESPN does not list (none 2014-2027).
# In a live season every listed team stays: most schedules are not posted yet. Without d1_teams
# the games alone decide (team_conferences()). Teams under a postseason ban (bans: season,
# team_id; data/postseason_bans.csv) are not eligible either.
season_teams <- function(d1, games, live = FALSE, bans = NULL) {
  gt <- team_conferences(games)
  if (is.null(d1) || !nrow(d1)) return(gt)
  if (!is.null(bans) && nrow(bans) && !is.null(games$season)) {
    banned <- bans$team_id[bans$season == games$season[1]]
    d1$eligible <- d1$eligible & !(d1$team_id %in% banned)
  }
  if (!live) d1 <- d1[d1$team_id %in% c(games$home_id, games$away_id), ]
  t <- data.frame(team_id = d1$team_id, team = dplyr::coalesce(gt$team[match(d1$team_id, gt$team_id)], d1$team),
                  conf = d1$conf, eligible = d1$eligible)
  extra <- gt[!gt$team_id %in% t$team_id, ]
  if (nrow(extra)) {
    warning(nrow(extra), " teams in D1 games are not on ESPN's D1 list: ", paste(extra$team, collapse = ", "))
    t <- rbind(t, data.frame(extra, eligible = TRUE))
  }
  t <- t[order(t$team_id), ]
  rownames(t) <- NULL
  t
}

# Each team's conference for the season (most frequent among its games)
team_conferences <- function(games) {
  if (!is.null(games$division)) games <- games[games$division == "d1", ]
  long <- rbind(data.frame(team_id = games$home_id, team = games$home, conf = games$home_conf),
                data.frame(team_id = games$away_id, team = games$away, conf = games$away_conf))
  long |>
    dplyr::count(team_id, team, conf) |>
    dplyr::arrange(team_id, dplyr::desc(n)) |>
    dplyr::distinct(team_id, .keep_all = TRUE) |>
    dplyr::select(team_id, team, conf)
}

# ---- Plays -------------------------------------------------------------------------

# Elapsed seconds from tip (halves 1,200 s, OT periods 300 s), from the period and the displayed
# clock; `clk` is the clock in seconds (CLOCK_SQL)
ELAPSED_SQL <- "case when period_number <= 2 then 1200 * (period_number - 1) + (1200 - least(clk, 1200))
                     else 2400 + 300 * (period_number - 3) + (300 - least(clk, 300)) end"
CLOCK_SQL <- "coalesce(try_cast(split_part(clock_display_value, ':', 1) as double) * 60
                       + try_cast(split_part(clock_display_value, ':', 2) as double),
                       try_cast(clock_display_value as double))"

# Play-by-play without substitutions. points_attempted is derived where the file lacks it or codes
# a field goal as anything but 2 or 3 (~0.5% of shots).
read_plays <- function(season) {
  con <- duck(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cols <- DBI::dbGetQuery(con, sprintf("describe select * from %s", pq("pbp", season)))$column_name
  pts <- sprintf("case when type_text = 'MadeFreeThrow' then 1
                       %s
                       when type_text ilike '%%three point%%' or text ilike '%%three point%%' then 3
                       when shooting_play then 2 else 0 end",
                 if ("points_attempted" %in% cols) "when points_attempted in (2, 3) then points_attempted" else "")
  DBI::dbGetQuery(con, sprintf(
    "select game_id, game_play_number, type_text, lower(text) txt, team_id, home_team_id, away_team_id,
            athlete_id_1, shooting_play, scoring_play, %s as points_attempted,
            coordinate_x_raw x, coordinate_y_raw y, home_score, away_score, %s elapsed, period_number, game_date
     from (select *, %s clk from %s where type_text <> 'Substitution')
     order by game_id, game_play_number", pts, ELAPSED_SQL, CLOCK_SQL, pq("pbp", season)))
}

# Substitutions (in ESPN play-by-play only from part of 2024-25 on): one row per player in or out
read_subs <- function(season) {
  con <- duck(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(con, sprintf(
    "select game_id, game_play_number, period_number period, %s elapsed, team_id, athlete_id_1 athlete_id,
            case when text ilike '%%subbing in%%' then 'in' when text ilike '%%subbing out%%' then 'out' end dir
     from (select *, %s clk from %s where type_text = 'Substitution')
     order by game_id, game_play_number", ELAPSED_SQL, CLOCK_SQL, pq("pbp", season)))
}

# ---- Players ------------------------------------------------------------------------

# Player box scores for the given games (ESPN bulk; did_not_play rows have no minutes)
player_box_table <- function(season, game_ids) {
  con <- duck(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  duckdb::duckdb_register(con, "ids", data.frame(game_id = game_ids))
  DBI::dbGetQuery(con, sprintf(
    "select p.game_id, team_id, athlete_id, athlete_display_name athlete, athlete_position_abbreviation pos,
            starter, did_not_play, ejected, minutes, points, field_goals_made fgm, field_goals_attempted fga,
            three_point_field_goals_made fg3m, three_point_field_goals_attempted fg3a, free_throws_made ftm,
            free_throws_attempted fta, offensive_rebounds oreb, defensive_rebounds dreb, assists ast, steals stl,
            blocks blk, turnovers tov, fouls pf
     from %s p join ids using (game_id)", pq("player_box", season)))
}

# Short-handed games, inferred after the fact from box scores (never pregame information): a
# rotation player (>= ABSENCE_MIN_GAMES earlier games, >= ABSENCE_MPG minutes a game over his last
# ABSENCE_WINDOW games) who did not play although he is listed as did-not-play or plays again later
# in the season. missing = their minutes a game / 200, summed: the share of the team's minutes that
# was missing. 2016-2026: 28% of team-games, residual -0.73 pts per 10% of minutes missing.
ABSENCE_MIN_GAMES <- 3
ABSENCE_MPG <- 20
ABSENCE_WINDOW <- 5
absence_table <- function(pb, games) {
  empty <- data.frame(game_id = integer(), team_id = integer(), missing = numeric(), n_missing = integer())
  if (is.null(pb) || !nrow(pb)) return(empty)
  g <- games[games$played, c("game_id", "game_date", "home_id", "away_id")]
  tg <- rbind(data.frame(game_id = g$game_id, game_date = g$game_date, team_id = g$home_id),
              data.frame(game_id = g$game_id, game_date = g$game_date, team_id = g$away_id))
  tg <- tg[order(tg$team_id, tg$game_date, tg$game_id), ]
  pb$minutes <- dplyr::coalesce(as.numeric(pb$minutes), 0)
  pb <- pb[!is.na(pb$athlete_id) & pb$game_id %in% g$game_id, ]
  # every (team game, player who appears for that team this season)
  pl <- unique(pb[, c("team_id", "athlete_id")])
  x <- merge(tg, pl, by = "team_id")
  k <- match(paste(x$game_id, x$athlete_id), paste(pb$game_id, pb$athlete_id))
  x$min <- dplyr::coalesce(pb$minutes[k], 0)
  x$dnp <- pb$did_not_play[k] %in% TRUE
  x <- x[order(x$team_id, x$athlete_id, x$game_date, x$game_id), ]
  # minutes a game over the last ABSENCE_WINDOW games played before this one
  recent <- function(min) {
    pl <- min > 0
    cs <- c(0, cumsum(min[pl]))
    n <- cumsum(pl) - pl
    lo <- pmax(n - ABSENCE_WINDOW, 0)
    ifelse(n > 0, (cs[n + 1] - cs[lo + 1]) / pmax(n - lo, 1), 0)
  }
  x <- x |>
    dplyr::group_by(team_id, athlete_id) |>
    dplyr::mutate(n_before = cumsum(min > 0) - (min > 0), mpg = recent(min),
                  later = rev(cumsum(rev(min > 0))) - (min > 0) > 0) |>
    dplyr::ungroup()
  out <- x[x$min == 0 & x$n_before >= ABSENCE_MIN_GAMES & x$mpg >= ABSENCE_MPG & (x$dnp | x$later), ] |>
    dplyr::group_by(game_id, team_id) |>
    dplyr::summarise(missing = sum(mpg) / 200, n_missing = dplyr::n(), .groups = "drop")
  as.data.frame(out)
}

# ESPN season rosters (bulk files from 2024-25 on); height in inches, weight in pounds
rosters_table <- function(season) {
  con <- duck(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- DBI::dbGetQuery(con, sprintf(
    "select team_id, try_cast(athlete_id as integer) athlete_id, display_name athlete, jersey, position_abbreviation pos,
            height, weight, try_cast(experience_years as integer) experience, experience_display_value class_year,
            birth_place_city city, birth_place_state state, birth_place_country country, status_name status
     from %s", pq("rosters", season)))
  ft <- suppressWarnings(as.numeric(sub("'.*", "", r$height)))
  inch <- suppressWarnings(as.numeric(sub(".*' *([0-9]+).*", "\\1", r$height)))
  r$height <- ft * 12 + dplyr::coalesce(inch, 0)
  r$weight <- suppressWarnings(as.numeric(sub(" *lbs", "", r$weight)))
  r
}

# Coarse families only: ESPN's finer descriptors (driving, floater, step-back, pull-up,
# turnaround) appear from 2025-26 on, so they would not mean the same thing across seasons
SHOT_FAMILIES <- c("jumper", "layup", "dunk", "tip", "hook")

shot_family <- function(txt, type) {
  # the shot description only: player names ("Hooker", "Tipton") must not decide the family
  txt <- sub("^.*?\\b(makes|made|misses|missed)\\b", "", txt, perl = TRUE)
  txt <- sub("\\(.*$|\\.? ?assisted by.*$|\\.? ?blocked by.*$", "", txt, perl = TRUE)
  f <- dplyr::case_when(
    grepl("tip", txt) | type == "TipShot" ~ "tip",
    grepl("dunk|alley oop", txt) | type == "DunkShot" ~ "dunk",
    grepl("layup", txt) | type == "LayUpShot" ~ "layup",
    grepl("hook", txt) ~ "hook",
    TRUE ~ "jumper"
  )
  factor(f, levels = SHOT_FAMILIES)
}

# Per-play context: possession starts (transition), putbacks, garbage time.
# A made free throw ends the possession when the next event is not another free throw by the
# same team (works with and without "1 of 2" in the text).
annotate_plays <- function(p, gt_rules = GT_RULES, ift_rule = IFT_RULE) {
  p <- p |>
    dplyr::group_by(game_id) |>
    dplyr::mutate(
      opp_id = ifelse(team_id == home_team_id, away_team_id, home_team_id),
      next_ft_same = dplyr::coalesce(dplyr::lead(type_text) == "MadeFreeThrow" & dplyr::lead(team_id) == team_id, FALSE),
      gain = dplyr::case_when(
        type_text == "Defensive Rebound" ~ team_id,
        grepl("Turnover", type_text) ~ opp_id,
        shooting_play & scoring_play & type_text != "MadeFreeThrow" ~ opp_id,
        type_text == "MadeFreeThrow" & scoring_play & !next_ft_same ~ opp_id,
        TRUE ~ NA_integer_),
      home_start = ifelse(gain == home_team_id, elapsed, NA_real_),
      away_start = ifelse(gain == away_team_id, elapsed, NA_real_),
      prev_type = dplyr::lag(type_text), prev_team = dplyr::lag(team_id), prev_t = dplyr::lag(elapsed),
      diff_before = dplyr::lag(home_score - away_score, default = 0)
    ) |>
    tidyr::fill(home_start, away_start, .direction = "down") |>
    dplyr::ungroup()
  # possession start for the acting team is the last gain before this event
  p$poss_start <- ifelse(p$team_id == p$home_team_id, dplyr::lag(p$home_start), dplyr::lag(p$away_start))
  secs_left <- pmax(2400 - p$elapsed, 0)
  p$garbage <- p$period_number >= 2 & Reduce(`|`, lapply(gt_rules, \(r)
    secs_left <= r[["secs_left"]] & abs(p$diff_before) >= r[["lead"]]), init = FALSE)
  p$excl <- p$garbage | p$elapsed > 2400        # efficiency signal: live regulation play only
  # free throws by the leading team late in a close game (fouls to stop the clock)
  lead_by <- ifelse(p$team_id == p$home_team_id, p$diff_before, -p$diff_before)
  p$ift <- if (is.null(ift_rule)) FALSE else
    p$type_text == "MadeFreeThrow" & p$period_number == 2 & secs_left <= ift_rule[["secs_left"]] & lead_by >= 1 & lead_by <= ift_rule[["lead"]]
  p
}

# Field-goal attempts with model features (distance may be NA; imputed in prep_shots)
shot_table <- function(p) {
  s <- p[p$shooting_play & p$type_text != "MadeFreeThrow" & p$points_attempted %in% 2:3, ]
  ok <- !is.na(s$x) & s$x >= 0 & s$x <= 50 & !is.na(s$y) & s$y >= 0 & s$y <= 94
  dist <- ifelse(ok, sqrt((s$x - 25)^2 + s$y^2), NA_real_)
  txt_dist <- suppressWarnings(as.numeric(sub(".* ([0-9]+)-foot .*", "\\1", ifelse(grepl("[0-9]+-foot", s$txt), s$txt, NA))))
  dist <- ifelse(is.na(dist) | dist > 47, txt_dist, dist)
  data.frame(
    game_id = s$game_id, team_id = s$team_id, excl = s$excl,
    made = as.integer(s$scoring_play), three = as.integer(s$points_attempted == 3),
    value = s$points_attempted,
    dist = dist,
    family = shot_family(s$txt, s$type_text),
    putback = as.integer(dplyr::coalesce(s$prev_type == "Offensive Rebound" & s$prev_team == s$team_id &
                                         s$elapsed - s$prev_t <= 4, FALSE)),
    transition = as.integer(!is.na(s$poss_start) & s$elapsed - s$poss_start <= 8)
  )
}

# Free-throw attempts, one row per attempt
ft_table <- function(p) {
  f <- p[p$type_text == "MadeFreeThrow", ]
  data.frame(game_id = f$game_id, game_date = as.Date(f$game_date), team_id = f$team_id,
             athlete_id = f$athlete_id_1, made = as.integer(f$scoring_play), excl = f$excl | f$ift)
}

# Share of regulation before garbage time began, per game
live_table <- function(p) {
  p |>
    dplyr::group_by(game_id) |>
    dplyr::summarise(gt_start = suppressWarnings(min(elapsed[garbage & elapsed <= 2400])), .groups = "drop") |>
    dplyr::transmute(game_id, live_share = ifelse(is.finite(gt_start), gt_start / 2400, 1))
}

# ---- Shot model ----------------------------------------------------------------------

# Median distance by family x three, used to impute shots without a location
dist_medians <- function(ref) {
  ref$family <- factor(as.character(ref$family), levels = SHOT_FAMILIES)
  med <- stats::aggregate(dist ~ family + three, ref, stats::median)
  med$family <- factor(as.character(med$family), levels = SHOT_FAMILIES)
  med
}

# Distance capped at 30 ft (heaves), missing distance imputed from `med`. Families outside
# `families` (absent from a shot model's training seasons) count as jumpers.
prep_shots <- function(s, med = dist_medians(s), families = SHOT_FAMILIES) {
  f <- as.character(s$family)
  f[!f %in% families] <- "jumper"
  s$family <- factor(f, levels = families)
  s <- dplyr::left_join(s, dplyr::rename(med, dist_med = dist), by = c("family", "three"))
  s$dist <- pmin(dplyr::coalesce(s$dist, s$dist_med, 20), 30)
  s$dist_med <- NULL
  s
}

# Twos and threes are fit separately, each with its own distance spline: threes only exist beyond
# ~20 ft, so one spline over 0-30 ft interacted with `three` is ill-conditioned (coefficients ~1e9)
fit_make_model <- function(shots) {
  fit <- function(f, d) {
    m <- stats::glm(f, family = stats::binomial(), data = d, model = FALSE, y = FALSE)
    # keep what predict() needs, not the data
    m$data <- NULL; m$residuals <- NULL; m$fitted.values <- NULL; m$weights <- NULL
    m$prior.weights <- NULL; m$linear.predictors <- NULL; m$effects <- NULL; m$qr$qr <- NULL
    m
  }
  structure(list(
    two = fit(made ~ splines::ns(dist, df = 4) + family + putback + transition, shots[shots$three == 0, ]),
    three = fit(made ~ splines::ns(dist, df = 3) + putback + transition, shots[shots$three == 1, ])
  ), class = "make_model")
}

predict.make_model <- function(object, newdata, type = "response", ...) {
  p <- numeric(nrow(newdata))
  for (k in c("two", "three")) {
    i <- newdata$three == (k == "three")
    if (any(i)) p[i] <- stats::predict(object[[k]], newdata[i, ], type = type)
  }
  p
}

# Out-of-sample calibration of a season's shot model: predicted vs actual make rate by family
# (threes as one family), every field-goal attempt of the season
shot_model_calibration <- function(data, shot_model, season) {
  if (is.null(data$shots) || !nrow(data$shots)) return(NULL)
  sh <- prep_shots(data$shots, shot_model$med, shot_model$families)
  sh$p <- stats::predict(shot_model$model, sh)
  sh$family <- ifelse(sh$three == 1, "three", as.character(data$shots$family))
  out <- stats::aggregate(cbind(pred = p, actual = made) ~ family, sh, mean)
  out$shots <- as.vector(table(sh$family)[out$family])
  data.frame(season = as.integer(season), out, diff = out$pred - out$actual)
}

# Shot model for a season, trained on earlier seasons' shots only (`train`)
fit_shot_model <- function(train, seasons = NULL) {
  counts <- table(factor(as.character(train$family), levels = SHOT_FAMILIES))
  families <- union("jumper", names(counts)[counts >= MIN_FAMILY_SHOTS])
  families <- SHOT_FAMILIES[SHOT_FAMILIES %in% families]
  med <- dist_medians(train)
  tr <- prep_shots(train, med, families)
  list(model = fit_make_model(tr), med = med, families = families, n = nrow(tr), seasons = seasons)
}

# ---- Expected points per team-game ----------------------------------------------------

# Expected points per (game, team) outside garbage time. ft_prior: one row per FT attempt with
# the shooter's shrunk FT% from attempts before that game (ft_rates_to_date).
game_xpts <- function(shots, fts, live, make_model) {
  shots$xp <- shots$value * stats::predict(make_model, shots, type = "response")
  if (anyNA(shots$xp)) stop(sum(is.na(shots$xp)), " shots without a predicted make probability")
  sh <- shots[!shots$excl, ] |>
    dplyr::group_by(game_id, team_id) |>
    dplyr::summarise(x_fg = sum(xp), pts_fg = sum(value * made), fga = dplyr::n(),
                     x3 = sum(xp[three == 1]), pts2 = sum((value * made)[three == 0]), .groups = "drop")
  ft <- fts[!fts$excl, ] |>
    dplyr::group_by(game_id, team_id) |>
    dplyr::summarise(x_ft = sum(ft_pct), pts_ft = sum(made), .groups = "drop")
  dplyr::full_join(sh, ft, by = c("game_id", "team_id")) |>
    dplyr::mutate(dplyr::across(c(x_fg, pts_fg, x_ft, pts_ft, fga, x3, pts2), \(v) dplyr::coalesce(v, 0)),
                  xpts = x_fg + x_ft, pts = pts_fg + pts_ft,
                  lux = pts2 + x3 + x_ft) |>   # luck-adjusted: actual 2s, expected 3s and FTs
    dplyr::left_join(live, by = "game_id")
}

# Shooter FT% before each game: attempts from earlier games (this season and `history`, earlier
# seasons' attempts), shrunk toward the league rate with FT_SHRINK attempts
ft_rates_to_date <- function(fts, history = NULL) {
  all <- dplyr::bind_rows(history, fts)
  lg <- mean(all$made)
  per_game <- all |>
    dplyr::group_by(athlete_id, game_date, game_id) |>
    dplyr::summarise(m = sum(made), n = dplyr::n(), .groups = "drop") |>
    dplyr::arrange(athlete_id, game_date, game_id) |>
    dplyr::group_by(athlete_id) |>
    dplyr::mutate(m_before = cumsum(m) - m, n_before = cumsum(n) - n) |>
    dplyr::ungroup()
  out <- dplyr::left_join(fts, per_game[, c("athlete_id", "game_id", "m_before", "n_before")], by = c("athlete_id", "game_id"))
  out$ft_pct <- (dplyr::coalesce(out$m_before, 0) + FT_SHRINK * lg) / (dplyr::coalesce(out$n_before, 0) + FT_SHRINK)
  out$ft_pct[is.na(out$athlete_id)] <- lg
  out
}

# A season's games with both signals. ft_history: earlier seasons' free throws (shooter FT%).
season_games <- function(data, shot_model, ft_history = NULL) {
  g <- data$games
  if (is.null(data$shots) || !nrow(data$shots)) {
    g$poss_live <- NA_real_; g$has_eff <- FALSE; g$eff100 <- 0; g$lux100 <- 0
    return(add_absences(g, data$player_box))
  }
  shots <- prep_shots(data$shots, shot_model$med, shot_model$families)
  fts <- ft_rates_to_date(data$free_throws, ft_history)
  add_absences(add_eff(g, game_xpts(shots, fts, data$game_live, shot_model$model)), data$player_box)
}

# home_missing / away_missing: share of each team's usual minutes missing (absence_table())
add_absences <- function(g, pb) {
  a <- absence_table(pb, g)
  k <- function(team) match(paste(g$game_id, team), paste(a$game_id, a$team_id))
  g$home_missing <- ifelse(g$played, dplyr::coalesce(a$missing[k(g$home_id)], 0), NA_real_)
  g$away_missing <- ifelse(g$played, dplyr::coalesce(a$missing[k(g$away_id)], 0), NA_real_)
  g
}

# Attach eff100 / lux100 (home - away, per 100 live possessions) to the games table
add_eff <- function(games, xp) {
  h <- dplyr::rename(xp[, c("game_id", "team_id", "xpts", "lux", "live_share")], home_id = team_id,
                     x_home = xpts, l_home = lux)
  a <- dplyr::rename(xp[, c("game_id", "team_id", "xpts", "lux")], away_id = team_id, x_away = xpts, l_away = lux)
  games |>
    dplyr::left_join(h, by = c("game_id", "home_id")) |>
    dplyr::left_join(a, by = c("game_id", "away_id")) |>
    dplyr::mutate(
      poss_live = poss * live_share * 2400 / (2400 + 300 * pmax(n_periods - 2, 0)),
      has_eff = !is.na(x_home) & !is.na(x_away) & !is.na(poss_live) & poss_live >= 20,
      eff100 = ifelse(has_eff, 100 * (x_home - x_away) / poss_live, 0),
      lux100 = ifelse(has_eff, 100 * (l_home - l_away) / poss_live, 0)
    )
}
