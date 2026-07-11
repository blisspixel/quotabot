# quotabot

[![CI](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml/badge.svg)](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**htop for your agentic-AI quota plans.**

See how much quota you have left across your agentic AI coding subscriptions, in
one place, and route the next request to whichever one has budget, so you can
reduce quota-related stalls and avoid leaving included quota unused.

> Early and under active development (0.x). The core works and is in daily use;
> expect changes on the road to 1.0. See [ROADMAP.md](ROADMAP.md).

quotabot does two things:

1. **Shows your remaining quota** for the rolling-window subscriptions you pay
   for: Claude (Pro/Max), Codex (OpenAI), Antigravity / Gemini (Google), and
   Grok (xAI). It also surfaces what supported **local LLM runtimes** (Ollama,
   LM Studio, Lemonade) have loaded while their daemon is reachable.
2. **Recommends where to send the next request.** `quotabot suggest` (and the
   same logic over MCP) ranks your subscriptions by confidence-weighted runway
   with a small use-it-or-lose-it boost for measured quota that would otherwise
   expire unused, and can fall back to a reachable local model when subscriptions
   are low, so AI tools and agents can route across accounts instead of guessing
   from a spent short-window bar.

It reuses the tokens your tools already store, so most providers need no setup:
Claude and Codex read live when their apps are signed in, Antigravity reads from
a signed-in IDE or a one-time quotabot login, and Grok can stay live with a
one-time quotabot login.

<p align="center">
  <img src="docs/quotabot-demo.gif" alt="quotabot demo showing the widget, compact strip, 90-day analytics, and top dashboard" width="620">
</p>

<p align="center"><sub>Demo mode: the desktop widget, compact strip, 90-day analytics view, and <code>quotabot top</code>.</sub></p>

Highlights:

- **Cross-platform.** One codebase on Windows, macOS, and Linux.
- **Easy and good-looking.** A small frameless widget that follows the system
  light/dark theme, supports per-profile themes including a high-contrast Hacker
  mode, pins always-on-top or to the taskbar, and collapses to a tiny status
  strip.
- **Useful analytics, no surveillance.** Insight into your own usage patterns
  (distribution, reliability, trend, smoothed and reset-aware best times to
  run). Outputs contain quota and routing metadata, never prompts, code, model
  output, or other user content.
- **Zero usage tokens.** quotabot makes no model or inference call, so its quota
  and routing operations never spend a usage token.
- **Advisor, not a proxy.** quotabot suggests where to send the next request;
  your own tools and agents make the call. It stays out of your request path, so
  there is nothing new to route through and nothing new to trust with your
  traffic - just a content-blind metadata signal that helps you use the
  subscriptions you already pay for.
- **Local-first, your data is yours.** No quotabot account, hosted service, or
  telemetry. Tokens, history, cache, preferences, profiles, and leases stay on
  your machine. Some live adapters send credentials and quota metadata to that
  provider's own metadata endpoint; Antigravity can also perform its provider-
  required account onboarding step before reading quota. External alert webhooks remain
  loopback-only unless you explicitly allow an external host. No path sends
  prompts, code, model output, or other user content.

## What it shows

Each provider is a card with one bar per rolling window (for example a 5 hour and
a weekly window): green when healthy, amber as it tightens, red when spent, with a
reset countdown. A longer window overrides a shorter one, so a spent weekly cap
collapses the card to a single "weekly spent - resets in 2d" line rather than
showing a green 5 hour bar you cannot use. Local runtimes have no quota, so their
card reports installed and loaded models instead, and acts as a routing fallback.

If a fresh provider read moves in a way that contradicts the last trusted read,
quotabot does not replace that trusted cache with the rejected values. The
desktop and `doctor` show **provider drift** with last-trusted quota marked stale
when it exists. Routing excludes that provider from selection, and measured
analytics records no new sample until a clean read establishes recovery.
`quotabot verify` names the failed drift check so the number can be compared with
the provider's own usage view. When an upgrade finds only an older `suspect`
cache record, quotabot cannot prove those windows were ever trusted. It
quarantines them without headroom instead of laundering them through the next
identical read. A later read establishes a new baseline only after every retained
quota reset has
advanced, or after an evidence-class transition.

Every observation also carries a normalized provenance class. Machine output
uses `source_class` with one of six values: `authoritative_live`,
`this_machine_fallback`, `passive_local_evidence`, `local_runtime`,
`status_only`, or `manual`. Human views use the shorter labels
`authoritative`, `this-machine fallback`, `passive local`, `local runtime`,
`status only`, and `manual`. This class is separate from freshness: a live
machine-scoped read can still omit activity from another device, while an
authoritative account read can become cached. Routing discounts measured
machine-scoped evidence by a `0.7` confidence factor without changing the raw
quota number. `quotabot verify` rejects a class that conflicts with its provider
or data shape. The exact assignments and verification methods are documented in
[docs/DATA_SOURCES.md](docs/DATA_SOURCES.md#source-classes).

The same view is available live in the terminal with `quotabot top`, a small
dashboard that redraws in place and, when it has enough history, notes which
window is likely to run out first. Full walkthrough of the widget, analytics, and
CLI: [docs/USAGE.md](docs/USAGE.md).

## Provider status

| Provider     | Source                                                   | Live usage      |
|--------------|----------------------------------------------------------|-----------------|
| Claude       | OAuth usage endpoint, token reused from Claude Code       | Yes             |
| Codex        | ChatGPT usage endpoint; local session fallback           | Yes; local fallback marked this machine |
| Antigravity  | Google Cloud Code API (Gemini), token reused and refreshed | Yes, signed-in account; local fallback marked this machine |
| Grok         | gRPC-web billing endpoint, token reused from the CLI     | Yes, when fresh |
| Cursor       | Local credits/state; passive detect for free/Pro          | opportunistic   |
| Windsurf     | Local `cachedPlanInfo` (daily/weekly Cascade quota)       | opportunistic   |
| Kiro         | Local credits/state (CLI+IDE); passive detect             | opportunistic   |
| Ollama / LM Studio / Lemonade | Local server; installed and loaded models | when running |
| NVIDIA NIM | `NVIDIA_API_KEY` or `nvapi` + safe `/v1/models` discovery | free trial available; numeric quota unknown |
| Manual entries | User-entered limit, used count, and reset for any tool  | self-reported   |

Claude and Codex are live with no quotabot login when their host apps have valid
signed-in credentials. Codex reads the ChatGPT usage endpoint using the token
Codex stores locally and falls back to this-machine session snapshots when the
live read is unavailable. Antigravity and Grok are live for the account their app
is signed into; quotabot refreshes that token on its own.
Google's consumer Gemini CLI has been superseded by Antigravity, so Google
coverage runs through the Antigravity adapter. Its live Cloud Code quota read is
preferred; local Antigravity settings are only used for account discovery and
offline last-known fallback, where the result is marked "(this machine)". Any
supported OpenAI-compatible local server uses the same normalized local-runtime
shape. NVIDIA NIM is an optional free trial signal when
`NVIDIA_API_KEY` or `nvapi` is present: quotabot confirms the key with a
model-list metadata read, but does not invent a numeric balance because NVIDIA
does not expose one without using the service. Because no quota windows are
known, NIM availability is not used as a routable model-budget candidate.

For exactly where each number comes from, see
[docs/DATA_SOURCES.md](docs/DATA_SOURCES.md); for each provider's own usage
command, [docs/PROVIDER_CLIS.md](docs/PROVIDER_CLIS.md).

For a tool quotabot does not read yet, `quotabot manual set` adds a local
self-reported quota window. Manual entries appear in the same views and JSON
snapshots with `source_class: "manual"` and the legacy `source: "manual"` hint,
but they are not treated as measured provider telemetry.

## Install

**macOS / Linux**
```bash
curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh | bash
```

**Windows (PowerShell)**
```powershell
irm https://raw.githubusercontent.com/blisspixel/quotabot/main/install.ps1 | iex
```

These convenience commands trust the bootstrap script delivered by GitHub over
TLS; the downloaded release archive is then checksum-verified. For an
inspect-before-run path and provenance verification, see
[docs/SETUP.md](docs/SETUP.md#inspect-before-running-the-installer).

Restart your terminal, then run `quotabot doctor`. Claude and Codex should read
live immediately when their host apps are signed in. Full getting-started guide,
including which providers need a one-time login: [docs/SETUP.md](docs/SETUP.md).

To build everything from source in one command (CLI, desktop app, and a
Desktop shortcut), run `pwsh tools/setup.ps1` on Windows or
`bash tools/setup.sh` on macOS/Linux (add `-CliOnly` / `--cli-only` for just the
CLI). Details in [docs/BUILDING.md](docs/BUILDING.md).

## Keeping Antigravity and Grok live

Antigravity and Grok can use the account their app has made discoverable. A
quotabot login creates a separate refreshable grant for that discovered account,
which is useful for account pinning or when the host credential is short-lived.
Run the provider app on this machine first; the grant does not replace local
account discovery. No Google Cloud setup is needed:

```bash
quotabot login grok          # device-code flow
quotabot login antigravity   # opens a browser; sign in with the account you want
quotabot doctor              # confirm it reads live
```

quotabot stores its own refresh token under your per-user config directory,
independent of the app's credentials. A new or rotated grant is not written
unless owner-only permission hardening succeeds. Details in
[docs/SETUP.md](docs/SETUP.md#4-keep-grok-and-antigravity-live-or-pin-an-account-optional).

## Routing for tools and agents

```bash
quotabot suggest              # balanced provider recommendation
quotabot suggest --local-first  # prefer a reachable local runtime
quotabot suggest --task=hard  # one concrete model for supplied requirements
quotabot models               # current registry entries, availability, budget, capabilities
quotabot watch                # alert on a low binding window and name the next route
quotabot verify               # test one live read for truthful behavior
```

The defaults are deliberate:

| Intent | Command | Default ordering and budget |
|---|---|---|
| Pick a provider | `quotabot suggest` | measured subscriptions first, reachable local fallback |
| Prefer local execution | `quotabot suggest --local-first` | reachable local runtime before subscriptions |
| Pick a model | `quotabot suggest --task=hard` | available first; local-runtime, loaded, lighter provider tier, then headroom |
| Filter to local-runtime classification | `quotabot suggest --task=hard --budget=local` | entries reported by supported local-runtime adapters; not proof of execution location or cost |
| Restrict to quota-plan and runtime classes | `quotabot suggest --task=hard --budget=quota` | measured included quota plus local-runtime entries; excludes catalogued manual and paid API classes |
| Inspect candidates | `quotabot models` | entries for providers represented in the current registry, ordered by routability with availability explicit |

Known 0.5.14 limit: Ollama can offload cloud models through its local daemon,
and quotabot does not yet have authoritative execution-location evidence for
those entries. Do not use an installed Ollama cloud model to satisfy a strict
local-only policy; conservative classification is a 1.0 release gate.

`--use-expiring-quota` applies only to a model suggestion and lets measured
included quota beat local when local history projects meaningful quota would
expire unused soon. `--exclude=A,B` avoids providers for one read. Advanced
capability, profile, account, alert, cost-policy, report, calibration, and
provenance commands are documented in [docs/USAGE.md](docs/USAGE.md).

For agent integration, use the MCP server described in [AGENTS.md](AGENTS.md).
It exposes live and cache-only decisions, model filters, resources, and expiring
local reservations over stdio or opt-in loopback HTTP with bearer auth available.
A smaller
plain loopback JSON endpoint is available for clients that do not speak MCP.
For an execution handoff, the [LiteLLM example](integrations/litellm/) consumes
quotabot's advice with explicit loopback authentication and no-surprise spend
classes. Python and TypeScript MCP examples live in
[integrations/mcp_clients/](integrations/mcp_clients/).

## Project layout

```
quotabot/
  app/           Flutter desktop application (Windows, macOS, Linux)
  collector/     Dart package: adapters, normalized model, auth, CLI, MCP server
  integrations/  LiteLLM proxy plugin and MCP client snippets
  docs/          Setup, usage, trust, architecture, strategy, and reference
  tools/         Packaging, icon, and developer helper scripts
```

The app and the collector are both Dart; the app imports the collector directly.
Use the [documentation index](docs/README.md) to find setup, usage, trust, and
integration guides. For product direction see
[docs/PRODUCT-STRATEGY.md](docs/PRODUCT-STRATEGY.md); for design and internals see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Security issues should be reported privately through [SECURITY.md](SECURITY.md).
Development and validation guidance is in [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer and terms of service

quotabot is an independent, unofficial tool. It is **not affiliated with,
endorsed by, or sponsored by** OpenAI, Anthropic, xAI, Google, Amazon, Cursor,
Codeium/Windsurf, or any other provider. All product names, logos, and trademarks
are the property of their respective owners and are used here only to identify the
service whose quota is being displayed.

quotabot produces quota and routing metadata only. It prefers local state and,
for some providers, makes a bounded authenticated call to that provider's own
quota or model-list endpoint. Antigravity collection can also perform the
provider-required account onboarding request that makes its quota endpoint
available. Normal operation can read credential material and
write local cache, history, preferences, grants, manual entries, and leases; the
credential values are never included in outputs. It makes no model or inference
calls and sends no prompts, code, model output, or other user content. Data stays
local except for provider metadata requests and alert metadata sent to an
external webhook only when the user explicitly enables that host. Even so:

- **You are solely responsible for ensuring your use complies with the Terms of
  Service and acceptable-use policies of every provider you connect to it.**
  Reading local state, reusing stored tokens, or automating routing may be
  restricted by a given provider's terms; review them and stop using quotabot
  with any provider whose terms it would violate for your account.
- Quota numbers are best-effort and may be incomplete, delayed, or wrong. Do not
  rely on them for billing or compliance; verify against the official dashboard.
- quotabot stores any login tokens you create under your user config directory.
  Protect that directory as you would any other credential store.

Provided "AS IS", without warranty, under the [Apache License 2.0](LICENSE). By
using quotabot you accept these terms; if you do not agree, do not use it.
