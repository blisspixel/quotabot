# Architecture

quotabot has two parts, both written in Dart: a collector package and a Flutter
desktop app. The app depends on the collector by path and calls it directly, so
there is a single code path and no subprocess or IPC. The collector also ships
two binaries: a CLI and an MCP server.

The map below is selective. It names architectural boundaries and public entry
points, not every helper or command.

```
collector/ (Dart package)
  models.dart        normalized ProviderQuota / QuotaWindow / ModelInfo / BurnStat
  parsing.dart       pure response/window parsing (no I/O)
  analysis.dart      pure routing: headroom, risk-adjusted headroom, strand
                     probability, suggestRoute, the shared forward-looking
                     forecast (classifyForecast/WindowForecast, used by both top
                     and the widget), adaptive refresh cadence
                     (nextRefreshSeconds, shared by top and the app)
  insights.dart      pure analytics: buckets, percentiles, trend, pace, raw and
                     smoothed heatmaps, best sampled windows, reset-aware
                     schedule hints, sampled-day streaks, contribution
                     calendars, burn rate with uncertainty
  alerts.dart        pure low-quota alerts shared by watch/app/MCP, plus
                     watch-only projected-waste thresholding
  webhook.dart       loopback-guarded, fail-soft alert webhook sender (postAlert)
  calibration.dart   pure: grade the strand predictor against recorded history
  registry.dart      pure: assemble the cross-provider model registry with budget
  model_catalog.dart committed cloud model capability catalog
  catalog_audit.dart pure/provider-owned model-list diffing for catalog currency
  schema_contracts.dart frozen quotabot.v1 JSON Schema and validator
  provider_adapters.dart compile-time adapter and fixture registry
  provider_filters.dart shared profile/account/exclusion filtering
  local_runtime_config.dart loopback runtime endpoint resolution and audit parity
  profiles.dart      named local profile schema, storage, and filtering
  manual_quota.dart  bounded local self-reported window storage
  cache.dart         last-known-good snapshot cache (per-account keyed where a
                     provider reads several logins); recent burn stats
  expiring_single_flight.dart short-lived MCP live-read coalescing
  file_guard.dart     claim-backed native process/isolate transaction guard
  leases.dart        local routing leases for parallel-agent reservation and
                     release, backed by the file guard in production
  litellm_metrics.dart  bounded parser and summarizer for local LiteLLM
                     routed-request JSONL metrics
  ansi.dart          shared ANSI styling and color-depth detection
  top.dart           pure renderer for the `quotabot top` live dashboard:
                     gradient meters, palettes, local detail lines, the
                     forward-looking forecast (strand probability/time-to-empty),
                     the interactive sort (TopSort + sortProvidersForTop), and the
                     keyboard helpers (moveSelection, osc52Copy clipboard)
  demo.dart          synthetic fleet + burn stats for QUOTABOT_DEMO previews
  simulation.dart    exact one-provider snapshots for deterministic CLI tests
  verification.dart  pure provider honesty and contract checks
  runtime_audit.dart dry-run and observed local/network trust-boundary records
  report.dart        pure markdown and quotabot.report.v1 assembly
  mcp.dart           MCP tool shapes, output schemas, shared server factory
  mcp_http.dart      Opt-in Streamable HTTP MCP wrapper with loopback guards
  collector.dart     full or provider-scoped adapter collection, cache; exports
  adapters/          codex, claude, grok, antigravity, kiro, cursor, windsurf,
                     nvidia, ollama, lmstudio, lemonade (thin I/O shells)
  auth/              tokens + store, disconnect markers, PKCE/loopback util,
                     anthropic, openai, xai, and google OAuth
  util.dart          home/config dirs, varint + protobuf helpers
  bin/collect.dart        CLI: status/doctor, top, watch, models, suggest,
                          update,
                          verify/explain, stats/report/calibration, manual,
                          json, login/logout (stable exit codes 0/64/65/69/74)
  bin/mcp_server.dart     MCP server over stdio or opt-in Streamable HTTP
                          (tools, local leases, quotas://current and
                          quotas://alerts resources)
  bin/local_server.dart   Optional plain HTTP JSON snapshot server
  bin/example_routing_agent.dart  Worked example using collect + analysis for routing

integrations/mcp_clients/
  Python and TypeScript MCP client snippets for stdio and Streamable HTTP,
  plus smoke tests that compile Python, typecheck TypeScript, and verify current
  SDK transport use.

app/ (Flutter desktop)
  main.dart   imports collectAll(), renders cards, adaptive refresh
  fleet.dart  the Quota Analytics screen (Now/7d/90d, charts, optional LiteLLM
              routed-request metrics)
  demo.dart   synthetic data for QUOTABOT_DEMO previews/screenshots
  logos.dart  vector provider logos (CustomPainter)
  prefs.dart  persisted UI preferences
  profile_editor.dart / profile_ui.dart  profile editing and presentation
  desktop_readiness.dart  native launch and tray readiness boundary
  theme_spec.dart / headroom_colors.dart  semantic theme and quota colors
  typography.dart  shared text-size scale (AppType) used by both screens
```

## The normalized model

Everything funnels into one shape (`models.dart`):

- `ProviderQuota`: provider id, display name, account, plan, ok flag, optional
  error note, capture time (`asOf`), a `stale` flag, and a list of windows.
- `QuotaWindow`: a label (such as `5h` or `weekly`), percent used, optional raw
  used and limit counts, and a reset time as a Unix timestamp.
- `QuotaProfile`: a local-only named view over a quota snapshot. It can allow
  providers, allow accounts per provider, hide providers, carry a routing
  policy, and remember UI-facing theme/sort labels. The `default` profile is
  implicit and preserves the zero-config behavior.

Adapters never talk to the UI. They return `ProviderQuota`, and the UI derives
everything it shows from that, including colors and the binding-constraint
collapse.

## Separation of pure logic from I/O

The bulk of the logic lives in `parsing.dart` and `analysis.dart` with no
network or disk access, so it is unit tested directly against fixtures. Adapters
are thin shells: they fetch bytes (file, SQLite, or HTTP) and delegate parsing.
This is why the core has high test coverage even though the adapters do I/O.
`simulation.dart` follows the same rule: it produces deterministic
`ProviderQuota` snapshots for CLI tests without adapter calls, history reads,
analytics buckets, active route leases, or passive host-tool detection. Human
surfaces retain an explicit simulation marker, while snapshot JSON and decision
receipts retain the simulation source. It is intentionally separate from
`demo.dart`, which is a
believable multi-provider screenshot fleet rather than an exact assertion tool.
The parser test layer includes seeded property/fuzz tests over malformed JSON,
protobuf-like byte streams, gRPC-web frames, embedded-token blobs, and passive
SQLite rows, plus sanitized provider-shape fixtures loaded from
`collector/test/fixtures/` so the pure parsers are checked against stable
recorded shapes without touching live credentials or provider APIs.
Antigravity skips non-metered helper models in its live model table - the
tab-completion and chat models it lists that carry no reset window - and keeps
the real metered windows, so a helper cannot reject the whole table; only a
metered row with an unparseable fraction still fails closed. Kiro projects only the
exact `kiro.resourceNotifications.usageState` child, so unrelated agent state
cannot become quota or freshness evidence. `provider_adapters.dart` is the
compile-time registry for all built-in adapters and their required sanitized
fixtures; tests fail when a new adapter lacks a registry row or fixture.

