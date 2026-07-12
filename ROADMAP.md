# Roadmap

Updated 2026-07-11. This file is the forward plan. Shipped work belongs in
[CHANGELOG.md](CHANGELOG.md), implementation detail belongs in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and the product reasoning behind
the plan belongs in [docs/PRODUCT-STRATEGY.md](docs/PRODUCT-STRATEGY.md).

## Product contract

quotabot does two jobs:

1. **SEE:** show the best available evidence of remaining AI coding quota and
   local-runtime readiness, including source, scope, age, and uncertainty.
2. **ROUTE:** recommend a usable provider or model for the next request without
   reading the request, entering the inference path, or silently enabling paid
   API spend.

The quality target is not the largest provider list or the most analytics. It is
the fastest path to a truthful answer, the clearest reason for a recommendation,
graceful behavior when providers change, and boring installation and updates.

1.0 means **exceptional and rock-solid: it just works** across every supported
service, on Windows, macOS, and Linux, with at least one quota-based service or
local runtime present. "Just works" includes the realistic case that a person
uses the same account on more than one machine: the quota a user sees must
reflect account-wide truth, not a single machine's stale local copy. Meeting
people where they are with what they have is the point; the product earns trust
by being correct, quiet, and predictable, not by being large.

## Non-negotiable boundaries

- **Zero inference and content-blind.** Runtime code never calls generation
  endpoints and never reads prompts, source code, model responses, or task
  content. Quota reads spend zero usage tokens.
- **Local-first, not network-free.** History, cache, preferences, profiles,
  grants, and leases are local. Live adapters may send credentials and quota
  metadata to that provider's own metadata endpoint; Antigravity may also run
  its provider-required account onboarding request. An external alert webhook
  can send alert metadata only after the user explicitly enables an external
  host.
- **Bounded local writes.** Cache, history, OAuth rotation, profiles, manual
  entries, preferences, alerts, and routing leases are explicit local metadata
  writes. Machine outputs never include secrets.
- **Advisor, never proxy.** quotabot supplies evidence and a recommendation. It
  does not carry the user's request or become a required hop.
- **No surprise bills.** Request-metered API routes are excluded by default.
  Included quota-plan routes require explicit evidence that overages are
  disabled. A runtime reached through a local daemon must not be called local or
  free if execution is actually offloaded to a cloud service.
- **Honest uncertainty.** Staleness, this-machine scope, manual input, passive
  detection, weighted consumption, and unknown balances stay visible. A spent
  binding window overrides a healthier shorter window.
- **Correct across a user's machines.** When a provider exposes an account-wide
  usage read, that read is the source of truth even on a machine the user has
  not actively used the tool on recently; quotabot keeps it live by refreshing
  its own credentials rather than depending on the host app to have run here. A
  machine-scoped fallback is only ever shown when nothing account-wide is
  available, and it is always labeled as this-machine.
- **Fail soft.** If quotabot is unavailable or lacks a safe route, callers keep
  their original behavior or receive an explicit no-safe-route result. Routing
  is an optimization, not a dependency.
- **Stable contracts.** Public JSON, MCP, CLI, profile, cache, and lease contracts
  evolve additively within 1.x. Breaking changes require a new schema or major
  version.
- **Cross-platform evidence.** Windows, macOS, and Linux are product claims, so
  release evidence must cover native hosts rather than only shared code paths.
- **Pure core, thin adapters.** Decisions and parsing remain deterministic and
  testable. Provider I/O stays isolated and bounded.
- **Machine-enforced quality.** Analyzer, tests, coverage, security checks,
  packaging checks, and contract checks are release gates, not aspirations.

## Current state

The current line, **0.5.18**, is best
understood as a feature-complete beta in release hardening. The core product
surface exists: CLI, `top`, desktop, analytics, MCP, loopback HTTP, model
registry, profiles, alerts, reports, leases, LiteLLM integration, verification
commands, release automation, and cross-platform CI. New breadth is frozen until
the remaining 1.0 trust gates close.

