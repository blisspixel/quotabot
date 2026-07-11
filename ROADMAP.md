# Roadmap

Updated 2026-07-10. This file is the forward plan. Shipped work belongs in
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

The current line, **0.5.14**, is best
understood as a feature-complete beta in release hardening. The core product
surface exists: CLI, `top`, desktop, analytics, MCP, loopback HTTP, model
registry, profiles, alerts, reports, leases, LiteLLM integration, verification
commands, release automation, and cross-platform CI. New breadth is frozen until
the remaining 1.0 trust gates close.

| Gate | State | Current evidence | What remains |
|---|---|---|---|
| Core contracts and automated quality | Ready for final rerun | Strict analysis, collector and desktop coverage floors, schema checks, CodeQL, secret scan, dependency review, and release policy are automated | Run the complete gate on the exact 1.0 candidate and tag |
| Integration trust boundary | Ready for CI | MCP and quotabot HTTP enforce loopback; the LiteLLM example now requires a bearer key and an explicit loopback host | Keep the launch regression test green and verify the packaged guidance |
| Provider truth and drift handling | Partial | Deterministic fail-closed drift admission, upgrade quarantine, `verify`, source docs, cache provenance, and a Windows live record exist | Close identity aliases, remaining response-shape fixtures, and current local-runtime compatibility gaps |
| Native provider evidence | Partial | Windows evidence exists; WSL covers truthful Linux failure behavior | Confirm naturally available states on native macOS and Linux, plus remaining human provider cross-checks |
| Installation and update | Partial | CLI archives, required checksums, attestations, one-line installers, source setup, lifecycle docs, and a three-OS smoke workflow exist | Record green clean-host lifecycle runs, automate remaining rollback/uninstall checks, and close desktop acquisition |
| First-run and recommendation comprehension | Partial | `doctor`, compact route lines, structured reasons, and setup recovery guidance exist | Prove a new user can identify the next route, why it won, source freshness, spend class, and fallback without decoding internal math |
| Accessibility and operator diagnostics | Partial | Desktop text scaling, keyboard and theme coverage, structured errors, `verify`, and `explain` exist | Run the final native keyboard/screen-reader smoke and verify every critical failure is actionable |
| Release rehearsal | Open | 0.5.14 release artifacts and provenance have been exercised | Run the true 1.0 tag-candidate workflow, install its artifacts on clean native hosts, then cut 1.0 |

Version numbers are not project phases. Continue small corrective 0.5.x patches
as needed, then cut 1.0 when the evidence gates pass. Do not manufacture 0.6,
0.7, 0.8, and 0.9 releases to represent work already completed.

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

## Work remaining before 1.0

The order below is dependency order, not an estimate.

### P0. Close truth and compatibility gaps

**Outcome:** every advertised route means what it says before more release
evidence is collected.

- **Completed 2026-07-10:** add the source-class contract to verification and
  user-facing documentation. Every built-in adapter now declares its allowed
  provenance classes; current snapshots, routing and model candidates, alerts,
  reports, checks, MCP schemas, and verification records emit the normalized
  six-value `source_class`. Contradictory class/data shapes and unregistered
  cache identities fail closed before routing or measured history,
  machine-scoped evidence has a documented `0.7` confidence factor, legacy
  `source` compatibility remains explicit, and concise human labels plus
  source/verification tables expose the same semantics as the code. Registry,
  schema, verification, routing, CLI, MCP, and desktop regressions pin the
  contract and presentation.
- Add provider identity aliases for current renames without losing profiles,
  hidden-provider choices, cache, or history.
- **Completed 2026-07-10:** distinguish a reader that likely drifted from
  signed-out, exhausted, offline, and unsupported states. The deterministic
  `provider-drift` fixture, failed `provider_drift` verification check, stale
  last-trusted fallback, non-overwriting cache admission, persistent recovery
  diagnostic, cross-process observation ordering, legacy-cache quarantine, and
  explicit provider/model routing diagnostics pin routing/history/analytics
  exclusions without changing the stable verification state enum.
