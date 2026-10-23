# ==============================================================================
# _targets.R — CBB Bayesian Rankings
#
#   sync (ESPN bulk + CBBD games/lines + Torvik -> data/cbb.duckdb)
#     -> data_<s>                 one season's games, shots, free throws, Torvik preseason
#     -> shotmodel_<s>            make model fit on the SHOT_MODEL_SEASONS before s (no leakage)
#     -> games_<s>                games with both signals (lux100, eff100)
#     -> prior_<s>                preseason prior: our final ratings of s-1 blended with Torvik's
#     -> dates_<s>                snapshot dates (opening night, Mondays, the day after the final)
#     -> inputs_<s> [per date]    Stan inputs
#     -> snaps_<s>  [per date]    ratings, resume, predictions, parameters, gates
#   -> snapshots -> backtest, coverage
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
  list(
    tar_target_raw(paste0("data_", s), bquote({ sync; read_season(.(s), db_path = .(DB_PATH)) })),
    tar_target_raw(paste0("shotmodel_", s), bquote(fit_shot_model(.(data_list(train, "shots")), seasons = .(train)))),
    tar_target_raw(paste0("games_", s), bquote(season_games(.(sym("data", s)), .(sym("shotmodel", s)), .(ft_hist)))),
    tar_target_raw(paste0("teams_", s), bquote(team_conferences(.(sym("games", s))))),
    tar_target_raw(paste0("prior_", s), bquote(build_prior(.(prev), .(sym("data", s))$torvik_pre, .(sym("teams", s)), cfg, torvik_names))),
    tar_target_raw(paste0("dates_", s), bquote(limit_snaps(
      snapshot_dates(.(sym("games", s)), .(s), cfg = cfg, final_only = .(first)), .(MAX_SNAPS)))),
    tar_target_raw(paste0("inputs_", s),
      bquote(snapshot_input(.(sym("games", s)), .(sym("dates", s)), .(sym("teams", s)), .(sym("prior", s)), cfg)),
      pattern = bquote(map(.(sym("dates", s)))), iteration = "list"),
    tar_target_raw(paste0("snaps_", s),
      bquote(run_snapshot(.(sym("inputs", s)), season = .(s), kind = .(sym("inputs", s))$kind, cfg = cfg)),
      pattern = bquote(map(.(sym("inputs", s)))), iteration = "list")
  )
}

list(
  tar_target(stan_file, "stan/power.stan", format = "file"),
  tar_target(torvik_names, "data/torvik_names.csv", format = "file"),
  # Compiles the model once here, so parallel fits never race to rebuild the same executable
  tar_target(cfg, {
    cmdstanr::cmdstan_model(stan_file)
    model_config(stan_file = stan_file)
  }),
  # Refreshes live seasons each run (final seasons make no requests); returns a data fingerprint
  # so downstream targets rerun only when a season's data changed
  tar_target(sync, sync_all(SEASONS, db_path = DB_PATH), cue = tar_cue(mode = "always")),

  lapply(SEASONS, season_targets),

  tar_target_raw("snapshots", as.call(c(quote(combine_snapshots), lapply(SEASONS, \(s) sym("snaps", s))))),
  tar_target(backtest, run_backtest(snapshots$predictions[snapshots$predictions$season >= FIRST_SEASON, ])),
  tar_target_raw("coverage", bquote(coverage_report(
    .(as.call(c(quote(list), setNames(lapply(SEASONS, \(s) sym("games", s)), SEASONS)))),
    .(as.call(c(quote(list), setNames(lapply(SEASONS, \(s) sym("prior", s)), SEASONS)))),
    .(as.call(c(quote(list), setNames(lapply(SEASONS, \(s) sym("teams", s)), SEASONS))))
  )))
)
