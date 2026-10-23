# Pilot step 4: resume (WAB) at Selection Sunday 2026 vs the real field and Torvik's WAB.
# Fit on all games before Monday 2026-03-16 (conference finals on Sunday included).
source("R/01_ingest.R"); source("R/02_prep.R"); source("R/03_model.R"); source("R/04_resume.R")
suppressMessages(library(dplyr))
games <- readRDS("data/derived/pilot_games.rds")$`2026`
prev <- readRDS("data/derived/prior_2025.rds")
nd <- readRDS("data/derived/pilot_nd_games.rds")$`2026`
teams <- team_conferences(games)
cfg <- model_config(eff_col = "lux100", dynamic = TRUE, sampling = 1000)
inp <- prepare_input(games, as.Date("2026-03-16"), teams, prev, cfg, nd)
fit_file <- "data/derived/pilot_fit_20260316.rds"
fit <- if (file.exists(fit_file)) readRDS(fit_file) else { f <- fit_snapshot(inp, cfg); saveRDS(f, fit_file); f }
cat("fit", round(fit$secs), "s; gates:", paste(names(fit$gates), round(fit$gates, 3)), "\n")

# The real field: NCAA tournament teams; automatic bids = conference tournament champions
ncaa <- games[games$ncaa, ]
field <- unique(c(ncaa$home_id, ncaa$away_id))
ct <- games |>
  filter(game_type == "TRNMNT", !ncaa, home_conf == away_conf, game_date < as.Date("2026-03-16"),
         is.na(tournament) | tournament != "NIT") |>
  group_by(home_conf) |> slice_max(game_date, n = 1, with_ties = FALSE) |> ungroup() |>
  mutate(champ = ifelse(home_score > away_score, home_id, away_id))
auto <- intersect(ct$champ, field)
at_large <- setdiff(field, auto)
cat("field", length(field), "| conf champs found", nrow(ct), "| auto bids in field", length(auto), "| at-large", length(at_large), "\n")
missing_conf <- setdiff(unique(teams$conf[teams$team_id %in% field]), ct$home_conf)
if (length(missing_conf)) cat("conferences without a detected champion:", missing_conf, "\n")

results <- lapply(c(35, 45, 55), function(b) {
  wab <- wab_draws(fit, inp, bubble = b)
  s <- summarise_wab(wab, inp, auto_bids = auto, n_at_large = length(at_large))
  pick <- s$team_id[!s$auto_bid][seq_along(at_large)]
  list(b = b, s = s, hit = length(intersect(pick, at_large)))
})
pw <- summarise_ratings(fit, inp)
pick_power <- pw$team_id[!(pw$team_id %in% auto)][seq_along(at_large)]

# Torvik WAB on Selection Monday (name-matched to ESPN teams)
hdr <- make.unique(names(read.csv("data/raw/torvik/team_results_2026.csv", check.names = FALSE, nrows = 1)))
tv <- jsonlite::fromJSON(gzcon(file("data/raw/torvik/tm_20260316.json.gz", "rb")))
tv <- as.data.frame(tv, stringsAsFactors = FALSE); names(tv) <- hdr[seq_len(ncol(tv))]
norm <- function(x) {
  x <- tolower(x); x <- gsub("\\bst\\.$|\\bst\\.(?= )", "state", x, perl = TRUE)
  x <- gsub("[^a-z ]", "", x); gsub("\\s+", " ", trimws(x))
}
tv$key <- norm(tv$team); s45 <- results[[2]]$s; s45$key <- norm(s45$team)
m <- inner_join(s45, transmute(tv, key, torvik_wab = as.numeric(WAB)), by = "key")
pick_tv <- m |> filter(!auto_bid) |> arrange(desc(torvik_wab)) |> slice_head(n = length(at_large)) |> pull(team_id)

summ <- data.frame(
  ranking = c(sprintf("WAB, bubble = #%d", sapply(results, `[[`, "b")), "Power rating", "Torvik WAB (name-matched)"),
  at_large_hits = c(sapply(results, `[[`, "hit"), length(intersect(pick_power, at_large)), length(intersect(pick_tv, at_large))),
  of = length(at_large))
print(summ)
cat("Torvik teams matched:", nrow(m), "of", nrow(s45), "; cor(WAB, Torvik WAB) =", round(cor(m$wab, m$torvik_wab), 3), "\n")
bub <- s45 |> filter(!auto_bid) |> mutate(al_rank = row_number(), selected = team_id %in% at_large) |>
  filter(al_rank >= 28, al_rank <= 46) |> select(al_rank, team, conf, wab, wab_lo, wab_hi, p_at_large, selected)
print(bub, digits = 3)
misses <- s45 |> filter(!auto_bid) |> mutate(al_rank = row_number(), selected = team_id %in% at_large) |>
  filter(xor(al_rank <= length(at_large), selected)) |> select(al_rank, team, conf, wab, p_at_large, selected)
writeLines(c("# Resume pilot: Selection Sunday 2026", "",
             sprintf("Field %d teams; %d automatic bids detected; %d at-large.", length(field), length(auto), length(at_large)), "",
             sprintf("Fit: %d s; %s", round(fit$secs), paste(names(fit$gates), round(fit$gates, 3), collapse = ", ")), "",
             "## At-large picks matched (top-N non-champions)", "", knitr::kable(summ), "",
             sprintf("WAB vs Torvik WAB: r = %.3f over %d name-matched teams.", cor(m$wab, m$torvik_wab), nrow(m)), "",
             "## Bubble (bubble = #45)", "", knitr::kable(bub, digits = 2), "",
             "## Disagreements with the committee", "", knitr::kable(misses, digits = 2)), "pilot/out/04_wab.md")
saveRDS(list(summary = s45, power = pw, field = field, auto = auto), "data/derived/pilot_wab.rds")