- Pin every remaining supported response shape with sanitized fixtures.
- Resolve Antigravity weekly-window versus baseline-credit semantics from
  provider evidence. If the API does not expose a stable mapping, keep baseline
  credits explicitly unsupported and unknown rather than inferring a window.
- Prefer LM Studio's current `GET /api/v1/models` contract, preserving v0 and
  OpenAI-compatible fallbacks. Parse loaded instances, context, size,
  quantization, and capability evidence without loading or invoking a model.
- Parse Ollama's documented loaded `context_length`. Detect or conservatively
  exclude cloud-offloaded Ollama models from policies that promise local-only or
  free execution. Do not estimate throughput by generating content.
- Keep the LiteLLM loopback, bearer-auth, and unauthenticated-denial regression
  green as its pinned dependency changes.

Acceptance: targeted parser, policy, schema, integration, and regression tests
pass; docs state the same source and spend semantics as the code; no ambiguous
runtime can satisfy a local-only budget.

### P0. Make the recommendation self-explanatory

**Outcome:** the simple surface is clearer because of the advanced engine, not
burdened by it.

- Define one plain human explanation shared by desktop, `doctor`, `suggest`, and
  `top`: winner, binding evidence, freshness/source, spend class, and fallback.
- Validate and keep the compact routing-intent matrix covering provider
  suggestion, local-first provider suggestion, model listing, model suggestion,
  `budget=local`, `budget=quota`, and expiring-quota behavior.
- Reserve terms such as strand probability, shrinkage, pipe discount, and cost
  weight for expanded or machine-readable detail. Replace unexplained phrases
  such as "thin data" on the glance surface.
- Verify loading, empty, stale, auth, provider-drift, no-safe-route, alert, and
  integration failure states with first-time user and operator checks.
- Complete the native accessibility smoke for widget, analytics, profiles,
  dialogs, tray, and terminal navigation.

Acceptance: a first-time user can answer the five recommendation questions in
definition-of-done item 4 from the default surface; machine detail remains
complete; affected persona and accessibility checks pass.

### P0. Complete native evidence and acquisition

**Outcome:** a user can install and verify the final product on every claimed OS.

- Re-run provider verification after P0 truth and recommendation changes.
- Complete native macOS and Linux records for naturally available providers and
  local runtimes. Human cross-check live numbers against provider-owned views.
- Keep simulated rare states separate from real-account evidence.
- Run the three-OS clean install, previous-version upgrade, required-checksum,
  attestation, persistent-state, and source-setup matrix.
- Ship native desktop bundles or explicitly narrow the 1.0 desktop promise.
- Exercise the documented inspect-before-run, update, data-preserving uninstall,
  destructive reset, and rollback paths. Automate the checks that can run safely
  on hosted clean machines.

Acceptance: each matrix cell has dated evidence or an explicit fixture/not-
applicable reason; every artifact installs and starts on a clean native host;
update preserves a sentinel; uninstall does not leave a broken PATH entry; data
reset does not remove a Windows CLI that remains on PATH.

### P0. Rehearse and cut

**Outcome:** 1.0 is a version change, not a discovery exercise.

1. Freeze the exact candidate and start from a clean main worktree.
2. Run all local and hosted quality gates.
3. Build the candidate tag artifacts and verify checksums and attestations.
4. Install and smoke the candidate on clean native Windows, macOS, and Linux.
5. Repeat native provider, recommendation, accessibility, and operator-failure
   evidence on the frozen candidate.
6. Confirm release notes, docs, version agreement, support path, rollback, and
   GitHub security status.
7. Cut 1.0 only when the run is boring and repeatable.

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

### P1. A unified decision receipt and routing evaluation

Expose one bounded receipt across CLI, desktop, MCP, HTTP, and LiteLLM: decision
id, snapshot source/age, binding pool, raw headroom, every adjustment, confidence
reasons, lease and pipe-health effects, spend policy, winner qualification, and
rejected-alternative reason. Keep it content-free and low-cardinality.

Build an offline conformance and replay corpus that measures policy invariants,
stalls avoided, quota stranded at reset, fallback use, and calibration honesty.
Do not claim optimality. A routing-math change must beat the current policy on a
declared metric without breaking a safety invariant.

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
