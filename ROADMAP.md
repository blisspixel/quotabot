# Roadmap

Updated 2026-07-19. This file is the forward plan. It records brief shipped
prerequisites only where remaining work depends on them; full shipped work
belongs in [CHANGELOG.md](CHANGELOG.md), implementation detail belongs in
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
  content. Quota reads spend zero usage tokens. Provider print or headless
  prompt commands such as `claude -p` are not quota APIs and are never used as
  collectors.
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
  not actively used the tool on recently. A configured refreshable quotabot
  grant must keep that read live by refreshing its own grant rather than
  depending on the host app to have run there. The implementation and fixtures
  exist; dated real-account idle-machine evidence remains a 1.0 gate. Without a
  usable host credential or local grant, it preserves last-trusted evidence as
  stale and gives an explicit repair step. A machine-scoped fallback is only
  ever shown when nothing account-wide is available, and it is always labeled
  as this-machine.
- **Stale resets prove nothing.** Cached quota keeps its original capture time
  and last observed percentage. A reset boundary passing after a failed live
  read never turns stale evidence into 100% free capacity or a routable result.
- **Scoped limits stay scoped.** A provider-reported model allowance can gate
  that model, but spending it never blocks unrelated models while the
  provider's shared subscription windows still have headroom. A measured scoped
  balance does not prove included-quota spend classification when entitlement
  differs by plan; that classification fails closed without explicit plan
  evidence.
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

The current line, **0.9.3**, contains the implemented core of the first three
milestones below: the truthful substrate (0.6), one calibrated forecast behind a
single decision core (0.7), and the self-tuning calibration moat (0.8). Those
implementation milestones are not the same as closing every 1.0 evidence gate.
The core product surface exists: CLI, `top`, desktop, analytics, MCP, loopback
HTTP, model registry, profiles, alerts, reports, leases, LiteLLM integration,
verification commands, release automation, and cross-platform CI. New breadth
is frozen until the remaining field validation, migration hardening,
accessibility, signing, and native release evidence below are complete.
Here, "current line" means the version prepared in source. The default
installer continues to resolve GitHub's latest published stable release, which
can remain the preceding version until this line's tag workflow completes.

| Gate | State | Current evidence | What remains |
|---|---|---|---|
| Core contracts and automated quality | Ready for final rerun | Strict analysis, collector and desktop coverage floors, schema checks, CodeQL, secret scan, dependency review, and release policy are automated | Run the complete gate on the exact 1.0 candidate and tag |
| Integration trust boundary | Ready for CI | MCP and quotabot HTTP enforce loopback; HTTP writes are authenticated lease-only metadata; LiteLLM atomically reserves remote routes and requires its own client bearer key on an explicit loopback host | Keep the launch regression test green and verify the packaged guidance |
| Provider truth and drift handling | Partial | Deterministic fail-closed drift admission, exact-account recovery, provider-backed Claude/Codex pool identities, source docs, cache provenance, grant implementations, and expired-host fall-through fixtures exist | Validate connected Claude/Codex grants on idle real-account machines; capture post-July-20 Fable entitlement evidence; link dated Windows evidence; close remaining response-shape fixtures and local-runtime compatibility gaps |
| Native provider evidence | Partial | Windows validation has been reported; WSL covers truthful Linux failure behavior | Link dated Windows evidence and confirm naturally available states on native macOS and Linux, plus remaining human provider cross-checks |
| Installation and update | Ready for candidate rerun | CLI and desktop archives have required checksums, restricted attestations, exact-asset barriers, and clean-runner lifecycle gates. The v0.9.2 published CLI passed clean install and prior-version upgrade smoke on Windows, macOS, and Linux. Official `v*` tags cannot be moved or deleted, and releases published after the July 18 immutability activation are locked | Run every gate on the exact candidate, then sign and notarize desktop apps and repeat the complete lifecycle on the frozen 1.0 candidate |
| First-run and recommendation comprehension | Ready for evidence | `doctor`, desktop, `suggest`, and `top` share one complete explanation, backed by the content-blind decision receipt and setup recovery guidance | Prove on native hosts that a new user can identify the next route, why it won, source freshness, spend class, and fallback without decoding internal math |
| Accessibility and operator diagnostics | Partial | Desktop text scaling, keyboard and theme coverage, structured errors, `verify`, and `explain` exist | Run the final native keyboard/screen-reader smoke and verify every critical failure is actionable |
| Release rehearsal | In progress | v0.9.2 passed the exact-asset and provenance audit plus clean native install, upgrade, source-setup, and persistent-state smoke | Run the same complete rehearsal on the frozen 1.0 candidate, including interactive desktop checks, then cut 1.0 |