## Adapters

Cloud adapters share one pooled, keep-alive HTTP client (`sharedHttpClient`)
instead of the top-level `http` helpers, which open and discard a fresh
connection per call. A fleet poll runs every adapter concurrently, so without
pooling it would open many cold DNS/TLS connections at once and the heavier
front ends could miss their deadline; a shared client reuses warm connections
and lets a multi-call adapter reuse one. Adapters still accept an injected client
for tests.

## Concurrency

Quota collection is I/O-bound: HTTP metadata, local files, and SQLite. The
useful parallelism is overlapping those waits, not occupying every CPU core.

- A fleet poll starts every selected adapter at once (`Future.wait` in
  `collector.dart`). Multi-account live reads inside Grok and Antigravity overlap
  the same way. Result order stays the discovered account order.
- Claude and Codex start host and grant reads together so a slow grant cannot
  hide a healthy host observation.
- The desktop app runs `collectAll` on a background isolate so SQLite, protobuf,
  and JSON work cannot freeze the UI isolate. If that isolate cannot start, it
  falls back to the UI isolate.
- One-shot CLI collection stays on the process isolate. Spawning a second
  isolate for a command that exits immediately would cost more than it saves.
- Analytics directory scans also run off the UI isolate, with a timeout and a
  same-isolate fallback, so a stalled scan cannot freeze refresh.

quotabot does not spawn one isolate per provider. Isolates do not share memory,
so that design would drop the shared HTTP pool, duplicate credential and cache
locks, and spend cores on waiting for network. Dart's test runner already uses
available cores for the suite; CI runs the three OS matrices in parallel.

Decision, parsing, and routing stay single-isolate and deterministic. Extra
cores belong to overlapping metadata I/O and keeping the UI responsive, not to
a 16-way compute farm on quota percentages.

Each adapter has a single `collect()` method returning a `ProviderQuota`:

- Codex calls the ChatGPT usage metadata endpoint with the OAuth access token
  Codex stores locally or a quotabot-owned grant. If no account-wide read
  succeeds, it fails closed with a login repair instead of opening mixed-content
  session files. Primary and secondary window labels come from the reported
  duration, an explicit null window is treated as absent, and named
  `additional_rate_limits` become sparse model-budget overlays. No model call.
- Claude, Grok, and Antigravity call live metadata endpoints (no model calls, no
  token cost). Claude reuses the token Claude Code stores for concurrent usage
  and profile reads. The profile plan is current provider evidence, and its
  account plus organization ids are hashed into one stable quota-pool identity.
  No raw profile id is retained. Grok and Antigravity
  prefer quotabot's own OAuth grant (see Authentication) and fall back to the
  token the host CLI or IDE currently holds. Grok reads every account in the CLI
  auth file and caches them separately. Antigravity scans the active account and
  profile databases, attempts live reads for each discovered account, refreshes
  the Gemini CLI token from disk when it is the active token source, and runs the
  Cloud Code onboarding step only when `loadCodeAssist` has not already returned
  an onboarded project before reading per-model quota.
- Claude's current usage response separates shared session and weekly windows
  from optional model-scoped weekly limits. Shared windows govern provider
  routing; a scoped row is a sparse model-budget overlay, so spending it cannot
  block unrelated Claude models. The parser requires both shared binding rows and
  every recognized scoped row in the authoritative `limits` array to be valid,
  and present known legacy blocks follow the same rule, so a malformed weekly or
  model sibling is never silently discarded while healthier rows continue to
  route. Additive non-account root blocks that ship alongside the `limits` array -
  usage credits, per-model, and rotating codenamed weekly windows - are tolerated
  rather than failing the whole response.
- Kiro, Cursor, and Windsurf are passive readers of local credit/state files, so
  they are detected (and report installed/free tiers) even with no live API.
  Current Cursor 3.x state can expose an owner-bound recognized plan, but it does
  not persist current Cursor Models and Other Models quota balances in supported
  local rows. That plan remains diagnostic and unroutable. Older exact
  provider-owned usage rows are parsed only as compatibility evidence when a
  Cursor build still writes them. Windsurf/Devin Desktop daily and weekly
  Cascade quota shapes are normalized from local SQLite state, with account and
  plan labels surfaced when present.
- Ollama, LM Studio, and Lemonade are local-runtime adapters: they report
  installed and loaded models instead of a quota window. A reachable, error-free
  loopback daemon acts as a routing fallback only when it represents at least
  one on-device model; cloud-offloaded-only and empty runtimes do not. Any
  OpenAI-compatible runtime can be added with the shared `localRuntimeQuota`
  helper. Lemonade's optional health read enriches inventory with loaded state
  and running context, but fails soft without hiding a successful model list.

An adapter that cannot produce live windows still returns a `ProviderQuota` with
account and plan and an explanatory `error` note, rather than throwing. The UI
shows that as "no live data" instead of a gap.

## Authentication

`auth/` holds quotabot's own OAuth, kept separate from the host apps' tokens:

- `tokens.dart`: the `Tokens` model and `TokenStore`, which persists tokens per
  provider, and optionally per provider account, under the config directory,
  only after checked owner-only permission hardening. Account-scoped filenames
  use a hash of the account id rather than the raw email. Rotated refresh tokens
  are saved on every successful refresh or the next refresh would fail. A load
  returns tokens and owner from one immutable file generation. Every writer
  takes the same per-slot process-and-isolate guard. The guard combines an
  exclusive claim file with a native file lock and removes its owned claim only
  after native unlock. Each refresh side effect is separately serialized before
  reloading the slot, and refresh conditionally replaces only the generation it
  loaded, so a late refresh cannot overwrite a completed login or account
  replacement. Existing credential paths must resolve as regular files without
  following links before quotabot changes permissions or reads content.
