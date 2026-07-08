# Roadmap

Where quotabot is headed and what is deliberately out of scope. For the record of
what has already shipped, see [CHANGELOG.md](CHANGELOG.md).

## What quotabot is (and is not)

quotabot does two jobs: **see** how much quota you have left across the AI coding
subscriptions you pay for and your local models, and **route** the next request to
whichever one has budget. The point is simple: never stall mid-flow on a spent
cap, and never leave paid quota sitting unspent.

It **is**:

- a live rolling-window quota monitor (5h / weekly / monthly windows, real resets);
- a routing advisor: a signal source any router, proxy, or meta-router can read,
  available as a CLI, an MCP server, and a LiteLLM plugin;
- local-first and cross-platform (Windows, macOS, Linux), desktop widget plus CLI;
- aware of local runtimes (Ollama, LM Studio, Lemonade) as first-class fallbacks.

It is **not**:

- a cost or dollar-spend ledger (a different, already-crowded category);
- a router or proxy in your request path: it advises, and something else routes on
  that advice (LiteLLM is the shipped example, a hand-rolled meta-router is
  another); quotabot never becomes the data path itself;
- telemetry, a cloud service, or an account;
- a model quality or benchmark tool.

That second list matters as much as the roadmap: it is what keeps quotabot from
sprawling into the pile of interchangeable usage dashboards.

## Invariants

Non-negotiables. Every change is held to these; a feature that breaks one is the
wrong feature.

- **Your data is yours, and it stays local.** Your tokens, usage history, cache,
  and preferences live only on your machine. quotabot has no account, no cloud,
  and no telemetry, and never uploads or shares any of it. (This is about your
  data, not about whether quotabot talks to a provider: a request to a provider,
  such as confirming a service is reachable, moves none of your data anywhere and
  is fine.)
- **Never touches user content.** quotabot handles quota and usage figures only.
  It never reads or transmits your prompts, code, or other content; if a feature
  ever talks to a model, it sends only quotabot's own synthetic probe.
- **Advisor, never a proxy.** quotabot recommends where to send the next
  request; it never carries the request itself, and it never uses a provider's
  subscription credentials to make a model call on your behalf. It reads what
  your own tools already store and hands back a suggestion, staying out of the
  request path. That keeps it a lightweight, read-only signal source rather than
  another gateway in the critical path: nothing new to route through, nothing
  new to trust with your traffic, and each provider's own client keeps making
  the call the way it always has. Reading multiple accounts is fully supported;
  making the call on their behalf is simply not what quotabot does.
- **No surprise bills.** Runtime code must not call paid model, chat, image, or
  content-generation APIs. True included-quota plans are allowed only when the
  caller can prove overages are disabled; request-metered API keys remain
  explicit opt-in surfaces outside quotabot's default routing envelope.
- **Credential-careful.** Tokens are stored locked-down (owner-only on POSIX,
  ACL-restricted on Windows), never logged, and never written to JSON output.
- **Never disturb host credentials.** quotabot's own grants are independent;
  refreshing or reading must never invalidate a provider CLI's or IDE's login.
- **Fail soft.** If quotabot is unavailable or its data is stale, callers fall
  back to what they asked for. Routing is an optimization, never a dependency.
- **Honest data.** Surface staleness and age; never fabricate a number. A spent
  longer window overrides a healthy shorter one (the binding-window rule).
- **Cross-platform parity.** Every feature works on Windows, macOS, and Linux
  from one codebase.
- **Pure core, thin adapters.** Logic lives in pure, tested functions; adapters
  are thin I/O shells. The test-coverage floor is enforced in CI.
- **The strict bar is machine-enforced, not aspirational.** The strict analyzer
  runs clean in CI (zero warnings or infos); closed sets are types, not magic
  strings; untrusted input is bounded and fails soft at every boundary; and a
  falsifiable numerical claim is pinned by a test. Quality that only lives in a
  reviewer's head is a regression waiting to happen.
- **No attribution, no emoji, no em-dashes** in the repo.

## Road to 1.0

1.0 is a promise that the **core works exceptionally** and the public surface is
**stable**, not a feature count. quotabot can be a small utility and still be held
to a high bar: it should do its narrow job clearly, safely, and repeatedly across
the machines and accounts people actually use. 1.0 is not a claim that the
product is finished forever. It is a claim that the SEE and ROUTE core is trusted,
the public contract is steady, the installation and update paths are boring, and
known failure modes are honest instead of surprising.

The current line, **0.5.8**, is best
understood as a corrective and hardening pass on the feature-complete original
1.0 foundation, not as 1.0 itself. The major pre-1.0 surfaces exist: desktop,
CLI, MCP, HTTP, LiteLLM integration, profiles, leases, model routing,
analytics, no-surprise cost guardrails, release automation, and cross-platform
CI. What remains before 1.0 is not random feature work. It is release-candidate
hardening, real-world provider verification, docs accuracy, installer/update
polish, and a final security/reliability pass.

Adding a new provider does not get us to 1.0; an existing provider never lying
about quota on any claimed OS does. Sheer breadth, optimizer depth, package
manager distribution, and ecosystem work stay After 1.0 unless they are needed to
fix a 1.0 trust issue.

The build order to 1.0, as operations (not dates):

1. **Finish the host-doable hardening** now underway: the recurring adversarial
   security and correctness rounds until a round comes back empty, the
   remaining fail-soft and boundary defenses, and the code-quality elevation
   below. This is the bulk of the unreleased batch and continues until dry.
2. **Verify on real hardware.** The live provider matrix (item 22) and the
   clean-host install/update smoke tests (item 25) need native macOS and Linux
   machines with real signed-in accounts; they cannot be finished from a single
   OS. This is the true gate that only hardware unblocks.
3. **Freeze, dry-run, cut.** The final contract audit, the release-candidate dry
   run from a tag (item 28), and the cut (item 29) follow once 1 and 2 are done
   and boring.

The near-term hardening inside operation 1, from a mid-2026 SEE audit, in
logical order (each enables the next; no dates):