Version numbers are not project phases. The logical 0.6 through 0.8 milestones
shipped together in 0.8.0, and 0.9.0 followed. Continue focused 0.9.x patches as
needed, then cut 1.0 when the evidence gates pass.

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

- **0.9.x, now - advisor completion and release hardening.** Finish the remaining
  0.9 explanation and decision-receipt work while taking focused corrective
  patches for provider truth, cross-machine correctness, install and update,
  desktop robustness, and documentation. No new breadth. This line ends when the
  1.0 evidence gates pass.
- **0.6 - Truthful substrate, core shipped.** Every advertised route means
  exactly what it says on every admitted provider. The remaining field evidence
  and migration hardening listed below are 1.0 acceptance work, not a second
  observation core.
- **0.7 - One forecast, one engine, shipped.** The decision and windowing spine
  is one pure, replayable core that every routing surface consumes, with a
  deterministic replay and simulation harness. Mostly invisible by design.
- **0.8 - The moat: a forecast that grades itself, shipped.** On the forecast core, add the
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
    refreshing quotabot's own credentials without requiring a fresh host token
    and without writing the host app's credential files. Host state may still be
    read for bounded credential or account discovery. When a live read cannot
    succeed, the number is shown stale with an actionable next step, never as a
    confident current value; a passed reset never changes stale evidence to
    100% free, and any machine-scoped fallback is labeled this-machine.

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
  snapshots, history, and analytics buckets written under the old provider id
  carry forward rather than regenerating from live reads after a rename.
- **Done:** new account-scoped snapshots, drift records, history, analytics
  buckets, evidence locks, and lease grouping use collision-resistant opaque
  account keys. During a one-way upgrade, exact-account legacy evidence remains
  readable, snapshot scans deduplicate canonical and legacy copies, and an
  ambiguous legacy bucket file can be claimed by only one verified identity.
- **Remaining:** mixed-version concurrent writes and downgrades are not a
  synchronization protocol. Once canonical history or bucket files exist, an
  older binary can still append to a legacy path that canonical readers do not
  merge. Safe aggregate reconciliation needs versioned baseline or generation
  metadata; without it, merging can double-count the shared legacy samples while
  choosing either file can discard newer samples. Stop
  older quotabot processes before upgrading, and do not run an older build
  against migrated state.
- Pin every remaining supported response shape with sanitized fixtures.
- **Done:** Antigravity weekly-window semantics resolved from live evidence. The
  Cloud Code endpoint reports each model's single binding limit with no window
  type; quotabot surfaces the account's most-constrained one as a single weekly
  window with its true reset, rather than a reset-delta guess that mislabeled a
  near-term weekly as "5h". The separate burst limit and per-model-group
  breakdown are not exposed by this endpoint and stay in the per-model quotas.
- **Done:** prefer LM Studio's current `GET /api/v1/models` contract, preserving
  v0 and OpenAI-compatible fallbacks. Parse loaded instances, context, size,
  quantization, and capability evidence without loading or invoking a model.
- **Done:** parse Ollama's documented loaded `context_length`. Detect or
  conservatively exclude cloud-offloaded Ollama models from policies that promise
  local-only or free execution. Never estimate throughput by generating content.
- Grant implementation and deterministic expired-host-token fall-through
  fixtures are shipped for Claude and Codex. Remaining: validate the connected
  login flows on idle real-account machines. Claude now hashes current provider
  profile account and organization ids into a stable pool identity for cache,
  drift, leases, routing, and duplicate credentials. When profile identity is
  unavailable, a credential-generation identity is the fallback and multiple
  successful credentials fail closed to one routable pool.
- Keep the LiteLLM loopback, bearer-auth, and unauthenticated-denial regression
  green as its pinned dependency changes.
- Already shipped on 0.5.x: the normalized six-value `source_class` contract
  across every surface; deterministic provider-drift admission with stale
  last-trusted fallback and legacy-cache quarantine.

Acceptance: targeted parser, policy, schema, integration, and regression tests
pass; docs state the same source and spend semantics as the code; no ambiguous
runtime can satisfy a local-only budget.

