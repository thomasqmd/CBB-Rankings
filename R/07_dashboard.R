# ==============================================================================
# Dashboard data: compact tables for docs/dashboard.qmd (Quarto + Observable JS).
#
#   ranks  one row per (season, snapshot, D1 team): resume, power, tempo, offence / defence,
#          field odds, team sheet, polls
#   snaps  one row per snapshot: date, label, games so far, gates, home court, game noise
#   games  one row per (game, D1 side): result, the model's pregame margin / win chance / total
#          (from the snapshot before the game), the closing line, and for games not yet played
#          the latest snapshot's numbers; wab_game = what the result earned against the benchmark
#   teams  ESPN id, name, abbreviation, logos (ESPN's CDN)
# Only the last DASH_SEASONS seasons go into the page (each season is ~8,000 ranking rows).
# ==============================================================================

DASH_SEASONS <- 3L

fetch_espn_teams <- function() {
  dest <- raw_path("espn", "teams.json")
  if (stale(dest, 24 * 30)) utils::download.file(sprintf("%s/teams?limit=500", ESPN_SITE), dest, quiet = TRUE)
  x <- jsonlite::fromJSON(dest, simplifyVector = FALSE)$sports[[1]]$leagues[[1]]$teams
  data.frame(id = vapply(x, \(t) as.integer(t$team$id), integer(1)),
             abbr = vapply(x, \(t) t$team$abbreviation %||% NA_character_, character(1)),
             short = vapply(x, \(t) t$team$shortDisplayName %||% NA_character_, character(1)))
}

# Columns a table may lack (snapshots built before a column existed) as NA
need <- function(df, cols) { for (k in cols) if (is.null(df[[k]])) df[[k]] <- rep(NA_real_, nrow(df)); df }

snap_label <- function(d, kind) {
  ifelse(kind == "preseason", "Preseason", ifelse(kind == "selection", "Selection Monday",
         ifelse(kind == "final", "Final", paste(format(d, "%b"), as.integer(format(d, "%d"))))))
}

