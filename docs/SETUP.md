# Getting started with quotabot

quotabot reads quota from the local state your existing AI tools already store.
Most providers need no setup at all. This guide takes you from install to a live
dashboard and (optionally) quota-aware routing.

## 0. What you need first

quotabot does not log you in to anything by itself; it reads what your tools
have already saved. So install and sign in to whichever you use before running
quotabot:

- Codex CLI, Claude Code, the Grok CLI, the Antigravity IDE.
- Optional, detected automatically with no setup: Kiro, Cursor, Windsurf, and a
  local runtime (Ollama or LM Studio).

If a tool has never run on your machine there is nothing for quotabot to read,
and that provider simply shows no live data until you use it once.

## 1. Install the CLI

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/blisspixel/quotabot/main/install.ps1 | iex
```

To install from a fork, set `QUOTABOT_REPO=owner/quotabot` before running the
installer. Restart your terminal afterward so the `quotabot` command is on your
PATH.

Running from source instead? You need the Flutter SDK (it includes Dart). Then:

```bash
cd collector
dart run bin/collect.dart doctor
```

## 2. See what is detected

```bash
quotabot doctor
```

Each row shows a state and, when useful, a next step:

- `live` - working now, nothing to do (Codex and Claude are always live).
- `cached (age)` - last good read; reopen that app, or connect quotabot once
  when that provider supports persistent login. The row tells you the exact
  command when available.
- `no live data` - that tool is not installed or has not run yet.
- `OUT OF QUOTA` - the binding window is spent; the row shows when it resets.

`doctor` ends with a one-line routing suggestion. For the full ranked list run
`quotabot suggest`.

## 3. Which providers need a login?

Everything is collected automatically. A `login` exists only for Grok and
Antigravity, and only to keep them live longer without reopening their app.

| Provider             | Works automatically?   | Optional `login` to stay live longer |
|----------------------|------------------------|--------------------------------------|
| Codex                | Yes (reads a file)     | not applicable                       |
| Claude               | Yes                    | not applicable                       |
| Grok                 | Yes, while CLI is fresh| `quotabot login grok`                |
| Antigravity          | Yes, while IDE is fresh| requires your own Google OAuth client |
| Kiro / Cursor / Windsurf | Passive, automatic | not applicable                       |
| Ollama / LM Studio (local) | Yes, when running   | not applicable                       |

```bash
quotabot login grok          # prints a URL and a device code to confirm
quotabot doctor              # confirm they now show "live", not "cached"
quotabot logout grok         # disconnect any time
```

quotabot stores its own refresh token under your per-user config directory and
refreshes silently from then on. This grant is independent of the host CLI and
IDE, so it never disturbs their credentials.

For persistent Antigravity login, create your own Google installed-app OAuth
client with access to the Cloud Code scopes, set
`QUOTABOT_GOOGLE_CLIENT_ID` and `QUOTABOT_GOOGLE_CLIENT_SECRET`, then run
`quotabot login antigravity`. Without those variables, Antigravity still works
from the IDE's fresh local token and falls back to cached values when it expires.

## 4. Run the desktop widget

```bash
cd app
flutter run -d windows   # or macos, linux
```

The widget is a small frameless card per provider with a bar per rolling window,
a reset countdown, and a collapse-to-strip mode. See the main README for the
menu options (hide providers, refresh cadence, always on top, and so on).

## 5. Route work to the freest provider (optional)

```bash
quotabot suggest          # recommended provider + ranked alternatives
quotabot suggest --json   # the same decision as JSON, for scripts and agents
```

To route a whole fleet of coding agents automatically, run the LiteLLM proxy
plugin in [../integrations/litellm/](../integrations/litellm/). It reads the
recommendation in a pre-call hook and sends each request to whichever deployment
has budget, falling back to a local model when your subscriptions are low.

## Troubleshooting

- "no live data" for a provider you use: open that provider's app once so it
  writes local state, then re-run `quotabot doctor`.
- Windows blocks a downloaded exe: verify the release checksum, then use the
  source path with `dart run` / `flutter run` if you prefer not to run a binary.
- Everything reads as cached: your machine has been offline or asleep; reopen a
  provider app, or connect Grok/Antigravity once (step 3).

Every command here is a local metadata read and costs zero usage tokens.
