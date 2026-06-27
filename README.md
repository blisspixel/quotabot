# quotabot

[![CI](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml/badge.svg)](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A small desktop widget that shows how much quota you have left across a few AI
coding subscriptions in one place: Codex (OpenAI), Claude (Anthropic), Grok
(xAI), Antigravity (Google), plus passive local support for Kiro, Cursor,
Windsurf, and local runtimes like Ollama and LM Studio.

Nothing fancy. If you pay for a few of these and keep forgetting which one still
has headroom, this might save you a little hassle. It just reads the usage your
tools already track locally, so for most providers there is nothing extra to set
up (an optional one-time login keeps Grok and Antigravity live longer).
The window is frameless and follows the system light/dark theme. It can be set
to always on top or shown in the taskbar via the menu (always on top defaults to
off, taskbar defaults to on). It collapses to a tiny status strip when you want
it out of the way.

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

## Layout

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
`doctor`, `suggest`, `login`, and `logout`; add `--json` for raw output), an MCP
server (tools plus quotas://current resource), a plain local HTTP snapshot
server, and an example routing agent.

New here? Start with [docs/SETUP.md](docs/SETUP.md) for a step-by-step getting
started guide (which providers work automatically and which take a one-time
login). For design and internals see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
and for exactly where each number comes from see
[docs/DATA_SOURCES.md](docs/DATA_SOURCES.md).

## Provider status

| Provider     | Source                                                   | Live usage      |
|--------------|----------------------------------------------------------|-----------------|
| Codex        | `rate_limits` event in the newest session rollout        | Yes             |
| Claude       | OAuth usage endpoint, token reused from Claude Code       | Yes             |
| Grok         | gRPC-web billing endpoint, token reused from the CLI     | Yes, when fresh |
| Antigravity  | Google Cloud Code API, token reused from the IDE          | Yes, when fresh |
| Kiro         | Local credits/state (CLI+IDE VSCode fork); passive detect | opportunistic   |
| Cursor       | Local credits/state (IDE); passive detect for free/Pro    | opportunistic   |
| Windsurf     | Local `cachedPlanInfo` in state.vscdb (daily/weekly/Cascade quota); passive detect | opportunistic   |
| Ollama       | Local daemon (`/api/tags` + `/api/ps`); installed and loaded models, in-use status | when running |
| LM Studio    | Local server (`/api/v0/models`, OpenAI `/v1/models` fallback); installed and loaded models | when running |

Kiro (even post-cancel), Cursor (free), and Windsurf (free tier) are detected
passively for robustness. Gemini CLI (consumer) transitioned to Antigravity
(~June 2026); Google coverage is via the Antigravity adapter. Aider/Cline and
similar are model-agnostic and use underlying provider quotas (already tracked).
See docs/DATA_SOURCES.md.

Local runtimes (Ollama, LM Studio) have no quota to spend, so they are not shown
as a usage bar. Instead their card reports what is installed, which model is
loaded, and whether one is in use, and it sorts below the cloud services. Any
other OpenAI-compatible local server (Jan, llama.cpp, GPT4All, and similar) can
be added the same way, since detection is just a local `/v1/models` style read.

Codex and Claude are always live. Grok and Antigravity are live while the token
their app stored is still valid; once it expires the card falls back to the last
cached value (shown with its age) until you reopen that app or connect
quotabot's own login (see below). See
[docs/DATA_SOURCES.md](docs/DATA_SOURCES.md) for exactly where each number comes
from.

None of these reads are model calls, so checking your quota costs no usage
tokens.

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

After install, restart your terminal and run:
```bash
quotabot doctor
quotabot login grok
```

To install from a fork, set `QUOTABOT_REPO=owner/quotabot` before running the
installer.

## Development / Running from source

Prerequisites: Flutter SDK (includes Dart). On Windows you also need the Visual Studio C++ build tools.

From the repo root:

```bash
# CLI
cd collector
dart run bin/collect.dart doctor
dart run bin/collect.dart login grok

# Desktop app
cd app
flutter run -d windows   # or macos / linux
```

## Keeping Grok and Antigravity live

Codex and Claude are always live. Grok and Antigravity are live while the token
their app holds is fresh. To keep Grok live without reopening the CLI, connect
quotabot's own login once:

```
dart run bin/collect.dart login grok
```

`login grok` prints a URL and a code to confirm (device flow). quotabot stores
its own refresh token under your config directory and refreshes silently from
then on. This grant is independent of the Grok CLI, so it never disturbs its
credentials. Disconnect with `logout grok`.

Antigravity's passive IDE token read still works automatically while the IDE
token is fresh. Persistent Antigravity login is available only when you provide
your own Google installed-app OAuth client through
`QUOTABOT_GOOGLE_CLIENT_ID` and `QUOTABOT_GOOGLE_CLIENT_SECRET`, then run
`dart run bin/collect.dart login antigravity`.

One-time setup keeps the cards live without reopening the host apps. Tokens
live under quotabot config (owner-only on POSIX). Run `dart run bin/collect.dart
doctor` after login to confirm live (not cached) state.

Run the desktop widget (replace platform as needed; build on target OS):

```
cd app
flutter run -d windows   # or macos, linux
```

Build a release binary:

```
cd app
flutter build windows --release   # or macos, linux on target OS
```

Packaging notes:
- Enable desktop targets: `flutter config --enable-windows-desktop --enable-macos-desktop --enable-linux-desktop`.
- Build on the target OS: `flutter build windows --release` (macos and linux similarly).
- CLI release assets for the one-command installers are built with `tools/package-cli.ps1` on Windows or `tools/package-cli.sh` on macOS/Linux. Upload the asset and its `.sha256` sidecar to the GitHub release.
- Windows: the release exe, data, and plugins land in `app/build/windows/x64/runner/Release/quotabot.exe`. `tools/package-windows.ps1` runs the build. Distribute the Release folder as portable, or package it with Inno Setup or MSIX.
- macOS: `flutter build macos --release`, then codesign and notarize (`codesign --deep --options runtime --sign "Developer ID Application: ..."`, `xcrun notarytool`, staple, ship a DMG or ZIP).
- Linux: `flutter build linux --release`. Package the bundle as an AppImage (`appimagetool`) or deb/rpm. Include a `.desktop` file (see `tools/package-linux.sh`).

## MCP server

The collector also runs as an MCP server, so other agents can query quota as a
primitive and route work to whichever subscription has budget. It speaks MCP
over stdio and exposes three tools plus a resource:

- `list_quotas` - the full normalized snapshot for every provider.
- `provider_with_most_headroom` - the account with the most remaining budget
  (binding window governs; includes resets_at).
- `suggest_provider` - the recommended provider to route the next request to,
  with ranked alternatives and a local fallback when subscriptions are low.
- `check_provider_availability` - whether a named provider is usable now and
  when it resets.
- Resource `quotas://current` - same snapshot for resource-oriented clients.

Run it directly with `dart run bin/mcp_server.dart`, or build a native binary:

```
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

See collector/bin/example_routing_agent.dart for a runnable Dart example
that performs the decision using the shared analysis logic. Binding rule:
if a weekly (or longer) window is spent, ignore green 5h bars.

## Routing work to the freest provider

quotabot can recommend where to send the next request. The decision prefers the
metered subscription with the most remaining headroom (above a comfort
threshold) and falls back to a local runtime (Ollama, LM Studio) when every
subscription is low, so a local model is a free safety net rather than always
winning on its unlimited headroom.

```
quotabot suggest          # human readable: recommended provider + ranked list
quotabot suggest --json   # same decision as JSON for scripts and agents
```

The same recommendation is available over MCP (`suggest_provider`) and HTTP
(`GET /suggest`). For a turnkey setup that routes a whole fleet of agents across
your subscriptions and local models, see the LiteLLM proxy plugin in
[integrations/litellm/](integrations/litellm/): it reads this recommendation in
a pre-call hook and rewrites each request to whichever deployment has budget,
failing soft to the requested model if quotabot is unavailable. It runs the same
on Windows, macOS, and Linux.

## Local HTTP endpoint

An optional local HTTP server for non-MCP consumers:

```
cd collector
dart run bin/local_server.dart [port]
```

Defaults to port 8721. GET / returns the full normalized snapshot as JSON.
Useful for external gadgets or scripts. Local only, zero tokens. Stop with
ctrl-c. See the bin for details.

## Using the widget

- Drag the header bar (full width) or the main content/cards area to move the window (only the control buttons on the right are excluded). The body is scrollable and the window height is derived from a deterministic content estimate capped at the screen height, so every visible provider shows without an overflow banner.
- The collapse button shrinks it to a compact strip of provider logos with a
  single status dot each; the expand button restores the full view.
- The menu button hides or shows individual providers, sets the refresh
  cadence (smart, every 15 minutes, or every hour), chooses display sort for
  icons (default, alphabetical, most available, or most used), and toggles
  always on top, taskbar visibility, notifications, and "Show account names".
  Account names auto-hide for single-account providers and appear only when a
  provider has more than one account on screen (e.g. multiple Antigravity
  logins); the "Show account names" toggle still applies on top, so turning it
  off hides all of them.
- The smart schedule refreshes more often as a reset approaches or a cap fills,
  and relaxes to as little as twice a day when everything is healthy and resets
  are far off.
- Your hidden providers, compact or expanded state, chosen cadence, always on
  top setting, taskbar visibility, notifications setting, show account names,
  and window position are remembered across restarts. The last update time shows
  without seconds (as of 10:25 AM style).
- Claude (and other windows with resetsAt) shows reset countdowns next to usage
  (e.g. "80%  3d12h"). Antigravity shows "free tier" explicitly when detected.
- Tap a provider card to expand its insights panel: a headroom sparkline plus
  the p10/p50/p90 distribution, how often it is usable, any tightening or easing
  trend, and the hour of day it is typically tightest. Tap again to collapse.

## History and analytics

quotabot keeps two tiers of local history, both zero-token. A short raw buffer
of recent checks drives the "usually ~X% free (last N)" line and the sparkline.
Alongside it, headroom is folded into compact hourly aggregate buckets retained
for 90 days; these power the analytics with no raw points kept long term.

From those buckets it derives the mean and spread of free headroom, the
p10/p50/p90 distribution (from a histogram), how reliably a provider has had
budget, a least-squares trend (percent per day with an R-squared confidence),
and a by-hour profile that surfaces when a provider is typically tightest. See
them per provider in the widget's insights panel or on the command line:

```
quotabot stats          # human readable analytics per provider
quotabot stats --json   # the same numbers for scripts
```

## Desktop icon and launcher

- The OS/desktop application icon (`app_icon.ico`, used for the window, taskbar, and shortcut) is a custom monochrome rune-style logo (works in light/dark, sharp at all sizes). See `tools/quotabot-icon-1024.png` (source), `app_icon.ico`, `quotabot.png` (Linux), `icon_preview.png`. (The in-app header shows the pool gauge + "Quota" wordmark, which is separate from this icon.)
- Build a standalone release once with `cd app; flutter build windows --release` (or mac/linux). The desktop `quotabot` shortcut points directly at the built release exe (`app/build/windows/x64/runner/Release/quotabot.exe`) and opens it instantly.
- `quotabot-gui` command (installed by `tools/local-setup.ps1` or equivalent) still launches from source with deep clean + visible console (recommended for live development + fixes); run `quotabot-gui` in a visible terminal.
- OneDrive note: builds can be flaky due to file locks on generated/ephemeral dirs. For reliable builds, move the project folder outside OneDrive.

## Caching and history

Each successful read is cached locally (per-account for Antigravity). If a later
read fails the last known values are shown with a small clock icon and their age.
Recent snapshots are also appended to provider jsonl history files; the widget
displays a short-term "usually ~X% free (last N)" history line when data exists.

## Disclaimer and terms of service

quotabot is an independent, unofficial tool. It is **not affiliated with,
endorsed by, or sponsored by** OpenAI, Anthropic, xAI, Google, Amazon, Cursor,
Codeium/Windsurf, or any other provider. All product names, logos, and
trademarks are the property of their respective owners and are used here only to
identify the service whose quota is being displayed.

quotabot reads usage and quota metadata from the local state, cache, and
credential files that each provider's own CLI or app has already stored on your
machine. It makes no model/inference calls of its own. Even so:

- **You are solely responsible for ensuring that your use of quotabot complies
  with the Terms of Service, acceptable-use policies, and developer agreements of
  every provider you connect to it.** Reading local state, reusing stored
  tokens, or automating routing decisions may be restricted by a given
  provider's terms. Review them and stop using quotabot with any provider whose
  terms it would violate for your account.
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