### 0.7 - One forecast, one engine

**Outcome:** SEE, ROUTE, and ALERT are three views of a single pure object, and
that object can be replayed and simulated deterministically.

- **Shipped:** `decide(observations, now, context) -> Decision` in
  `collector/lib/decision.dart` is the single pure front door. It recomputes
  nothing - the routing core already produced the whole forward forecast, so
  `Decision.forecasts` (the ranked candidates, each carrying headroom, recent
  burn and its standard error, strand probability, confidence, and runway) is
  the SEE view, `Decision.recommended` is ROUTE, and `alertsBelow` is ALERT: one
  object, three views, pinned by test. `DecisionContext` bundles the bounded
  caller inputs so a decision is one recordable value. The MCP, HTTP, and CLI
  suggest surfaces now source from `decide` (behaviour-identical).
- **Shipped:** the forecast already carries honest uncertainty as first-class
  data - burn standard error, strand probability, and confidence per candidate -
  so a view renders a word or a dot without re-deriving it.
- **Shipped:** `replay(frames)` folds the pure core over recorded observation
  frames deterministically; the `--mock-provider` simulation (`simulateFleet`)
  drives the whole pipeline through `decide` with no network. Both pinned by test.
- **Shipped:** secondary route surfaces, including `top`, desktop, HTTP, and MCP,
  receive their recommendation from `decide`; the calibration ledger keeps its
  pinned replay of hourly history.
- No public contract change and no visible behavior change: existing SEE / ROUTE /
  `suggest` output stays stable, `decide().route` equals `suggestRoute()`.

Acceptance (met by the pure core, its tests, and routing surfaces):
the pure core has no I/O; SEE, ROUTE, and ALERT are all expressed as views of its
output; a recorded-history replay reproduces current decisions; the simulation
mode drives the full pipeline from fixtures with no network.

### 0.8 - The moat: a forecast that grades itself

**Outcome:** the number is not only shown, it is measured against what actually
happened, and it improves on the user's own data.

- **Shipped:** the calibration ledger replays the strand predictor over the
  hourly history quotabot already keeps, resolving each prediction against the
  outcome later buckets reveal (`calibration.dart`).
- **Shipped:** graded with proper scoring rules - Brier score, expected
  calibration error, and a reliability diagram (predicted probability versus
  observed frequency).
- **Shipped:** surfaced at the hood via `quotabot calibration` ("N% calibrated
  over M predictions, Kd of history", the reliability diagram, and per-provider
  lines), with an honest empty state when the history is too thin to grade, and
  the headline also appears in `quotabot doctor`.
- **Shipped (first parameter):** self-tuning fits the burn lookback that makes
  the predictor best-calibrated on the user's own history (minimum Brier over
  candidates), degrading to the shipped default unless enough predictions have
  resolved and a candidate beats it on a comparable sample size - never
  overfitting a thin history. It is advisory by default; `quotabot suggest
  --tuned-burn` opts in to applying the fitted lookback to the burn feeding the
  decision. The other free parameters (comfort threshold, risk z, lead time) are
  routing-policy values tuned by realized regret (the oracle-benchmark corpus, a
  1.x piece), not calibration; see `.agent/DECISIONS.md`.
- The plain-language layer generates every casual sentence from the calibrated
  number underneath, so "about an hour left" is always backed and inspectable one
  layer down.
- **Shipped:** reset-aware burn. The recent-burn regression now fits only the
  current draw-down run, segmenting at a refill (a large single-step headroom
  jump, a scheduled or redeemed reset) so a mid-window refill is never read as
  "recovering" and does not skew the runway. A rolling window's gradual give-back
  is well under the threshold and is not segmented. The observed availability
  history already records the post-reset capacity; this makes the burn and runway
  honest around
  it, and pairs with the spent-window escape-hatch detection in 0.9.

Acceptance: predictions and outcomes are logged and replayable; Brier and
reliability are computed and exposed only when observations suffice; a documented
metric shows the tuned parameters beat the shipped defaults on recorded history
without breaking a safety invariant; thin-data cases degrade to the defaults.

### 0.9 - The self-explanatory, opinionated advisor

**Outcome:** the simple surface is clearer because of the engine under it, and the
recommendation is aligned to what the user actually wants.