| Gate | State | Current evidence | What remains |
|---|---|---|---|
| Core contracts and automated quality | Ready for final rerun | Strict analysis, collector and desktop coverage floors, schema checks, CodeQL, secret scan, dependency review, and release policy are automated | Run the complete gate on the exact 1.0 candidate and tag |
| Integration trust boundary | Ready for CI | MCP and quotabot HTTP enforce loopback; the LiteLLM example now requires a bearer key and an explicit loopback host | Keep the launch regression test green and verify the packaged guidance |
| Provider truth and drift handling | Partial | Deterministic fail-closed drift admission, upgrade quarantine, `verify`, source docs, cache provenance, cross-machine account-wide live reads via self-refreshing Claude/Codex grants, and a Windows live record exist | Validate the connected-grant login flows on real accounts; close identity aliases, remaining response-shape fixtures, and current local-runtime compatibility gaps |
| Native provider evidence | Partial | Windows evidence exists; WSL covers truthful Linux failure behavior | Confirm naturally available states on native macOS and Linux, plus remaining human provider cross-checks |
| Installation and update | Partial | CLI archives, required checksums, attestations, one-line installers, source setup, lifecycle docs, and a three-OS smoke workflow exist | Record green clean-host lifecycle runs, automate remaining rollback/uninstall checks, and close desktop acquisition |
| First-run and recommendation comprehension | Partial | `doctor`, compact route lines, structured reasons, and setup recovery guidance exist | Prove a new user can identify the next route, why it won, source freshness, spend class, and fallback without decoding internal math |
| Accessibility and operator diagnostics | Partial | Desktop text scaling, keyboard and theme coverage, structured errors, `verify`, and `explain` exist | Run the final native keyboard/screen-reader smoke and verify every critical failure is actionable |
| Release rehearsal | Open | 0.5.14 release artifacts and provenance have been exercised | Run the true 1.0 tag-candidate workflow, install its artifacts on clean native hosts, then cut 1.0 |

Version numbers are not project phases. Continue small corrective 0.5.x patches
as needed, then cut 1.0 when the evidence gates pass. Do not manufacture 0.6,
0.7, 0.8, and 0.9 releases to represent work already completed.

## Version plan

The milestones below are a logical order of operations, not a schedule. There are
no time estimates. Each version is one coherent capability that the next builds on,
and the order is dependency order: make the inputs truthful, unify them into one
forecast, teach that forecast to grade itself, make its recommendation legible and
opinionated, then make the whole thing boring to install everywhere. The
non-negotiable boundaries above hold at every version; they are the constitution,
not a milestone, and a release that would break one is wrong regardless of its
number.

The ladder follows from what quotabot actually is. Under the meter it is one
object: a calibrated, honest forecast of each resource's availability over time,
shown as two faces from a single local, zero-token, advisor-never-proxy engine -
SEE (the glance) and ROUTE (the suggestion). The meter is commodity and a routing
heuristic is copyable in an afternoon; the durable moat is a calibrated,
self-tuning decision engine grounded in longitudinal local history no competitor
keeps. An exceptional 1.0 therefore ships that engine, not only a hardened meter,
which is why calibration lands before 1.0 rather than after it.

- **0.5.x, now - release hardening.** Feature-complete beta receiving only
  corrective patches: provider truth, cross-machine correctness, install and
  update, desktop robustness, and documentation. No new breadth. This line ends
  when 0.6 opens.
- **0.6 - Truthful substrate.** Every advertised route means exactly what it says,
  on every claimed provider, before anything is built on top. Close the remaining
  observation-layer gaps so the data feeding the forecast is trustworthy. A
  forecast built on untrustworthy observations is worse than no forecast, so this
  is first.
- **0.7 - One forecast, one engine.** Refactor the decision and windowing spine
  into a single pure, replayable core that every surface is a view of, and ship the
  deterministic replay and simulation harness it makes possible. The structural
  keystone: calibration, the decision receipt, and self-tuning are all impossible
  to do well until one forecast object exists, and cheap once it does. Mostly
  invisible by design.
- **0.8 - The moat: a forecast that grades itself.** On the forecast core, add the
  calibration ledger - log every prediction with the outcome later snapshots
  reveal, score it (Brier, reliability), and tune the free parameters on the user's
  own history - and surface it at the hood as "~94% calibrated over your last 30
  days". A predictor that publishes its own calibration cannot bluff. The only
  durable moat and the deepest honesty; it silently makes the glance truer.
- **0.9 - The self-explanatory, opinionated advisor.** With routing resting on a
  calibrated forecast, make it legible and aligned to the user: one plain-language
  explanation shared by every surface, one unified decision receipt, an explicit
  spend-order and provider-preference policy, local-first QOL, and multi-account.
  The visible product payoff, resting on an engine that has earned trust.
