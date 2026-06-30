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
  model_catalog.dart committed, refreshable cloud model capability catalog
  cache.dart         last-known-good snapshot cache (per-account keyed where a
                     provider reads several logins); recent burn stats
  ansi.dart          shared ANSI styling and color-depth detection
  top.dart           pure renderer for the `quotabot top` live dashboard:
                     gradient meters, palettes, local detail lines, the
                     forward-looking forecast (strand probability/time-to-empty),
                     the interactive sort (TopSort + sortProvidersForTop), and the
                     keyboard helpers (moveSelection, osc52Copy clipboard)
  demo.dart          synthetic fleet + burn stats for QUOTABOT_DEMO previews
  mcp.dart           MCP tool shapes, output schemas, and registration
  collector.dart     collectAll(): run adapters, apply cache; package exports
  adapters/          codex, claude, grok, antigravity, kiro, cursor, windsurf,
                     ollama, lmstudio, lemonade (thin I/O shells)
  auth/              tokens + store, PKCE/loopback util, xai + google OAuth
  util.dart          home/config dirs, varint + protobuf helpers
  bin/collect.dart        CLI: status/doctor, top, watch, models, calibration,
                          check, suggest, stats, json, login, logout
                          (stable exit codes 0/64/69)
  bin/mcp_server.dart     MCP server over stdio (tools + quotas://current resource)
  bin/local_server.dart   Optional plain HTTP JSON snapshot server
  bin/example_routing_agent.dart  Worked example using collect + analysis for routing

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

Adapters never talk to the UI. They return `ProviderQuota`, and the UI derives
everything it shows from that, including colors and the binding-constraint
collapse.

## Separation of pure logic from I/O

The bulk of the logic lives in `parsing.dart` and `analysis.dart` with no
network or disk access, so it is unit tested directly against fixtures. Adapters
are thin shells: they fetch bytes (file, SQLite, or HTTP) and delegate parsing.
This is why the core has high test coverage even though the adapters do I/O.

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
For multi-account providers, stale per-account snapshots are appended only when
the account is still present in that provider's current local account index and
the live adapter did not already return it. This is the signed-out auto-hide
rule: a cached work account disappears once the provider's own local account
state no longer lists it.

## Routing helpers and the MCP server

`analysis.dart` exposes `providerHeadroom`, `providerWithMostHeadroom`,
`providerAvailability`, `bindingWindow`, `averageRecentHeadroom`, and the
forecast helpers `riskAdjustedHeadroom`, `strandProbability`, and `suggestRoute`.
`bin/mcp_server.dart` wraps `collectAll()` plus helpers as MCP tools and a
`quotas://current` resource over stdio. `bin/example_routing_agent.dart` shows
the same logic used for routing decisions. `bin/local_server.dart` provides a
simple HTTP alternative. The reasoning behind the routing math (risk-adjusted
headroom, strand probability, and the planned extensions) is written up in
[ROUTING-MATH.md](ROUTING-MATH.md).

The model registry (`registry.dart`, `model_catalog.dart`) assembles a normalized,
cross-provider list of models with per-model budget, surfaced as `quotabot models`
and the MCP `list_models` tool.

## Alerts and `quotabot watch`

`alerts.dart` is a pure, edge-triggered alert pass: `computeAlerts` takes the
current snapshot, the routing suggestion, and the set of providers already
alerting, and returns the alerts that newly crossed into a triggering severity
(red by default) plus the updated armed set, so a provider fires once on the
crossing and re-arms only after it recovers. Each `QuotaAlert` serializes as
`quotabot.alert.v1` (metadata only, never content). Two thin shells consume it:
the `quotabot watch` command in `bin/collect.dart` (poll, print, optionally POST)
and the desktop app's notifier. `webhook.dart` delivers an alert with
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