- **Done (shared explanation):** one plain human explanation shared by desktop,
  `doctor`, `suggest`, and `top`:
  winner, binding evidence, freshness and source, spend class, and fallback.
  Replace unexplained glance phrases such as "thin data"; reserve strand
  probability, shrinkage, pipe discount, and cost weight for expanded or
  machine-readable detail.
- **Done (decision receipt):** one unified, low-cardinality
  `quotabot.receipt.v1` receipt across CLI, desktop, MCP, HTTP, and LiteLLM:
  deterministic decision id, snapshot source and age, binding pool, raw
  headroom, every adjustment, confidence reasons, lease and pipe-health effects,
  spend policy, winner qualification, and each rejected alternative's reason.
  Content-free and pinned by routing, schema, MCP, desktop, and LiteLLM tests.
- **Done (provider preference):** an explicit per-profile provider preference,
  applied among viable candidates only - it never revives an unavailable, spent,
  or spend-blocked route, and it shows in the reason ("first by your
  preference"). Persisted as `preference_order` in the profile and overridable
  per run with `suggest --prefer=a,b`; a pure `preferredViableCandidate` threaded
  through the decision core. A finer spend-order beyond provider preference
  (per-model or per-cost) remains open.
- **Done (local hardware fit):** reachable on-device models carry passive RAM
  and largest-single-GPU capacity evidence and a conservative `loaded`,
  `comfortable`, `tight`, `constrained`, or `unknown` fit. The model registry
  ranks that signal after loaded state, exposes the estimate and selected pool
  across CLI/MCP JSON, and explains it in plain model suggestions. Probes are
  bounded, cached, fail soft, and never load or invoke a model; fit remains
  advisory because runtimes may split memory.
- Remaining local-first QOL: thread declared local tool/vision capabilities into
  capability gates, and add local-first stretch behavior when cloud quota is
  low.
- **Done (multi-account):** provider accounts discovered on one machine can be
  shown together in one dashboard. Account-scoped profiles, cache, drift,
  history, and expansion state prevent work and personal evidence from being
  combined or visually confused.
- **Done:** Spent-window escape hatch. Codex's authoritative usage metadata
  carries `rate_limit_reset_credits.available_count` - the redeemable off-cycle
  resets a user can spend to refresh their limit early - verified against a live
  account (not inferred). quotabot surfaces it as an actionable line ("N
  rate-limit reset credits available - redeem in Codex to refresh your limit
  early") wherever provider details render, and `top` now shows provider details
  on a spent card too (previously dropped on the spent-collapse path), so a spent
  window shows the way out and not only a wait time. Detection and display only,
  no purchase action.
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
  **Done (portable artifact pipeline):** native Windows x64, macOS Apple Silicon,
  and Linux x64 archives now receive SHA-256 sidecars, archive-shape validation,
  native Windows/Linux readiness checks, build-provenance attestations, and a
  draft-release barrier. Clean native runners also re-download the draft assets
  and exercise side-by-side update, rollback, and data-preserving uninstall
  mechanics. Application signing, notarization, and a green tagged acquisition
  record remain required before this gate is closed.
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

The [release candidate for the planned `2026-07-28` MCP specification](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/)
is a breaking protocol revision. Keep current final `2025-11-25` behavior until
the new revision is final and the Dart SDK and conformance path are ready. Then
add a dual-version compatibility matrix before changing initialization,
sessions, subscriptions, caching, trace context, or JSON Schema behavior. Trace
metadata must remain content-free.

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

Market review, 2026-07-18: candidate coding plans use provider-specific rolling,
weekly, or credit pools whose exact ratios and weights are time-sensitive.
[GLM consumption](https://docs.z.ai/devpack/faq) is model-weighted and
time-weighted, which is precisely why quota-as-a-typed-shared-pool must land
before GLM rather than after. [GitHub Copilot billing](https://docs.github.com/en/billing/concepts/product-billing/github-copilot-billing)
uses a monthly AI Credit pool with optional paid continuation, so if it is ever
added it is a credit-pool provider like Cursor, never an included-quota plan.
[Amazon Q Developer](https://aws.amazon.com/blogs/devops/amazon-q-developer-end-of-support-announcement/)
blocks new signups from 2026-05-15 and ends support for IDE plugins and paid
subscriptions on 2027-04-30 while other AWS experiences continue, so it does not
justify a separate adapter ahead of Kiro. None of this changes the 1.0 scope;
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