- **1.0 - Exceptional and rock-solid: it just works.** The quality bar in "1.0
  definition of done": native prebuilt desktop acquisition on every claimed OS,
  real native macOS and Linux evidence, accessibility smoke on native hosts, a
  boring clean-host install / update / uninstall / rollback lifecycle, every gate
  green on the frozen candidate, honest docs, and no known blocker - then rehearse
  until the cut is boring, and cut.
- **1.x - stabilization, then ranked outcomes.** The first 30 days are
  stabilization only (below). After that, the remaining ranked outcomes land
  additively without breaking a published 1.x contract: the next final MCP revision
  adopted deliberately, quota modeled as a typed shared pool before any weighted
  coding plan, multi-agent reservations hardened at volume, then distribution
  channels and admission-gated providers.
- **2.0 - only to change an invariant or a stable contract.** No 2.0 is planned;
  it exists solely as the escape hatch if a non-negotiable boundary or a public
  JSON/MCP/CLI/profile/cache/lease contract must change. Provider count and
  analytics breadth never justify a major version.

## 1.0 definition of done

1. Every claimed provider is assigned a source class: authoritative live,
   this-machine fallback, passive local evidence, local runtime, status-only, or
   manual. Each class has a documented routing rule, drift response, and
   verification method.
2. Deterministic fixtures cover healthy, low, exhausted, signed-out, stale,
   multi-account, reset-edge, malformed, and provider-drift states. Real-host
   evidence covers every naturally available state; unavailable states are
   marked fixture or not applicable rather than blocking forever.
3. No spent, stale, capability-exhausted, unverified manual, offloaded-cloud, or
   surprise-billing route can win a policy that excludes it.
4. A normal recommendation states what to use, why it won, how current and
   authoritative the evidence is, the applicable spend policy, and the fail-soft
   fallback. Advanced factors remain inspectable without dominating the default
   copy.
5. Public JSON, MCP, CLI, profile, cache, and lease contracts pass compatibility
   tests and are documented accurately.
6. The CLI installs from a verified release artifact with one documented path,
   and update, uninstall, data preservation, and rollback behavior are explicit.
7. The desktop surface has a native prebuilt acquisition path on every claimed
   OS, with no Flutter SDK required for normal use, or it is clearly labeled a
   source-built preview and removed from the primary 1.0 promise. The preferred
   outcome is a prebuilt first-class desktop surface.
8. Critical desktop and terminal flows pass keyboard, focus, text scaling,
   contrast, reduced-motion, and basic screen-reader smoke checks on native
   hosts.
9. Provider, auth, cache, webhook, integration, and alert failures are visible
   through bounded user copy, structured output, logs, or verification records.
10. Runtime paths contain no paid generation endpoint, credential leak, unsafe
    external bind, or silent external webhook behavior.
11. CI, lint, tests, collector and desktop coverage floors, CodeQL, secret scan,
    dependency review, packaging checks, checksums, and provenance checks pass
    on the final commit and tag.
12. README, setup, usage, data-source, schema, architecture, security, agent, and
    release docs describe the shipped artifacts without absolutes the product
    cannot guarantee.
13. No known release-blocking correctness, billing, credential, data-loss,
    installation, accessibility, or security issue remains open.
14. For every provider with an account-wide usage read, that read stays live on
    a machine the user has not actively used the host app on recently, by
    refreshing quotabot's own credentials without reading or writing the host
    app's credential files. When it cannot, the number is shown stale with an
    actionable next step, never as a confident current value, and any machine-
    scoped fallback is labeled this-machine.

## The path to 1.0, in detail

Dependency order, not a schedule. Each subsection is a milestone from the version
plan with its concrete work and its acceptance test. Items already shipped on the
0.5.x line are noted where they complete part of a milestone; the full history is
in the changelog.

### 0.6 - Truthful substrate

**Outcome:** every advertised route means exactly what it says, on every claimed
provider, before a forecast is built on top of it.

- Provider identity aliases for renames. **Mechanism shipped:** a one-way
  `kProviderIdAliases` map plus `canonicalizeProviderId`, funnelled through every
  identity seam (profile/hidden/filter/manual normalization, adapter resolution,
  lease keys, cache filename stems), so registering a rename preserves the user's
  durable state and routing resolution. The map is empty until a real rename
  ships (identity, zero behavior change), and guard tests keep it one-way and
  stop it shadowing a live provider. Remaining: an on-disk migration so cached
  snapshots, history, and analytics buckets written under the old id carry
  forward rather than regenerating from live reads after a rename.
