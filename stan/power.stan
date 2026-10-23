// =============================================================================
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
// =============================================================================

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
  vector<lower=0, upper=1>[N_games] home_adv;
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
  real<lower=2> nu;
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
  vector[N_teams] r0 = mu_conf[team_conf] + b_prev * prev_dev
                       + sqrt(square(sigma_team) + square(b_prev * prev_sd)) .* z;
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
  hca ~ normal(4, 2);
  sigma_m ~ normal(14, 5);
  nu ~ gamma(2, 0.1);
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
    vector[N_games] mu = r_state[home_state] - r_state[away_state] + hca * home_adv;
    if (use_eff) {
      vector[N_eff] mu_e = mu[idx_eff];
      vector[N_eff] res = eff[idx_eff] - lambda * mu_e;
      target += normal_lpdf(eff[idx_eff] | lambda * mu_e, sigma_eff ./ sw_e[idx_eff]);
      target += student_t_lpdf(margin[idx_eff] | nu, mu_e + kappa * res, sigma_m ./ sw_m[idx_eff]);
    }
    target += student_t_lpdf(margin[idx_noeff] | nu, mu[idx_noeff],
                             sqrt(square(sigma_m ./ sw_m[idx_noeff]) + square(kappa * sigma_eff ./ sw_e[idx_noeff])));
  }
  if (N_nd > 0) {
    target += student_t_lpdf(nd_margin | nu, r_state[nd_state] - r_nd_raw[1] + hca * nd_venue,
                             sqrt((square(sigma_m) + square(kappa * sigma_eff)) ./ nd_w + square(sigma_nd_raw[1])));
  }
}

generated quantities {
  // Rating at the snapshot date: latest state plus the drift since
  vector[N_teams] r;
  // Marginal sd of a game's margin per 100 at w = 1 (for win probabilities)
  real sigma_game = sqrt(square(sigma_m) + square(kappa * sigma_eff));
  for (i in 1:N_teams) {
    r[i] = now_state[i] == 0 ? r0[i] : r_state[now_state[i]];
    if (dynamic) r[i] += tau * sqrt(now_gap[i]) * normal_rng(0, 1);
  }
}