- `provider_disconnect.dart`: owner-only, provider-wide disconnect markers for
  Claude, Codex, Grok, and Antigravity. Logout writes the marker before removing
  quotabot grants. Adapters then ignore every host and quotabot credential for
  that provider, including named accounts, without changing host state. Only a
  successful explicit quotabot login clears the marker. Marker mutation uses an
  exact provider allowlist, no-follow path checks, and the same process-and-
  isolate locking discipline as other auth state. Reads treat an unreadable or
  non-regular entry at the exact marker path as disconnected, so corrupted state
  cannot fail open into host credentials.
- `oauth_util.dart`: PKCE (S256), a free-port helper, a one-shot loopback server
  to capture the redirect, and a system-browser launcher.
- `xai_auth.dart`: the Grok device-code login and refresh.
- `google_auth.dart`: the Antigravity loopback plus PKCE authorization-code
  login and refresh.

Each login mints an independent grant, so refreshing never invalidates the host
CLI's or IDE's credentials. `login`/`logout` are CLI subcommands. Refresh alone
cannot clear a disconnect marker, and a failed login cannot make collection
fall through to host credentials.

The desktop `prefs.json` may contain an authenticated webhook URL. Its directory
and any existing file are checked owner-only before read or write; a failure
returns safe defaults or leaves the previous file unchanged. Permission helpers
run asynchronously against one shared three-second deadline, request
termination of a timed-out child process, and expose only a bounded storage
warning. Every temporary file is restricted before content is written. A legacy file that cannot be
protected is ignored and retained for explicit user remediation rather than
deleted automatically. Loads accept only a regular file up to 64 KiB and bound
the read to one second; protection, malformed-data, unsupported-file, and read
failures remain distinct. Save bursts retain at most one active and one latest
snapshot, window movement persists only after a 250 ms quiet period, and normal
tray Quit flushes the final snapshot before teardown.

## Collection and caching

`collectAll()` runs every adapter concurrently (Antigravity via multi-account
profile scan + per-account caches) and wraps each in a cache layer (`cache.dart`):

Provider-specific CLI `check` resolves its adapter before I/O and runs only that
registry row. Filtered strict verification computes the registry subset from its
profile, exclusions, and local-only policy before I/O, so its `runtime_access`
observation matches the adapters actually invoked. Account allowlists and hidden
account targets remain post-collection because a multi-account adapter must run
before returned account identities are known. The bounded local manual-entry
file is still read so a manual provider can be checked without any built-in
adapter call. Normal status, desktop, MCP snapshot, and routing reads retain the
full-fleet `collectAll()` behavior.

1. Capture a local observation generation, then run the adapter. The generation
   marks when collection began, so an older slow read cannot finish late and
   overwrite evidence from a newer collection.
2. Compare a fresh, windowed result with the last trusted snapshot when provider,
   account, plan, kind, source, and machine scope describe the same evidence
   class. A changed evidence class establishes a new baseline.
3. Admit a plausible result into the last-known cache, history, and measured
   analytics, and clear any earlier drift diagnostic for that identity.
4. If a trusted window or model pool disappears, reset time moves earlier,
   usage falls without a completed reset, a window lacks derivable usage, or a
   capture timestamp is missing or materially future, reject the fresh values.
   Keep the trusted cache unchanged, persist a bounded sanitized drift
   diagnostic separately, and return the prior snapshot as stale evidence.
5. If collection otherwise fails or has no windows, load the last-known trusted
   snapshot, mark it stale, and return that.
6. If an upgraded cache contains only a legacy `suspect` snapshot, retain it as
   an admission baseline but remove its windows from every public result. An
   identical fresh read remains quarantined; only a materially advanced reset
   or a changed evidence class can establish a new trusted baseline.

The cache lives under the platform application-data directory
(`%LOCALAPPDATA%/quotabot/cache` on Windows). This is what keeps a transient
rate limit or an expired token from blanking a provider.
The cache directory and atomic-write files are best-effort owner-only local
metadata. Cache-only routing reads only canonical snapshot filenames that match
the parsed provider/account identity and rejects snapshots dated materially in
the future, so a stray JSON file in the cache directory cannot become a fresh
routing recommendation.

### Provider-ID cache migration

Provider renames use one registered, one-way retired-to-current alias map and a
bounded startup coordinator. The map is empty in the shipped build until a real
rename is required. When an alias exists, live CLI collection, normal desktop
collection, direct analytics recovery, and MCP live or disk-backed quota reads
await a coalesced in-process migration flight before touching cache evidence.
The completed flight is cleared so a later pass can reconcile a released older
writer. Demo, help, version, update, login, and simulation-only paths remain
no-touch.

One claim-backed native coordinator guard serializes processes and isolates.
For each affected identity, the coordinator then acquires every retired
evidence guard before every canonical guard, matching the order used by current
cache transactions. Current writers recheck the retired branch inside those
guards immediately before mutation. A released older writer can therefore
finish without being overwritten: its one-sided advance is carried on the next
pass, while independently advanced branches are preserved and quarantined.

The coordinator recognizes only fixed snapshot, drift, history, bucket,
analytics-checkpoint, and legacy-owner roles. It rejects links, malformed
identities, unregistered evidence classes, future captures, nonmonotonic
history, impossible bucket aggregates, invalid checkpoints, unsafe filename
components, and malformed canonical targets. Accepted files are copied byte for
byte, so raw-history and analytics checkpoint digests do not change. Readers
canonicalize an embedded retired provider id only in memory.

Released raw account filenames remain evidence only after the bounded file
content, and bucket-owner evidence when required, proves one exact account. The
coordinator copies those bytes into the opaque canonical `account_<digest>`
target while retaining both raw and opaque retired-then-current lock domains.
A new-provider raw compatibility file is treated as another preserved branch:
equal evidence can coalesce into the opaque target, while divergent evidence is
quarantined. A durable opaque-target deletion also suppresses that raw fallback,
so an older writer cannot resurrect deleted canonical evidence.

Each alias has an owner-only `quotabot.provider-id-migration.v1` receipt. A
record contains a fixed role and tier, an opaque account digest when the role is
account-scoped, bounded byte counts, and SHA-256 branch digests. It contains no
raw account, path, prompt, code, credential, or provider response. A prepared
record is published while the identity guards are still held, before the
canonical target is atomically installed. A committed record is published
before those guards are released. Restart can therefore distinguish an initial
copy with an installed target, a shared branch baseline, a one-sided legacy
advance, and a true two-branch conflict. If a prepared initial target is absent
after restart, the coordinator cannot distinguish a pre-rename interruption
from a post-rename canonical deletion, so it preserves the retired branch and
fails closed instead of copying it again.