1. **SEE completeness and cross-device authority.** Quota is an account-level,
   server-side truth consumed across every device a person uses (laptop,
   desktop, phone), so quotabot must reflect the authoritative cross-machine
   number, not a per-machine local view. Landed: Antigravity per-model quota
   (`model_quotas`) now reads from the authoritative live endpoint, with the
   local `userStatus` cache demoted to an offline last-known fallback - it is
   per-machine, so it lagged usage on another machine and showed a stale ~100%.
   Claude already does this right: it reads the authoritative
   `api.anthropic.com/api/oauth/usage` endpoint (the same data the in-CLI
   `/usage` shows), reusing the stored token, so it is cross-device like Grok
   and Antigravity. The real gap is Codex: it reads `~/.codex/sessions` local
   files, and its own code notes the symptom - a fresh bucket shows 0% while
   real usage sits on another machine. Landed for Codex: it now reads the
   authoritative `chatgpt.com/backend-api/wham/usage` endpoint (the source the
   CLI's own status view polls), reusing the stored token - a free metadata
   read, no inference, no credential proxy - with the local sessions kept only
   as a this-machine fallback when signed out. Cursor/Windsurf/Kiro read local
   IDE state and may have no clean endpoint; landed: their reads (and the Codex
   session fallback) now carry `per_machine`, shown as a "(this machine)" note
   and exposed over MCP, so a local-only number is never mistaken for the
   account's cross-device total. Finding their own usage endpoints, if any, is
   the follow-up. Local runtimes are correctly per-machine. Addressed for
   Antigravity: successful reads use the live Cloud Code quota endpoint and keep
   the local `userStatus` cache as an offline last-known fallback, marked
   `per_machine`. Open: exact weekly versus baseline-credit distinction in the
   Antigravity API (research, no guessing). Rule: capture richly, display
   compactly, prefer authoritative over local.
2. **SEE integrity - a silent-drift canary.** 1.0 acceptance criterion 1 is
   "every provider either reads correctly or fails with a plain message," but
   nothing caught a read that is wrong and does not fail: a re-rated or
   repurposed pool, an inverted field, a fuzzy-key match that grabs an unrelated
   number. Landed: a first canary at the cache boundary compares each fresh read
   against the last cached one and flags a `suspect` value instead of trusting
   it (a reset that moved earlier, or usage that fell with no reset), fail-soft
   and provider-aware (Grok's legitimate re-rate and Antigravity's synthetic
   max-over-models window are exempt), surfaced in `json`, `doctor`, and MCP.
   This is the first use of stored history to validate a fresh read. Per-model
   drift on Antigravity's `model_quotas` now runs too (its window is synthetic,
   so the real signal is per-model). Next layer: calibrated large-jump/inversion
   detection (a big single-interval swing not explained by a reset), which needs
   a threshold tuned against real history to avoid flagging a heavy-use burst.
3. **The refresh and currency loop.** Run the drift canary and the model-catalog
   audit on a regular cadence so how usage works and which models exist stay
   current automatically.
4. **Close the feedback loop - pipe-health, not just the reservoir.** The world
   model is quota-only: no rate-limit, throttle, 529/degradation, or
   account-health state, and every adapter collapses a 429 into "no data," so a
   quota-rich but throttled provider is still recommended as free. The one live
   traffic stream (LiteLLM metrics) records only tokens and cost. Represent a
   throttled/degraded state distinct from no-data, and mine the 429/latency
   signal already flowing through the plugin.
5. **Capability-aware-by-default routing.** The capability-aware engine is
   opt-in behind `--task`; the default `suggest`, MCP `suggest_route`, and the
   `top`/`doctor` route line are capability-blind and can name the most-open but
   weakest provider for a hard task. Give the default path a capability floor
   (or carry task context) so the advisor's default answer is good, not only its
   opt-in answer. Antigravity's per-model quota is the prerequisite: routing a
   hard task there should require a capable model with headroom.
6. **A runtime-auditable trust surface.** The privacy boundary (reads only
   metadata, never your code, zero tokens) is asserted in docs and enforced at
   CI, but not verifiable at runtime. A `quotabot explain --reads --network`
   that emits the exact files touched and hosts called this run, tagged
   read-only/metadata, turns the headline claim from assertion into
   demonstration; `verify` is its natural home.

**Already in place** (the full record is in [CHANGELOG.md](CHANGELOG.md)): the
binding-window SEE rule with honest staleness; self-explaining, risk-aware
`suggest` with provenance (burn standard error, strand probability, confidence,
`--risk`); the per-model registry with capability and tier filters across CLI and
MCP; concrete model recommendation (`suggest --task`); MCP 2025-11-25 output
schemas and read-only annotations; calibration that grades the predictor;
the no-surprise-cost guardrail that rejects direct paid inference and image API
surfaces in runtime sources;
`quotabot top` with gradient meters, palettes, adaptive refresh, the
forward-looking forecast on the binding window, and full keyboard interaction
(sort, navigate, hide, copy-route) with stable exit codes; the same forecast in
the desktop widget; proactive low-quota alerts as `quotabot watch` and in the
widget, with an optional loopback webhook; the cross-platform release pipeline;
and CI green on an 85% coverage floor across Linux, macOS, and Windows.

The original feature foundation is recorded below. The release-candidate plan
after it is the path from 0.5.4 to 1.0. These are ordered as operations, not
time estimates.

### Version plan

- **0.5.x - foundation complete, small corrective patches.** Keep the current
  core stable, patch provider drift such as Fable 5 catalog changes, fix bugs,
  and avoid new breadth unless it protects the no-surprise routing promise.
- **0.6.x - release-candidate hardening.** Verify real provider behavior across
  supported operating systems and account states, tighten failure messages, and
  close any reliability or security defects found by daily use.
- **0.7.x - product polish and operator confidence.** Refine desktop, CLI, MCP,
  docs, logging, diagnostics, and accessibility so the utility feels quiet,
  predictable, and trustworthy instead of merely functional.
- **0.8.x - install, update, and packaging confidence.** Smoke test clean
  installs, upgrades, setup scripts, release artifacts, checksums, and rollback
  paths. The goal is a boring install and a boring update.
- **0.9.x - final release candidates.** Freeze scope, allow only fixes,
  documentation corrections, provider-drift patches, and release-blocker polish.
  There should be no planned breaking CLI, JSON, MCP, or profile-storage changes.
- **1.0 - stable utility release.** Cut only when the acceptance criteria below
  are true on the shipped artifacts, not only on a developer machine.
- **1.x - breadth after trust.** Add providers, package-manager distribution,
  deeper optimizer features, ecosystem integrations, and richer local-runtime
  capability work without weakening the local-first and no-surprise invariants.

