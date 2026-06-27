# Roadmap

What is planned next and what is deliberately out of scope. For the record of
what has already shipped, see [CHANGELOG.md](CHANGELOG.md).

## Invariants

Non-negotiables. Every change is held to these; a feature that breaks one is the
wrong feature.

- **Local-first.** Nothing leaves the machine. No account, no cloud, no
  telemetry.
- **Free to check, minimal by exception.** Reading quota and recommending a route
  cost zero usage tokens (metadata only). Any feature that would spend tokens
  (for example a tiny capability probe to validate a local model) must be
  opt-in, as small as possible, and clearly disclosed, never silent or on by
  default.
- **Never reads user content.** quotabot reads quota and usage figures and, when
  it must talk to a model at all, only ever sends its own synthetic probe, never
  your prompts, code, or other content.
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

## From the user panel

Themes from four user archetypes (power user, casual, optimizer, broke indie),
ordered by how many of them asked for it.

Make `suggest` the centerpiece (everyone but the casual user):

- **Blunt one-line verdict** with the reset baked in: "Use local (Ollama llama3);
  Pro resets in 38m, ~6 requests left."
- **Capability-aware routing.** Respect task needs, not just raw headroom:
  `suggest --min-context`, `--require-tools`, `--budget`, `--exclude`. Cheapest
  -with-room is wrong when the task needs 200k context.
- **Aggressive local-first mode** for tight budgets: prefer local, escalate to
  paid only when the task needs it or a window is about to reset.
- **Concurrency leases** so parallel agents do not dogpile the same pick:
  `quotabot reserve <provider> --ttl 5m` / `release`, atomic and local.
- **Provenance on every payload:** `as_of`, `source` (measured vs estimated), and
  a confidence/staleness signal, so a stale route is not trusted blindly.

Serve the casual user by hiding depth (they ignore analytics/CLI/MCP entirely):

- Default to the compact status strip, not the full grid.
- Plain-language low warning ("about 1 hour of usage left") over a bare percent.
- Put Analytics/CLI/MCP behind an "Advanced" affordance.

Dollarize value for the optimizer:

- **Use-it-or-lose-it alert:** fire when projected waste at reset crosses a
  threshold, with a one-click "what can I run now" number.
- **Downgrade/upgrade ROI:** rolling 90d p90 vs each tier's cap, with $/mo saved
  and breach probability ("under Tier 2's ceiling 11 of 13 weeks").
- **Reset-anchored scheduling:** `suggest --after-reset` prints the next refresh
  timestamp per provider so batch work queues the moment a window flips.

Make local models first-class for the broke indie:

- Show real readiness: loaded-in-VRAM vs cold, est. tokens/sec, and "fits your
  GPU?", so "free" does not secretly mean two-minute waits.
- Per-model capability tags (coding, long-context) so a hard refactor is not
  routed to a 7B that flubs it and forces a paid retry.

## Platform maturity (external review)

From an architecture review. Kept the right-sized items, deferred the premature
platform work, and noted what does not fit the Dart/Flutter reality.

Worth doing, in order:

1. **Adapter interface + fixtures.** A small `Adapter` abstraction (collect,
   parseFixture, healthCheck, metadata) with a required test fixture per adapter,
   plus a compile-time registry, so adding Z.ai/Kimi/Amp is a short, well-trodden
   path instead of copy-paste. A "add a provider in 10 minutes" checklist in
   CONTRIBUTING.
2. **`suggest` as the default brain, not a CLI afterthought:** capability flags
   (`--min-context`, `--require-tools`, `--budget`), an explainable reason
   ("picked Grok: 91% free, resets soonest"), and a concurrency lease
   (`reserve`/`release`, file-lock or SQLite-atomic) so parallel agents do not
   dogpile the same pick.
3. **Local runtimes as first-class:** VRAM/readiness awareness ("can I run 70B Q4
   right now?", loaded vs cold, tokens/sec), the strongest differentiator since no
   rival does it.
4. **Tray-first desktop UX:** tray icon, configurable global hotkey, native toasts
   with "Route now / Switch to Ollama" actions; the current frameless widget
   becomes the expanded view. This is the casual user's "make it disappear".
5. **Simulation mode:** `--mock-provider claude --state exhausted` for tests,
   demos, and screenshots (extends the existing demo mode).

Deferred until after a public launch with real users: publishing the collector to
pub.dev, a mdBook docs site, winget/MSIX/Homebrew/flatpak packaging, sigstore /
reproducible builds, a Prometheus endpoint, and a token-store audit log. (See
also "Not doing", below.)

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

Medium value:

- GitHub-style year contribution calendar and a 30-day stacked-by-provider chart.
- Plan-tier modeling (Pro/Max 5x/20x) so headroom and runway map to the real
  allowance; surface projected overage.
- Provider status/incident polling ("is the provider even up right now").
- Streaks and summary stats (longest/current streak, best day, daily average).
- Reusable passive-reader adapter taxonomy (JSONL-transcript, SQLite-session,
  OTel-file) to expand provider coverage cheaply.
- Optional cost dimension from local session logs, kept distinct from headroom.

## Later

Worth doing eventually, not now:

- Richer MCP and HTTP transports and client examples.
- Further notification and trend-view polish.
- macOS and Linux packaging polish (Windows release is verified; macOS/Linux have
  notes, a `.desktop` file, and code paths ready for target builds).
- Platform-maturity items deferred until after a public launch (pub.dev publish,
  mdBook site, OS package managers, signing, metrics endpoint, audit log).

## Not doing (and why)

Deliberately out of scope. Listed so the boundary is explicit.

- **A Rust core or a Tauri rewrite.** Discards a working cross-platform Flutter
  app to chase packaging debt that is real but overstated.
- **Runtime plugin discovery from pub.dev.** Not feasible in an AOT-compiled
  Flutter app; a compile-time adapter registry is the workable form.
- **GitHub Copilot.** For individuals it is a monthly premium-request allowance
  with pay-as-you-go overage, not a rolling-window quota; usage is server-side
  only and the token lives in the OS keyring, not a file. Revisit only if GitHub
  exposes a local premium-request read.
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
