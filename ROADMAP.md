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
- **No attribution, no emoji, no em-dashes** in the repo, with the single
  sanctioned exception of the math-derived analytics glyph.

## Road to 1.0

1.0 is a promise that the **core works exceptionally** and the public surface is
**stable**, not a feature count. Everything below is depth on what already exists:
the SEE and ROUTE jobs done flawlessly on every platform, for the providers
quotabot already claims. Adding a new provider does not get us to 1.0; Antigravity
never lying about quota on any OS does.

"Done flawlessly" is meant strictly, so 1.0 is the excellent, polished product,
not a minimal core. That is why two things that round out the core are 1.0 gates
rather than later breadth: **profiles** (so the multi-account user sees work and
personal cleanly in one place, item 8) and the **router-grade signal** a real
meta-router leans on - leases, a cheap cached decision, scoped queries, and a
subscribe path (items 15-16). Both deepen SEE and ROUTE for the providers already
claimed; neither is a new provider. Sheer breadth (more providers, optimizer math,
ecosystem) stays After 1.0.

**Already in place** (the full record is in [CHANGELOG.md](CHANGELOG.md)): the
binding-window SEE rule with honest staleness; self-explaining, risk-aware
`suggest` with provenance (burn standard error, strand probability, confidence,
`--risk`); the per-model registry with capability and tier filters across CLI and
MCP; concrete model recommendation (`suggest --task`); MCP 2025-11-25 output
schemas and read-only annotations; calibration that grades the predictor;
`quotabot top` with gradient meters, palettes, adaptive refresh, the
forward-looking forecast on the binding window, and full keyboard interaction
(sort, navigate, hide, copy-route) with stable exit codes; the same forecast in
the desktop widget; proactive low-quota alerts as `quotabot watch` and in the
widget, with an optional loopback webhook; the cross-platform release pipeline;
and CI green on an 85% coverage floor across Linux, macOS, and Windows.

What is left is the ordered plan below. The phases are sequenced deliberately -
each unblocks or de-risks the next - so this is the order to build in, not a menu
to pick from. 1.0 is cut when every box is checked and the suite is green on
Windows, macOS, and Linux.

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
   remain item 8. (Copilot's per-account read lands post-1.0 with the provider
   itself.)
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
    live, the 90-day analytics view), generated from demo mode so it stays
    reproducible, plus verified macOS and Linux packaging.
    Shipped: README now uses `docs/quotabot-demo.gif`, generated by
    `tools/generate_readme_demo.py` from the Flutter demo screenshot exporter.
    Screenshot mode captures expanded and compact widget frames, a 90-day
    analytics frame, and the demo `top` frame. CI now verifies macOS and Linux
    desktop release bundle builds on native runners through dedicated package
    scripts.
20. [x] Final cut: every box above checked, suite green on Windows, macOS, and
    Linux.
    Shipped: all 1.0 roadmap boxes are checked. The final local gate passed on
    Windows with collector format/analyze/tests/coverage, app
    format/analyze/tests/build, MCP client checks, LiteLLM direct plus real
    proxy tests, collector executable builds, generated README media validation,
    shell script syntax checks through Git Bash, and hygiene scans. GitHub
    Actions passed the matrix on Linux, macOS, and Windows, including native
    macOS/Linux desktop package-build verification.

### Continuous hardening (runs throughout, not a phase)

Getting to "exceptional" is a cadence, repeated until it stops finding anything,
in parallel with the phases above rather than after them:

- **Repeated adversarial bug-hunt rounds:** multi-agent sweeps over the whole
  codebase, each finding fixed and pinned with a regression test, run again until a
  round comes back empty.
- **Recurring security reviews:** token handling, host/SSRF validation for local
  runtimes, injection via provider data, and the install supply chain. Each pass
  fixes what it finds.

Self-tuning - using the calibration loop to fit the routing parameters on local
history - and the deeper statistical layers are quality multipliers: valued and
pursued continuously, but not 1.0 gates.

## After 1.0

Breadth and depth, once the core is trusted:

- **More quota-window providers:** the "coding plan" cohort is the truest fit and
  the priority, since it sells Claude-Max-style rolling request windows that map
  straight onto the SEE model - Z.ai (GLM), MiniMax, Kimi, and Qwen all meter
  prompts per 5h / week / month with real resets. Then Amp, OpenCode, DeepSeek,
  Perplexity, and GitHub Copilot (see Not doing below; its premium-request
  allowance has become a per-user monthly window with a usage API, so it earns a
  second look). Spend-based aggregators (OpenRouter, Together, Fireworks), the
  credit-metered app builders (Replit, v0, Lovable, Bolt), and credit-pool tools
  like Warp and JetBrains AI only ever as a secondary cost view, since they meter
  dollars or credits, not a rolling-window quota. Amazon Q is deliberately
  skipped: AWS is sunsetting it in favor of Kiro, which quotabot already reads, so
  the AWS path is to deepen Kiro rather than chase a retiring product.
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
  shipped: CLI `suggest` and `models` accept
  `--exclude=A,B`, and MCP read/routing/reservation/model tools accept
  `exclude`; local HTTP `GET /suggest` accepts `?exclude=A,B` for the same
  one-off provider exclusion without editing profiles. Provider routing now has
  an explicit local-first policy as well: CLI `suggest --local-first`, MCP
  `local_first`, and HTTP `?local_first=true` recommend a local runtime before
  subscription quota when local capacity is available. The LiteLLM plugin also
  distinguishes `spend: quota_plan` from `spend: paid_api` so included quota
  plans with overages disabled can be used while request-metered API routes are
  skipped by default. Model routing now has a `budget` envelope too:
  `--budget=local` is a hard local-only cap, while `--budget=quota` allows local
  runtimes plus measured built-in quota plans and rejects self-reported manual
  quotas.
- **Optimizer features:** use-it-or-lose-it alerts when projected waste at reset
  crosses a threshold; downgrade/upgrade ROI (rolling p90 vs each tier's cap, with
  $/mo saved and breach probability); reset-anchored scheduling. Foundation
  shipped: `quotabot watch --waste-threshold=N` emits opt-in
  `projected_waste` alerts from current pace analytics.
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
  `quotabot stats`, `quotabot report`, and `quotabot.report.v1`.
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
- **Ecosystem and packaging:** a plugin model, OS package managers (winget/MSIX,
  Homebrew, AppImage/flatpak), a docs site, and a reusable passive-reader adapter
  taxonomy to widen coverage cheaply.

Differentiators (from a scan of ccusage, CodexBar, ClaudeBar, TokenTracker, and
others) to keep leaning on: a cross-platform widget (most rivals are macOS
menu-bar only), real rate-limit windows (not token or dollar accounting), routing
as a primitive, and first-class local runtimes.

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
- **GitHub Copilot - reclassified as a post-1.0 candidate (see After 1.0), no
  longer a flat exclusion.** The original objection was that premium requests
  were server-side only with the token in the OS keyring, not a file. As of 2026
  the premium-request allowance is a clean monthly window (counters reset on the
  1st, UTC) and GitHub exposes a per-user usage API. It still is not a silent
  local read: it needs an opt-in personal access token (the same one-time-login
  pattern as Grok and Antigravity), and seats managed by an org or enterprise do
  not appear on the user endpoint. Worth doing post-1.0 for individual plans,
  with those limits stated plainly.
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