### 1.0 acceptance criteria

1. Every claimed provider either reads correctly or fails with a plain, truthful
   reason across supported operating systems and common account states.
2. No runtime path calls paid model, chat, image, or content-generation APIs.
   Included quota is used only through explicit quota-plan routes, and
   request-metered paid APIs remain opt-in outside the default envelope.
3. The CLI, MCP server, HTTP endpoint, LiteLLM plugin, desktop widget, docs, and
   release notes tell the same routing story.
4. Public JSON, CLI, MCP, profile, and cache contracts are stable enough for
   users and agents to build around without churn.
5. Installers, source setup scripts, release artifacts, and checksum files pass
   clean install and upgrade smoke tests on Windows, macOS, and Linux.
6. CI, CodeQL, secret scanning, dependency review, linting, tests, and the
   coverage floor are green on the final commit and tag.
7. The README, ROADMAP, setup docs, usage docs, schema docs, architecture docs,
   and changelog describe what the product actually does, without overclaiming.
8. No known release-blocking security, billing, data-loss, credential-handling,
   installation, or provider-correctness issue remains open.

### Original foundation checklist

### Phase 1 - Parity across the surfaces

Finish the features that already half-exist, so the CLI, the widget, and the
alerts all tell the same story.

1. [x] Interactive `top`: sort (headroom / burn / strand risk / reset), filter or
   hide providers, keyboard navigation, and a one-key "suggest and copy the route
   command", with documented, stable exit codes a shell or agent can branch on.
   Shipped: live sort (`s`), cursor navigation (`j`/`k`, arrows), hide/unhide
   (`x`/`u`), copy-route to the clipboard via OSC 52 (`c`), and the 0/64/69 exit
   codes on `check` and a piped `top`.
2. [x] Forward-looking forecast in the **widget**, in plain language ("about an
   hour of usage left"), matching what `top` already shows.
3. [x] Proactive low-quota routing alerts: when a window crosses amber/red, name
   where to route next ("Claude 5h at 8% - send the next calls to Grok"), with an
   optional local webhook so the signal can reach a tray toast, a shell, or chat.
   Shipped as the headless `quotabot watch` command and the desktop app, both on
   one shared edge-triggered engine (`computeAlerts`) that fires once per
   crossing; the webhook is loopback-only unless external is explicitly allowed.

### Phase 2 - SEE is flawless on every platform

The real 1.0 promise: every claimed provider reads correctly, everywhere, with no
silent failures. It comes before the deeper testing work because the real runners
it stands up serve every phase after it.

4. [x] macOS and Linux CI runners, not just Linux. CI now runs the full suite on
   a matrix of ubuntu-latest and macos-latest (Windows to follow with item 5).
5. [x] Real cross-platform verification on macOS and Linux machines, not just
   "code paths ready"; a provider that cannot read says why, plainly. CI now runs
   the full suite on Linux, macOS, and Windows, so the paths are exercised on
   real hosts of every claimed OS; each adapter returns a plain error note
   (`ProviderQuota.error`, e.g. "no ~/.claude/.credentials.json", "token expired
   (re-run claude)") and `collectAll` falls back to the last-known snapshot
   rather than blanking. (Deeper hardware/manual passes continue as needed.)
6. [x] Token-refresh and onboarding edge cases handled and tested (Antigravity,
   Grok, Codex): expiry, multi-account, and signed-out states. Generalize the
   per-account model Antigravity already has (cross-platform profile scan, one
   card per active account, per-account caches keyed by email, auto-hide of
   signed-out accounts) to the other providers, keying auth and cache by
   (provider, account) in independent owner-only slots so work and home accounts
   under different emails coexist and the UI can group or filter by account. One
   primary account per provider stays the zero-config default; multi-account is
   additive, never forced on the common case. Foundation shipped: the OAuth token
   store now supports independent account-scoped grants; Grok device login and
   Antigravity OAuth login persist an account-scoped grant when the account email
   is available; Grok/Antigravity prefer the matching account grant before
   falling back to the provider-default grant or host-app token; Grok reads every
   account in its auth file with per-account cache fallback; Antigravity now
   attempts a live quota read for every discovered active profile/account. Codex
   now has adapter fixtures for missing sessions, absent `rate_limits`, stale
   snapshots, and multi-bucket scans. The desktop widget now groups distinct
   account identities, scopes expansion by provider/account, and automatically
   labels duplicate-provider cards. The shared active-account cache rule is
   tested and suppresses stale account snapshots once the provider's current
   local account index no longer contains that account. No additional pre-1.0
   provider exposes a reliable inactive-account index here; full named profiles
   remain item 8.
7. [x] Cursor and Windsurf first-class reads (both keep rich local state), and
   each provider's plan tier surfaced (e.g. Grok Free vs SuperGrok vs SuperGrok
   Heavy), so the value of the higher tier is visible. Two moving targets to
   absorb here: Cursor's paid plans are now a dollar-denominated monthly credit
   pool with pay-as-you-go overage, so surface it as remaining-pool-percent on
   its monthly reset (a window) rather than per-token cost accounting; and
   Windsurf was acquired by Cognition and folded under the Devin brand
   (renamed Devin Desktop in mid-2026), so the Cascade daily/weekly quota must
   keep reading under the new product name and local state path. Cursor now
   reads monthly included-usage pool shapes from local SQLite state and
   Windsurf/Devin Desktop reads daily/weekly Cascade quota shapes from its
   local state database. Both adapters surface account and plan labels when
   local metadata provides them; CLI-only Devin installs remain truthful
   detection-only results rather than fabricated quota windows.
8. [x] Profiles: named bundles (work / personal / per-project) that select which
   accounts and providers are in view, carry their own UI preferences (theme,
   sort, hidden providers), and pin a routing policy (local-only here,
   paid-tier-first there). Built on the per-(provider, account) plumbing from
   item 6, this is the polished way the multi-account case is handled: toggle in
   the app, or pass `--profile NAME` to the CLI and MCP so a router routes within
   the right identity. Shipped: `quotabot.profile.v1` storage, safe names,
   provider/account filters, routing policy, CLI `--profile`, MCP `profile`,
   desktop switching, desktop create/edit/delete, profile-scoped hidden
   providers, sort, theme, notifications, alert webhooks, and analytics. The
   `default` profile remains file-free and keeps the zero-config path.

### Phase 3 - Deterministic testability, then hard testing

9. [x] A simulation mode (`--mock-provider claude --state exhausted`) for
   deterministic core tests - built first here, since the tests below lean on it.
   Shipped: CLI simulation flags accept both `--name=value` and separated
   `--name value` forms, create one exact synthetic provider snapshot, and
   isolate the run from real adapter calls, analytics history, and burn-history
   influence. Covered states are `healthy`, `low`, `exhausted`, `blocked`
   (healthy short window but spent longer binding window), `signed-out`, and
   `stale`, with pure tests and process-level CLI tests for snapshots, checks,
   suggestions, and invalid-state usage errors.
10. [x] Property/fuzz tests on the untrusted parsers (they ingest external JSON
   and protobuf), plus integration tests against recorded provider fixtures.
   Shipped: seeded deterministic property/fuzz tests now exercise the JSON quota
   parsers, local-runtime JSON parsers, gRPC-web frame extraction, schema-less
   protobuf scanner, Grok billing window parser, Antigravity plan scanner, and
   embedded-token recovery. Parser boundaries reject non-finite numbers and keep
   emitted percentages bounded to 0..100. Sanitized provider-shape fixture files
   cover Codex, Claude, Antigravity, Cursor, Windsurf/Devin Desktop, Kiro, Grok,
   LM Studio, and Ollama through the pure parser paths.
11. [x] LiteLLM plugin covered by real-proxy integration tests. Shipped: CI now
    installs current `litellm[proxy]` under Python 3.13 and runs the plugin
    against a real LiteLLM proxy process, a loopback fake quotabot `/suggest`
    endpoint, and a loopback fake OpenAI-compatible backend. The test proves the
    actual `async_pre_call_hook` rewrites a logical model to the provider with
    budget, spends no model tokens, avoids external network calls, and exercises
    the current config-relative custom-callback loader. The plugin no longer
    depends on dataclass decoration so it remains loadable through LiteLLM's
    Python 3.13 config loader.
12. [x] Model-catalog currency: a refresh/audit tool that diffs the curated
    catalog against each provider's own model list (capabilities stay curated,
    since `/v1/models` endpoints do not expose context/tools/tier). Shipped:
    `collector/bin/catalog_audit.dart` reads provider-owned model-list endpoints
    for OpenAI/Codex, Anthropic/Claude, xAI/Grok, and Gemini/Antigravity,
    follows provider pagination tokens, filters obvious non-language modalities,
    redacts query-string secrets, and emits `quotabot.catalog_audit.v1` with
    `missing_from_catalog` and `catalog_only` diffs. It skips missing API keys
    without failing by default and offers `--fail-on-drift` / `--fail-on-error`
    for CI wiring; it never rewrites curated capability metadata automatically.

