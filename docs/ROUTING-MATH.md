# The mathematics of quotabot routing and quota analytics

Design note (forward-looking; the shipped subset is marked as such). The aim is to
turn quotabot's local history into routing decisions with stated assumptions and
honest uncertainty, rather than an opaque heuristic. Everything here is grounded in
data we
already collect (`insights.dart`: burn, pace, reliability, percentiles, trend,
week-hour heatmap) and the routing primitive we already ship (`analysis.dart`:
`effectiveHeadroom`, `suggestRoute`). Where a section proposes new math it states
how it reduces to the shipped heuristic, so nothing is a rewrite, only a deepening.

The shipped `effectiveHeadroom = clamp(headroom - max(0, burn) * lead, 0, 100)` is
the linchpin. By the end of this note it is revealed as the first-order (mean,
risk-neutral) term of a principled forecast, and we extend it carefully outward.

---

## 1. The roundtable

Four people want different things from the same numbers. Their wishes are the
requirements; the math is how we grant all of them at once.

**Maya, operations researcher (efficiency).** "Two failure modes, and they are not
symmetric. Stalling mid-flow on a spent cap is expensive; leaving paid quota
unspent at reset is pure waste I already paid for. I want an objective that prices
both and a policy that is optimal against it, not a vibe. Show me the marginal
value of one more request on each provider and route to the maximum."

**Dev, the SRE (reliability).** "I think in tail risk and capacity. Don't tell me
the mean; tell me P(this provider strands me before its reset). When several
agents fan out, they will dogpile the same pick and self-inflict a limit. I want
leases with the queueing math behind them, and a confidence label on every number
so a stale or thin estimate is never trusted like a fresh one."

**Sol, decision theory / ML.** "This is sequential decision-making under
uncertainty with replenishing resources and deadlines: a restless multi-armed
bandit with knapsack constraints. There is a clean index policy hiding in here.
And we should forecast with predictive intervals, not point estimates - quantify
what we don't know."

**Pip, broke hobbyist coder.** "I have almost no money and barely any history.
Free and local first, always; only spend paid quota when the task truly needs it
or the window is about to reset and would be wasted anyway. And please don't make
me collect a month of data before the tool is smart - borrow strength from the
providers that do have history."

Synthesis of requirements:

| Want | Owner | Math that delivers it |
|---|---|---|
| Price stall vs waste | Maya | utility / expected-loss objective (S5) |
| Marginal value, route to max | Maya | water-filling, Whittle index (S6) |
| Tail risk, P(strand) | Dev | first-passage / survival (S4) |
| No dogpile | Dev | leases via newsvendor + Erlang (S9) |
| Confidence on everything | Dev, Sol | predictive intervals, shrinkage (S3, S11) |
| Bandit/knapsack policy | Sol | restless RMAB, Lagrangian index (S6) |
| Free-first, spend only when needed | Pip | cost term + reset-aware pacing (S5, S7) |
| Smart with little data | Pip | hierarchical Bayes shrinkage (S11) |

---

## 2. Data model and notation

For one provider `i` and one rolling window `w` (e.g. 5h, weekly):

- Capacity is normalized to 1. Let `u_i(t) in [0,1]` be the fraction used and
  `h_i(t) = 1 - u_i(t)` the remaining headroom (we store percent; here a fraction).
- The window resets at epoch `r_i`. Time-to-reset `T_i = r_i - t >= 0`.
- History is compact hourly buckets `{(t_b, h_b)}` retained 90 days. From these
  `insights.dart` derives mean, p10/p50/p90, reliability, least-squares trend, and
  the weekday-by-hour profile. We treat the bucket series as samples of a
  piecewise-smooth depletion process reset to ~1 at each `r_i`.
- Usage arrives as a marked point process: requests at times `{tau_k}` each
  consuming `c_k` of capacity. Aggregated, the **burn rate** is the intensity
  `beta_i(t) = E[d u_i / dt]` in units of capacity per hour.

The binding-window rule (a spent longer window overrides a healthy shorter one) is
the constraint `h_i = min over w of h_{i,w}`, with `r_i` the reset of the argmin
window. Everything below operates on the binding window unless said otherwise.

---

## 3. Burn-rate estimation, with uncertainty

