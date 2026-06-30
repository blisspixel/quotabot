# Architecture

quotabot has two parts, both written in Dart: a collector package and a Flutter
desktop app. The app depends on the collector by path and calls it directly, so
there is a single code path and no subprocess or IPC. The collector also ships
two binaries: a CLI and an MCP server.

```
collector/ (Dart package)
  models.dart        normalized ProviderQuota / QuotaWindow / ModelInfo / BurnStat
  parsing.dart       pure response/window parsing (no I/O)
  analysis.dart      pure routing: headroom, risk-adjusted headroom, strand
                     probability, suggestRoute, the shared forward-looking
                     forecast (classifyForecast/WindowForecast, used by both top
                     and the widget), adaptive refresh cadence
                     (nextRefreshSeconds, shared by top and the app)
  insights.dart      pure analytics: buckets, percentiles, trend, pace, heatmap,
                     burn rate with uncertainty
  alerts.dart        pure: low-quota alert severity + edge-triggered computeAlerts
                     (quotabot.alert.v1), shared by quotabot watch and the widget
  webhook.dart       loopback-guarded, fail-soft alert webhook sender (postAlert)
  calibration.dart   pure: grade the strand predictor against recorded history
  registry.dart      pure: assemble the cross-provider model registry with budget
  model_catalog.dart committed cloud model capability catalog
  catalog_audit.dart pure/provider-owned model-list diffing for catalog currency
  schema_contracts.dart frozen quotabot.v1 JSON Schema and validator
  provider_adapters.dart compile-time adapter and fixture registry
  profiles.dart      named local profile schema, storage, and filtering
  cache.dart         last-known-good snapshot cache (per-account keyed where a
                     provider reads several logins); recent burn stats
  leases.dart        local routing leases for parallel-agent reservation and
                     release, backed by file locking in production
  ansi.dart          shared ANSI styling and color-depth detection
  top.dart           pure renderer for the `quotabot top` live dashboard:
                     gradient meters, palettes, local detail lines, the
                     forward-looking forecast (strand probability/time-to-empty),
                     the interactive sort (TopSort + sortProvidersForTop), and the
                     keyboard helpers (moveSelection, osc52Copy clipboard)
  demo.dart          synthetic fleet + burn stats for QUOTABOT_DEMO previews
  simulation.dart    exact one-provider snapshots for deterministic CLI tests
  mcp.dart           MCP tool shapes, output schemas, shared server factory
  mcp_http.dart      Opt-in Streamable HTTP MCP wrapper with loopback guards
  collector.dart     collectAll(): run adapters, apply cache; package exports
  adapters/          codex, claude, grok, antigravity, kiro, cursor, windsurf,
                     ollama, lmstudio, lemonade (thin I/O shells)
  auth/              tokens + store, PKCE/loopback util, xai + google OAuth
  util.dart          home/config dirs, varint + protobuf helpers
  bin/collect.dart        CLI: status/doctor, top, watch, models, calibration,
                          check, suggest, stats, json, login, logout
                          (stable exit codes 0/64/69)
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
  fleet.dart  the Quota Analytics screen (Now/7d/90d, charts, the oracle glyph)
  demo.dart   synthetic data for QUOTABOT_DEMO previews/screenshots
  logos.dart  vector provider logos (CustomPainter)
  prefs.dart  persisted UI preferences
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
`ProviderQuota` snapshots for CLI tests without adapter calls, history reads, or
burn-history influence. It is intentionally separate from `demo.dart`, which is a
believable multi-provider screenshot fleet rather than an exact assertion tool.
The parser test layer includes seeded property/fuzz tests over malformed JSON,
protobuf-like byte streams, gRPC-web frames, and embedded-token blobs, plus
sanitized provider-shape fixtures loaded from `collector/test/fixtures/` so the
pure parsers are checked against stable recorded shapes without touching live
credentials or provider APIs. `provider_adapters.dart` is the compile-time
registry for all built-in adapters and their required sanitized fixtures; tests
fail when a new adapter lacks a registry row or fixture.

## Adapters

Each adapter has a single `collect()` method returning a `ProviderQuota`:

- Codex reads a local file (the newest session rollout) and parses the
  `rate_limits` snapshot. No network or auth.
- Claude, Grok, and Antigravity call live metadata endpoints (no model calls, no
  token cost). Claude reuses the token Claude Code stores. Grok and Antigravity
  prefer quotabot's own OAuth grant (see Authentication) and fall back to the
  token the host CLI or IDE currently holds. Grok reads every account in the CLI
  auth file and caches them separately. Antigravity scans the active account and
  profile databases, attempts live reads for each discovered account, refreshes
  the Gemini CLI token from disk when it is the active token source, and runs the
  Cloud Code onboarding step before reading per-model quota.
- Kiro, Cursor, and Windsurf are passive readers of local credit/state files, so
  they are detected (and report installed/free tiers) even with no live API.
  Cursor's current included-usage pool is normalized as a monthly quota window
  when the local SQLite state exposes used/included values. Windsurf/Devin
  Desktop daily and weekly Cascade quota shapes are normalized from local SQLite
  state, with account and plan labels surfaced when present.
- Ollama, LM Studio, and Lemonade are local-runtime adapters: they report
  installed and loaded models instead of a quota window and act as a routing
  fallback. Any OpenAI-compatible runtime can be added with the shared
  `localRuntimeQuota` helper.

An adapter that cannot produce live windows still returns a `ProviderQuota` with
account and plan and an explanatory `error` note, rather than throwing. The UI
shows that as "no live data" instead of a gap.

## Authentication

`auth/` holds quotabot's own OAuth, kept separate from the host apps' tokens:

- `tokens.dart`: the `Tokens` model and `TokenStore`, which persists tokens per
  provider, and optionally per provider account, under the config directory,
  owner-only on POSIX. Account-scoped filenames use a hash of the account id
  rather than the raw email. Rotated refresh tokens are saved on every refresh or
  the next refresh would fail.
- `oauth_util.dart`: PKCE (S256), a free-port helper, a one-shot loopback server
  to capture the redirect, and a system-browser launcher.
- `xai_auth.dart`: the Grok device-code login and refresh.
- `google_auth.dart`: the Antigravity loopback plus PKCE authorization-code
  login and refresh.

Each login mints an independent grant, so refreshing never invalidates the host
CLI's or IDE's credentials. `login`/`logout` are CLI subcommands.

## Collection and caching

`collectAll()` runs every adapter concurrently (Antigravity via multi-account
profile scan + per-account caches) and wraps each in a cache layer (`cache.dart`):

1. Run the adapter.
2. If it succeeded and has windows, write the snapshot to the local cache and
   return it.
3. Otherwise, load the last-known snapshot, mark it stale, and return that.

The cache lives under the platform application-data directory
(`%LOCALAPPDATA%/quotabot/cache` on Windows). This is what keeps a transient
rate limit or an expired token from blanking a provider.
The cache directory and atomic-write files are best-effort owner-only local
metadata. Cache-only routing reads only canonical snapshot filenames that match
the parsed provider/account identity and rejects snapshots dated materially in
the future, so a stray JSON file in the cache directory cannot become a fresh
routing recommendation.
For multi-account providers, stale per-account snapshots are appended only when
the account is still present in that provider's current local account index and
the live adapter did not already return it. This is the signed-out auto-hide
rule: a cached work account disappears once the provider's own local account
state no longer lists it.

## Routing helpers and the MCP server

`analysis.dart` exposes `providerHeadroom`, `providerWithMostHeadroom`,
`providerAvailability`, `bindingWindow`, `averageRecentHeadroom`, and the
forecast helpers `riskAdjustedHeadroom`, `strandProbability`, and `suggestRoute`.
`suggestRoute` can accept active local lease discounts so concurrent routers see
reduced effective headroom for the provider/account another caller already
reserved. `leases.dart` owns those reservations: production uses a small
file-backed store protected by a lock file, while tests use an in-memory store.
Leases are advisory local metadata with TTLs and idempotency keys; they never
contact providers and never sit in the prompt or inference data path.

`mcp.dart` builds one MCP server definition: tools, resources, output schemas,
read-only/idempotent annotations, capability scope, and standard MCP resource
subscription handlers. Most tools read a live `collectAll()` snapshot. They can
also apply exact `account` filters after named profile filters for routers that
need one provider account without creating a profile. `decide_now` is
deliberately different: it reads the in-memory or disk last-known snapshot only,
returns `source`, `snapshot_as_of`, age, and staleness, and never forces a live
collect. `reserve_provider` and `release_provider` are the only local-write
tools, and their annotations mark that distinction for MCP clients.
`quotas://current` remains the unfiltered live snapshot resource.
`quotas://alerts` stores the last `quotabot.alert.v1` objects fired by the MCP
subscription loop. Clients subscribe with `resources/subscribe`; on an amber/red
crossing, the server emits the standard `notifications/resources/updated` event
for `quotas://alerts`, so clients react by reading the resource instead of
polling a tool. `bin/mcp_server.dart` feeds the shared server factory over stdio
by default or MCP Streamable HTTP when launched with `--http`. `mcp_http.dart`
keeps HTTP opt-in and loopback-only, enables DNS-rebinding host/origin checks,
rejects batch JSON-RPC payloads, and can require a bearer token.
`bin/example_routing_agent.dart` shows the same logic used for direct Dart
routing decisions, while `integrations/mcp_clients/` shows Python and TypeScript
MCP clients for both stdio and Streamable HTTP.
`bin/local_server.dart` provides a plain HTTP JSON alternative for non-MCP
consumers. The reasoning behind the routing math (risk-adjusted headroom, strand
probability, and lease discounts) is written up in
[ROUTING-MATH.md](ROUTING-MATH.md).