### Phase 4 - MCP reference depth and the router-grade signal

Make quotabot the de-facto quota/routing MCP server, on the one routing contract
shared by the CLI, MCP, and the LiteLLM plugin - including the primitives a real
router or meta-router leans on. quotabot advises, it is never the data path; the
leverage is the quality of the signal it hands a router.

13. [x] Streamable HTTP transport alongside stdio, tested, with capability scoping
    and complete tool-discovery metadata. Shipped: stdio remains the default;
    `bin/mcp_server.dart --http` starts an MCP Streamable HTTP endpoint on a
    loopback host only, with DNS-rebinding host/origin checks, batch rejection,
    optional bearer-token auth, and the same shared server factory, schemas,
    read-only annotations, resources, and tool metadata as stdio.
14. [x] Client snippets (Python/TS) so the contract is trivial to adopt.
    Shipped: `integrations/mcp_clients/` now contains Python and TypeScript MCP
    clients for both stdio and Streamable HTTP, shared summary helpers, stable
    SDK guidance checked on June 29, 2026, bearer-token support for HTTP, and CI
    smoke tests that compile Python snippets, typecheck TypeScript snippets
    against the current SDK, and assert current SDK transport imports.
15. [x] Concurrency leases (`reserve` / `release`) so parallel agents do not
    dogpile the same pick and the next caller sees the reduced effective headroom,
    paired with a cheap cached "decide now" read that always states its
    `as_of`/staleness so a router can query per request without forcing a live
    collect. Shipped: MCP now exposes cache-only `decide_now`, local
    `reserve_provider`, and idempotent `release_provider`; active leases are
    file-backed with locking in production, in-memory in tests, TTL-bound, capped,
    idempotency-key aware, and surfaced as `lease_discount_percent` on ranked
    candidates without entering the prompt or model-request path.
16. [x] Profile- and account-scoped routing queries (`--profile`, from item 8),
    plus a subscribe path - the Phase 1 threshold webhook generalized to an MCP
    notification - so a router reacts to a window crossing amber or red instead of
    polling for it. Shipped: MCP read/routing tools accept exact `account`
    filters after named `profile` filters, `check_provider_availability` can
    target a provider/account pair, and the server exposes `quotas://alerts` with
    standard `resources/subscribe` / `resources/unsubscribe`. The subscription
    loop reuses the existing edge-triggered alert engine, emits
    `notifications/resources/updated` for `quotas://alerts` on amber/red
    crossings, and keeps resources unfiltered for compatibility.
    Watchlist 2026-07-07: the MCP 2026-07-28 release candidate is
    roadmap-relevant but not a 1.0 blocker while it remains pre-final. After the
    final spec lands, run a focused MCP compatibility audit for stateless
    Streamable HTTP, `Mcp-Method` / `Mcp-Name`, `server/discover`, resource
    subscription migration from `resources/subscribe` to `subscriptions/listen`,
    `ttlMs` / `cacheScope` on list/read responses including `tools/list`, Tasks
    / Apps extensions, authorization hardening, full JSON Schema 2020-12 tool
    schemas, and roots/sampling/logging deprecations.

### Phase 5 - Freeze and ship

Last, once every schema-touching feature above has landed, so the contract frozen
here is the final one.

17. [x] Freeze the `quotabot.v1` JSON schema and add a compile-time adapter plus
    required-fixture registry, with an "add a provider in 10 minutes" checklist in
    CONTRIBUTING.
    Shipped: `schema_contracts.dart` now defines the additive JSON Schema
    2020-12 contract and validator for `quotabot.v1`; `provider_adapters.dart`
    is the compile-time built-in adapter and fixture registry; registry tests
    require one committed sanitized provider-shape fixture per adapter, including
    Lemonade; CONTRIBUTING has the provider checklist.