`insights.burnPerHour` today is essentially a recent slope. Make it a proper
estimator with a variance, because Dev and Sol both need the error bar.

Let consecutive in-window bucket diffs be `d_j = (u(t_j) - u(t_{j-1})) /
(t_j - t_{j-1})`, dropping any interval that crosses a reset (a reset is not burn).

**EWMA mean and variance.** With smoothing `alpha = 1 - 2^{-1/H}` for half-life
`H` hours (recency without noise):

```
beta_hat   <- alpha * d_j + (1 - alpha) * beta_hat
s2         <- alpha * (d_j - beta_hat)^2 + (1 - alpha) * s2      # EWMA variance
```

The effective sample size of an EWMA is `n_eff = (2 - alpha) / alpha`, so the
standard error of the mean burn is `se(beta) = sqrt(s2 / n_eff)`.

**Robustness.** Usage is bursty and heavy-tailed, so a single huge bucket should
not dominate. Use the median of diffs as a robust center and the MAD for scale:
`beta_med = median(d_j)`, `sigma_rob = 1.4826 * MAD(d_j)`. Report
`beta = beta_med` when `|beta_hat - beta_med| > 2 se` (outlier-contaminated),
else the EWMA. This is a soft Huberization; the PhD board cares that we did not
let one spike masquerade as a trend.

Output: a burn estimate `beta_i` with standard error `se_i`. Today's code keeps
only `beta`; adding `se` is the smallest change that unlocks every interval below.

---

## 4. Forecasting headroom and the probability of stranding

Dev's question - "will this strand me before reset?" - is a first-passage problem.

**Mean forecast.** Over a planning horizon `L` (lead time), expected headroom is

```
h_hat_i(L) = clamp(h_i - beta_i * L, 0, 1).
```

This is exactly the shipped `effectiveHeadroom` (with `L = leadHours`, `beta` the
burn). So the heuristic is the conditional mean of a depletion forecast - good, but
silent about risk.

**Predictive interval.** Treating cumulative burn over `L` as approximately
Gaussian with mean `beta_i L` and variance `(se_i^2 + sigma_rob^2/n) L^2 + sigma_rob^2 L`
(parameter uncertainty plus process noise; the `L^2` term is parameter error, the
linear term is diffusion), the headroom at horizon `L` has sd `s_i(L)`. Then a
risk-adjusted headroom at confidence level `z` (e.g. z=1.28 for the 10th
percentile) is

```
h_risk_i(L) = clamp(h_i - beta_i L - z * s_i(L), 0, 1).
```

Maya routes on the mean; Dev routes on `h_risk` with a `z` set by his risk
appetite. One knob, `z`, slides continuously from optimistic to paranoid, and
`z = 0` recovers today's behavior exactly. That continuity is the design win.

**Probability of stranding before reset.** The chance the binding window is spent
before it resets (first passage of `h` to 0 within `T_i`):

```
p_strand_i = P( h_i - B_i(T_i) <= 0 ),   B_i(T) = cumulative burn over T,
           ~= Phi( (beta_i T_i - h_i) / s_i(T_i) ).
```

`p_strand` is the honest, comparable risk number Dev asked for, and it feeds both
the routing penalty (S5) and the confidence label on the UI.

---

## 5. The routing objective: pricing stall against waste

Maya insists the policy optimize a stated objective. Define, for routing the next
request to provider `i`, an expected utility (all terms in comparable units of
"value of a served request"):

```
U_i = V_served * (1 - p_strand_i)          # got the work done
      - C_stall  * p_strand_i              # stalled mid-flow (asymmetric, large)
      - C_money  * price_i                 # paid-tier cost (Pip's term; 0 for free/local)
      + W_reset  * waste_relief_i          # spending quota that would otherwise be wasted
      - C_risk   * z_penalty_i.            # variance aversion (Dev's z)
```

- `price_i = 0` for local runtimes and for plans already paid as flat-rate within
  the window (the marginal request is free until the cap). This is why Pip's
  "free-first" is not a special case bolted on - it falls out of `C_money * price_i`.
- `waste_relief_i` rewards consuming quota that the forecast says will be unused at
  reset (S7). For a flat-rate plan with projected wa- waste, the marginal request
  has negative effective cost near reset: use-it-or-lose-it, derived, not hacked.