The public snapshot contract is frozen as `quotabot.v1` in
`schema_contracts.dart` and documented in [SCHEMA.md](SCHEMA.md). The contract is
additive: consumers must tolerate unknown fields, while quotabot must keep the
meaning and type of existing fields stable until a new schema id is introduced.

The model registry (`registry.dart`, `model_catalog.dart`) assembles a normalized,
cross-provider list of models with per-model budget, surfaced as `quotabot models`
and the MCP `list_models` tool. `catalog_audit.dart` keeps the committed cloud
catalog honest without adding runtime network calls: the standalone
`bin/catalog_audit.dart` tool reads provider-owned model-list endpoints for
OpenAI/Codex, Anthropic/Claude, xAI/Grok, and Gemini/Antigravity, follows
pagination tokens, filters obvious non-language modalities, redacts query-string
secrets, and emits a diff. It does not rewrite the catalog automatically because
capability fields such as context, tools, vision, reasoning, and tier remain
curated routing metadata.

## LiteLLM proxy integration

`integrations/litellm/` is the shipped example of using quotabot as a routing
signal without putting quotabot in the request data path. The Python
`quotabot_router.py` plugin registers a LiteLLM `async_pre_call_hook` that reads
only the local quotabot `/suggest` quota recommendation and rewrites a logical
model to a concrete LiteLLM deployment. It fails soft: bad policy, unreachable
quotabot, or malformed response leaves the requested model unchanged.

