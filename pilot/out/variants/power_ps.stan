// =============================================================================
// CBB power model, pilot copy for prior sensitivity (pilot/18_priorsense.R): stan/power.stan plus
// lprior, the joint log density of the hyperparameter priors (for priorsense's power-scaling).
//
// CBB power model (pilot). Each D1 team has a net strength r in points per 100 possessions
// against an average D1 team on a neutral floor; it moves week to week as a random walk.
//
//   mu = r[home] - r[away] + hca * home_adv          (expected margin per 100 possessions)
//
// Two per-game signals share r (as in the CFB model):
//   eff    : shot-quality margin per 100 live possessions     eff ~ Normal(lambda mu, sigma_eff / sqrt(w_e))
//   margin : regulation margin per 100 regulation possessions (OT -> 0), conditioned on the eff
//            residual so the two are not counted as independent evidence:
//            margin ~ Student-t(nu, mu + kappa (eff - lambda mu), sigma_m / sqrt(w_m))
// Games without eff use the margin's marginal law (scale widened by kappa^2 sigma_eff^2).
// w = possessions / 70: per-100 rates from short or slow games are noisier.
//
// Preseason level: r0 = mu_conf[conf] + b_prev * prev_dev + sqrt(sigma_team^2 + (b_prev prev_sd)^2) z.
//   conf_carry = 0: mu_conf ~ Normal(0, sigma_conf); prev_dev = last season's final rating
//                   (0 when unknown). Conference strength is in both terms, so mu_conf and
//                   b_prev trade off.
//   conf_carry = 1: mu_conf ~ Normal(b_conf * prev_conf, sigma_conf), prev_conf = mean last-season
//                   rating of the conference's current members; prev_dev = a team's rating minus
//                   its conference's prev_conf. The two carry-overs then act on separate levels.
// conf_centred = 1 samples mu_conf directly (centred), better once each conference has many games.
// Non-D1 games (N_nd): the D1 team's margin against one pooled non-D1 level r_nd, with extra
// spread sigma_nd for the mix of D2/D3/NAIA opponents; margin signal only.
// Dynamics: one state per period (state_days, in R) with a game; step sd tau * sqrt(periods
// elapsed); dynamic = 0 freezes ratings.
// Options tested by backtest (pilot/out/12_variants.md; R's model_config() sets the defaults:
// use_prev2 on, normal margins): use_prev2 adds b_prev2 * the rating two seasons back to r0; team_hca gives each team its own home edge, hca + sigma_hca * z (shrunk to the season's);
// margin_family 1 = Student-t, 2 = normal, 3 = contaminated normal (share p_out with scale k_out
// times sigma); save_loglik stores each D1 game's margin log density (for LOO).
// =============================================================================

functions {
  // Pointwise margin log density for the chosen family
  vector margin_pointwise(vector y, vector mu, vector sigma, int family, real nu, real p_out, real k_out) {
    int n = num_elements(y);
    vector[n] lp;
    for (i in 1:n) {
      if (family == 1) lp[i] = student_t_lpdf(y[i] | nu, mu[i], sigma[i]);
      else if (family == 2) lp[i] = normal_lpdf(y[i] | mu[i], sigma[i]);
      else lp[i] = log_mix(p_out, normal_lpdf(y[i] | mu[i], k_out * sigma[i]), normal_lpdf(y[i] | mu[i], sigma[i]));
    }
    return lp;
  }
  // Summed margin log density (vectorised for the t and the normal)
  real margin_total(vector y, vector mu, vector sigma, int family, real nu, real p_out, real k_out) {
    if (family == 1) return student_t_lpdf(y | nu, mu, sigma);
    if (family == 2) return normal_lpdf(y | mu, sigma);
    return sum(margin_pointwise(y, mu, sigma, family, nu, p_out, k_out));
  }
  // Margin mean and sd per game: conditioned on the eff residual where a game has eff, the
  // margin's marginal law (scale widened by kappa sigma_eff) where it does not
  matrix margin_moments(vector mu, vector eff, array[] int idx_eff, array[] int idx_noeff, vector sw_m, vector sw_e,
                        real lambda, real kappa, real sigma_m, real sigma_eff) {
    int n = num_elements(mu);
    matrix[n, 2] m;
    m[:, 1] = mu;
    m[idx_eff, 1] = mu[idx_eff] + kappa * (eff[idx_eff] - lambda * mu[idx_eff]);
    m[idx_eff, 2] = sigma_m ./ sw_m[idx_eff];
    m[idx_noeff, 2] = sqrt(square(sigma_m ./ sw_m[idx_noeff]) + square(kappa * sigma_eff ./ sw_e[idx_noeff]));
    return m;
  }
}