The policy is `argmax_i U_i` subject to the binding-window feasibility
(`h_i > floor`). With `C_stall` dominant and the other weights zero, `argmax U_i`
collapses to "most headroom that clears the comfort floor" - today's `suggestRoute`.
So the shipped policy is the corner of this objective where only stalls are priced;
turning on the other weights is a smooth generalization.

---

## 6. Allocation across providers: water-filling and a Whittle index

When work is a stream (fan-out, a long session), routing is not one pick but an
allocation `{x_i}` of request rate across providers. Sol's framing.

**Water-filling.** Maximize total served subject to each provider's depletion not
crossing its reset. The Lagrangian optimum equalizes the marginal value of rate
across all active providers: pour load into the provider whose marginal "time
bought per unit risk" is highest until its risk rises to meet the next, exactly
like water finding its level. Concretely, allocate to equalize the index below.

**Restless multi-armed bandit.** Each provider is an arm whose state (headroom)
depletes when pulled and replenishes at reset - a restless bandit. The optimal
policy for restless bandits is intractable in general, but the **Whittle index**
is the principled, near-optimal relaxation (Lagrangian decomposition of the
per-arm subsidy-for-passivity). The quotabot index per provider:

```
I_i = ( h_risk_i / max(beta_i, beta_floor) )    # hours of runway, risk-adjusted
      * freshness_i                             # decay stale data toward 0
      * (1 + W_reset * waste_fraction_i)        # boost near-wasted flat-rate quota
      / (1 + C_money * price_i).                # discount paid tiers
```

Route to `argmax_i I_i`; for streaming work, split rate proportionally to a
softmax of `I_i` (a smooth water-filling). `I_i` has units of risk-adjusted
runway-hours, is comparable across providers, degrades gracefully as data thins
(via `freshness_i` and the shrinkage of S11), and reduces to "most headroom first"
when burn, price, and waste terms are neutral. This single index is the
mathematical heart of "routing as a primitive."

**Knapsack with deadlines.** Over a horizon spanning multiple resets, choosing
which requests to place where to maximize served-before-deadline is a
multiple-knapsack / job-scheduling problem (resets are deadlines, headroom is
capacity). The greedy `argmax I_i` is the standard 1 - 1/e-competitive heuristic;
exact DP is available offline for the optimizer/report view.

---

## 7. Use-it-or-lose-it and reset-anchored pacing

Maya and Pip's shared wish: never waste flat-rate quota, never overspend it early.

**Projected waste.** For a flat-rate window, expected unused capacity at reset is

```
waste_i = E[ h_i - B_i(T_i) ]_+ ~= h_i - beta_i T_i,   when beta_i T_i < h_i.
```

If `waste_i` exceeds a threshold, the quota is on track to expire unused: raise an
alert and, in the index, set `waste_fraction_i = waste_i / h_i` so routing leans
into that provider precisely when spending is free value.

**Reset-anchored pacing (a reverse token bucket).** To consume remaining headroom
smoothly by reset, the target burn is `beta_target = h_i / T_i`. Compare to actual:

```
pace_ratio = beta_i / beta_target.
```

`pace_ratio < 1` means under-using (waste risk; bias toward this provider);
`> 1` means on track to strand early (bias away). This is a proportional
controller whose setpoint is "finish exactly at reset," the textbook way to
exhaust a renewing budget without starving or stranding. `insights.computePace`
already computes runway vs reset; this names the controller and closes the loop
into routing.

---

## 8. Tier ROI: should Pip downgrade, or upgrade?

Decide a plan tier from the fitted usage distribution, not anecdotes.

Let `q_p` be the p-th percentile of in-window peak usage (we already compute
p10/p50/p90 via a histogram). For a candidate tier with cap `K` and price `m`:

```
P(breach) = P(peak_usage > K) ~= 1 - F_hat(K)      # from the fitted CDF
E[overage_cost] = m_overage * E[(peak_usage - K)_+]  # newsvendor-style tail integral
ROI(downgrade) = (m_current - m_lower) - E[overage_cost at K_lower].
```