- Pin every remaining supported response shape with sanitized fixtures.
- Resolve Antigravity weekly-window versus baseline-credit semantics from provider
  evidence. If the API exposes no stable mapping, keep baseline credits explicitly
  unsupported and unknown rather than inferring a window.
- Prefer LM Studio's current `GET /api/v1/models` contract, preserving v0 and
  OpenAI-compatible fallbacks. Parse loaded instances, context, size, quantization,
  and capability evidence without loading or invoking a model.
- Parse Ollama's documented loaded `context_length`. Detect or conservatively
  exclude cloud-offloaded Ollama models from policies that promise local-only or
  free execution. Never estimate throughput by generating content.
- Validate the connected-grant login flows (`login claude` / `login codex`) on real
  accounts, and add fixtures for the expired-host-token fall-through.
- Keep the LiteLLM loopback, bearer-auth, and unauthenticated-denial regression
  green as its pinned dependency changes.
- Already shipped on 0.5.x: cross-machine account-wide live reads via
  self-refreshing grants; the normalized six-value `source_class` contract across
  every surface; deterministic provider-drift admission with stale last-trusted
  fallback and legacy-cache quarantine.

Acceptance: targeted parser, policy, schema, integration, and regression tests
pass; docs state the same source and spend semantics as the code; no ambiguous
runtime can satisfy a local-only budget.

### 0.7 - One forecast, one engine

**Outcome:** SEE, ROUTE, and ALERT are three views of a single pure object, and
that object can be replayed and simulated deterministically.

- Consolidate the decision and windowing spine into one pure function,
  `decide(observations, now) -> (forecast, decision)`, with provider I/O kept in
  thin adapters. The code already leans this way; this finishes it.
- The forecast carries honest uncertainty as first-class data (a distribution or
  bounded interval, not a bare point), so a downstream view can render a word or a
  dot without re-deriving it.
- Build the replay harness: run the pure core over recorded local history, plus a
  `--mock-provider` simulation mode that drives it from fixtures. This is both the
  test bed for everything after and the substrate for the oracle benchmark.
- No public contract change and no visible behavior change beyond equal-or-better
  routes; existing SEE / ROUTE / `suggest` / `top` output stays stable, now sourced
  from the unified core.

Acceptance: the pure core has no I/O; SEE, ROUTE, and ALERT are all expressed as
views of its output; a recorded-history replay reproduces current decisions; the
simulation mode drives the full pipeline from fixtures with no network.

### 0.8 - The moat: a forecast that grades itself

**Outcome:** the number is not only shown, it is measured against what actually
happened, and it improves on the user's own data.

