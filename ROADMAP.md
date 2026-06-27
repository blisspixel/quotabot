# Roadmap

Status of the project and what is planned next. Ordered roughly by priority.

## Done

- Normalized quota model shared by the collector and the app.
- Codex adapter: reads the `rate_limits` snapshot from the newest session
  rollout file (5 hour and weekly windows, reset times, plan).
- Claude adapter: live 5 hour and weekly usage from the OAuth usage endpoint,
  reusing the access token stored in Claude Code local credentials.
- Antigravity adapter: live per-model quota from the Google Cloud Code API,
  reusing the token the IDE stores; falls back to account and plan when the
  token has expired.
- Grok adapter: live monthly credit usage from the gRPC-web billing endpoint,
  reusing the token the CLI stores; falls back to account and plan when expired.
- CLI `doctor` command: a readable per-provider validation table that costs no
  usage tokens.
- MCP server (`bin/mcp_server.dart`): exposes `list_quotas`,
  `provider_with_most_headroom`, and `check_provider_availability` over stdio.
- Project skill describing how to check quota and route work.
- Test suite covering the parsing, model, cache, analysis, and auth logic
  (about 90 percent line coverage of that core).
- Persistent OAuth login for Grok (device flow) and Antigravity (loopback +
  PKCE), each an independent grant that keeps the provider live without
  reopening its app and without disturbing the host credentials. `login` and
  `logout` CLI subcommands.
- Persisted UI preferences: hidden providers, compact state, refresh cadence,
  always on top, taskbar visibility, and window position survive restarts.
- Multiple Antigravity accounts support via per-account caching (shows multiple
  when accounts switch).
- Basic desktop notifications for low quota (immediate + scheduled reset alerts, toggleable).
- Basic historical snapshot logging (per-provider jsonl, average headroom display in UI).
- Local HTTP server (bin/local_server.dart) serving normalized JSON on a port.
- Example routing agent (bin/example_routing_agent.dart) using shared analysis.
- Windows desktop packaging exercised (flutter build windows --release verified; minimal helpers + .desktop; macOS/Linux docs + code paths complete).
- Full multi-Antigravity (cross-platform Profiles scan + per-account).
- Expanded providers: Kiro (CLI+IDE credits, passive for installed/cancelled) and Cursor (free/Pro, local detection). Windsurf (daily/weekly Cascade quota via cachedPlanInfo). Gemini CLI (consumer) transitioned to Antigravity; Google support via existing Antigravity adapter. Agnostic tools covered via underlying.
- Desktop widget: frameless, system light/dark, vector provider logos,
  availability bars with reset countdowns. Menu toggles for always on top
  (default off), show in taskbar (default on), and notifications (default on).
- Binding-constraint logic: a spent longer window collapses the card and
  overrides shorter windows so nothing reads as healthy when it is not.
- Compact and expanded views with a window that scales to fit.
- Hide and show individual providers.
- Adaptive refresh interval.
- Last-known-good caching with a stale indicator.
- Custom monochrome rune-style application icon (light/dark friendly; multi-size .ico + Linux .png).
- Desktop launcher: robust quotabot-gui (.cmd/.ps1) with deep clean, visible console, focus, kept for running from source during development. Desktop shortcut now opens the built release exe directly (app/build/windows/x64/runner/Release/quotabot.exe) instead of the source launcher.
- "Show account names" setting (global toggle in menu; hides usernames when off). On top of this, account/username is auto-hidden for single-account providers and shown only when a provider has more than one account on screen (e.g. multiple Antigravity logins); so single-account Grok no longer shows its email.
- In-app header app mark is a dynamic radial "pool gauge" plus a "Quota" wordmark (AppGauge in app/lib/logos.dart): it fills to the average remaining headroom across visible providers (computed by _poolHeadroom in app/lib/main.dart) and colors green (>=50% free) / amber (>=25%) / orange (>0) / red (spent), neutral when no data. The OS application icon (taskbar/shortcut/.ico) is unchanged.
- Per-provider history line reworded to "usually ~X% free (last N)" ("N recent checks" when no average is available).
- Layout overflow fix: the body is now scrollable and window height is derived from a deterministic content estimate capped at the actual screen height, so all visible providers render without the "BOTTOM OVERFLOWED" banner (replaces the old fixed 900px height clamp).
- Claude weekly (and windows with resetsAt) shows reset countdowns in bars (e.g. "80%  3d12h").
- Antigravity "free tier" explicit display.
- Window fixes: measured content size (no dead zones), smaller min size, broader drag areas (full header + content), reduced focus flash.
- Routing recommendation: shared `suggestRoute` analysis that prefers the freest
  live subscription above a comfort threshold and falls back to a local runtime
  when subscriptions are low. Exposed as `quotabot suggest` (CLI, human + JSON),
  the `suggest_provider` MCP tool, and `GET /suggest` on the local HTTP server.
- Local runtimes (Ollama, LM Studio): detected via their local APIs and shown by
  what they have (installed and loaded models, in-use status) rather than a
  meaningless quota bar. They sort below the cloud services, act as an
  always-available routing fallback, and carry real icons. Other
  OpenAI-compatible runtimes can be added with the shared `localRuntimeQuota`
  helper.
- LiteLLM integration (`integrations/litellm/`): a pre-call hook that routes each
  proxy request to the deployment with budget (per-agent steering, local
  fallback, fail-soft) plus a success-event usage logger. Cross-platform.
- Display clarity: usage bars read "X% free" (was an unlabeled "X%"); the header
  timestamp shows an absolute clock time ("as of 8:38 AM") instead of "N minutes
  ago", with a date appended once stale.