18. [x] A recurring security pass and an adversarial bug-hunt round that returns
    empty (see continuous hardening below).
    Shipped: a repository-wide adversarial scan reviewed 101 tracked source,
    integration, installer, and CI files, fixed seven plausible security
    candidates, pinned each fix with regression tests, and closed with no open
    reportable findings. Hardened areas include cache snapshot provenance,
    owner-only local metadata permissions, Windows SQLite library loading,
    LiteLLM agent identity, LiteLLM loopback fetch redirects, LiteLLM metrics
    path containment, and least-privilege GitHub Actions token permissions.
19. [x] An animated GIF in the README (the widget collapsing and expanding, `top`
    live, the 90-day analytics view), built from demo mode so it stays
    reproducible, plus verified macOS and Linux packaging.
    Shipped: README now uses `docs/quotabot-demo.gif`; the reproducible source is
    `tools/generate_readme_demo.py` with the Flutter demo screenshot exporter.
    Screenshot mode captures expanded and compact widget frames, a 90-day
    analytics frame, and the demo `top` frame. CI now verifies macOS and Linux
    desktop release bundle builds on native runners through dedicated package
    scripts.
20. [x] Original feature foundation complete, suite green on Windows, macOS, and
    Linux.
    Shipped: all original 1.0 foundation boxes are checked. The local gate
    passed on Windows with collector format/analyze/tests/coverage, app
    format/analyze/tests/build, MCP client checks, LiteLLM direct plus real
    proxy tests, collector executable builds, generated README media validation,
    shell script syntax checks through Git Bash, and hygiene scans. GitHub
    Actions passed the matrix on Linux, macOS, and Windows, including native
    macOS/Linux desktop package-build verification. The 0.5.x line is a strong
    release-candidate foundation, not an automatic 1.0.

### Release-candidate hardening to 1.0

21. [x] Freeze 1.0 scope. Only allow fixes, provider-drift corrections, docs
    corrections, release-blocking polish, and validation improvements. Defer new
    providers and broad feature ideas to After 1.0 unless they are required to
    protect an invariant.
    Declared with the 0.5.x line: the scope freeze is in effect. New work from
    here to 1.0 is limited to the categories above; everything else moves to
    After 1.0.
22. [ ] Run a live provider verification matrix on real machines and accounts:
    Claude, Codex, Antigravity/Gemini, Grok, Cursor, Windsurf/Devin Desktop,
    Kiro, Ollama, LM Studio, Lemonade, and manual entries. Cover healthy,
    exhausted, signed-out, stale, multi-account, and reset-edge states wherever
    the provider exposes them.
    Tooling shipped: `quotabot verify` runs the mechanical honesty checks over
    one live read (bounds, capture times, staleness labels, reset plausibility,
    account uniqueness, and frozen `quotabot.v1` conformance), emits a
    `quotabot.verify.v1` record with `--json`, exits 65 on any failure, and
    names each provider's own usage surface for the human cross-check. The
    matrix itself is filled from date-stamped verify records per OS; the first
    Windows column is recorded, macOS and Linux remain.
23. [x] Re-audit no-surprise billing end to end. Confirm runtime sources still
    avoid paid model, chat, image, and content-generation APIs; confirm LiteLLM
    paid API routes stay opt-in; confirm `--budget=quota` excludes manual,
    credit-backed, request-metered, and expired temporary quota routes.
    Re-audited 2026-07-01: every outbound call site classified (quota
    metadata, auth, or local runtime reads only), LiteLLM gating and the
    manual/cutoff exclusions confirmed with their pinned tests, and the one
    gap found was closed: `--budget=quota` now enforces an explicit
    quota-plan provider allowlist instead of relying on catalog omission,
    pinned with a test.
24. [ ] Polish user-facing trust surfaces. The desktop widget, `top`, `doctor`,
    `suggest`, `models`, alerts, and docs should make quota age, staleness,
    account identity, fallback behavior, and spend class clear without noisy
    caveats. In progress: `top` now shows cache age, account identity on
    duplicate providers, spend class, local-only scope, and column-stable narrow
    rendering; analytics shares the dashboard chrome; `verify` now states each
    provider's honesty plainly, labels live/cached/error/metadata provenance,
    and surfaces truthful cached/no-data reasons; weekly markdown reports now
    show read state, spend class, and capture age while preserving report JSON;
    failed quota-plan reads now keep their spend class in `doctor` and `verify`;
    desktop provider cards and human `doctor`, alert, provider recommendation,
    and model recommendation surfaces now label live/cached state, spend class,
    real account identity, local readiness where applicable, per-machine scope,
    and capture age; local runtime snapshots also set the existing
    `per_machine` JSON flag explicitly, while recommendation JSON shapes remain
    stable.
25. [ ] Smoke test install and update paths on clean Windows, macOS, and Linux
    hosts: one-line installers, source setup scripts, desktop shortcut/tray
    setup, CLI-only setup, release archives, checksums, `quotabot doctor`, and
    upgrade from the latest 0.x release. Progress 2026-07-01: Windows
    `install.ps1` verified against the live v0.5.5 artifacts (checksum,
    upgrade over a source install, correct version, verify passes) and
    `install.sh` verified in WSL Ubuntu with a truthful signed-out `verify`.
    Native macOS and Linux hosts remain.
26. [x] Final contract audit. Review `quotabot.v1`, model JSON, report JSON,
    MCP tools/resources, profile storage, leases, cache files, exit codes, and
    docs for accidental churn before declaring the surface stable.
    Audited 2026-07-01 across every schema id, MCP tool, storage file, and
    documented flag. Fixed: `check --json` no longer mislabels its shape as
    `quotabot.v1` (now `quotabot.check.v1` with `as_of`), MCP
    `provider_with_most_headroom` gained `quotabot.headroom.v1` plus `as_of`,
    MCP output schemas declare their injected profile/account/error fields,
    and SCHEMA.md now documents every emitted field including
    `quotabot.calibration.v1` and `quotabot.catalog_audit.v1`.
