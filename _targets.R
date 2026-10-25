# ==============================================================================
# _targets.R — CBB Bayesian Rankings
#
#   sync (ESPN bulk + CBBD games/lines + Torvik -> data/cbb.duckdb)
#     -> data_<s>                 one season's games, shots, free throws, Torvik preseason
#     -> shotmodel_<s>            make model fit on the SHOT_MODEL_SEASONS before s (no leakage)
#     -> games_<s>                games with both signals (lux100, eff100) and the venue (`site`)
#     -> teams_<s>                D1 teams: ESPN membership, conference, NCAA-tournament eligibility (transitions, bans)
#     -> roster_<s>               roster features from Torvik's player tables (returning, transfers, freshmen)
#     -> prior_<s>                preseason prior: our final ratings of s-1 and Torvik's, with the roster
#                                 regression fit on earlier seasons (cfg$prior_method)
#     -> tourney_<s>              conference-tournament sizes (last season's), for the season simulation
#     -> dates_<s>                snapshot dates (opening night, Mondays, the day after the final)
#     -> champs_<s>               conference tournament champions (champions_db), for the automatic bids
#     -> inputs_<s> [per date]    Stan inputs
#     -> snaps_<s>  [per date]    ratings, resume, predictions, parameters, gates
#     -> polls_<s>                AP and Coaches polls matched to the snapshot dates (polls_db)
#     -> torvik_<s>               Torvik's ratings the day before each snapshot (time machine), for the backtest
#   -> snapshots -> backtest (vs the closing line and total, and Torvik), coverage, venues (recoded /
#      disputed sites), shot_calibration (make model by family and season)
#   -> dashboard_data -> docs/index.html (docs/dashboard.qmd) and the reports in docs/reports/
#
# Seasons: PRIOR_SEASON (CBB_FIRST_SEASON - 1) is fit once, at its end, for the carry-over;
# CBB_FIRST_SEASON (default 2015) through CBB_LAST_SEASON (default the current season) get every
# snapshot. CBB_MAX_SNAPS (development) keeps opening night plus the last n - 1 dates per season.
# ==============================================================================

library(targets)
library(tarchetypes)

# Core budget (CBB_CORES, default all cores). Each fit runs 4 chains, so CORES / 4 fits at once.
CORES <- as.integer(Sys.getenv("CBB_CORES", parallel::detectCores()))
FIT_WORKERS <- max(1L, CORES %/% 4L)

tar_option_set(
  packages = c("dplyr", "tidyr", "posterior", "cmdstanr"),
  memory = "transient",
  garbage_collection = TRUE,
  controller = crew::crew_controller_local(workers = FIT_WORKERS, seconds_idle = 60)
)

tar_source("R")

FIRST_SEASON <- as.integer(Sys.getenv("CBB_FIRST_SEASON", "2015"))
LAST_SEASON <- as.integer(Sys.getenv("CBB_LAST_SEASON", current_cbb_season()))
MAX_SNAPS <- as.integer(Sys.getenv("CBB_MAX_SNAPS", "0"))
PRIOR_SEASON <- FIRST_SEASON - 1L
SEASONS <- PRIOR_SEASON:LAST_SEASON
DB_PATH <- "data/cbb.duckdb"

sym <- function(x, s) as.symbol(paste0(x, "_", s))
data_list <- function(seasons, field) {
  as.call(c(quote(dplyr::bind_rows), lapply(seasons, \(k) call("$", sym("data", k), as.symbol(field)))))
}

season_targets <- function(s) {
  first <- s == PRIOR_SEASON
  train <- intersect((s - SHOT_MODEL_SEASONS):(s - 1L), SEASONS)
  if (!length(train)) train <- s          # the very first season trains on itself (flagged in coverage)
  ft_hist <- if ((s - 1L) %in% SEASONS) call("$", sym("data", s - 1L), quote(free_throws)) else quote(NULL)
  prev <- if (first) quote(NULL) else call("season_final_prior", sym("snaps", s - 1L))
  prev2 <- if ((s - 2L) %in% SEASONS) call("season_final_prior", sym("snaps", s - 2L)) else quote(NULL)
  # roster regression history: earlier seasons' features with their final ratings
  hist <- as.call(c(quote(dplyr::bind_rows), lapply(if (s > FIRST_SEASON) FIRST_SEASON:(s - 1L) else integer(),
                                                    \(k) call("roster_history", sym("prior", k), sym("snaps", k)))))
  tour_from <- if (first) s else if (s == 2021L && 2019L %in% SEASONS) 2019L else s - 1L   # 2020's tournaments were cut short
  list(
    tar_target_raw(paste0("data_", s), bquote({ sync; read_season(.(s), db_path = .(DB_PATH)) })),
    tar_target_raw(paste0("shotmodel_", s), bquote(fit_shot_model(.(data_list(train, "shots")), seasons = .(train)))),
    tar_target_raw(paste0("games_", s), bquote(season_games(.(sym("data", s)), .(sym("shotmodel", s)), .(ft_hist)))),
    tar_target_raw(paste0("teams_", s), bquote(season_teams(.(sym("data", s))$d1_teams, .(sym("games", s)), live = !season_final(.(s)),
                                                           bans = read_bans(bans_file)))),
    if (!first) tar_target_raw(paste0("roster_", s), bquote(roster_features(.(s), .(sym("teams", s)), .(sym("teams", s - 1L)), torvik_names,
      recruits = if (!season_final(.(s))) read_cbbd_recruits(.(s), cbbd_team_ids(.(s), .(sym("games", s)))) else NULL))),
    tar_target_raw(paste0("prior_", s), if (first) bquote(build_prior(NULL, .(sym("data", s))$torvik_pre, .(sym("teams", s)), cfg, torvik_names))
      else bquote(build_prior(.(prev), .(sym("data", s))$torvik_pre, .(sym("teams", s)), cfg, torvik_names,
                              roster = .(sym("roster", s)), history = .(hist), prev2 = .(prev2)))),
    tar_target_raw(paste0("tourney_", s), bquote(tourney_sizes(.(sym("games", tour_from))))),
    tar_target_raw(paste0("dates_", s), bquote(limit_snaps(
      snapshot_dates(.(sym("games", s)), .(s), cfg = cfg, final_only = .(first)), .(MAX_SNAPS)))),
    tar_target_raw(paste0("champs_", s), bquote(champions_db[champions_db$season == .(s), c("conf", "game_date", "team_id")])),
    tar_target_raw(paste0("inputs_", s),
      bquote(snapshot_input(.(sym("games", s)), .(sym("dates", s)), .(sym("teams", s)), .(sym("prior", s)), cfg, .(sym("champs", s)),
                            .(sym("tourney", s)))),
      pattern = bquote(map(.(sym("dates", s)))), iteration = "list"),
    if (!first) tar_target_raw(paste0("torvik_", s), bquote(torvik_snapshots(.(sym("dates", s)), .(sym("teams", s)), .(s), torvik_names))),
    tar_target_raw(paste0("polls_", s), bquote(match_polls(polls_db[polls_db$season == .(s), ], .(sym("dates", s))))),
    tar_target_raw(paste0("snaps_", s),
      bquote(run_snapshot(.(sym("inputs", s)), season = .(s), kind = .(sym("inputs", s))$kind, cfg = cfg)),
      pattern = bquote(map(.(sym("inputs", s)))), iteration = "list")
  )
}

