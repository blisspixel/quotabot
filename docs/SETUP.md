# Getting started with quotabot

quotabot has two parts, and you can use either on its own:

1. A **CLI** you install with one command. It prints your quota in the terminal
   and powers routing. Works on Windows, macOS, and Linux.
2. A **desktop widget** (a small always-available card per provider). You run it
   from source today; it builds on Windows, macOS, and Linux.

Everything reads quota from the local files your existing AI tools already wrote.
quotabot makes no model calls, so every command here costs zero usage tokens.

If you just want the numbers fast, do steps 1 to 3. The widget (step 5) and
routing (step 6) are optional.

---

## 1. Sign in to the tools you use (once)

quotabot does not log in to providers for you; it reads what their own apps have
already saved. So before running quotabot, make sure you have used each tool at
least once on this machine:

- **Always live once their app has run:** Codex CLI, Claude Code.
- **Live while their app is fresh:** Grok CLI, Antigravity IDE (step 4 keeps
  these live longer).
- **Detected automatically, no setup:** Kiro, Cursor, Windsurf, and a local
  runtime (Ollama, LM Studio, or Lemonade) while its server is running.

If a tool has never run here, that provider simply shows "no live data" until you
use it once.

### Local models (Ollama, LM Studio, Lemonade)

A local runtime only appears in quotabot while its **local server** is running,
because quotabot reads its models over a local HTTP API. If you have one
installed but do not see it, start its server:

- **Ollama:** runs as a background service once installed (port 11434). Honors
  `OLLAMA_HOST`.
- **LM Studio:** loading a model in the chat window is not enough; you must start
  the **local server** (the Developer tab, toggle "Start Server", or run
  `lms server start`). It listens on port 1234.
- **Lemonade:** start the server (`lemonade-server serve`); it listens on port
  8000. Honors `LEMONADE_HOST`.

Any other OpenAI-compatible server works the same way once it is serving.

## 2. Install the quotabot CLI

Run the one-liner for your OS, then **restart your terminal** so the `quotabot`
command is on your PATH.

**macOS / Linux**
```bash
curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh | bash
```

**Windows (PowerShell)**
```powershell
irm https://raw.githubusercontent.com/blisspixel/quotabot/main/install.ps1 | iex
```

The installer downloads a prebuilt binary to `~/.local/bin` (macOS/Linux) or
`%LOCALAPPDATA%\quotabot\bin` (Windows) and verifies its checksum. To install
from a fork, set `QUOTABOT_REPO=owner/quotabot` first.

> No prebuilt binary for your platform yet, or you would rather not run one? Skip
> to [Run everything from source](#run-everything-from-source) at the bottom.

## 3. See your quota

```bash
quotabot doctor
```

Each row shows a state and, when useful, the exact next step:

| State           | Meaning                                                        |
|-----------------|---------------------------------------------------------------|
| `live`          | Working now, nothing to do (Codex and Claude are always live). |
| `cached (age)`  | Last good read; reopen that app or connect quotabot (step 4).  |
| `no live data`  | That tool is not installed or has not run on this machine yet. |
| `OUT OF QUOTA`  | The binding window is spent; the row shows when it resets.     |

`doctor` ends with a one-line routing suggestion. Other useful commands:

```bash
quotabot doctor --json    # same data as JSON, for scripts
quotabot stats            # per-provider history and analytics
quotabot suggest          # where to send the next request (step 6)
```

## 4. Keep Grok and Antigravity live (optional)

Claude and Codex are always live. Antigravity and Grok are live for the account
their app is signed into, and quotabot refreshes that token on its own. Two cases
call for a one-time `login`: the app is signed out, or you use several accounts
and want a specific one shown.

```bash
quotabot login grok          # device-code flow; confirm in the browser
quotabot login antigravity   # opens a browser; sign in with the account you want
quotabot doctor              # confirm they now read "live"
quotabot logout grok         # or: quotabot logout antigravity
```

Neither needs any cloud setup. quotabot stores its own refreshing grant for the
account you pick, separate from the host apps, so it never disturbs their
credentials. (Advanced: override the Antigravity OAuth client with
`QUOTABOT_GOOGLE_CLIENT_ID` and `QUOTABOT_GOOGLE_CLIENT_SECRET`.)

## 5. Run the desktop widget (optional)

The widget builds from source on all three platforms. You need the
[Flutter SDK](https://docs.flutter.dev/get-started/install) (it includes Dart),
plus the per-OS build tools:

| OS      | Build tools                                                          |
|---------|---------------------------------------------------------------------|
| Windows | Visual Studio with the "Desktop development with C++" workload       |
| macOS   | Xcode and CocoaPods (`sudo gem install cocoapods`)                   |
| Linux   | `clang cmake ninja-build pkg-config libgtk-3-dev` (apt names)        |

Then, from the repo root, run the widget for your OS:

```bash
cd app
flutter run -d windows    # on Windows
flutter run -d macos      # on macOS
flutter run -d linux      # on Linux
```

That opens the live widget. To build a standalone app you can pin to your
taskbar/dock and launch without a terminal, see
[Building from source](../README.md#building-from-source) in the README.

## 6. Route work to the freest provider (optional)

```bash
quotabot suggest          # recommended provider + ranked alternatives
quotabot suggest --json   # the same decision as JSON, for scripts and agents
```

To route a whole fleet of coding agents automatically, use the LiteLLM proxy
plugin in [../integrations/litellm/](../integrations/litellm/). It reads this
recommendation in a pre-call hook and sends each request to whichever deployment
has budget, falling back to a local model when your subscriptions are low. It
runs the same on all three platforms.

---

## Where quotabot stores its data

quotabot writes only its own cache, history, preferences, and any login tokens
you create. Everything is local and per-user:

| OS      | Location                                              |
|---------|------------------------------------------------------|
| Windows | `%LOCALAPPDATA%\quotabot`                             |
| macOS   | `~/.config/quotabot`                                  |
| Linux   | `$XDG_CONFIG_HOME/quotabot` (or `~/.config/quotabot`) |

Login tokens are owner-only on macOS/Linux and ACL-restricted on Windows. Delete
that folder to reset quotabot completely.

## Troubleshooting

- **"no live data" for a provider you use:** open that provider's app once so it
  writes local state, then re-run `quotabot doctor`.
- **Everything reads as "cached":** your machine was offline or asleep; reopen a
  provider app, or connect Grok/Antigravity once (step 4).
- **`quotabot` not found after install:** restart your terminal so the new PATH
  entry is picked up. On Windows, open a fresh PowerShell window.
- **Windows blocks the downloaded exe:** it is unsigned for now. Verify the
  release `.sha256`, or run from source instead (below).
- **Widget build fails on Windows inside OneDrive:** OneDrive file locks break
  Flutter builds; move the repo outside OneDrive (e.g. `%USERPROFILE%\dev`).

## Run everything from source

No install step, just the [Flutter SDK](https://docs.flutter.dev/get-started/install):

```bash
# CLI (any OS)
cd collector
dart run bin/collect.dart doctor
dart run bin/collect.dart login grok

# Desktop widget (use your OS device below)
cd app
flutter run -d windows    # or: macos, linux
```

Every command in this guide is a local metadata read and costs zero usage tokens.