- Correctness fixes: Codex snapshots now carry their real capture time and are
  marked stale past the window age (no more idle "100% free"); the Antigravity
  last-known-good fallback loads the per-account cache it actually writes;
  headroom selection prefers live data over fuller stale caches; Windsurf no
  longer double-counts duplicate window keys; history files are size-bounded;
  Windows token files are restricted with icacls.
- Codex multi-bucket usage: aggregates the latest snapshot of each model limit
  bucket across recent sessions and shows the binding window, so usage on one
  model is no longer masked by a fresh bucket on another.
- Historical analytics: headroom folded into compact hourly buckets retained 90
  days, with mean/spread, p10/p50/p90 from a histogram, reliability, a
  least-squares trend (percent per day with R-squared), and a by-hour profile.
  Surfaced as `quotabot stats` and an expandable in-app insights panel with a
  sparkline.
- Security and robustness: token files created owner-only before the secret is
  written and the auth dir locked down; the local HTTP server returns generic
  errors and throttles outbound provider calls; the LiteLLM local fallback no
  longer preempts a metered provider with budget; cache writes are atomic.
- Desktop binary renamed to quotabot.

## Next

### Build out the MCP routing primitive
Core delivered (tools, resource, worked example in bin/example_routing_agent.dart,
plus `suggest_provider` and the LiteLLM proxy plugin). Possible next: Streamable
HTTP transport, and surfacing the LiteLLM usage-metrics log back in the widget so
routed-request counts sit next to subscription headroom.

### Multiple Antigravity accounts
Full support delivered (per-account cache + cross-platform profile dir scan in adapter for Windows/macOS/Linux; live primary + stale cached others shown).

### Configuration
Complete via in-app menu (cadence, hides, always on top, taskbar, notifications).

## Quota as a primitive (MCP server and skill)

The collector produces a normalized, provider-agnostic quota feed. This is
exposed so agents can consume it:

- MCP server in bin/mcp_server.dart with tools: list_quotas, provider_with_most_headroom,
  check_provider_availability. Also a quotas://current resource. Every call is a
  zero-token metadata read.
- Project skill for non-MCP consumers.
- Example routing agent in bin/example_routing_agent.dart.

Binding constraint logic (longer window spent overrides) is enforced in both
analysis helpers and the UI. Core is delivered.

## Ideas from the field (competitive scan)

From a deep read of similar tools (ccusage, CodexBar, ClaudeBar, TokenTracker,
codeburn, tokscale, tokcat, Claude-Code-Usage-Monitor, coding_agent_usage_tracker).
quotabot's differentiators to keep leaning on: cross-platform desktop widget
(most rivals are macOS menu-bar only), reading real rate-limit windows (vs token
or dollar accounting), routing as a primitive (suggest/MCP/LiteLLM), local-runtime
monitoring, and value analytics. Prioritized backlog of ideas worth adopting:

High value, on-brand:
- Hour x day-of-week headroom heatmap ("best time to run"). None of the rivals
  show both dimensions at once; quotabot already computes both profiles.
- Routing-aware alerts: when a provider goes low, the notification names where to
  route next (ties alerts to the suggest engine). Tiered 70%/90% thresholds with
  an A-F urgency rank so the most urgent risk surfaces first.
- Actionable warnings with a one-line remedy ("route to X", "switch to Ollama for
  this task", "downgrade Opus to Sonnet") - the strongest UX idea from codeburn.
- More quota-window providers in the same lane: Z.ai (GLM), Kimi, Amp, OpenCode.
  (Skip pay-as-you-go API vendors - that is cost, not a rolling-window quota.)
  Not Gemini CLI (EOL, folded into Antigravity, already covered).
- GitHub Copilot: intentionally NOT supported. For individuals it is not really a
  rolling-window quota (premium requests are a monthly allowance with pay-as-you-go
  overage), the usage is server-side only (GitHub billing analytics, nothing cached
  locally), and the token lives in the OS keyring rather than a file. Revisit only
  if GitHub exposes a local or simple premium-request quota read.
- Versioned machine-readable schema on all outputs (e.g. "quotabot.v1") so agents
  can consume routing data stably.
- Merged "most-constrained provider" compact mode for the collapsed widget.
- Per-window reset countdown rows in the "% left + bar + resets in" format.

Medium value:
- GitHub-style year contribution calendar and a 30-day stacked-by-provider chart.
- Plan-tier modeling (Pro/Max 5x/20x) so headroom and runway map to the real
  allowance; surface projected overage.
- Provider status/incident polling ("is the provider even up right now").
- Streaks and summary stats (longest/current streak, best day, daily average).
- Reusable passive-reader adapter taxonomy (JSONL-transcript, SQLite-session,
  OTel-file) to expand provider coverage cheaply.
- doctor / status --json diagnostics for per-provider detection.
- Optional cost dimension from local session logs (kept distinct from the
  headroom positioning).

Deliberately skipped: token/dollar cost ledgers as the primary view, git-commit
productivity correlation, global leaderboards / cloud sync (local-first), browser
cookie + keychain decryption (platform-specific, privacy-sensitive), 3D isometric
graphs (high cost, mostly aesthetic), CLI-PTY scraping of `/usage` (brittle;
prefer the OAuth/file sources quotabot already uses).

## Later

- Enhance the local HTTP endpoint and MCP (basic HTTP server and stdio MCP
  present; richer transports or client examples possible).
- Polish notifications and historical display (desktop platform details + debounce + 10-snapshot retention delivered; further trend views or UI optional).
- macOS and Linux packaging polish (Windows release verified + helpers; macOS/Linux notes + .desktop + code ready for target builds).
