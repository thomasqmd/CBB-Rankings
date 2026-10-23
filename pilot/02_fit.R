# Pilot step 2: single-snapshot fits. 2024-25 full season (no carry-over) -> prior for 2025-26;
# then 2025-26 at Selection Sunday (2026-03-15) under four variants, with timing and gates.
source("R/01_ingest.R"); source("R/02_prep.R"); source("R/03_model.R")
suppressMessages(library(dplyr))
games <- readRDS("data/derived/pilot_games.rds")
nd <- readRDS("data/derived/pilot_nd_games.rds")
cmdstanr::cmdstan_model("stan/power.stan", quiet = TRUE)   # compile once

t25 <- team_conferences(games$`2025`)
inp25 <- prepare_input(games$`2025`, as.Date("2025-05-01"), t25, NULL, model_config(dynamic = FALSE), nd$`2025`)
f25 <- fit_snapshot(inp25, model_config(dynamic = FALSE))
prev <- final_prior(f25, inp25)
saveRDS(prev, "data/derived/prior_2025.rds")
cat("2024-25 final fit:", round(f25$secs), "s\n"); print(round(f25$gates, 3))
print(head(summarise_ratings(f25, inp25), 10), digits = 3)

variants <- list(
  margin_static = model_config(use_eff = FALSE, dynamic = FALSE),
  shotq_static  = model_config(eff_col = "eff100", dynamic = FALSE),
  lux_static    = model_config(eff_col = "lux100", dynamic = FALSE),
  lux_dynamic   = model_config(eff_col = "lux100", dynamic = TRUE)
)
t26 <- team_conferences(games$`2026`)
ss <- as.Date("2026-03-15")
res <- lapply(names(variants), function(v) {
  inp <- prepare_input(games$`2026`, ss, t26, prev, variants[[v]], nd$`2026`)
  f <- fit_snapshot(inp, variants[[v]])
  list(inp = inp, fit = f)
})
names(res) <- names(variants)
saveRDS(res, "data/derived/pilot_selection_sunday.rds")

tab <- do.call(rbind, lapply(names(res), function(v) {
  f <- res[[v]]$fit
  data.frame(variant = v, secs = round(f$secs), t(round(f$gates, 3)), t(round(colMeans(f$par), 2)))
}))
print(tab)
top <- summarise_ratings(res$lux_dynamic$fit, res$lux_dynamic$inp)
print(head(top, 25), digits = 3)
writeLines(c("# Pilot fits at Selection Sunday 2026", "",
             sprintf("2024-25 full-season fit (carry-over source): %d s; gates %s", round(f25$secs),
                     paste(names(f25$gates), round(f25$gates, 3), collapse = ", ")), "",
             "## Variants (posterior means of structural parameters, per 100 possessions)", "",
             knitr::kable(tab), "", "## Top 25, lux_dynamic", "",
             knitr::kable(head(top, 25), digits = 1)), "pilot/out/02_fits.md")
