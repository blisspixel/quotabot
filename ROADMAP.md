# Roadmap

Where the project stands and what is planned next. For the full record of
shipped changes, see [CHANGELOG.md](CHANGELOG.md).

## Shipped

The core is complete and in daily use:

- Normalized, provider-agnostic quota model shared by the collector and the app.
- Live adapters for Codex, Claude, Grok, and Antigravity (metadata reads, zero
  usage tokens), plus passive detection for Kiro, Cursor, and Windsurf and
  local-runtime reporting for Ollama and LM Studio.
- Persistent OAuth login for Grok (device flow) and Antigravity (loopback +
  PKCE), each an independent grant that never disturbs the host app credentials.
- Cross-platform desktop widget: frameless, system light/dark, vector logos,
  availability bars with reset countdowns, binding-constraint collapse, compact
  and expanded views, per-provider hide/show, adaptive refresh, and last-known
  -good caching with a stale indicator.
- History and analytics: 90-day hourly buckets feeding distribution, reliability,
  trend, and by-hour profiles, surfaced as `quotabot stats` and an in-app panel.
- Routing as a primitive: a shared recommendation engine exposed as `quotabot
  suggest`, the MCP server (`list_quotas`, `provider_with_most_headroom`,
  `suggest_provider`, `check_provider_availability`, plus a `quotas://current`
  resource), a local HTTP server, and a LiteLLM proxy plugin.
- Test suite over the parsing, model, cache, analysis, and auth logic, with CI on
  Linux running format, analyze, and tests for both Dart packages and the router.

## Next

- **Surface routed-request metrics in the widget.** The LiteLLM plugin already
  logs per-request usage; show those counts next to subscription headroom so
  routing outcomes sit beside the budget that drove them.
- **Streamable HTTP transport for MCP**, in addition to stdio.
- **Routing-aware alerts.** When a provider goes low, name where to route next
  (ties the notification to the suggest engine), with tiered 70%/90% thresholds
  and an urgency rank so the most urgent risk surfaces first.
- **Actionable warnings with a one-line remedy** ("route to X", "switch to Ollama
  for this task", "downgrade Opus to Sonnet").

## Ideas from the field (competitive scan)

From a read of similar tools (ccusage, CodexBar, ClaudeBar, TokenTracker,
codeburn, tokscale, Claude-Code-Usage-Monitor, and others). quotabot's
differentiators to keep leaning on: a cross-platform desktop widget (most rivals
are macOS menu-bar only), reading real rate-limit windows (vs token or dollar
accounting), routing as a primitive (suggest/MCP/LiteLLM), local-runtime
monitoring, and value analytics.

High value, on-brand:

- Hour x day-of-week headroom heatmap ("best time to run"). quotabot already
  computes both profiles; no rival shows both dimensions at once.
- More quota-window providers in the same lane: Z.ai (GLM), Kimi, Amp, OpenCode.
  (Skip pay-as-you-go API vendors - that is cost, not a rolling-window quota.)
- Versioned machine-readable schema on all outputs (e.g. `quotabot.v1`) so agents
  can consume routing data stably.
- Merged "most-constrained provider" compact mode for the collapsed widget.

GitHub Copilot is intentionally not supported: for individuals it is a monthly
premium-request allowance with pay-as-you-go overage rather than a rolling-window
quota, the usage is server-side only, and the token lives in the OS keyring
rather than a file. Revisit only if GitHub exposes a local premium-request read.

Medium value:

- GitHub-style year contribution calendar and a 30-day stacked-by-provider chart.
- Plan-tier modeling (Pro/Max 5x/20x) so headroom and runway map to the real
  allowance; surface projected overage.
- Provider status/incident polling ("is the provider even up right now").
- Streaks and summary stats (longest/current streak, best day, daily average).
- Reusable passive-reader adapter taxonomy (JSONL-transcript, SQLite-session,
  OTel-file) to expand provider coverage cheaply.
- Optional cost dimension from local session logs, kept distinct from headroom.

Deliberately skipped: token/dollar cost ledgers as the primary view, git-commit
productivity correlation, global leaderboards / cloud sync (local-first), browser
cookie + keychain decryption (platform-specific, privacy-sensitive), and CLI-PTY
scraping of `/usage` (brittle; prefer the OAuth/file sources quotabot uses).

## Later

- Richer MCP and HTTP transports and client examples.
- Further notification and trend-view polish.
- macOS and Linux packaging polish (Windows release is verified; macOS/Linux have
  notes, a `.desktop` file, and code paths ready for target builds).
