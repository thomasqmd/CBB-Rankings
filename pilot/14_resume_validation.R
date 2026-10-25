# ==============================================================================
# Resume validation 2016-2026 (no 2020 tournament): at Selection Monday, how many of the
# committee's at-large teams our WAB picks (the actual automatic bids given), how our WAB and
# power ranks follow the seed lines, and how our WAB ranks against Torvik's WAB (his time-machine
# ratings for Selection Sunday). NET needs a cbbdata account (CBD_USER / CBD_PW), so it is left out.
#   Rscript pilot/14_resume_validation.R      -> pilot/out/14_resume_validation.rds
# ==============================================================================

suppressMessages({ library(targets); library(dplyr) })
tar_source("R")
snaps <- tar_read(snapshots)
champs <- tar_read(champions_db)
# Field teams missing from the game data: the 2017 First Four losers (in neither ESPN nor CBBD)
# and VCU in 2021 (selected, withdrew before playing)
EXTRA <- data.frame(season = c(2017L, 2017L, 2021L), team_id = c(2443L, 154L, 2670L), seed = c(16L, 11L, 10L))

out <- lapply(setdiff(2016:2026, 2020), function(s) {
  g <- tar_read_raw(paste0("games_", s)); tm <- tar_read_raw(paste0("teams_", s))
  x <- g[g$ncaa, ]
  field <- unique(rbind(data.frame(team_id = x$home_id, seed = x$home_seed), data.frame(team_id = x$away_id, seed = x$away_seed),
                        EXTRA[EXTRA$season == s, c("team_id", "seed")]))
  field$conf <- tm$conf[match(field$team_id, tm$team_id)]
  ch <- champs[champs$season == s, ]
  # automatic bids: the conference champion if it is in the field, else the conference's only field team
  field$auto <- FALSE
  for (cf in unique(field$conf)) {
    k <- which(field$conf == cf)
    c1 <- intersect(ch$team_id[ch$conf == cf], field$team_id[k])
    if (length(c1)) field$auto[field$team_id == c1[1]] <- TRUE
    else if (length(k) == 1) field$auto[k] <- TRUE
  }
  sel <- snaps$resume[snaps$resume$season == s & snaps$resume$kind == "selection", ]
  rat <- snaps$ratings[snaps$ratings$season == s & snaps$ratings$kind == "selection", ]
  if (!nrow(sel)) return(NULL)
  elig <- tm$team_id[team_eligible(tm)]
  n_al <- sum(!field$auto)
  pool <- sel[sel$team_id %in% elig & !(sel$team_id %in% field$team_id[field$auto]), ]
  pick <- pool$team_id[order(-pool$wab)][seq_len(n_al)]
  pick_pow <- rat$team_id[rat$team_id %in% pool$team_id][order(-rat$rating[rat$team_id %in% pool$team_id])][seq_len(n_al)]
  al <- field$team_id[!field$auto]
  # Torvik WAB on Selection Sunday
  snap <- unique(sel$snap_date)
  f <- fetch_torvik_tm(snap - 1)
  tv <- if (!is.na(f)) {
    z <- jsonlite::fromJSON(gzcon(file(f, "rb")))
    torvik_team_ids(data.frame(team = z[, 2], wab = as.numeric(z[, 42])), tm)
  }
  m <- if (!is.null(tv)) merge(sel[, c("team_id", "wab")], tv[, c("team_id", "wab")], by = "team_id", suffixes = c("", "_torvik"))
  fs <- merge(field, sel[, c("team_id", "wab")], by = "team_id")
  fs <- merge(fs, rat[, c("team_id", "rating")], by = "team_id")
  data.frame(season = s, field = nrow(field), at_large = n_al, auto = sum(field$auto),
             overlap_wab = sum(pick %in% al), overlap_power = sum(pick_pow %in% al),
             missed = paste(tm$team[match(setdiff(al, pick), tm$team_id)], collapse = "; "),
             wrongly_in = paste(tm$team[match(setdiff(pick, al), tm$team_id)], collapse = "; "),
             seed_cor_wab = stats::cor(fs$seed, -fs$wab, method = "spearman"),
             seed_cor_power = stats::cor(fs$seed, -fs$rating, method = "spearman"),
             torvik_wab_cor = if (!is.null(m)) stats::cor(m$wab, m$wab_torvik, method = "spearman") else NA_real_,
             torvik_n = if (!is.null(m)) nrow(m) else 0L)
})
tab <- bind_rows(out)
print(tab[, setdiff(names(tab), c("missed", "wrongly_in"))], digits = 3)
cat(sprintf("\nmean at-large overlap: WAB %.1f / %.1f, power %.1f\n", mean(tab$overlap_wab), mean(tab$at_large), mean(tab$overlap_power)))
for (i in seq_len(nrow(tab))) cat(tab$season[i], " missed:", tab$missed[i], " | picked instead:", tab$wrongly_in[i], "\n")
saveRDS(tab, "pilot/out/14_resume_validation.rds")