data {
  int<lower=1> N_teams;
  int<lower=1> N_conf;
  array[N_teams] int<lower=1, upper=N_conf> team_conf;
  vector[N_teams] prev_dev;
  vector<lower=0>[N_teams] prev_sd;
  vector[N_conf] prev_conf;
  int<lower=0, upper=1> conf_carry;

  int<lower=0> N_states;
  array[N_states] int<lower=1, upper=N_teams> state_team;
  array[N_states] int<lower=1, upper=N_states> state_first;
  vector<lower=0>[N_states] state_gap;
  array[N_teams] int<lower=0, upper=N_states> now_state;
  vector<lower=0>[N_teams] now_gap;

  int<lower=0> N_games;
  array[N_games] int<lower=1, upper=N_states> home_state;
  array[N_games] int<lower=1, upper=N_states> away_state;
  vector<lower=-1, upper=1>[N_games] home_adv;  // +1 home team on its floor, -1 on the away team's, 0 neutral
  vector[N_games] margin;
  vector<lower=0>[N_games] w_m;
  array[N_games] int<lower=0, upper=1> has_eff;
  vector[N_games] eff;
  vector<lower=0>[N_games] w_e;

  int<lower=0> N_nd;
  array[N_nd] int<lower=1, upper=N_states> nd_state;
  vector<lower=-1, upper=1>[N_nd] nd_venue;     // +1 D1 team at home, -1 away, 0 neutral
  vector[N_nd] nd_margin;                       // D1 - non-D1, per 100 regulation possessions
  vector<lower=0>[N_nd] nd_w;

  int<lower=0, upper=1> use_eff;
  int<lower=0, upper=1> dynamic;
  int<lower=0, upper=1> conf_centred;
  // (mean, sd) of the normal priors on the hierarchy scales and the weekly drift
  vector[2] sigma_conf_prior;
  vector[2] sigma_team_prior;
  vector[2] tau_prior;
  vector[2] hca_prior;

  int<lower=0, upper=1> use_prev2;
  vector[N_teams] prev2_dev;                    // rating two seasons back (0 when unknown)
  int<lower=0, upper=1> team_hca;
  int<lower=1, upper=3> margin_family;
  int<lower=0, upper=1> save_loglik;
}

transformed data {
  int N_eff = use_eff ? sum(has_eff) : 0;
  array[N_eff] int idx_eff;
  array[N_games - N_eff] int idx_noeff;
  {
    int i = 1;
    int j = 1;
    for (k in 1:N_games) {
      if (use_eff && has_eff[k] == 1) { idx_eff[i] = k; i += 1; }
      else { idx_noeff[j] = k; j += 1; }
    }
  }
  vector[N_states] sqrt_gap = sqrt(state_gap);
  vector[N_games] sw_m = sqrt(w_m);
  vector[N_games] sw_e = sqrt(w_e);
  // the team whose floor it is (home_adv = 0: unused)
  array[N_games] int host;
  for (k in 1:N_games) host[k] = home_adv[k] < 0 ? state_team[away_state[k]] : state_team[home_state[k]];
}

parameters {
  real<lower=0> sigma_conf;
  vector[conf_centred ? 0 : N_conf] conf_raw;
  vector[conf_centred ? N_conf : 0] mu_conf_c;
  real<lower=0> sigma_team;
  real<lower=0, upper=1.2> b_prev;
  vector[conf_carry] b_conf_raw;
  vector[N_teams] z;
  vector<lower=0>[dynamic] tau_raw;
  vector[dynamic ? N_states : 0] eps;

  real hca;
  real<lower=0> sigma_m;
  vector<lower=2>[margin_family == 1] nu_raw;
  vector<lower=0, upper=0.5>[margin_family == 3] p_out_raw;
  vector<lower=1>[margin_family == 3] k_out_raw;
  vector[use_prev2] b_prev2_raw;
  vector<lower=0>[team_hca] sigma_hca_raw;
  vector[team_hca ? N_teams : 0] hca_z;
  vector<lower=0>[use_eff] lambda_raw;
  vector<lower=0>[use_eff] sigma_eff_raw;
  vector[use_eff] kappa_raw;
  vector[N_nd > 0] r_nd_raw;
  vector<lower=0>[N_nd > 0] sigma_nd_raw;
}

transformed parameters {
  real b_conf = conf_carry ? b_conf_raw[1] : 0;
  vector[N_conf] mu_conf;
  if (conf_centred) mu_conf = mu_conf_c;
  else mu_conf = b_conf * prev_conf + sigma_conf * conf_raw;
  real b_prev2 = use_prev2 ? b_prev2_raw[1] : 0;
  vector[N_teams] r0 = mu_conf[team_conf] + b_prev * prev_dev + b_prev2 * prev2_dev
                       + sqrt(square(sigma_team) + square(b_prev * prev_sd)) .* z;
  // normal and contaminated-normal margins: nu stands in as a large df for the win-probability code
  real nu = margin_family == 1 ? nu_raw[1] : 1e4;
  real p_out = margin_family == 3 ? p_out_raw[1] : 0;
  real k_out = margin_family == 3 ? k_out_raw[1] : 1;
  real sigma_hca = team_hca ? sigma_hca_raw[1] : 0;
  vector[N_teams] hca_team = rep_vector(hca, N_teams);
  if (team_hca) hca_team += sigma_hca * hca_z;
  real tau = dynamic ? tau_raw[1] : 0;
  real lambda = use_eff ? lambda_raw[1] : 0;
  real sigma_eff = use_eff ? sigma_eff_raw[1] : 0;
  real kappa = use_eff ? kappa_raw[1] : 0;
  vector[N_states] r_state = r0[state_team];
  if (dynamic && N_states > 0) {
    vector[N_states] step = sqrt_gap .* eps;
    vector[N_states] cs = cumulative_sum(step);
    r_state += tau * (cs - cs[state_first] + step[state_first]);
  }
}

