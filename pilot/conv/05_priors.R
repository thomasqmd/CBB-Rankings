# Convergence pilot, step 4.
# A: informative priors on sigma_conf, sigma_team, tau (CFB's fix for the same funnel), +/- longer chains.
#    Prior centres are this season's posterior means (in-sample; the full build pools 2015-2025 refits).
# B: preseason prior source: our 2024-25 final rating vs Torvik's preseason rating (2025-11-02) vs their mean.
source("R/01_ingest.R"); source("R/02_prep.R"); source("R/03_model.R")
suppressMessages(library(dplyr))
games <- readRDS("data/derived/pilot_games.rds")$`2026`
own <- readRDS("data/derived/prior_2025.rds"); teams <- team_conferences(games)
invisible(cmdstanr::cmdstan_model("stan/power.stan", quiet = TRUE))

# Torvik preseason AdjEM (per 100), name-matched, centred on the matched D1 mean
hdr <- make.unique(names(read.csv("data/raw/torvik/team_results_2026.csv", check.names = FALSE, nrows = 1)))
tv <- as.data.frame(jsonlite::fromJSON(gzcon(file("data/raw/torvik/tm_20251102.json.gz", "rb"))), stringsAsFactors = FALSE)
names(tv) <- hdr[seq_len(ncol(tv))]
norm <- function(x) { x <- tolower(x); x <- gsub("\\bst\\.$|\\bst\\.(?= )", "state", x, perl = TRUE); gsub("\\s+", " ", trimws(gsub("[^a-z ]", "", x))) }
tv <- tv |> transmute(key = norm(team), em = as.numeric(adjoe) - as.numeric(adjde))
tvm <- teams |> mutate(key = norm(team)) |> inner_join(tv, by = "key") |> mutate(em = em - mean(em))
cat("Torvik preseason matched:", nrow(tvm), "of", nrow(teams), "| cor with own prior:",
    round(cor(tvm$em, own$prev_dev[match(tvm$team_id, own$team_id)], use = "c"), 3), "\n")
prior_from <- function(src) {
  p <- teams |> select(team_id) |> left_join(own, by = "team_id") |> left_join(select(tvm, team_id, em), by = "team_id")
  p$prev_dev <- switch(src, own = p$prev_dev,
                       torvik = dplyr::coalesce(p$em, p$prev_dev),
                       blend = ifelse(is.na(p$em), p$prev_dev, ifelse(is.na(p$prev_dev), p$em, (p$em + p$prev_dev) / 2)))
  p$prev_sd <- dplyr::coalesce(p$prev_sd, 3)
  p[!is.na(p$prev_dev), c("team_id", "prev_dev", "prev_sd")]
}

tight <- list(sigma_conf_prior = c(4.5, 0.7), sigma_team_prior = c(6.4, 0.6), tau_prior = c(0.6, 0.1))
cfgs <- list(base = model_config(),
             tight = do.call(model_config, tight),
             tight_long = do.call(model_config, c(tight, list(warmup = 1000, sampling = 1000))))
snapsA <- as.Date(c("2025-11-10", "2025-11-24", "2025-12-08", "2025-12-22", "2026-01-05", "2026-02-02", "2026-03-02"))
snapsB <- snapsA[1:4]
jobs <- rbind(expand.grid(part = "A", setup = c("tight", "tight_long"), prior = "own", snap = snapsA, stringsAsFactors = FALSE),
              expand.grid(part = "B", setup = "tight", prior = c("torvik", "blend"), snap = snapsB, stringsAsFactors = FALSE))
res <- parallel::mclapply(seq_len(nrow(jobs)), function(j) {
  cfg <- cfgs[[jobs$setup[j]]]; sd <- jobs$snap[j]
  inp <- prepare_input(games, sd, teams, prior_from(jobs$prior[j]), cfg)
  f <- fit_snapshot(inp, cfg)
  new <- games[games$game_date >= sd & games$game_date < sd + 14 & !is.na(games$spread), ]
  pr <- predict_games(f, inp, new); act <- pr$home_score - pr$away_score
  data.frame(jobs[j, ], t(f$gates), secs = f$secs, worst = f$worst$variable[1], b_prev = mean(f$par$b_prev),
             sigma_conf = mean(f$par$sigma_conf), tau = mean(f$par$tau),
             n_pred = nrow(pr), mae = mean(abs(act - pr$pred_margin)), mae_line = mean(abs(act + pr$spread)),
             logloss = -mean(ifelse(act > 0, log(pr$p_home), log(1 - pr$p_home))))
}, mc.cores = 3)
bad <- vapply(res, inherits, logical(1), "try-error"); if (any(bad)) { print(res[bad][[1]]); stop("failed") }
rows <- bind_rows(res) |> mutate(pass = max_rhat <= 1.01 & min_ess >= 400 & divergences == 0 & min_ebfmi > 0.2)
saveRDS(rows, "pilot/conv/05_priors.rds")
print(as.data.frame(rows |> filter(part == "A") |> group_by(setup) |> summarise(pass = sum(pass), fits = n(), min_ess = min(min_ess),
  max_rhat = max(max_rhat), div = sum(divergences), secs = mean(secs), mae = weighted.mean(mae, n_pred), logloss = weighted.mean(logloss, n_pred))))
print(as.data.frame(rows |> select(part, setup, prior, snap, max_rhat, min_ess, divergences, worst, secs, b_prev, mae, mae_line, logloss)), digits = 3)
