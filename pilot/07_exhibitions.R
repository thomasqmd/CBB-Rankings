# Pilot step 7: exhibition games from school athletics sites (2025-26), on a random sample of
# D1 schools. Measures each link of the chain: ncaa.com match -> site -> parsed schedule -> games.
source("R/01_ingest.R"); source("R/02_prep.R"); source("pilot/exh_scraper.R")
suppressMessages(library(dplyr))
games <- readRDS("data/derived/pilot_games.rds")$`2026`
teams <- team_conferences(games)
n_sample <- as.integer(Sys.getenv("EXH_SAMPLE", "40"))

sch <- ncaa_schools()
sch$key <- name_key(sch$name)
teams$key <- name_key(teams$team)
cw <- left_join(teams, select(sch, key, slug), by = "key", relationship = "many-to-one")
cat("D1 teams matched to an ncaa.com slug:", sum(!is.na(cw$slug)), "of", nrow(cw), "\n")

set.seed(7)
smp <- cw[!is.na(cw$slug), ]
smp <- smp[sample(nrow(smp), min(n_sample, nrow(smp))), ]
smp$site <- vapply(smp$slug, school_site, character(1))
out <- lapply(seq_len(nrow(smp)), function(i) {
  if (is.na(smp$site[i])) return(list(status = "no_site", ex = NULL))
  school_exhibitions(smp$site[i], 2026)
})
smp$status <- vapply(out, `[[`, character(1), "status")
smp$n_exh <- vapply(out, \(o) if (is.null(o$ex)) 0L else nrow(o$ex), integer(1))
ex <- bind_rows(lapply(seq_along(out), \(i) if (!is.null(out[[i]]$ex)) data.frame(team = smp$team[i], team_id = smp$team_id[i], out[[i]]$ex)))
if (nrow(ex)) {
  ex$opp_id <- teams$team_id[match(name_key(ex$opponent), teams$key)]
  ex$opp_level <- ifelse(is.na(ex$opp_id), "non-D1 (or unmatched)", "D1")
}
cov <- smp |> count(status, name = "schools")
print(cov); cat("sidearm schools with >= 1 exhibition:", sum(smp$status == "sidearm" & smp$n_exh > 0), "of", sum(smp$status == "sidearm"), "\n")
print(ex |> select(team, date, venue, opponent, opp_level, result, pts, opp_pts), row.names = FALSE)
saveRDS(list(sample = smp, exhibitions = ex), "data/derived/pilot_exhibitions.rds")
writeLines(c("# Exhibition scrape pilot (2025-26)", "",
             sprintf("D1 teams matched to an ncaa.com school slug: %d of %d.", sum(!is.na(cw$slug)), nrow(cw)),
             sprintf("Random sample of %d matched schools; one request per second, pages cached in data/raw/sites/.", nrow(smp)), "",
             "## Coverage", "", knitr::kable(cov), "",
             sprintf("Sidearm schools with at least one exhibition listed: %d of %d.", sum(smp$status == "sidearm" & smp$n_exh > 0), sum(smp$status == "sidearm")), "",
             "## Exhibitions found", "", if (nrow(ex)) knitr::kable(select(ex, team, date, venue, opponent, opp_level, result, pts, opp_pts)) else "None.", "",
             "## Schools", "", knitr::kable(select(smp, team, conf, slug, site, status, n_exh))), "pilot/out/08_exhibitions.md")