- Calibration ledger: log every prediction (strand probability, runway, "usable
  until X") with the outcome later snapshots reveal.
- Grade with proper scoring rules: Brier score and a reliability diagram - when the
  engine says 20% strand, does it happen about 20% of the time?
- Surface it at the hood: `quotabot calibration` and a deep `doctor` view
  ("predictions ~94% calibrated over your last 30 days"), so a skeptic can verify
  the glance is honest. Never assert calibration without enough local observations
  to support it.
- Self-tuning: fit the free parameters (EWMA half-life, comfort threshold, risk z,
  lead time) to minimize realized regret on local history, reducing to the shipped
  defaults when data is thin.
- The plain-language layer generates every casual sentence from the calibrated
  number underneath, so "about an hour left" is always backed and inspectable one
  layer down.
- Reset-aware burn. The recent-burn regression is a flat lookback today, so a
  refill inside the window (a scheduled reset, or a redeemed bonus reset) can read
  as "recovering" and skew the runway. Segment the burn at reset boundaries so a
  refill never counts as negative burn, and treat a redemption as a first-class
  event rather than an unexplained jump. The observed availability history already
  records the post-reset capacity; this makes the burn and runway honest around
  it, and pairs with the spent-window escape-hatch detection in 0.9.

Acceptance: predictions and outcomes are logged and replayable; Brier and
reliability are computed and exposed only when observations suffice; a documented
metric shows the tuned parameters beat the shipped defaults on recorded history
without breaking a safety invariant; thin-data cases degrade to the defaults.

### 0.9 - The self-explanatory, opinionated advisor

**Outcome:** the simple surface is clearer because of the engine under it, and the
recommendation is aligned to what the user actually wants.

- One plain human explanation shared by desktop, `doctor`, `suggest`, and `top`:
  winner, binding evidence, freshness and source, spend class, and fallback.
  Replace unexplained glance phrases such as "thin data"; reserve strand
  probability, shrinkage, pipe discount, and cost weight for expanded or
  machine-readable detail.
- One unified, low-cardinality decision receipt across CLI, desktop, MCP, HTTP, and
  LiteLLM: decision id, snapshot source and age, binding pool, raw headroom, every
  adjustment, confidence reasons, lease and pipe-health effects, spend policy,
  winner qualification, and each rejected alternative's reason. Content-free.
- An explicit user spend-order and provider-preference policy, per profile, applied
  among viable candidates only: it never overrides availability or the
  no-surprise-spend envelope, and it always shows in the reason ("Codex first by
  your preference").
- Local-first QOL: local model capability (context, size, quantization, loaded
  state), a hardware-fit signal (which installed models comfortably fit this RAM or
  VRAM, metadata only, never a throughput probe), and local-first stretch behavior
  when cloud quota is low.
- Multi-account: a work-and-home account per provider visible in one dashboard,
  generalizing the existing per-account model, without cross-contaminating
  profiles, cache, or history.
- Spent-window escape hatch. Some providers offer a one-time reset or bonus
  credit you can redeem to keep working after a window is spent (Codex/ChatGPT
  has surfaced such a reset). Investigate whether that availability is present in
  the usage metadata quotabot already reads; if it is, surface "a reset is
  available" on a spent card so the user sees the escape hatch instead of only a
  wait time. Zero inference and no purchase action - detection and display only,
  and only if the signal is authoritative (never inferred). Verify the exact
  provider mechanism before relying on it.
- Validate loading, empty, stale, auth, provider-drift, no-safe-route, alert, and
  integration states with first-time-user and operator checks.
- Already shipped on 0.5.x: the concise desktop route line with detail on hover,
  and the when-back emphasis on cards (a precise near-term countdown, an absolute
  day and time for a far reset).

Acceptance: a first-time user can answer the five recommendation questions in
definition-of-done item 4 from the default surface; the receipt is present and
low-cardinality on every listed surface; preference reorders only viable candidates
and is always explained; machine detail stays complete.

### 1.0 - Exceptional and rock-solid, then rehearse and cut

**Outcome:** the whole product is boring to install, verify, and update on every
claimed OS, and 1.0 is a version change rather than a discovery exercise.

- Complete native macOS and Linux records for naturally available providers and
  local runtimes; human cross-check live numbers against provider-owned views; keep
  simulated rare states separate from real-account evidence.
- Ship native prebuilt desktop bundles on every claimed OS with no Flutter SDK
  required for normal use, or explicitly narrow the 1.0 desktop promise to a labeled
  source-built preview (the prebuilt outcome is preferred). Confirm clean tray
  teardown on quit across all three OSes.
- Complete the native accessibility smoke for widget, analytics, profiles, dialogs,
  tray, and terminal navigation: keyboard, focus, text scaling, contrast, reduced
  motion, and basic screen reader.
- Run the three-OS clean install, previous-version upgrade, required-checksum,
  attestation, persistent-state, and source-setup matrix; exercise the
  inspect-before-run, update, data-preserving uninstall, destructive reset, and
  rollback paths, automating what can run safely on hosted clean machines.
- Rehearse and cut: freeze the exact candidate from a clean main worktree; run all
  local and hosted gates; build the tag artifacts and verify checksums and
  attestations; install and smoke on clean native Windows, macOS, and Linux; repeat
  native provider, recommendation, accessibility, and operator-failure evidence on
  the frozen candidate; confirm notes, docs, version agreement, support path,
  rollback, and GitHub security status; cut 1.0 only when the run is boring and
  repeatable.

Acceptance: every definition-of-done item is met with dated evidence or an explicit
fixture / not-applicable reason; every artifact installs and starts on a clean
native host; update preserves a sentinel; uninstall leaves no broken PATH entry;
the candidate run is boring and repeatable.

## First 30 days after 1.0

Stabilization only:

- provider drift and quota-correctness fixes;
- install, update, launch, and uninstall fixes;
- crash, auth, cache, and integration diagnostics;
- accessibility regressions;
- documentation corrections and support-safe diagnostic guidance;
- additive compatibility fixes for the final MCP specification if it publishes
  after the 1.0 freeze.

No provider-count race, broad analytics expansion, or speculative architecture
work enters this window.

## Ranked outcomes after stabilization

### P1. Grow the routing-evaluation corpus

The engine and its legibility land pre-1.0: the pure forecast core and replay
harness in 0.7, the calibration ledger and oracle benchmark in 0.8, and the
unified decision receipt in 0.9. What remains after 1.0 is to keep growing the
offline conformance and replay corpus that measures policy invariants, stalls
avoided, quota stranded at reset, fallback use, and calibration honesty across
more recorded histories and provider shapes. Do not claim optimality. A
routing-math change must beat the current policy on a declared metric without
breaking a safety invariant.

### P1. Adopt the next final MCP revision deliberately

The 2026-07-28 release candidate is a breaking protocol revision. Keep current
final `2025-11-25` behavior until the new revision is final and the Dart SDK and
conformance path are ready. Then add a dual-version compatibility matrix before
changing initialization, sessions, subscriptions, caching, trace context, or
JSON Schema behavior. Trace metadata must remain content-free.

### P1. Model quota as a typed shared pool

Before adding weighted coding plans, record pool scope, meter type, consumption
predictability, paid-continuation behavior, source authority, and policy
effective date. Cross-product and compute-weighted percentages must not be
presented as a linear number of future prompts. Write an ADR before changing the
windowing spine.

### P1. Harden multi-agent reservation behavior

Stress atomic cross-process reserve/release, idempotency, bounded TTL expiry,
crash cleanup, corrupt-ledger recovery, and decision visibility. Any reservation
weight is an explicit bounded caller policy because quotabot does not read the
task.

### P2. Expand distribution

After direct artifacts and update behavior are boring, add package-manager
channels in order of user demand and maintainability. Every channel must preserve
checksum/provenance verification, rollback, and cross-platform parity.

### P2. Add high-fit providers through an admission gate

GLM, MiniMax, Kimi, and Qwen are candidates, not commitments. A provider enters
implementation only when it passes all of these:

1. demonstrated user demand;
2. authoritative or clearly bounded quota metadata;
3. stable identity and authentication without cookie scraping;
4. zero-inference collection and explicit paid-continuation semantics;
5. a quota model representable without fabricated precision;
6. sanitized fixtures and deterministic malformed/drift cases;
7. a cross-platform discovery and verification plan;
8. fail-soft behavior and a named maintenance owner;
9. more routing value than the complexity it adds.

GLM remains the best researched first candidate because its official coding plan
publishes five-hour and weekly limits, but its time and model weighting means the
typed shared-pool work comes first.

Market survey, 2026-07-11: GLM, Kimi, Qwen (Alibaba ModelStudio), and MiniMax now
all sell subscription coding plans on exactly quotabot's native five-hour rolling
window plus a weekly cap - GLM at 4x the five-hour limit, Kimi 5x, Alibaba/Volcano
7.5x - so the windowing model already fits them. The complication that still gates
GLM is real: GLM-5 consumes quota at 3x GLM-4.7 and there are peak/off-peak
multipliers, which is precisely why quota-as-a-typed-shared-pool must land before
GLM rather than after. GitHub Copilot moved to usage-based AI Credits plus a weekly
token cap on 2026-06-01, so if it is ever added it is a credit-pool provider like
Cursor, never an included-quota plan. Amazon Q Developer is retiring (no new
signups from 2026-05-15) and migrating users to Kiro, which quotabot already
supports, so Q needs no separate adapter. None of this changes the 1.0 scope;
these remain post-1.0, admission-gated, and behind the typed shared-pool work.

## Product measures

quotabot has no telemetry. These are release and local evaluation measures, not
cloud collection:

- clean-install success and time to the first truthful `doctor` result;
- percentage of claimed source/OS cells with current evidence;
- route invariant pass rate over deterministic and replay corpora;
- recommendation explanation completeness across public surfaces;
- calibration error only when enough local observations exist;
- provider-drift detection and truthful degradation behavior;
- accessibility and keyboard smoke completion;
- support-safe diagnostic completeness without secrets or content.

## Deliberately deferred or rejected

- becoming a request proxy or hosted service;
- global leaderboards, account sync, or automatic telemetry;
- a general dollar-spend ledger;
- provider breadth as a goal by itself;
- model quality rankings or task-content inspection;
- inference probes for latency or tokens per second;
- automatic paid API fallback or hidden overages;
- draft-only MCP behavior before a final specification and supported SDK path;
- decorative analytics without a routing, trust, or support outcome;
- opaque learned routing while a small auditable policy is sufficient.

The recurring product question is: does this make the available-capacity
decision truer, clearer, safer, or easier to act on? If not, it is not roadmap
work.