Alias count, directory entries, candidate records, per-record bytes, total
evidence bytes, receipt size, and lock acquisition are hard-bounded. Cooperative
wall-time checks stop between bounded local filesystem operations; they do not
claim to interrupt a stalled operating-system call. Partial scans retain prior
baselines and publish explicit global uncertainty. Missing, malformed, prepared,
contradicted, or globally uncertain receipts fail closed at cache reads and
writes. Quarantine remains exact to the affected provider identity and quota,
history, or bucket tier whenever the evidence is specific enough; unresolved
legacy ownership stays preserved without being admitted to an unrelated exact
account.

Account-scoped recent history and hourly buckets also use canonical opaque
filenames. Their first canonical write stores a best-effort owner-only
`quotabot.analytics-migration.v1` checkpoint for the exact-account legacy path:
ordered raw-history row digests plus a bounded hourly aggregate baseline. The
checkpoint contains a provider id and account digest, never a raw account, path,
prompt, code, or credential. Reads compare the live legacy generation with that
baseline. A changed or untrusted checkpoint quarantines only the affected
history tier, preserves both generations, stops further writes to that tier, and
surfaces a bounded diagnostic through desktop Analytics and human `doctor`;
bucket-tier conflicts also annotate the affected `stats --json` row because
that command reads hourly buckets. Ambiguous legacy data cannot influence
routing. Burn-aware routing continues using frozen canonical account buckets or
the validated pre-divergence checkpoint. If neither exists and the current
snapshot has exactly one measured account, the same provider-only compatibility
series that was eligible before conflict remains eligible. Conflict evaluation
evaluates both possible hourly cutoff sets, applies cross-provider shrinkage to
each complete candidate map, then retains the higher burn, higher uncertainty,
and lower sample count for the conflicted identity. Healthy identities keep the
pooled result matching the actual current hour offset, so conflict uncertainty
cannot penalize their route position. Quarantine therefore cannot make the
affected provider rank more optimistically as evidence ages. No automatic merge or
deletion occurs when the delta cannot be proven, because choosing one generation
can lose samples and combining both can double-count their shared baseline.
The explicit recovery boundary is `verify --recover-analytics`. Its default
mode only inspects one exact provider/account/tier. With `--yes`, it repeats the
checks while holding both the identity's canonical evidence lock and its lossy
legacy lock domain, even when a legacy file was absent at inspection time. It
rejects links and other non-regular sources, enforces a 16 MiB total evidence
cap, and creates a unique owner-only bundle outside the cache directory.
Owner-only permissions on the recovery root, bundle, manifest, and archived
files are checked and fail closed. Canonical and legacy files for only the
selected tier are atomically moved into fixed-role archive names; the migration
marker and legacy bucket-owner record, when applicable, are copied. A legacy
history file must contain only rows for the requested identity, and a legacy
bucket file must carry exact ownership evidence, so colliding account stems are
never adopted or moved. A manifest records byte counts and SHA-256 digests with
an opaque account digest and no raw source paths. An explicit recovery guard is
installed before originals move. Only after every archive digest verifies and
every selected path, including paths absent at inspection, remains absent can
the selected tier be replaced. Raw history receives an exact merge only when
strict parsing proves the exact provider/account identity, trusted evidence,
monotonic branch order, one unique ordered-checkpoint suffix overlap per branch,
and enough retained baseline to reconstruct the 200-row cap. Aggregate buckets
receive an exact merge only when every checkpoint and branch row has one unique
aligned start and valid bounded counts, histograms, moments, exhausted counts,
and extrema. Any retained checkpoint rows must form a complete suffix, and each
branch's additive fields must cover that baseline. The aggregate merge computes
canonical plus legacy minus the shared checkpoint once, retains independent new
buckets, and keeps the newest bounded 90-day series. The merged canonical file
is atomically installed and digest-verified before the migration marker admits
an empty legacy checkpoint. Unprovable evidence restarts the selected tier
empty. A still-conflicted other tier retains its conflict flag and trusted
checkpoint.
Failures before checkpoint admission retain quarantine and partial archives
retain their manifest. If manifest finalization fails after admission, retry
returns the retained receipt as `recovered_receipt_incomplete`. A late legacy
write differs from the empty legacy baseline and reactivates quarantine.
The transaction never contacts a provider and never touches quota snapshots,
credentials, profiles, preferences, leases, alerts, other identities, or
provider-only compatibility analytics. Aggregate-bucket reconciliation fails
closed whenever any exact-merge invariant cannot be proven.

Mixed-version state also has a separate digest-private incident inventory. A
detected checkpoint mismatch is persisted under the existing identity evidence
lock with explicit tier flags, a first-recorded timestamp, and a random 128-bit
incident reference. On upgrade, a valid older marker can be checked using only
validated exact identity evidence from its canonical local snapshot; quotabot
never guesses an account from a filename. A valid explicit marker that lacks a
reference is upgraded under the same canonical digest lock. Recovery preserves
the reference and first-recorded time while any tier remains conflicted, then
removes both when every tier is resolved.

The default unfiltered snapshot enumerates markers with an asynchronous,
non-link-following scan. It caps directory entries, candidate markers, emitted
incidents, each marker size, total marker bytes, and cached identity evidence.
The result says `complete`, `partial`, or `suppressed` and includes bounded
invalid, unverifiable, and truncation evidence, so an empty partial list cannot
be mistaken for a clean cache. An incident exposes provider, fixed tiers,
recorded time, and its random reference. It exposes a provider-row index only
when the exact identity is already visible in the enclosing snapshot. Raw
accounts, account digests, paths, and recovery authority are absent. Profiled
or excluded snapshots inspect visible exact rows only, preventing local marker
enumeration from bypassing the requested view. This inventory never contributes
quota, availability, burn, routing, or recovery authorization.
The in-memory result also attributes verifiable uncertainty to canonical
provider ids while keeping malformed or truncated uncertainty global. Desktop
profile views therefore retain an in-scope or global partial warning without
revealing a known out-of-scope provider incident. Those attribution fields are
not serialized.
Drift diagnostics use separate per-provider/account records in the cache
directory. They remain attached to cache-only and failed-read fallbacks so a
process restart or transient provider failure cannot silently clear the warning.
Canonical cache and drift records carry internal microsecond observation
generations. Admission, generation comparison, cache write, and diagnostic
update run under one per-provider/account claim-backed native guard that
serializes processes and isolates. Multi-lock recovery preserves the released
legacy-then-canonical order, shares one bounded acquisition deadline, and
releases every acquired claim on partial failure. A clean writer
clears only an older drift record, and a late older writer cannot hide a newer
warning or baseline even when both provider timestamps fall in the same second.
Baseline reads reject a mismatched provider, a mismatched scoped account, a
negative or materially future capture time, and a materially future internal
generation. If the admission lock cannot be acquired, the result fails closed
as stale last-trusted evidence, legacy quarantine, or an unavailable no-window
record. The next clean admitted provider result newer than the warning clears it.
Neither rejected values nor a drift-marked fallback can enter
cache/history/analytics as trusted evidence or become routable capacity.
For multi-account providers, stale per-account snapshots are appended only when
the account is still present in that provider's current local account index and
the live adapter did not already return it. This is the signed-out auto-hide
rule: a cached work account disappears once the provider's own local account
state no longer lists it.

