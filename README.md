# quotabot

[![CI](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml/badge.svg)](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

See how much quota you have left across your agentic AI coding subscriptions, in
one place, and let your tools route work to whichever one still has budget.

quotabot does two things:

1. **Shows your remaining quota** for the rolling-window subscriptions you pay
   for: Claude (Pro/Max), Codex (OpenAI), Antigravity / Gemini (Google), and
   Grok (xAI). It also surfaces what your **local LLM runtimes** (Ollama, LM
   Studio, Lemonade) have loaded, so a free local model is always in view.
2. **Recommends where to send the next request.** `quotabot suggest` (and the
   same logic over MCP) ranks your subscriptions by remaining headroom and falls
   back to a local model when they are low, so AI tools and agents can route
   across your accounts instead of stalling on a spent cap.

It reads the usage your tools already track locally, so most providers need no
setup (Claude and Codex just work; a one-time login covers Antigravity and Grok).

Highlights:

- **Cross-platform.** One codebase on Windows, macOS, and Linux.
- **Easy and good-looking.** A small frameless widget that follows the system
  light/dark theme, pins always-on-top or to the taskbar, and collapses to a tiny
  status strip.
- **Useful analytics, no surveillance.** Insight into your own usage patterns
  (distribution, reliability, trend, best time to run). Only quota metadata is
  ever read, never prompts, code, or other content.
- **Zero usage tokens.** Every read is local metadata, never a model call.
- **Local-first.** Nothing leaves your machine; there is no account or cloud.

## What it shows

Each provider is a card with one bar per rolling window (for example a 5 hour and
a weekly window): green when healthy, amber as it tightens, red when spent, with a
reset countdown. A longer window overrides a shorter one, so a spent weekly cap
collapses the card to a single "weekly spent - resets in 2d" line rather than
showing a green 5 hour bar you cannot use. Local runtimes have no quota, so their
card reports installed and loaded models instead, and acts as a routing fallback.

Full walkthrough of the widget, analytics, and CLI: [docs/USAGE.md](docs/USAGE.md).

## Provider status

| Provider     | Source                                                   | Live usage      |
|--------------|----------------------------------------------------------|-----------------|
| Claude       | OAuth usage endpoint, token reused from Claude Code       | Yes             |
| Codex        | `rate_limits` event in the newest session rollout        | Yes             |
| Antigravity  | Google Cloud Code API (Gemini), token reused and refreshed | Yes, signed-in account |
| Grok         | gRPC-web billing endpoint, token reused from the CLI     | Yes, when fresh |
| Cursor       | Local credits/state; passive detect for free/Pro          | opportunistic   |
| Windsurf     | Local `cachedPlanInfo` (daily/weekly Cascade quota)       | opportunistic   |
| Kiro         | Local credits/state (CLI+IDE); passive detect             | opportunistic   |
| Ollama / LM Studio / Lemonade | Local server; installed and loaded models | when running |

Claude and Codex are always live with no setup. Antigravity and Grok are live for
the account their app is signed into; quotabot refreshes that token on its own.
Google's consumer Gemini CLI has been superseded by Antigravity, so Google
coverage runs through the Antigravity adapter. Any OpenAI-compatible local server
(Lemonade, Jan, llama.cpp, GPT4All, and similar) is detected the same way.

For exactly where each number comes from, see
[docs/DATA_SOURCES.md](docs/DATA_SOURCES.md); for each provider's own usage
command, [docs/PROVIDER_CLIS.md](docs/PROVIDER_CLIS.md).

## Install

**macOS / Linux**
```bash
curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh | bash
```

**Windows (PowerShell)**
```powershell
irm https://raw.githubusercontent.com/blisspixel/quotabot/main/install.ps1 | iex
```

Restart your terminal, then run `quotabot doctor`. Claude and Codex should read
live immediately. Full getting-started guide, including which providers need a
one-time login: [docs/SETUP.md](docs/SETUP.md). To run from source instead, see
[docs/BUILDING.md](docs/BUILDING.md).

## Keeping Antigravity and Grok live

Antigravity and Grok are live for the account their app is signed into, and
quotabot refreshes that token on its own. To pin a specific account, or if an app
is signed out, connect quotabot's own login once (no Google Cloud setup needed):

```bash
quotabot login grok          # device-code flow
quotabot login antigravity   # opens a browser; sign in with the account you want
quotabot doctor              # confirm it reads live
```

quotabot stores its own refresh token under your per-user config directory
(owner-only on POSIX), independent of the app's credentials. Details in
[docs/SETUP.md](docs/SETUP.md#4-keep-grok-and-antigravity-live-optional).

## Routing for tools and agents

```bash
quotabot suggest          # recommended provider + ranked alternatives
quotabot suggest --json   # the same decision for scripts and agents
```

The same recommendation is available over MCP (`suggest_provider`) and a loopback
HTTP server. For how an agent should call quotabot and route, see
[AGENTS.md](AGENTS.md). For a turnkey fleet setup, see the LiteLLM proxy plugin in
[integrations/litellm/](integrations/litellm/), which routes each request to a
deployment with budget and fails soft when quotabot is unavailable.

## Project layout

```
quotabot/
  app/           Flutter desktop application (Windows, macOS, Linux)
  collector/     Dart package: adapters, normalized model, auth, CLI, MCP server
  integrations/  LiteLLM proxy plugin for quota-aware request routing
  docs/          Setup, usage, building, architecture, and data-source notes
  tools/         Packaging, icon, and developer helper scripts
```

The app and the collector are both Dart; the app imports the collector directly.
For design and internals see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Disclaimer and terms of service

quotabot is an independent, unofficial tool. It is **not affiliated with,
endorsed by, or sponsored by** OpenAI, Anthropic, xAI, Google, Amazon, Cursor,
Codeium/Windsurf, or any other provider. All product names, logos, and trademarks
are the property of their respective owners and are used here only to identify the
service whose quota is being displayed.

quotabot reads usage and quota metadata from the local state and credential files
each provider's own CLI or app has already stored on your machine. It makes no
model/inference calls. Even so:

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
