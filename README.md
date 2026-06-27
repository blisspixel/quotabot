# quotabot

[![CI](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml/badge.svg)](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

See how much quota you have left across your agentic AI coding subscriptions, in
one place, and let your tools route work to whichever one still has budget.

quotabot does two things:

1. **Shows your remaining quota** for the rolling-window subscriptions you pay
   for: Claude (Pro/Max), Codex (OpenAI), Antigravity / Gemini (Google), and
   Grok (xAI). It also surfaces what your **local LLM runtimes** (Ollama, LM
   Studio) have loaded, so a free local model is always in view as a fallback.
2. **Recommends where to send the next request.** `quotabot suggest` (and the
   same logic over MCP) ranks your subscriptions by remaining headroom and falls
   back to a local model when they are low, so AI tools and agents can route
   across your accounts and spend the budget you are paying for instead of
   stalling on a spent cap.

It reads the usage your tools already track locally, so most providers need no
setup (Claude and Codex just work; a one-time login covers Antigravity and Grok).

Highlights:

- **Cross-platform.** One codebase on Windows, macOS, and Linux.
- **Easy and good-looking.** A small frameless widget that follows the system
  light/dark theme automatically, pins always-on-top or to the taskbar, and
  collapses to a tiny status strip.
- **Useful analytics, no surveillance.** Statistical insight into your own usage
  patterns (distribution, reliability, trend, best time to run) to get more value
  from what you pay for. Only quota/usage metadata is ever read, never prompts,
  code, or other sensitive content.
- **Zero usage tokens.** Every read is local metadata, never a model call, so
  checking quota never costs you anything.
- **Local-first.** Nothing leaves your machine; there is no account or cloud.

New to quotabot? Start with [docs/SETUP.md](docs/SETUP.md), a step-by-step guide
covering which providers work automatically and which take a one-time login.

## Contents

- [What it shows](#what-it-shows)
- [Provider status](#provider-status)
- [Install](#install)
- [Keeping Antigravity and Grok live](#keeping-antigravity-and-grok-live)
- [Using the widget](#using-the-widget)
- [History and analytics](#history-and-analytics)
- [Routing work to the freest provider](#routing-work-to-the-freest-provider)
- [MCP server](#mcp-server)
- [Local HTTP endpoint](#local-http-endpoint)
- [Building from source](#building-from-source)
- [Project layout](#project-layout)
- [Disclaimer and terms of service](#disclaimer-and-terms-of-service)

## What it shows

Each provider is a card with one bar per rolling window (for example a 5 hour
window and a weekly window). The bar shows remaining headroom: green when
healthy, amber as it tightens, red when spent. A reset countdown tells you when
each window frees up again. Recent snapshots are logged and a simple "usually
~X% free (last N)" history line appears under the bars when history exists.

The header shows a small dynamic radial "pool gauge" next to the "Quota"
wordmark. The gauge fills clockwise in proportion to the average remaining
headroom across the visible providers (the pool), colored on the same scale as
the cards: green at >=50% free, amber at >=25%, orange above 0, red when spent,
and neutral grey when no data.

The display understands that a longer window overrides a shorter one. If your
weekly cap is spent, the card collapses to a single "weekly spent - resets in
2d" line instead of misleading you with a green 5 hour bar you cannot use.

## Provider status

| Provider     | Source                                                   | Live usage      |
|--------------|----------------------------------------------------------|-----------------|
| Claude       | OAuth usage endpoint, token reused from Claude Code       | Yes             |
| Codex        | `rate_limits` event in the newest session rollout        | Yes             |
| Antigravity  | Google Cloud Code API (Gemini), token reused and refreshed | Yes, signed-in account |
| Grok         | gRPC-web billing endpoint, token reused from the CLI     | Yes, when fresh |
| Cursor       | Local credits/state (IDE); passive detect for free/Pro    | opportunistic   |
| Windsurf     | Local `cachedPlanInfo` in state.vscdb (daily/weekly/Cascade quota); passive detect | opportunistic   |
| Kiro         | Local credits/state (CLI+IDE VSCode fork); passive detect | opportunistic   |
| Ollama       | Local daemon (`/api/tags` + `/api/ps`); installed and loaded models, in-use status | when running |
| LM Studio    | Local server (`/api/v0/models`, OpenAI `/v1/models` fallback); installed and loaded models | when running |

Claude and Codex are always live with no setup. Antigravity and Grok are live for
the account their app is signed into; quotabot refreshes that token on its own, so
a card only falls back to its last cached value (shown with its age) if the app is
signed out (see [Keeping Antigravity and Grok live](#keeping-antigravity-and-grok-live)).

Cursor (free/Pro), Windsurf (free tier), and Kiro (even post-cancel) are detected
passively for robustness. Google's consumer Gemini CLI has been superseded by
Antigravity (the Gemini-powered IDE and CLI), so Google coverage runs through the
Antigravity adapter. Aider/Cline and similar are model-agnostic and use the
underlying provider quotas (already tracked).

Local runtimes (Ollama, LM Studio) have no quota to spend, so they are not shown
as a usage bar. Instead their card reports what is installed, which model is
loaded, and whether one is in use, and it sorts below the cloud services. Any
other OpenAI-compatible local server (Jan, llama.cpp, GPT4All, and similar) can
be added the same way, since detection is just a local `/v1/models` style read.

See [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md) for exactly where each number
comes from, and [docs/PROVIDER_CLIS.md](docs/PROVIDER_CLIS.md) for each
provider's own usage command and official docs.

## Install

One command install (recommended):

**macOS / Linux**
```bash
curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh | bash
```

**Windows (PowerShell)**
```powershell
irm https://raw.githubusercontent.com/blisspixel/quotabot/main/install.ps1 | iex
```

After install, restart your terminal and check what was detected:
```bash
quotabot doctor
```

Claude and Codex should already read live (they need no setup). To install from a
fork, set `QUOTABOT_REPO=owner/quotabot` before running the installer. Prefer to
run from source instead? See [Building from source](#building-from-source).

## Keeping Antigravity and Grok live

Claude and Codex are always live with no setup. Antigravity and Grok are live for
the account their app is signed into, and quotabot refreshes that token on its
own. If an app is signed out, connect quotabot's own login once so the card stays
live regardless:

```bash
quotabot login grok      # prints a URL and a device code to confirm
quotabot doctor          # confirm it now shows live, not cached
quotabot logout grok     # disconnect any time
```

quotabot stores its own refresh token under your per-user config directory
(owner-only on POSIX) and refreshes silently from then on. This grant is
independent of the app's own credentials, so it never disturbs them.

For Antigravity, quotabot reads and refreshes the token of the account you are
signed into in the Antigravity IDE or the Gemini CLI. If that is not the account
you want shown (for example you use several Google accounts), pin a specific one:

```bash
quotabot login antigravity   # opens a browser; sign in with the account you want
```

This needs no Google Cloud setup. quotabot then holds its own refreshing grant
for that account, independent of the IDE. Advanced users can override the OAuth
client with `QUOTABOT_GOOGLE_CLIENT_ID` and `QUOTABOT_GOOGLE_CLIENT_SECRET`.

## Using the widget

- Drag the header bar (full width) or the main content/cards area to move the
  window (only the control buttons on the right are excluded). The body is
  scrollable and the window height is derived from a deterministic content
  estimate capped at the screen height, so every visible provider shows without
  an overflow banner.
- The collapse button shrinks it to a compact strip of provider logos with a
  single status dot each; the expand button restores the full view.
- The menu button hides or shows individual providers, sets the refresh cadence
  (smart, every 15 minutes, or every hour), chooses display sort for icons
  (default, alphabetical, most available, or most used), and toggles always on
  top, taskbar visibility, notifications, and "Show account names". Account names
  auto-hide for single-account providers and appear only when a provider has more
  than one account on screen (e.g. multiple Antigravity logins); the "Show
  account names" toggle still applies on top, so turning it off hides all of them.
- The smart schedule refreshes more often as a reset approaches or a cap fills,
  and relaxes to as little as twice a day when everything is healthy and resets
  are far off. The last update time shows without seconds (as of 10:25 AM style).
- Your hidden providers, compact or expanded state, chosen cadence, always on top
  setting, taskbar visibility, notifications setting, show account names, and
  window position are remembered across restarts.
- Claude (and other windows with resetsAt) shows reset countdowns next to usage
  (e.g. "80%  3d12h"). Antigravity shows "free tier" explicitly when detected.
- Tap a provider card to expand its insights panel: a headroom sparkline plus the
  p10/p50/p90 distribution, how often it is usable, any tightening or easing
  trend, and the hour of day it is typically tightest. Tap again to collapse.

## History and analytics

quotabot keeps two tiers of local history, both zero-token. A short raw buffer of
recent checks drives the "usually ~X% free (last N)" line and the sparkline.
Alongside it, headroom is folded into compact hourly aggregate buckets retained
for 90 days; these power the analytics with no raw points kept long term.

From those buckets it derives the mean and spread of free headroom, the
p10/p50/p90 distribution (from a histogram), how reliably a provider has had
budget, a least-squares trend (percent per day with an R-squared confidence), and
a by-hour profile that surfaces when a provider is typically tightest. See them
per provider in the widget's insights panel or on the command line:

```bash
quotabot stats          # human readable analytics per provider
quotabot stats --json   # the same numbers for scripts
```

Each successful read is also cached locally (per-account for Antigravity). If a
later read fails, the last known values are shown with a small clock icon and
their age, so a transient rate limit or an expired token never blanks a provider.

## Routing work to the freest provider

quotabot can recommend where to send the next request. The decision prefers the
metered subscription with the most remaining headroom (above a comfort threshold)
and falls back to a local runtime (Ollama, LM Studio) when every subscription is
low, so a local model is a free safety net rather than always winning on its
unlimited headroom.

```bash
quotabot suggest          # human readable: recommended provider + ranked list
quotabot suggest --json   # same decision as JSON for scripts and agents
```

The same recommendation is available over MCP (`suggest_provider`) and HTTP
(`GET /suggest`). For how an agent or tool should call quotabot and route, see
[AGENTS.md](AGENTS.md). For a turnkey setup that routes a whole fleet of agents across
your subscriptions and local models, see the LiteLLM proxy plugin in
[integrations/litellm/](integrations/litellm/): it reads this recommendation in a
pre-call hook and rewrites each request to whichever deployment has budget,
failing soft to the requested model if quotabot is unavailable. It runs the same
on Windows, macOS, and Linux.

## MCP server

The collector also runs as an MCP server, so other agents can query quota as a
primitive and route work to whichever subscription has budget. It speaks MCP over
stdio and exposes four tools plus a resource:

- `list_quotas` - the full normalized snapshot for every provider.
- `provider_with_most_headroom` - the account with the most remaining budget
  (binding window governs; includes resets_at).
- `suggest_provider` - the recommended provider to route the next request to,
  with ranked alternatives and a local fallback when subscriptions are low.
- `check_provider_availability` - whether a named provider is usable now and when
  it resets.
- Resource `quotas://current` - same snapshot for resource-oriented clients.

Run it directly with `dart run bin/mcp_server.dart`, or build a native binary:

```bash
cd collector
dart compile exe bin/mcp_server.dart -o build/quotabot-mcp.exe
```

Then point an MCP client at that command. Like the rest of quotabot, every tool
and resource is a metadata read and costs no usage tokens.

Example routing (conceptual agent logic):

```
results = call list_quotas or read quotas://current
best = call provider_with_most_headroom
if best and best.headroom_percent > 5:
  route work to best.provider
else:
  wait for check_provider_availability reset
```

See `collector/bin/example_routing_agent.dart` for a runnable Dart example that
performs the decision using the shared analysis logic. Binding rule: if a weekly
(or longer) window is spent, ignore green 5h bars.

## Local HTTP endpoint

An optional local HTTP server for non-MCP consumers:

```bash
cd collector
dart run bin/local_server.dart [port]
```

Defaults to port 8721. `GET /` returns the full normalized snapshot as JSON, and
`GET /suggest` returns the routing recommendation. Local only, zero tokens. Stop
with ctrl-c.

## Building from source

Prerequisites: the Flutter SDK (it includes Dart). On Windows you also need the
Visual Studio C++ build tools.

Run from source (no install step):

```bash
# CLI
cd collector
dart run bin/collect.dart doctor
dart run bin/collect.dart login grok

# Desktop app
cd app
flutter run -d windows   # or macos / linux
```

Build a release binary:

```bash
cd app
flutter build windows --release   # or macos, linux on the target OS
```

Packaging notes:

- Enable desktop targets once: `flutter config --enable-windows-desktop
  --enable-macos-desktop --enable-linux-desktop`.
- Build on the target OS (cross-compilation is not supported).
- Windows: the release exe, data, and plugins land in
  `app/build/windows/x64/runner/Release/quotabot.exe`. `tools/package-windows.ps1`
  runs the build. Distribute the Release folder as portable, or package it with
  Inno Setup or MSIX.
- macOS: `flutter build macos --release`, then codesign and notarize (`codesign
  --deep --options runtime --sign "Developer ID Application: ..."`, `xcrun
  notarytool`, staple, ship a DMG or ZIP).
- Linux: `flutter build linux --release`. Package the bundle as an AppImage
  (`appimagetool`) or deb/rpm, including the `.desktop` file (see
  `tools/package-linux.sh`).
- CLI release assets for the one-command installers are built with
  `tools/package-cli.ps1` (Windows) or `tools/package-cli.sh` (macOS/Linux), each
  writing the asset plus a `.sha256` sidecar; upload both to the GitHub release.

The application icon (`app/windows/runner/resources/app_icon.ico` on Windows,
`tools/quotabot.png` on Linux, sourced from `tools/quotabot-icon-1024.png`) is a
custom monochrome rune-style logo that works in light or dark and stays sharp at
all sizes. It is distinct from the in-app pool gauge and "Quota" wordmark in the
header. During development, `tools/local-setup.ps1` installs a `quotabot-gui`
command that launches from source with a deep clean and a visible console.

Note: on Windows, OneDrive-synced folders can cause flaky builds because of file
locks on generated directories. Move the project outside OneDrive for reliable
builds.

## Project layout

```
quotabot/
  app/           Flutter desktop application (Windows, macOS, Linux)
  collector/     Dart package: adapters, normalized model, auth, CLI, MCP server
  integrations/  LiteLLM proxy plugin for quota-aware request routing
  docs/          Setup, architecture, and data-source notes
  tools/         Packaging, icon, and developer helper scripts
```

The app and the collector are both Dart. The app imports the collector directly
and renders its output. The collector also ships a CLI (`collect.dart`, with
`doctor`, `suggest`, `stats`, `login`, and `logout`; add `--json` for raw
output), an MCP server, a plain local HTTP snapshot server, and an example
routing agent. For design and internals see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Disclaimer and terms of service

quotabot is an independent, unofficial tool. It is **not affiliated with,
endorsed by, or sponsored by** OpenAI, Anthropic, xAI, Google, Amazon, Cursor,
Codeium/Windsurf, or any other provider. All product names, logos, and trademarks
are the property of their respective owners and are used here only to identify the
service whose quota is being displayed.

quotabot reads usage and quota metadata from the local state, cache, and
credential files that each provider's own CLI or app has already stored on your
machine. It makes no model/inference calls of its own. Even so:

- **You are solely responsible for ensuring that your use of quotabot complies
  with the Terms of Service, acceptable-use policies, and developer agreements of
  every provider you connect to it.** Reading local state, reusing stored tokens,
  or automating routing decisions may be restricted by a given provider's terms.
  Review them and stop using quotabot with any provider whose terms it would
  violate for your account.
- Quota numbers are best-effort readings of data those providers expose locally
  and may be incomplete, delayed, or wrong. Do not rely on them for billing,
  compliance, or any decision with financial or contractual consequences. Verify
  against the provider's official dashboard.
- quotabot stores any login tokens you create for it under your own user config
  directory. Protect that directory as you would any other credential store.

This software is provided "AS IS", without warranty of any kind, under the
[Apache License 2.0](LICENSE). See the license for the full limitation of
liability. By using quotabot you accept these terms; if you do not agree, do not
use it.