## Routing helpers and the MCP server

`decision.dart` is the one engine's front door: `decide(observations, now,
context) -> Decision` is the single pure entry point every suggest surface
(CLI, MCP, HTTP) sources from. It recomputes nothing - the routing core already
produces the whole forward forecast, so `Decision.forecasts` (the ranked
candidates, each carrying headroom, burn and its standard error, strand
probability, confidence, and runway) is the SEE view, `Decision.recommended` is
ROUTE, and `alertsBelow` is ALERT: one object, three views. `DecisionContext`
bundles the bounded caller inputs so a decision is one recordable value, and
`replay(frames)` folds `decide` over recorded observation frames
deterministically - the substrate for calibration and the oracle benchmark.

`analysis.dart` exposes `providerHeadroom`, `providerWithMostHeadroom`,
`providerAvailability`, `bindingWindow`, `averageRecentHeadroom`, and the
forecast helpers `riskAdjustedHeadroom`, `strandProbability`, and `suggestRoute`
(the decision core `decide` wraps).
`suggestRoute` can accept active local lease discounts so concurrent routers see
reduced effective headroom for the provider/account another caller already
reserved. `leases.dart` owns those reservations: production uses a small
file-backed store protected across processes and same-process isolates by the
same claim-backed native guard, while tests use an in-memory store. Lease
generations are flushed through unique exclusive temporary files before rename.
Leases are advisory local metadata with TTLs and idempotency keys; they never
contact providers and never sit in the prompt or inference data path.
`suggestRoute` accepts two explicit alternatives to the default balanced policy,
where a comfortable metered subscription wins and local runtimes are fallbacks.
Local-first mode recommends an available local runtime before subscription quota
and records `routing_policy: "local_first"`. Quota-stretch mode keeps fresh
measured included quota while effective headroom is at or above a default 25
percent reserve, then prefers a reachable on-device runtime and records
`routing_policy: "quota_stretch"`. Its caller override is bounded from 20 through
50 percent. Manual, non-quota metered, stale, drifted, and cloud-offloaded
candidates cannot satisfy the policy. Loaded local runtimes sort before cold
ones for this choice; if no local runtime exists, the decision fails soft to the
best usable included-quota route. Public adapters reject simultaneous
local-first and quota-stretch requests. The core resolves an internal conflict to
local-first defensively. `suggestRoute` can also accept explicit caller-supplied
cost penalties; these are relative policy inputs, not prices inferred by
quotabot, and they only discount the shared routing score when the caller
provides them.

`mcp.dart` builds one MCP server definition: tools, resources, output schemas,
behavior annotations, capability scope, and standard MCP resource subscription
handlers. Most tools collect a live `collectAll()` snapshot. Concurrent cold
tool calls share one in-progress collection, and successful snapshots are reused
for five seconds; failed collections are not cached. Collection can
refresh local cache, history, and OAuth state; Antigravity may also perform its
provider-required onboarding request. Those tools are therefore annotated as
non-read-only and non-idempotent even though they never invoke a model. They can
also apply exact `account` filters after named profile filters for routers that
need one provider account without creating a profile. `decide_now` is
deliberately different: it reads the in-memory or disk last-known snapshot only,
returns `source`, `snapshot_as_of`, age, and whole-snapshot staleness with
explicit `snapshot` scope, and never forces a live collect. Envelope age or an
unsafe provider can set that flag. Winner and alternative
records retain their own provider-level stale flags. It can still compact expired records while reading the local lease
ledger, so it is not annotated read-only or idempotent. `suggest_provider` and
`decide_now` both accept `local_first` for always-local dispatch or
`quota_stretch` with an optional bounded `quota_stretch_threshold_percent` for a
low included-quota reserve, plus explicit `cost_penalties` for caller-owned cost
policy. `reserve_provider` and
`release_provider` explicitly mutate the local lease ledger; release is local
and idempotent, while reserve also collects live metadata.
`quotas://current` remains the unfiltered live snapshot resource.
`quotas://alerts` stores the last `quotabot.alert.v1` objects fired by the MCP
subscription loop. Clients subscribe with `resources/subscribe`; on an amber/red
crossing, the server emits the standard `notifications/resources/updated` event
for `quotas://alerts`, so clients react by reading the resource instead of
polling a tool. `bin/mcp_server.dart` feeds the shared server factory over stdio
by default or MCP Streamable HTTP when launched with `--http`. `mcp_http.dart`
keeps HTTP opt-in and loopback-only, enables DNS-rebinding host/origin checks,
rejects batch JSON-RPC payloads, requires a bearer token of at least 32
characters, and admits requests before the session transport reads a body.
Missing or invalid bearer tokens return HTTP 401 with a Bearer challenge.
POST bodies without a declared length, or larger than 256 KiB, return HTTP 413
without buffering. Body reads have a 15-second deadline, and at most 64 active
sessions are retained, including concurrent initialization attempts. A separate
128-request admission cap covers incomplete requests that have not created a
session. Every early rejection with an unread body flushes a correctly framed
response and releases its socket without waiting for the sender to finish. The
public server constructor enforces the same loopback, timeout, request-limit,
and session-limit invariants as CLI startup. Host and origin rebinding stays
HTTP 403. Bearer sources are bounded to 4 KiB; token-file mode requires a
regular file and applies the checked owner-only permission boundary on Windows
and macOS while Linux rejects group or other permission bits.
`bin/example_routing_agent.dart` shows the same logic used for direct Dart
routing decisions, while `integrations/mcp_clients/` shows Python and TypeScript
MCP clients for both stdio and Streamable HTTP.
`bin/local_server.dart` provides a plain HTTP JSON alternative for non-MCP
consumers, including `GET /suggest?local_first=true` for the same opt-in local
first routing policy, `GET /suggest?quota_stretch=true` for the default reserve,
and `GET /suggest?cost_penalty=codex:2` for explicit caller-owned cost
discounting. The server accepts a quota-stretch threshold from 20 through 50 and
rejects malformed, out-of-range, or mutually exclusive policy inputs before
collection. Its read endpoints are unauthenticated loopback metadata.
Email-shaped account labels in those reads are replaced with stable keyed
pseudonyms unless the caller presents the server's owner-only bearer token. The
only write endpoints are authenticated, bounded lease reserve and
release operations. Server startup creates and permission-checks a stable
per-user bearer token without printing it. First-start token creation uses the
same process-and-isolate guard plus an owner-only flushed temporary file, so
parallel servers publish one complete token. `GET /auth/prove` returns a
nonce-bound HMAC over the listener endpoint for local clients that already
possess the bearer. The bundled LiteLLM router requires that proof from the
exact peer and sends the bearer only on the same still-open TCP connection, so
a process that pre-binds the configured port cannot collect the credential. A
reserve request submits only
provider/account targets and lease policy, then selects and writes under one
ledger guard. Mutation body reads have a 15-second deadline. The server never
receives task text, prompts, source code, or model output.
Before any provider work, the server also validates browser `Origin` and Fetch
Metadata. Non-loopback and null origins are rejected, as are originless
same-site or cross-site subresource fetches. Normal non-browser clients without
Fetch Metadata and explicit user-activated top-level navigations remain valid.
The reasoning behind the routing math (risk-adjusted
headroom, strand probability, burn-stat shrinkage, reliability shrinkage,
heatmap usable-rate shrinkage, routing score, projected-waste route boosts, and
cost/lease discounts) is written up in
[ROUTING-MATH.md](ROUTING-MATH.md).