Recommend the cheapest tier whose `P(breach) <= epsilon` (Pip sets `epsilon`, her
risk tolerance), reporting `$/mo saved` and the breach probability so the decision
is hers with the tail laid bare. The shipped "barely used, a lower tier may be
enough" flag is the `q_90 << K` special case; this generalizes it to a costed,
risk-bounded recommendation. (Strictly post-1.0, and optional/secondary per the
roadmap's no-cost-ledger stance - it informs, it does not become the main view.)

---

## 9. Reliability and concurrency leases (queueing)

**Reliability as availability.** Define `A_i = fraction of recent buckets with
h_i > floor` - the probability a provider is usable when asked. With sparse data
use a Beta-Binomial posterior (S11) so `A_i` is a credible interval, not a brittle
ratio. Reliability enters the index as a multiplier on `V_served`.

**Leases for the dogpile (Dev's headline).** N agents reading the same snapshot
all pick the same freshest provider and collectively breach it - a thundering
herd. Model concurrent in-flight requests as an M/M/c-style system; the chance an
arriving request finds the provider already saturated is Erlang-C in the offered
load. The fix is a `reserve`/`release` lease: each route provisionally debits an
estimate `c_hat` of capacity. How much to reserve is a **newsvendor** problem -
under-reserve and you dogpile (stall cost `C_stall`), over-reserve and you idle
quota (waste cost `W_reset`):

```
reserve_quantile = C_stall / (C_stall + W_reset),
c_reserve = F_consumption^{-1}( reserve_quantile ).
```

Leases are decremented from `h_i` before the next routing decision, so concurrent
deciders see each other's intent and water-fill instead of dogpiling. This is the
biggest dependability gap and it has a clean, classical answer.

---

## 10. Best-time-to-run: a periodic intensity model

The weekday-by-hour heatmap (`weekHourHeatmap`) is samples of a periodic intensity
`lambda(weekday, hour)` - the typical tightness at each of the 168 weekly bins.
Model each bin as a Poisson/Beta rate with hierarchical smoothing across adjacent
bins (a 2-D circular smoother on the (day, hour) torus) so a single quiet Tuesday
3am does not read as a reliable trough. "Best time to run" is then
`argmin_bin lambda_hat`, with a credible band. For deferrable work the scheduler
recommends the nearest low-contention bin before the relevant reset - capacity
planning, exactly as Dev would do it for a datacenter, scaled to one developer.

---

## 11. Doing it well with almost no data (Pip's problem)

A new user, or a rarely used provider, has a handful of buckets. Naive estimates
are wild. Borrow strength.

**Hierarchical shrinkage.** Treat each provider's mean headroom `mu_i` as drawn
from a population `N(mu_0, tau^2)`. The posterior mean shrinks the noisy
per-provider estimate toward the global mean by its unreliability:

```
mu_i_shrunk = lambda_i * mu_i_hat + (1 - lambda_i) * mu_0,
lambda_i    = n_i / (n_i + sigma^2 / tau^2).
```

This is the James-Stein / empirical-Bayes estimator: with `n_i` small, `lambda_i`
is near 0 and we lean on the fleet; as history accrues, `lambda_i -> 1` and the
provider speaks for itself. The same Beta-Binomial shrinkage stabilizes reliability
`A_i` and the heatmap rates. The practical payoff for Pip: quotabot is sensible on
day one and sharpens automatically, never demanding a month of data to be useful.

**Confidence as a first-class output.** Every routed number carries
`n_eff`/`freshness`/credible-interval width, surfaced as a confidence tag
(`fresh` / `thin` / `stale`). Routing already prefers live over stale; this makes
the preference quantitative and visible, satisfying the roadmap's provenance goal.

---

## 12. The unified routing score (implementable today)

Collapsing S3-S11 into one comparable score per provider, with the shipped
heuristic as the `z=0`, neutral-weights limit:

```
runway_i      = h_risk_i(L) / max(beta_i, beta_floor)         # S3, S4
score_i       = runway_i
                * reliability_i                               # S9, shrunk (S11)
                * freshness_i                                 # S11
                * (1 + W_reset * waste_fraction_i)            # S7
                / (1 + C_money * price_i)                     # S5, S8
route         = argmax_i feasible(i) ? score_i : -inf         # binding-window floor
fallback      = local runtime, else soonest reset, else passthrough   # shipped
```

Properties we can state and defend:
- **Reduces to today.** Set `z=0`, `W_reset=0`, `C_money=0`, `reliability=freshness=1`:
  `score_i = h_i / beta_i`, monotone in headroom and inverse burn - i.e. rank by
  effective headroom, which is exactly `suggestRoute`. Nothing regresses.
- **Risk-monotone.** `dscore/dz <= 0`: more caution never increases a pick's score.
- **Fail-soft.** Missing data -> `freshness -> 0` -> the provider sinks below the
  guaranteed fallback, never above it. The invariant holds by construction.
- **Units.** `score` is risk-adjusted, reliability-weighted runway-hours per dollar:
  a quantity a board can interrogate, not an arbitrary index.

---

## 13. Worked example

Two paid providers and a local runtime, `L = 1h`, `z = 1.28` (10th-pctile caution):

| Provider | h | beta (/h) | se | T_reset | price |
|---|---|---|---|---|---|
| Claude | 0.25 | 0.20 | 0.05 | 3h | 0 (flat) |
| Codex  | 0.60 | 0.05 | 0.02 | 30h | 0 (flat) |
| Ollama | 1.00 | 0    | -   | -   | 0 |

- Claude: `h_risk = 0.25 - 0.20*1 - 1.28*s ~= 0.02`; `p_strand ~ Phi((0.20*3 -
  0.25)/s_T)` is high -> low runway, high strand risk.
- Codex: `h_risk ~= 0.60 - 0.05 - 1.28*small ~= 0.53`; runway `~10.6h` -> clear winner.
- Ollama stays the always-on floor; it only wins if both paid providers fall below
  the feasibility floor.

Mean-only (`z=0`) would still pick Codex here, but near a boundary (Claude at
0.35 instead of 0.25) the risk term flips the pick before a real stall happens -
the measurable improvement over the shipped heuristic.

---

## 14. Mapping to code, and build order

| Section | Lands in | Status |
|---|---|---|
| burn + se, robust | `insights.dart` `burnRateWithError` -> `BurnStat` | shipped |
| `h_risk`, `p_strand` | `analysis.dart` `riskAdjustedHeadroom`, `strandProbability` | shipped |
| confidence + provenance | `RouteCandidate.confidence`, `as_of`/`risk_z` | shipped (suggest); top/widget pending |
| `--risk` opt-in | `analysis.dart` `suggestRoute` riskZ | shipped |
| unified `score_i` (Whittle) | `analysis.dart` `suggestRoute` | next |
| shrinkage | `insights.dart` (cross-provider pool) | next |
| pacing controller | `computePace` -> routing weight | medium |
| leases reserve/release | new `leases.dart` + MCP `reserve`/`release` | post-1.0 |
| tier ROI | `stats` / optimizer view | post-1.0, secondary |
| heatmap intensity | `weekHourHeatmap` smoothing + scheduler hint | post-1.0 |

Build order honors the roadmap: ship `se` + `h_risk` + the unified score with
neutral weights first (zero behavior change, full machinery in place), then turn on
risk (`z`), then shrinkage (Pip), then leases (Dev), then the optimizer (Maya) and
scheduler. Each step is a one-knob, reduces-to-previous change with its own tests.

---

## 15. Design principles

- Every estimator carries an error bar (EWMA variance, Wald/credible intervals, MAD).
- The objective is stated, and the policy is optimal or near-optimal against it
  (expected-utility argmax; Whittle index for the restless bandit; newsvendor for
  leases; empirical Bayes for small samples) - named, classical results rather than
  ad hoc rules.
- The shipped heuristic is recovered as an explicit limit, so each deepening is
  non-regressive.
- It stays honest under uncertainty: confidence is an output, missing data fails
  soft, and a stale 99% never beats a live 80%.

The point is not to be clever; it is that "route to whichever has budget" becomes a
precise statement - maximize risk-adjusted, reliability-weighted, cost-discounted
runway, with leases preventing self-interference and shrinkage covering the
cold-start - that holds up to scrutiny and still collapses to the simple, fast
thing we already ship when the data is thin.