27. [ ] Final security and reliability pass. Run secret scanning, CodeQL,
    dependency review, installer/script review, credential-handling review,
    local-file permission review, webhook/HTTP host validation review, and an
    adversarial bug hunt. Fix and pin anything real with tests. First
    post-freeze round completed 2026-07-01: credential handling, webhook/HTTP
    validation, file permissions, and installers came back clean; two real
    findings (terminal escape injection via provider strings; a hung provider
    wedging the fleet and the desktop poll loop) were fixed and pinned with
    tests. The item closes when a repeat round comes back empty.
28. [ ] 1.0 release candidate dry run. Build artifacts from a tag candidate,
    verify release notes and checksums, install from artifacts, run smoke tests,
    verify GitHub alerts are clear, and confirm the working tree has one clean
    main branch.
29. [ ] Cut 1.0 only after the dry run is boring. The final release should feel
    like publishing a utility that has already been used, installed, updated,
    and audited, not like discovering whether it works.

### Continuous hardening (runs throughout, not a phase)

Getting to "exceptional" is a cadence, repeated until it stops finding anything,
in parallel with the phases above rather than after them:

- **Repeated adversarial bug-hunt rounds:** multi-agent sweeps over the whole
  codebase, each finding fixed and pinned with a regression test, run again until a
  round comes back empty.
- **Recurring security reviews:** token handling, host/SSRF validation for local
  runtimes, injection via provider data, and the install supply chain. Each pass
  fixes what it finds. Automation shipped: Dependabot now tracks GitHub Actions,
  Dart `pub`, and the MCP TypeScript snippet package, CodeQL analyzes the Python
  and TypeScript surfaces GitHub supports, and a pinned gitleaks job scans for
  secrets server-side on every push and PR.
- **Code-quality elevation (raise the bar, then hold it):** the pure core, the
  defensiveness, and the naming are already at the "would-a-CS-PhD-be-proud"
  bar; a few enforceable elevations remain, ordered by leverage. (1) The strict
  analyzer is on with `strict-casts`; the deliberate follow-up,
  `strict-inference` + `strict-raw-types`, was completed 2026-07-07 with the
  collector analyzer enforcing all three strict modes, explicit generic JSON
  and collection boundaries, full collector tests, app tests, and 90.24% line
  coverage. (2) Turn the core's
  remaining closed sets from magic strings into the type system so a new value
  cannot be half-handled: `ProviderQuota.kind` (completed 2026-07-07 with
  `ProviderQuotaKind`, `ProviderAdapterClass.quotaKind`, and JSON wire values
  preserved), the manual quota source marker (completed 2026-07-07 with
  `providerQuotaManualSource` / `ProviderQuota.isManual` and JSON wire values
  preserved), and `RouteFallback.kind` (an enum, dropping the `_ =>` catch-all
  that would silently swallow a new kind; completed 2026-07-07 with JSON wire
  values preserved). (3) Make the provider registry executable - a `collect`
  factory on the registration so `collectAll` and the cache's account-scoped
  set derive from it - so adding a provider is one declarative addition, not a
  four-to-six-site edit (completed 2026-07-07 with registry-owned collectors,
  account-scoped cache metadata, and collection-order tests). (4) Route the
  desktop color
  through the collector's `Palette.rgbFor` to kill a small drift; completed
  2026-07-07 by routing desktop headroom colors through the shared palette.
  Numerical contracts (erf/normal-CDF) are now pinned by tests; keep new
  falsifiable math claims pinned the same way.

Self-tuning - using the calibration loop to fit the routing parameters on local
history - and the deeper statistical layers are quality multipliers: valued and
pursued continuously, but not 1.0 gates.

## After 1.0

Breadth and depth, once the core is trusted:

- **More quota-window providers:** the "coding plan" cohort is the truest fit
  and the priority, since it sells Claude-Max-style rolling request windows that
  map straight onto the SEE model. Build order, chosen by fit and read model
  (each is trackable through the provider's own usage endpoint with the API key
  the user already holds, so no cookie or keychain scraping): **GLM (Z.ai)
  first** (explicit 5h + weekly prompt numbers, public devpack docs), then
  **MiniMax** (request-per-5h with weekly = 10x), then **Kimi** (5h + weekly,
  metered in tokens/calls within the window), then **Qwen** (fixed monthly,
  rolling 5h, but credit-weighted by model, so a looser fit). Watch **OpenCode
  Go** as a multi-model aggregator front-end (it covers DeepSeek/Qwen/MiniMax/
  GLM behind one sub) rather than adding DeepSeek natively, since DeepSeek has
  no rolling-window subscription of its own. Amp is pay-as-you-go credits with a
  daily dollar cap, so cost-only or skip.
- **Peak-hour and per-model consumption weighting (build before or with the
  cohort above):** the new cohort breaks the flat "prompts remaining" model. GLM
  consumes 2-3x during peak hours; Kimi and Qwen meter tokens/credits within the
  window. "Remaining" is therefore model- and time-weighted, not linear. This is
  a shared requirement across GLM/MiniMax/Kimi/Qwen, so build the weighting once,
  at the window model. Note the code-quality dependency: `QuotaWindow` is a flat
  value type today and `windowUsedPercent` is a pure function of the stored
  percent, so an honest multiplier is a deliberate change to the windowing spine
  (an optional `weight` threaded through `windowUsedPercent`/`windowHeadroom`/
  the parsers/to-from-JSON), not a bolt-on. Do it with the type-system elevation
  below, not hastily.
- **Provider renames and identity aliasing:** 2026 renames must not silently
  break existing configs or history keyed by the old id. Amazon Q -> Kiro is
  handled (quotabot reads Kiro); still to alias: Windsurf -> Devin Desktop
  (Cognition, June 2026) and Gemini CLI -> Antigravity CLI. Map old ids to new
  in provider identity so a user's saved profile, hidden set, and burn history
  survive the rename.
- **Guard the fragile readers:** two current readers can break silently on
  provider drift and deserve a "reader may have broken" signal plus a pinned
  shape test. Claude's usage read depends on a rotating `anthropic-beta` header
  that has changed before; Antigravity's local session-file path is churning as
  Gemini CLI becomes Antigravity CLI. A silently-empty read here should surface
  as a plain "couldn't read, the provider may have changed" rather than a blank.
- **Reclassify Windsurf/Devin Desktop as a primary window provider.** As of June
  2026 it dropped the monthly credit pool for daily + weekly Cascade quotas,
  which fit the primary rolling-window model; keep it there (not in the cost-only
  tranche) under the new Devin Desktop name.