list(
  tar_target(stan_file, "stan/power.stan", format = "file"),
  tar_target(torvik_names, "data/torvik_names.csv", format = "file"),
  tar_target(bans_file, "data/postseason_bans.csv", format = "file"),
  # Compiles the model once here, so parallel fits never race to rebuild the same executable
  tar_target(cfg, {
    cmdstanr::cmdstan_model(stan_file)
    model_config(stan_file = stan_file)
  }),
  # Refreshes live seasons each run (final seasons make no requests); returns a data fingerprint
  # so downstream targets rerun only when a season's data changed
  tar_target(sync, sync_all(SEASONS, db_path = DB_PATH), cue = tar_cue(mode = "always")),
  # The polls and champions tables are outside the sync fingerprint (a new poll should not refit
  # anything), so they are reread every run; polls_<s> and champs_<s> rerun only when they changed
  tar_target(polls_db, { sync; read_polls(SEASONS, db_path = DB_PATH) }, cue = tar_cue(mode = "always")),
  tar_target(champions_db, { sync; read_champions(SEASONS, db_path = DB_PATH) }, cue = tar_cue(mode = "always")),

  lapply(SEASONS, season_targets),

  tar_target_raw("snapshots", as.call(c(quote(combine_snapshots), lapply(SEASONS, \(s) sym("snaps", s)),
    list(polls = as.call(c(quote(dplyr::bind_rows), lapply(SEASONS, \(s) sym("polls", s)))))))),
  tar_target_raw("backtest", bquote(run_backtest(snapshots$predictions[snapshots$predictions$season >= FIRST_SEASON, ],
    .(as.call(c(quote(dplyr::bind_rows), lapply(setdiff(SEASONS, PRIOR_SEASON), \(s) sym("torvik", s))))),
    .(as.call(c(quote(dplyr::bind_rows), lapply(SEASONS, \(s) call("game_outcomes", sym("games", s))))))))),
  tar_target_raw("shot_calibration", as.call(c(quote(dplyr::bind_rows), lapply(setdiff(SEASONS, PRIOR_SEASON),
    \(s) call("shot_model_calibration", sym("data", s), sym("shotmodel", s), s))))),
  tar_target_raw("venues", as.call(c(quote(dplyr::bind_rows), lapply(SEASONS, \(s) call("venue_report", sym("games", s)))))),
  tar_target_raw("coverage", bquote(coverage_report(
    .(as.call(c(quote(list), setNames(lapply(SEASONS, \(s) sym("games", s)), SEASONS)))),
    .(as.call(c(quote(list), setNames(lapply(SEASONS, \(s) sym("prior", s)), SEASONS)))),
    .(as.call(c(quote(list), setNames(lapply(SEASONS, \(s) sym("teams", s)), SEASONS))))
  ))),
  # The dashboard shows the last DASH_SEASONS seasons
  tar_target_raw("dashboard_data", bquote(build_dashboard_data(snapshots,
    .(as.call(c(quote(list), setNames(lapply(utils::tail(SEASONS, DASH_SEASONS), \(s) sym("games", s)), utils::tail(SEASONS, DASH_SEASONS))))),
    .(as.call(c(quote(list), setNames(lapply(utils::tail(SEASONS, DASH_SEASONS), \(s) sym("teams", s)), utils::tail(SEASONS, DASH_SEASONS))))),
    backtest, cfg))),
  # The stylesheet and logos are tracked too, so editing only them re-renders the dashboard
  tar_quarto(dashboard, path = "docs/dashboard.qmd", quiet = TRUE,
             extra_files = c("docs/styles/cbb.css", "docs/logos/TRlogo.svg", "docs/logos/TRlogo-dark.svg")),
  tar_quarto(report_season, path = "docs/reports/season_retro.qmd", quiet = TRUE),
  tar_quarto(report_diagnostics, path = "docs/reports/model_diagnostics.qmd", quiet = TRUE)
)