model {
  sigma_conf ~ normal(sigma_conf_prior[1], sigma_conf_prior[2]);
  sigma_team ~ normal(sigma_team_prior[1], sigma_team_prior[2]);
  b_prev ~ normal(0.7, 0.2);
  b_conf_raw ~ normal(0.8, 0.3);
  hca ~ normal(hca_prior[1], hca_prior[2]);
  sigma_m ~ normal(14, 5);
  nu_raw ~ gamma(2, 0.1);
  p_out_raw ~ beta(2, 20);
  k_out_raw ~ normal(2.5, 1);
  b_prev2_raw ~ normal(0.2, 0.2);
  sigma_hca_raw ~ normal(0, 1);
  hca_z ~ std_normal();
  tau_raw ~ normal(tau_prior[1], tau_prior[2]);
  lambda_raw ~ normal(0.7, 0.3);
  sigma_eff_raw ~ normal(12, 5);
  kappa_raw ~ normal(0.5, 0.5);
  conf_raw ~ std_normal();
  if (conf_centred) mu_conf_c ~ normal(b_conf * prev_conf, sigma_conf);
  r_nd_raw ~ normal(-25, 10);
  sigma_nd_raw ~ normal(10, 5);
  z ~ std_normal();
  eps ~ std_normal();

  if (N_games > 0) {
    vector[N_games] mu = r_state[home_state] - r_state[away_state] + hca_team[host] .* home_adv;
    if (use_eff) {
      vector[N_eff] mu_e = mu[idx_eff];
      target += normal_lpdf(eff[idx_eff] | lambda * mu_e, sigma_eff ./ sw_e[idx_eff]);
    }
    matrix[N_games, 2] mm = margin_moments(mu, eff, idx_eff, idx_noeff, sw_m, sw_e, lambda, kappa, sigma_m, sigma_eff);
    target += margin_total(margin, mm[:, 1], mm[:, 2], margin_family, nu, p_out, k_out);
  }
  if (N_nd > 0) {
    target += margin_total(nd_margin, r_state[nd_state] - r_nd_raw[1] + hca * nd_venue,
                           sqrt((square(sigma_m) + square(kappa * sigma_eff)) ./ nd_w + square(sigma_nd_raw[1])),
                           margin_family, nu, p_out, k_out);
  }
}

generated quantities {
  // Rating at the snapshot date: latest state plus the drift since
  vector[N_teams] r;
  // Marginal sd of a game's margin per 100 at w = 1 (for win probabilities)
  real sigma_game = sqrt(square(sigma_m) + square(kappa * sigma_eff));
  vector[save_loglik ? N_games : 0] log_lik;
  real lprior = normal_lpdf(sigma_conf | sigma_conf_prior[1], sigma_conf_prior[2]) + normal_lpdf(sigma_team | sigma_team_prior[1], sigma_team_prior[2])
                + normal_lpdf(b_prev | 0.7, 0.2) + normal_lpdf(hca | hca_prior[1], hca_prior[2]) + normal_lpdf(sigma_m | 14, 5)
                + normal_lpdf(b_prev2_raw | 0.2, 0.2) + normal_lpdf(tau_raw | tau_prior[1], tau_prior[2]) + normal_lpdf(lambda_raw | 0.7, 0.3)
                + normal_lpdf(sigma_eff_raw | 12, 5) + normal_lpdf(kappa_raw | 0.5, 0.5);
  if (save_loglik && N_games > 0) {
    vector[N_games] mu = r_state[home_state] - r_state[away_state] + hca_team[host] .* home_adv;
    matrix[N_games, 2] mm = margin_moments(mu, eff, idx_eff, idx_noeff, sw_m, sw_e, lambda, kappa, sigma_m, sigma_eff);
    log_lik = margin_pointwise(margin, mm[:, 1], mm[:, 2], margin_family, nu, p_out, k_out);
  }
  for (i in 1:N_teams) {
    r[i] = now_state[i] == 0 ? r0[i] : r_state[now_state[i]];
    if (dynamic) r[i] += tau * sqrt(now_gap[i]) * normal_rng(0, 1);
  }
}