- **Cost-only, never primary:** GitHub Copilot moved most plans to AI Credits in
  June 2026, Cursor is a dollar credit pool (two pools since June 2026), Kiro
  meters monthly interactions, and Amp/DeepSeek are token pay-as-you-go. Spend-
  based aggregators (OpenRouter, Together, Fireworks), the credit-metered app
  builders (Replit, v0, Lovable, Bolt), and credit-pool tools (Warp, JetBrains
  AI) are only ever a secondary cost view, since they meter dollars or credits,
  not a rolling-window quota. Amazon Q is skipped: AWS retired it in favor of
  Kiro (which quotabot reads), so the AWS path is to deepen Kiro.
- **User-defined manual quota entries:** an optional way to add a tool quotabot
  has no adapter for (a limit, a reset, and an updatable used figure), so the
  long tail (Tabnine, JetBrains Junie, Trae, and similar) still shows in one
  place. Clearly marked self-reported, never fed into the routing confidence math
  as if it were measured burn, and never invented - the number is only ever what
  the user typed. Foundation shipped: `quotabot manual set/list/remove` stores
  local self-reported windows, exposes them in normal views and JSON as
  `source: "manual"`, excludes them from measured analytics history, and lowers
  routing confidence for them.
- **Capability-aware routing, deeper.** The foundation shipped (`--task`,
  `--min-context`, `--require-tools`/`--require-vision`/`--require-reasoning`, tier
  floor/ceiling, cheapest-qualifying-with-budget-wins, local-first, and the
  invariant that quotabot never reads the task). What remains post-1.0 is the rest
  of the knobs (broader `--exclude` surfaces) and a cohesive aggressive
  local-first mode that escalates to a paid plan only when the requirements force
  it or a window is about to reset. Models stay filtered by objective capability
  and the provider's own tier, never a quotabot quality ranking. Foundation
  shipped: all quota-reading CLI commands accept `--exclude=A,B` after profile
  filtering, MCP read/routing/reservation/model tools accept `exclude`, and
  local HTTP `GET /suggest` accepts `?exclude=A,B` for the same one-off provider
  exclusion without editing profiles. Provider routing now has an explicit
  local-first policy as well: CLI `suggest --local-first`, MCP
  `local_first`, and HTTP `?local_first=true` recommend a local runtime before
  subscription quota when local capacity is available. The LiteLLM plugin also
  distinguishes `spend: quota_plan` from `spend: paid_api` so included quota
  plans can be used only after an explicit `overages_disabled: true` or
  `overages: disabled` declaration, while request-metered API routes are
  skipped by default. Model routing now has a `budget` envelope too:
  `--budget=local` is a hard local-only cap, while `--budget=quota` allows local
  runtimes plus measured built-in quota plans and rejects self-reported manual
  quotas. Profiled `suggest --use-expiring-quota` and MCP `suggest_model` with
  `use_expiring_quota: true` now cover the use-it-or-lose-it branch: a measured
  quota-backed model can outrank local only when local burn analytics project at
  least 35 percent of included quota would expire unused within 24 hours. Burn
  history is account-scoped when account identity is available, so multi-account
  routing uses the matching account's pace instead of a provider-wide estimate.
  The desktop widget header now surfaces the same burn-aware route provenance in
  a compact next-route line with confidence, while keeping single-account labels
  out of the main view. Provider suggestions now rank metered subscriptions by
  an additive `routing_score`: confidence-weighted risk-adjusted runway, so a
  slower-burning provider can beat one with more instantaneous headroom but a
  shorter runway. Recent burn estimates now use conservative empirical-Bayes
  shrinkage at the routing input boundary, pulling thin provider/account
  histories toward the current fleet burn mean without changing account
  identity or raw stored history. Provider suggestions now also accept explicit
  caller-supplied cost penalties: CLI `--cost-penalty=provider:N`, MCP
  `cost_penalties`, and loopback HTTP `cost_penalty=provider:N` apply a
  default-one cost weight only when the caller supplies the policy, exposing
  `cost_penalty`, `cost_discount`, and `cost_weight` provenance without
  inferring prices or enabling paid API routes.
- **Optimizer features:** use-it-or-lose-it alerts when projected waste at reset
  crosses a threshold; downgrade/upgrade ROI (rolling p90 vs each tier's cap, with
  $/mo saved and breach probability); reset-anchored scheduling. Foundation
  shipped: `quotabot watch --waste-threshold=N` emits opt-in
  `projected_waste` alerts from current pace analytics. The first tier ROI slice
  is now an explicit `quotabot stats --tier-plan=NAME:CAP[:PRICE]` advisory:
  callers supply candidate caps and prices, quotabot estimates breach
  probability from local history, and optional monthly deltas are shown only from
  caller-supplied prices.