# snapshots: combine_snapshots() output; games: list of games_<s>; teams: list of teams_<s>;
# backtest: run_backtest() output (its games carry each prediction with its result)
build_dashboard_data <- function(snapshots, games, teams, backtest, cfg = model_config(), seasons = NULL) {
  all_s <- sort(unique(snapshots$ratings$season))
  seasons <- if (is.null(seasons)) utils::tail(all_s, DASH_SEASONS) else intersect(seasons, all_s)
  keep <- function(df) df[df$season %in% seasons, ]
  rt <- need(keep(snapshots$ratings), c("tempo", "off", "def", "tempo_eff", "total_eff"))
  rs <- need(keep(snapshots$resume), c("proj_wab", "p_auto", "p_at_large", "p_field", "p_conf_reg", "luck", "sor", "colley",
                                       paste0("q", rep(1:4, each = 2), c("_w", "_l"))))
  pa <- need(keep(snapshots$params), c("mu_p", "mu_t"))
  pa$mu_p <- dplyr::coalesce(pa$mu_p, TEMPO$mu_p); pa$mu_t <- dplyr::coalesce(pa$mu_t, TEMPO$mu_t)
  rt$tempo_eff <- dplyr::coalesce(rt$tempo_eff, 0); rt$total_eff <- dplyr::coalesce(rt$total_eff, 0)
  gt <- keep(snapshots$gates)
  pl <- if (is.null(snapshots$polls)) NULL else keep(snapshots$polls)

  sn <- unique(rt[, c("season", "snap_date", "kind")])
  sn <- sn[order(sn$season, sn$snap_date), ]
  sn$w <- stats::ave(seq_len(nrow(sn)), sn$season, FUN = seq_along) - 1L
  key <- function(df) paste(df$season, df$snap_date)
  wof <- function(df) sn$w[match(key(df), key(sn))]

  r <- dplyr::left_join(rt, rs[, setdiff(names(rs), c("team", "conf", "kind"))], by = c("season", "snap_date", "team_id"))
  r <- r |>
    dplyr::group_by(season, snap_date) |>
    dplyr::mutate(prk = rank(-rating, ties.method = "first"),
                  rrk = if (all(is.na(wab))) NA_integer_ else rank(-wab, ties.method = "first", na.last = "keep"),
                  off_rk = rank(-off, ties.method = "first", na.last = "keep"), def_rk = rank(def, ties.method = "first", na.last = "keep"),
                  tempo_rk = rank(-tempo, ties.method = "first", na.last = "keep"),
                  sos_rk = if (all(is.na(sos))) NA_integer_ else rank(-sos, ties.method = "first", na.last = "keep"),
                  sor_rk = if (all(is.na(sor))) NA_integer_ else rank(sor, ties.method = "first", na.last = "keep"),
                  colley_rk = if (all(is.na(colley))) NA_integer_ else rank(-colley, ties.method = "first", na.last = "keep")) |>
    dplyr::ungroup()
  # polls: the latest AP / Coaches release on or before each snapshot (match_polls())
  if (!is.null(pl) && nrow(pl)) {
    pk <- function(p) { x <- pl[pl$poll == p & !is.na(pl$rank), ]; x$rank[match(paste(key(r), r$team_id), paste(key(x), x$team_id))] }
    r$ap <- pk("AP"); r$coaches <- pk("Coaches")
  } else r$ap <- r$coaches <- NA_integer_
  # the committee's seeds, shown from Selection Monday on
  seed <- dplyr::bind_rows(lapply(games[as.character(seasons)], function(g) {
    x <- g[g$ncaa %in% TRUE, ]
    unique(rbind(data.frame(season = x$season, team_id = x$home_id, seed = x$home_seed), data.frame(season = x$season, team_id = x$away_id, seed = x$away_seed)))
  }))
  r$seed <- if (nrow(seed)) seed$seed[match(paste(r$season, r$team_id), paste(seed$season, seed$team_id))] else NA_integer_
  sel <- stats::ave(as.numeric(r$snap_date) * (r$kind %in% "selection"), r$season, FUN = max)
  r$seed[as.numeric(r$snap_date) < sel | sel == 0] <- NA_integer_
  el <- dplyr::bind_rows(lapply(teams[as.character(seasons)], \(t) data.frame(team_id = t$team_id, elig = team_eligible(t))), .id = "season")
  r$elig <- el$elig[match(paste(r$season, r$team_id), paste(el$season, el$team_id))] %in% TRUE

  num <- function(x, d) round(x, d)
  ranks <- data.frame(
    s = r$season, w = wof(r), id = r$team_id, team = r$team, conf = r$conf, elig = r$elig,
    wins = r$wins, losses = r$losses, wab = num(r$wab, 2), wab_lo = num(r$wab_lo, 2), wab_hi = num(r$wab_hi, 2),
    rrk = r$rrk, rrk_lo = round(r$wab_rank_lo), rrk_hi = round(r$wab_rank_hi),
    pw = num(r$rating, 1), pw_lo = num(r$lo, 1), pw_hi = num(r$hi, 1), pw_sd = num(r$sd, 2),
    prk = r$prk, prk_lo = round(r$rank_lo), prk_hi = round(r$rank_hi),
    off = num(r$off, 1), def = num(r$def, 1), off_rk = r$off_rk, def_rk = r$def_rk, tempo = num(r$tempo, 1), tempo_rk = r$tempo_rk,
    sos = num(r$sos, 3), sos_rk = r$sos_rk, proj_wab = num(r$proj_wab, 2),
    p_field = num(r$p_field, 3), p_auto = num(r$p_auto, 3), p_al = num(r$p_at_large, 3), p_reg = num(r$p_conf_reg, 3),
    q1w = r$q1_w, q1l = r$q1_l, q2w = r$q2_w, q2l = r$q2_l, q3w = r$q3_w, q3l = r$q3_l, q4w = r$q4_w, q4l = r$q4_l,
    luck = num(r$luck, 2), sor_rk = r$sor_rk, colley_rk = r$colley_rk, ap = r$ap, coaches = r$coaches, seed = r$seed)

  pa$w <- wof(pa); gt$w <- wof(gt)
  snaps <- data.frame(s = sn$season, w = sn$w, date = format(sn$snap_date), kind = sn$kind, label = snap_label(sn$snap_date, sn$kind))
  m <- match(key(sn), key(pa)); mg <- match(key(sn), key(gt))
  snaps$n_games <- pa$n_games[m]
  snaps$hca <- round(pa$hca[m] * pa$mu_p[m] / 100, 2)            # points at league-average tempo
  snaps$hca100 <- round(pa$hca[m], 2)
  snaps$mu_p <- round(pa$mu_p[m], 1)
  snaps$sigma_game <- round(pa$sigma_game[m], 2); snaps$nu <- round(pa$nu[m], 1)
  snaps$bench_rank <- round(pa$bench_rank[m], 1)
  snaps$passed <- gt$pass[mg]
  snaps$field <- vapply(snaps$s, field_size, integer(1), cfg = cfg)

  # games: pregame predictions from the backtest (the latest snapshot before each game),
  # unplayed games from the latest snapshot of the season
  bt <- need(backtest$games[backtest$games$season %in% seasons, ], "pred_total")
  sides <- dplyr::bind_rows(lapply(games[as.character(seasons)], function(g) {
    g <- need(g[g$division %in% "d1", ], c("home_missing", "away_missing"))
    g$conf_game <- !is.na(g$home_conf) & g$home_conf == g$away_conf
    b <- bt[match(paste(g$season, g$game_id), paste(bt$season, bt$game_id)), ]
    latest <- max(rt$snap_date[rt$season == g$season[1]])
    lr <- rt[rt$season == g$season[1] & rt$snap_date == latest, ]
    lp <- pa[pa$season == g$season[1] & pa$snap_date == latest, ]
    rate <- function(id) lr$rating[match(id, lr$team_id)]
    temp <- function(id) lr$tempo_eff[match(id, lr$team_id)]
    tot <- function(id) lr$total_eff[match(id, lr$team_id)]
    poss <- lp$mu_p + temp(g$home_id) + temp(g$away_id)
    fut_m <- (rate(g$home_id) - rate(g$away_id) + lp$hca * game_site(g)) * poss / 100
    fut_wp <- stats::pt((rate(g$home_id) - rate(g$away_id) + lp$hca * game_site(g)) / (lp$sigma_game / sqrt(poss / 70)), df = lp$nu)
    fut_t <- poss * (lp$mu_t + tot(g$home_id) + tot(g$away_id)) / 100
    # what each result earned against the latest benchmark (posterior means)
    bench <- sort(lr$rating, decreasing = TRUE)[max(1, round(lp$bench_rank))]
    pb <- function(opp, v) stats::pt((bench - rate(opp) + lp$hca * v) / (lp$sigma_game / sqrt(dplyr::coalesce(g$poss_reg, 70) / 70)), df = lp$nu)
    played <- g$played %in% TRUE
    one <- function(home) {
      sg <- if (home) 1 else -1
      data.frame(s = g$season, game_id = g$game_id, date = format(g$game_date),
                 id = if (home) g$home_id else g$away_id, team = if (home) g$home else g$away,
                 opp_id = if (home) g$away_id else g$home_id, opp = if (home) g$away else g$home,
                 venue = ifelse(game_site(g) == 0, "N", ifelse(game_site(g) * sg > 0, "H", "A")),
                 conf_game = g$conf_game, tourn = g$tournament, ncaa_seed = if (home) g$home_seed else g$away_seed,
                 result = ifelse(played, ifelse((g$home_score - g$away_score) * sg > 0, "W", "L"), NA),
                 pts = ifelse(played, if (home) g$home_score else g$away_score, NA), opp_pts = ifelse(played, if (home) g$away_score else g$home_score, NA),
                 ot = g$ot %in% TRUE & played,
                 pre_margin = round(sg * b$pred_margin, 1), pre_wp = round(if (home) b$p_home else 1 - b$p_home, 3), pre_total = round(b$pred_total, 1),
                 line = round(-sg * g$spread, 1), ou = g$total_line,
                 fut_margin = ifelse(played, NA, round(sg * fut_m, 1)), fut_wp = ifelse(played, NA, round(if (home) fut_wp else 1 - fut_wp, 3)),
                 fut_total = ifelse(played, NA, round(fut_t, 1)),
                 missing = round(if (home) g$home_missing else g$away_missing, 2),
                 wab_game = ifelse(played, round(((g$home_score - g$away_score) * sg > 0) - pb(if (home) g$away_id else g$home_id, sg * game_site(g)), 2), NA))
    }
    rbind(one(TRUE), one(FALSE))
  }))
  sides <- sides[!is.na(sides$id), ]

  tm <- dplyr::bind_rows(lapply(teams[as.character(seasons)], \(t) t[, c("team_id", "team", "conf")]))
  tm <- tm[!duplicated(tm$team_id, fromLast = TRUE), ]
  ab <- tryCatch(fetch_espn_teams(), error = \(e) data.frame(id = integer(), abbr = character(), short = character()))
  teams_out <- data.frame(id = tm$team_id, team = tm$team, conf = tm$conf,
                          abbr = ab$abbr[match(tm$team_id, ab$id)], short = ab$short[match(tm$team_id, ab$id)],
                          logo = sprintf("https://a.espncdn.com/i/teamlogos/ncaa/500/%d.png", tm$team_id),
                          logo_dark = sprintf("https://a.espncdn.com/i/teamlogos/ncaa/500-dark/%d.png", tm$team_id))

  list(ranks = ranks, snaps = snaps, games = sides, teams = teams_out,
       config = list(generated = format(Sys.time(), "%Y-%m-%d %H:%M %Z"), seasons = seasons,
                     live = max(seasons) == current_cbb_season() && !season_final(max(seasons))))
}