The integration is covered at two layers. Unit tests import the hook directly to
check policy precedence, trusted key alias/user_id agent identity, local-fallback
ordering, loopback URL hardening, no-redirect quotabot fetches, and metrics path
containment under `~/.quotabot`. CI also installs the current `litellm[proxy]`
package and starts a real LiteLLM proxy on loopback with a fake quotabot
`/suggest` server and a fake OpenAI-compatible backend. That test proves the
actual proxy `async_pre_call_hook` path rewrites a logical model to the provider
with budget, spends no model tokens, and performs no external network calls. The
plugin uses plain value classes rather than dataclasses because LiteLLM's
current config-relative custom-callback loader executes modules before
registering them in `sys.modules`, which breaks dataclass decoration on Python
3.13.

## Alerts and `quotabot watch`

`alerts.dart` is a pure, edge-triggered alert pass: `computeAlerts` takes the
current snapshot, the routing suggestion, and the set of providers already
alerting, and returns the alerts that newly crossed into a triggering severity
(red by default for CLI/app, amber or red for MCP subscriptions) plus the updated
armed set, so a provider fires once on the crossing and re-arms only after it
recovers. Each `QuotaAlert` serializes as `quotabot.alert.v1` (metadata only,
never content). Three thin shells consume it: the `quotabot watch` command in
`bin/collect.dart` (poll, print, optionally POST), the desktop app's notifier,
and the MCP `quotas://alerts` subscription loop. `webhook.dart` delivers an alert with
`postAlert`, which refuses a non-loopback host unless explicitly allowed and
never throws, so delivery fails soft. An alert is just the binding-window
forecast viewed as a threshold crossing, so it shares the same model as `top`.

## The UI

- The window is frameless via `window_manager`, with a transparent background
  so the rounded card can hug its content and any surplus window height is
  invisible. Always on top and taskbar entry are optional and controlled by
  prefs. The body is scrollable and the window height comes from a deterministic
  content-size estimate (provider and window counts) capped at the screen
  height; live render-measurement proved unreliable because window_manager's
  pixel units don't match Flutter's logical pixels under display scaling. This
  fixes the "BOTTOM OVERFLOWED" banner that appeared with many providers, so all
  providers display without an overflow. Small minimum size supports compact
  mode. Dragging works on the full header bar and content/cards area (buttons
  excluded).