- **First-class local models (the moat):** VRAM/readiness awareness ("can I run
  70B Q4 right now?", loaded vs cold, tokens/sec) and per-model capability tags,
  so "free" never secretly means a two-minute wait or a flubbed refactor.
  Foundation shipped: model registry entries now surface `local_readiness`
  (`loaded` or `cold`), and concrete model suggestions prefer loaded local
  models ahead of installed-but-cold local models when both satisfy the same
  requirements. MCP model schemas now advertise local `size_bytes`,
  `vram_bytes`, and `quant` metadata, and local model recommendation reasons
  include available VRAM/context/size evidence without making a model call.
- **Richer analytics:** hour-by-weekday heatmap polish, a contribution calendar,
  streaks and summary stats, plan-tier modeling, and provider status polling.
  Foundation shipped: analytics now compute current sampled-day usable/spent
  streaks from the same compact hourly history buckets and surface them in
  `quotabot stats`, `quotabot report`, and `quotabot.report.v1`. Provider/account
  bucket files now preserve per-account burn history for routing, reports, alerts,
  stats, and the desktop widget, while provider-only files remain a legacy
  fallback for unambiguous snapshots; `quotabot stats` now uses account-qualified
  series keys only when a provider appears more than once. Stats and reports now
  also include a compact sampled-day
  contribution calendar derived from those same local buckets. Heatmap polish has
  started: stats, reports, JSON, and the desktop heatmap now surface the best
  sampled weekday/hour windows with sample counts, and those best-window
  rankings now use conservative wrapped smoothing when neighboring evidence
  exists so one isolated quiet hour cannot dominate the recommendation. The same
  local history now produces a reset-aware schedule hint: the nearest strong
  weekday/hour slot that starts before the active reset. Reliability rates in
  stats, reports, and desktop analytics now use conservative beta-binomial
  shrinkage, pulling thin provider/account histories toward the current fleet
  usable rate without changing raw stored history. Best-time windows now also
  carry shrunk weekday/hour usable rates and a reliability-weighted scheduling
  score, so sparse quiet cells with spent samples cannot outrank consistently
  usable windows on raw free percent alone. The first optimizer provenance hook
  now exposes per-candidate `runway_hours` separately from the confidence
  multiplier, making the public route score auditable. Provider routing now also
  applies the first explicit waste weight: measured, available quota near reset
  gets a modest use-it-or-lose-it boost when local burn projects meaningful
  unused included quota at reset, while manual, stale, local, and ambiguous
  multi-account signals are excluded. Explicit provider cost weighting is now
  shipped as an opt-in caller policy. Tier ROI has its first safe slice through
  explicit plan inputs in `stats`; broader plan-price modeling remains secondary
  and must not turn the primary product into a spend ledger.
- **Surface routed-request metrics** from the LiteLLM plugin back in the widget.
  Foundation shipped: the desktop Quota Analytics Now view reads the default
  `~/.quotabot/litellm-metrics.jsonl` file, summarizes a bounded local JSONL
  tail, and shows served requests, routed requests, tokens, tracked cost, top
  served models, last request age, and spend-class counts for local, quota-plan,
  paid-API, and legacy unknown records.
- **Shareable reports:** a "weekly quota health" markdown export worth posting.
  Foundation shipped: `quotabot report` prints markdown and `--json` emits
  `quotabot.report.v1`, covering the current recommendation, headroom, resets,
  local/manual caveats, seven-day history metrics, and current sampled-day
  streaks.
- **Themes for the widget:** selectable color themes (the `top` palettes already
  shipped), including a high-contrast "hacker" mode, still honoring light/dark.
  Foundation shipped: desktop profiles now offer System, Light, Dark, and
  Hacker themes, with Hacker mapped through the normal Flutter theme system as a
  high-contrast dark green widget palette.
- **Ecosystem and packaging:** a plugin model, OS package managers (winget/MSIX,
  Homebrew, AppImage/flatpak), a docs site, and a reusable passive-reader adapter
  taxonomy to widen coverage cheaply.

Differentiators, re-scanned mid-2026 (ccusage, CodexBar, ClaudeBar,
TokenTracker, and the new entrants Quotio and Quotio's Linux fork). The niche
that was empty is now contested at the edges, so lean on the intersection no
one else holds, not on any single axis:

- **Advisor, not proxy.** quotabot suggests where the next request should go and
  lets each provider's own client make the call; it stays out of the request
  path. Other routing tools work by proxying the request through a gateway, so
  staying an advisor is a real architectural difference: quotabot is one more
  read-only signal, not one more hop your traffic depends on, which is the
  cleanest fit for the agent-facing routing it is built around. Lead with the
  value, not the contrast: quotabot helps you get the most out of the
  subscriptions you already pay for, and the agent-facing suggestion lets agents
  route across accounts the way a person would.
- **True cross-platform, not a fork.** The menu-bar incumbents (CodexBar,
  ClaudeBar, Quotio) are macOS-only; Quotio's Linux is a community fork. One
  first-class Windows/Linux/macOS codebase is a real, present gap.
- **First-class local runtimes as routing targets** (Ollama/LM Studio/Lemonade)
  - still unclaimed; the natural overflow when every subscription window is
  spent, and it reinforces local-first.
- **MCP server exposing quota to agents** - nobody in the consumer category does
  this; it is the cleanest expression of routing-as-a-primitive.

What is now table-stakes (not a differentiator): reading *real* rolling-window
quota rather than spend-derived estimates, multi-account/per-account breakdown,
pre-limit notifications, and making any Full-Disk-Access-style permission
optional. Raw provider *breadth* is a losing race (CodexBar is at ~56 and
climbing); compete on what quotabot does with a provider, not the count.

Staying relevant is a standing habit, re-checked each release rather than a fixed
list: re-survey what people actually run and what quota model each tool uses,
because the market is splitting in two. One camp keeps true rolling-window prompt
quotas - Claude, Codex, and the fast-growing coding-plan cohort (GLM, MiniMax,
Kimi, Qwen) that sells Claude-Max-style 5h / weekly / monthly request windows -
and that camp is quotabot's home turf, where new coverage pays off most. The other
camp (Cursor, Warp, JetBrains AI, Replit, the app builders) has moved to dollar-
or credit-metered pools with a monthly reset; quotabot can show those as
remaining-pool-percent on their reset (a window) but never crosses into per-token
cost accounting. The whole premise keeps checking out: a clear majority of
engineers now run two to four of these tools at once, which is the exact problem
quotabot exists to solve, so the relevance test for any new provider is simply
whether it has a quota people are juggling, not how new or hyped it is.

## Not doing (and why)

Deliberately out of scope. Listed so the boundary is explicit.

- **A Rust core or a Tauri rewrite.** Discards a working cross-platform Flutter
  app to chase packaging debt that is real but overstated.
- **Runtime plugin discovery from pub.dev.** Not feasible in an AOT-compiled
  Flutter app; a compile-time adapter registry is the workable form.
- **GitHub Copilot as a primary quota provider.** Rechecked on June 30, 2026:
  Copilot usage is now governed by AI Credits for most plans, while premium
  requests remain only for legacy annual Pro and Pro+ subscribers. That makes it
  a secondary cost/credit view at most, not a clean rolling-window quota source
  for quotabot's primary routing surface.
- **Token/dollar cost ledgers as the primary view.** quotabot tracks rolling
  windows, not spend accounting; a cost dimension stays optional and secondary.
- **Pay-as-you-go API vendors** (as quota providers). That is cost, not a
  rolling-window quota.
- **Global leaderboards or cloud sync.** Violates local-first.
- **Browser cookie / OS-keychain decryption.** Platform-specific and
  privacy-sensitive; quotabot reuses tokens the provider's own tools already
  wrote, nothing more.
- **CLI-PTY scraping of `/usage`.** Brittle; prefer the OAuth and file sources.
- **Git-commit / productivity correlation.** Out of the tool's lane.