The public snapshot contract is frozen as `quotabot.v1` in
`schema_contracts.dart` and documented in [SCHEMA.md](SCHEMA.md). The contract is
additive: consumers must tolerate unknown fields, while quotabot must keep the
meaning and type of existing fields stable until a new schema id is introduced.

The model registry (`registry.dart`, `model_catalog.dart`) assembles a normalized,
cross-provider list of models with per-model budget, surfaced as `quotabot models`
and the MCP `list_models` tool. Model budget filters are applied in the registry:
`local` is intended to admit only locally executed runtime models, while `quota`
admits local runtimes and
measured built-in quota plans but excludes self-reported manual quotas because
quotabot cannot verify their overage settings. Local-runtime entries surface
`local_readiness` (`loaded` or `cold`), and model recommendations rank loaded
local models ahead of cold installed models when both satisfy the same profile.
When a reachable runtime has an on-device model, `local_hardware.dart` performs
one cached, deadline-bounded passive read of system RAM and GPU evidence.
NVIDIA uses `nvidia-smi`; the Windows compatibility fallback uses
`Win32_VideoController` for names and count only. Its 32-bit AdapterRAM and
unbound aggregate GPU Engine counters are not capacity or activity evidence.
The largest supported GPU memory pool is
selected; separate devices are never summed. Cold models with size evidence get an advisory `hardware_fit`
of `comfortable`, `tight`, `constrained`, or `unknown`; loaded models retain the
direct `loaded` state. The fit evidence is carried in the provider snapshot and
the selected pool, capacities, estimate, and observation time are repeated on
model registry entries so MCP and CLI clients can audit the rank without another
read. Fit reorders cold local candidates but never changes availability and never
loads or invokes a model.
Recommendations also echo available local size, context, and fit evidence so
callers can see why a model is loaded versus merely installed without forcing a
model call.
Ollama's explicit `thinking` capability propagates through the existing model
reasoning field. Missing or malformed declarations cannot satisfy a reasoning
requirement, and capability support cannot override cloud, embedding, stale,
context, or spend exclusions. LM Studio reasoning remains unadmitted while its
LM Link execution location cannot be established from the model-list contract.
Ollama exposes cloud-offloaded models through the local daemon with a `-cloud`
tag suffix. Lemonade exposes configured cloud routes with `recipe: "cloud"` and
`cloud_provider`. quotabot preserves either as `cloud_offloaded` and excludes it
from `budget=local` and free budgets, so a remote model reached through a local
daemon is never counted as on-device or free. Detection uses each runtime's
documented execution-location evidence.
Concrete-model suggestions can opt into `use_expiring_quota`, which computes a
pure `ExpiringQuotaSignal` from existing headroom, reset, and local burn
statistics. The signal is intentionally narrow: measured quota-backed providers
only, no manual entries, no local runtimes, no paid API routes, reset within the
bounded horizon, and projected unused quota above the threshold. Burn history is
keyed by provider/account when the provider exposes a specific account, so
multi-account providers can use the signal only from matching account history.
Legacy provider-only buckets are still a fallback for unambiguous single-account
snapshots. A quarantined account prefers its frozen canonical buckets or
validated pre-divergence checkpoint; when both are absent, the same
single-account provider compatibility fallback remains eligible and uses the
same conservative post-pooling, two-boundary burn estimate. When present it lets
included quota that would otherwise expire unused outrank local capacity, but
the hard `budget=local` filter still wins.
`catalog_audit.dart` keeps the
committed cloud catalog honest without adding runtime network calls: the standalone
`bin/catalog_audit.dart` tool reads provider-owned model-list endpoints for
OpenAI/Codex, Anthropic/Claude, xAI/Grok, and Gemini/Antigravity, follows
pagination tokens, filters obvious non-language modalities, redacts query-string
secrets, and emits a diff. It does not rewrite the catalog automatically because
capability fields such as context, tools, vision, reasoning, and tier remain
curated routing metadata.

`insights.dart` also owns the explicit tier-fit advisory used by
`quotabot stats --tier-plan=...`. It compares caller-supplied plan caps against
the compact local headroom histogram and reports breach probability plus optional
monthly delta only when prices are supplied on the command line. The result is
analytics-only: it is not persisted, does not affect routing, and does not infer
provider price catalogs.

## LiteLLM proxy integration

`integrations/litellm/` is the shipped example of using quotabot as a routing
signal without putting quotabot in the request data path. The Python
`quotabot_router.py` plugin registers a LiteLLM `async_pre_call_hook` that reads
the local quotabot `/suggest` quota recommendation, atomically reserves from the
complete eligible remote target set, and rewrites a logical model to the
reserved LiteLLM deployment. Success and failure callbacks release the lease;
TTL expiry handles a callback that never runs. Unmanaged model names still pass
through unchanged so the proxy can serve ordinary LiteLLM traffic.
For managed logical models, the plugin now has a stricter billing guardrail:
normal API-key deployments are `spend: paid_api` and skipped unless
`allow_paid_api` is explicitly true; included quota-plan deployments must be
marked `spend: quota_plan` and must also declare `overages_disabled: true` or
`overages: disabled`; local candidates are always allowed. Agent pins skip
headroom ranking but still require a safe `pin_spend` class plus
`pin_overages_disabled: true` for quota-plan pins, or paid API opt-in. If a
managed logical model has no safe route and `block_unsafe_passthrough` is true,
the request fails closed before any provider call instead of falling through to
surprise API spend.