- `ProviderTile` computes the binding window (the one with the least headroom).
  If that window is exhausted, the card collapses to a single line; otherwise it
  renders one `WindowBar` per window. Windows with `resetsAt` (e.g. Claude weekly)
  show countdowns (e.g. "80%  3d12h"). When a provider is visibly burning it adds
  a glance-layer forecast line on the binding window, worded plainly from the
  shared `classifyForecast` (the same forecast `top` shows): a runway estimate or,
  once a strand is material, a plain warning. It is shown only with a real burn
  signal, never invented.
- `fleet.dart` is the Quota Analytics screen, opened from the header and pushed as
  a route over the strip (the window resizes to a steady portrait and restores on
  Back). It is a range switch (Now / 7d / 90d): the live view ranks headroom and
  shows a consumption donut; the historical views recompute `Insights` and the
  heatmap from the raw buckets. It carries the one sanctioned emoji, a glyph
  derived from the fleet's numbers (`pythagorasOracle`).
- Provider logos are vector `CustomPainter`s (`logos.dart`) so they stay sharp
  at any size and recolor for light or dark. The in-app header shows a small
  dynamic radial "pool gauge" (`AppGauge` in `logos.dart`) next to the "Quota"
  wordmark; it fills clockwise to the average remaining headroom across visible
  providers (`_poolHeadroom` in `main.dart`) and is colored with the same
  `_availColor` scale as the cards (green at >=50% free, amber >=25%, orange >0,
  red when spent; neutral grey when no data). The OS application icon
  (`app_icon.ico`) is separate and unchanged: a custom monochrome rune-style
  mark (light/dark friendly) for the desktop icon.
- Compact and expanded views, plus hide/show per provider. The expanded view
  groups distinct account identities when work and personal accounts coexist,
  and expansion state is keyed by provider/account so opening one account's
  details does not open its sibling. Duplicate-provider cards always show their
  account to avoid ambiguity; the "Show account names" toggle still exposes
  usernames for single-account providers. `prefs.dart` persists hidden providers,
  compact state, cadence, always on top, taskbar visibility, enable
  notifications, showAccounts, and window position across restarts.
- Named profiles live under the per-user quotabot config directory as
  `quotabot.profile.v1` JSON files. Profile names and provider ids are validated
  against safe filename/id characters, profile files are bounded in size, and
  filtering is pure over the already-normalized `ProviderQuota` list.
- The CLI loads `--profile=NAME` once, then every quota-reading command consumes
  the same profiled snapshot. Missing profiles fail with usage exit code 64.
- The MCP tools accept optional `profile` and exact `account` filters, applying
  the same pure profile filter before account narrowing for quota, routing,
  availability, and model responses. Missing profiles return a structured
  `error` field and no providers; resources remain unfiltered for compatibility.
- The desktop app loads local profiles at startup and on refresh, lets users
  create/edit/delete non-default profiles, applies the active profile before
  display, notifications, webhook alerts, and analytics, and persists
  non-default profile hidden-provider, sort, and theme preferences back into the
  profile file. The `default` profile keeps the legacy app prefs file.
- A thirty second timer repaints so the age label ("as of HH:MM AM") and reset
  countdowns stay current; actual data refresh is on a separate adaptive timer.
- History snapshots (last few per provider) load from jsonl and show a
  "usually ~X% free (last N)" line in expanded tiles when an average is present
  ("N recent checks" otherwise).
- Notifications toggle drives guarded immediate low-headroom alerts and
  scheduled reset notifications via flutter_local_notifications.

## Adaptive refresh

`_nextInterval()` picks the next refresh delay from the current data: about
thirty seconds when a reset is imminent, five minutes near a cap, fifteen
minutes when partially used, and one hour to twelve hours when everything is
healthy and resets are far off. A cycle that returns nothing live backs off to
one hour, then six. A fixed cadence (15 minutes or 1 hour) can be chosen from
the menu instead of the smart schedule.

## Packaging

Code is cross platform (platform-aware paths and sqlite in collector; Flutter desktop + window_manager in app). Windows release build verified (build/windows/x64/runner/Release). See README + tools/package-*.ps1/sh + .desktop for build and packaging. macOS: codesign + notarize; Linux: AppImage + .desktop. Build on target OS.