The integration is covered at two layers. Unit tests import the hook directly to
check policy precedence, trusted key alias/user_id agent identity, spend-class
guardrails, local-fallback ordering, loopback URL hardening, no-redirect quotabot
fetches, exact-peer authentication before bearer disclosure, authenticated
concurrent reservation, callback release, and metrics path containment under
`~/.quotabot`. CI also installs the current
`litellm[proxy]` package and starts a real LiteLLM proxy on loopback with a fake
quotabot suggestion and lease server plus a fake OpenAI-compatible backend. That
test proves the actual proxy hook reserves and rewrites a logical model, releases
its lease after completion, spends no model tokens, and performs no external
network calls. The plugin uses plain value classes rather than dataclasses
because LiteLLM's current config-relative custom-callback loader executes
modules before registering them in `sys.modules`, which breaks dataclass
decoration on Python 3.13.

When the plugin writes the default `~/.quotabot/litellm-metrics.jsonl`, the
desktop analytics screen reads a bounded tail of that local JSONL file through
`litellm_metrics.dart` and shows request count, routed count, token count,
tracked cost, spend-class counts, top served models, and last-request age. This
keeps routed-request usage visible without making quotabot a proxy or request
data path.

## Alerts and `quotabot watch`

`alerts.dart` is a pure, edge-triggered alert pass: `computeAlerts` takes the
current snapshot, the routing suggestion, and the set of provider/account
identities already alerting, and returns the alerts that newly crossed into a
triggering severity (red by default for CLI/app, amber or red for MCP
subscriptions) plus the updated armed set, so a quota identity fires once on the
crossing and re-arms only after it recovers. `computeProjectedWasteAlerts`
applies the same edge-trigger model to pace analytics: when
`quotabot watch --waste-threshold=N` is set, the CLI raises a `projected_waste`
alert if the current burn pace says at least N percent of a paid renewing window
would expire unused at reset. Each `QuotaAlert` serializes as `quotabot.alert.v1`
with provider/account metadata only, never content. Three thin shells consume
low-quota alerts: the `quotabot watch` command in `bin/collect.dart` (poll,
print, optionally POST), the desktop app's notifier, and the MCP
`quotas://alerts` subscription loop. `webhook.dart` delivers an alert with
`postAlert`, which refuses a non-loopback host unless explicitly allowed and
never throws, so delivery fails soft. An alert is just the binding-window
forecast viewed as a threshold crossing, so it shares the same model as `top`.
Watch startup and external-host rejection diagnostics never echo the configured
URL because webhook paths and queries can carry bearer credentials.
`bin/collect.dart` strictly validates an explicit watch interval. Its
`WatchLoopHealth` state emits only a failure edge and a recovery edge on standard
error, tracks the consecutive failure count used by bounded retry backoff, and
leaves JSON standard output reserved for alert records.

## The UI

- The window is frameless via `window_manager`, with a transparent background
  so the rounded card can hug its content and any surplus window height is
  invisible. Always on top and taskbar entry are optional and controlled by
  prefs. The body is scrollable and expanded quota height comes from the actual
  rendered content when measurement is available, with the deterministic
  provider/window estimate retained as a bounded fallback. Logical dimensions
  are reconciled with the active display work area before `window_manager`
  applies them. Content that cannot fit keeps an explicit scrollbar rather than
  hiding the last provider. Compact mode has its own bounded minimum. Dragging
  works on the full header bar and content/cards area (buttons excluded).
- `ProviderTile` computes the binding window (the one with the least headroom)
  and defaults to a tight view: the window bars with their reset countdowns
  or absolute far reset times, plus the always-actionable failure, drift, and
  last-known signals. If the binding window is exhausted, the card collapses to
  a single line; otherwise it renders one `WindowBar` per window. Clicking a card expands
  it to reveal the full provenance line, the model-specific rows, the recent
  "usually ~X% free" line, and the burn forecast. That forecast is worded plainly
  from the shared `classifyForecast` (the same one `top` shows): a runway estimate
  or, once a strand is material, a plain warning, shown only with a real burn
  signal, never invented. A provider that supports quotabot's own login (Grok,
  Antigravity) shows an inline Connect action for authentication or reconnection
  failures, so it can be reconnected from the app without a terminal. Automatic
  timeout, rate-limit, and service-error recovery does not show that action.
- Desktop maintenance uses one responsive Settings dialog instead of a long
  popup menu. Profile and provider visibility, display, refresh and alert, and
  update controls are grouped into bounded sections. Release discovery is
  user-triggered, reads GitHub's dedicated Latest endpoint plus small bounded
  preview pages under one deadline and byte budget, distinguishes the newest
  candidate from the newest stable release, and opens release details rather
  than silently replacing a running binary. The CLI `update` command follows
  the installed channel, uses the same dedicated Latest endpoint for stable
  selection, small bounded pages for preview selection, and the direct tag
  endpoint for exact selection. It invokes only the installer bundled inside
  its authenticated archive. That
  installer verifies the new archive sidecar and extracted executable version
  before the existing rollback-protected generation switch. The command then
  executes the stable entry to verify the selected version again. No update
  request runs at startup.
- `fleet.dart` is the Quota Analytics body, opened under the same dashboard
  header and menu as the quota view. It swaps the body in place without pushing
  a route. Entry grows a short content-hugged quota window to the normal
  Analytics viewport and adjusts its position only when necessary to keep the
  resulting bounds inside the current display's work area. User-enlarged
  dimensions are preserved when they fit. The body retains a visible scroll
  fallback, large-text card headings stack instead of overflowing, and the
  header's Back to quotas control resumes content-hugged quota sizing, or
  compact-strip sizing when Analytics was opened from compact mode. It is a
  range switch (Now / 7d / 90d): the live view ranks headroom and shows a
  consumption donut; the historical views recompute `Insights` and the heatmap
  from the raw buckets.
- Provider logos are vector `CustomPainter`s (`logos.dart`) so they stay sharp
  at any size and recolor for light or dark. The in-app header shows a small
  dynamic radial "pool gauge" (`AppGauge` in `logos.dart`) next to the "Quota"
  wordmark; it fills clockwise to the average remaining headroom across visible
  providers (`_poolHeadroom` in `main.dart`) and is colored through
  `headroomColor`, which delegates to the collector's `Palette.rgbFor`; neutral
  grey is still used when no data is available. The OS application icon
  (`app_icon.ico`) is separate and unchanged: a custom monochrome rune-style mark
  (light/dark friendly) for the desktop icon.
- A whole-widget compact strip pins the shared next-route or no-safe-route
  control before the horizontally scrollable provider logos and status dots.
  It opens the same decision detail as expanded mode, and a widget-order focus
  traversal group keeps every clipped provider chip keyboard reachable. The
  compact window uses a 200 logical-pixel minimum and display-bounded automatic
  width that reserves space for the route label and visible duplicate-provider
  account identity. Window chrome retains at least a 28 by 28 logical-pixel
  target, and provider focus and expansion transitions become immediate when
  reduced motion is requested. If tray initialization fails, a bounded warning
  explains that Close will exit instead of silently changing behavior. The full
  card view also supports hide/show per provider. In the card view, per-card
  expansion
  toggles the card's own detail - the provenance line, model-specific rows, and
  analytics - on top of the tight default, and it also groups distinct account
  identities when work and personal accounts coexist. Expansion state is keyed by
  provider/account so opening one account's details does not open its sibling. Duplicate-provider cards always show their
  account when the "Show account names" preference is enabled; single-account
  labels remain hidden. `prefs.dart` persists hidden providers, compact state,
  cadence, always on top, taskbar visibility, enable notifications,
  showAccounts, window position, and a bounded 128-entry reset-reminder handled
  ledger across restarts. Ledger entries contain only the numeric notification
  ID and reset epoch, never the provider or account label.
- `WindowBar` keeps normal text in a compact three-column row with safe reset
  wrap points. At large text it reflows label and value above a full-width meter,
  preserving common normalized window names and far reset times at the 320
  logical-pixel expanded minimum. An unusual provider-supplied label remains
  bounded to two visible lines and exposes its complete tooltip and semantics.
- Named profiles live under the per-user quotabot config directory as
  `quotabot.profile.v1` JSON files. Profile names and provider ids are validated
  against safe filename/id characters, profile files are bounded in size, and
  filtering is pure over the already-normalized `ProviderQuota` list.
- The CLI loads `--profile=NAME` once, then every quota-reading command consumes
  the same profile semantics. `check` and filtered strict verification also use
  the provider-level portion of that profile before adapter execution; account
  filters remain post-collection. Missing profiles fail with usage exit code 64.
- The MCP tools accept optional `profile` and exact `account` filters, applying
  the same pure profile filter before account narrowing for quota, routing,
  availability, and model responses. Missing profiles return a structured
  `error` field and no providers; resources remain unfiltered for compatibility.
- The desktop app loads local profiles at startup and on refresh, lets users
  create/edit/delete non-default profiles, applies the active profile before
  display, notifications, webhook alerts, and analytics, and persists
  non-default profile hidden-provider, sort, and theme preferences back into the
  profile file. The `default` profile keeps the legacy app prefs file.
- A thirty second timer repaints so the last-check label ("checked HH:MM AM")
  and reset countdowns stay current. Each card carries its own evidence capture
  age in its expanded provenance line; actual data refresh is on a separate
  adaptive timer.
- History snapshots (last few per provider) load from jsonl and show a
  "usually ~X% free (last N)" line in expanded tiles when an average is present
  ("N recent checks" otherwise).
- Notifications toggle drives guarded immediate low-headroom alerts, scheduled
  reset reminders, and edge-triggered redeemable-reset notifications via
  flutter_local_notifications. A trusted window above 80 percent used is
  scheduled at reset minus 15 minutes, or shown immediately when first observed
  inside that lead. Native notification bodies and Windows subtitles follow the
  account-name preference and expose an account only when duplicate provider
  accounts need disambiguation.
- Pending reset requests are owned only when their payload exactly equals
  `quotabot.reset-reminder.v1`. Reconciliation cancels obsolete owned requests
  and preserves every foreign payload. It compares the owned request title and
  body with current privacy-aware text; a mismatch is cancelled and rescheduled,
  so hiding account names takes effect on already-pending reminders.
- Alert checks, privacy reconciliation, and notification disablement share one
  serialized flight. A disable request queued behind an in-progress schedule
  cancels that newly registered owned request before the flight completes, while
  a re-enable queued behind cancellation schedules the current desired set.
- Successful schedules and immediate reset deliveries enter the bounded
  preference ledger through their reset epoch. The ledger is not cleared by a
  temporary stale or threshold gap, so a delivered OS schedule cannot become a
  duplicate immediate alert after the pending request disappears, including
  across process restarts. Cancelling an undelivered future schedule removes its
  ledger entry, and expired epochs are pruned, preserving retry behavior for a
  genuinely eligible reminder.

## Adaptive refresh

`_nextInterval()` picks the next refresh delay from the current data. Quota moves
slowly and a cloud read can be rate-limited, so the default leans gentle: about
thirty seconds only when a reset is imminent, ten to twenty minutes when a
provider is near a cap and its binding window's own reset is near enough to be
worth watching, twenty minutes at the healthy baseline, and one to twelve hours
as the nearest reset recedes. A provider that is spent (or nearly so) but whose
reset is far away is not watched closely - it just sits there until it resets -
so it relaxes like a healthy provider rather than pinning the whole fleet to a
fast poll. A cycle that returns nothing live backs off to one hour, then six.
When a provider keeps pushing back, the back-off escalates each consecutive
cycle - twenty minutes, then forty, then ninety - and honors an explicit
retry-after, so quotabot stops checking a provider that is not ready; an
imminent reset is still caught promptly. A timeout reads as `provider slow`,
HTTP 429 as `rate limited`, and HTTP 5xx as `provider error`, while all three
retain the same bounded automatic recovery policy. A
fixed cadence (15 minutes or 1 hour) can be chosen from the menu instead of the
smart schedule. `top` and `watch` share the same `nextRefreshSeconds`, so all
three poll alike.

## Packaging

The CLI release workflow builds native archives for Windows x64, macOS arm64,
Linux x64, and Linux arm64, with checksums and provenance attestations. The
Flutter desktop app also produces native portable Windows x64, macOS arm64, and
Linux x64 archives with checksum sidecars, shape validation, provenance
attestations, clean-runner lifecycle checks, and a draft-release publication
barrier. Source setup remains available when a launcher or shortcut is wanted.
The official repository also blocks `v*` tag updates and deletion. GitHub
release immutability locks the tag and assets when a draft is published after
the setting activation. Stable v0.10.3 follows the same exact 14-asset release
and three-OS GitHub Latest lifecycle contracts. Stable v0.10.2 established the
preceding audited record through its native
[release run](https://github.com/blisspixel/quotabot/actions/runs/33595583014)
and [install smoke](https://github.com/blisspixel/quotabot/actions/runs/33598880949).
Releases published before the July 18, 2026 activation were not changed
retroactively.
Application signing and notarization are pre-1.0 completion gates. Interactive
native evidence remains a final 1.0 gate and must run again on the exact signed
candidate. Platform prerequisites and artifacts are documented in
[BUILDING.md](BUILDING.md), [DESKTOP-DISTRIBUTION.md](DESKTOP-DISTRIBUTION.md),
and [../ROADMAP.md](../ROADMAP.md).
