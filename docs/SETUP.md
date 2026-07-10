# Getting started with quotabot

quotabot has two parts, and you can use either on its own:

1. A **CLI** you install with one command. It prints your quota in the terminal
   and powers routing. Works on Windows, macOS, and Linux.
2. A **desktop widget** (a small always-available card per provider). You run it
   from source today; the source setup command builds and installs it on Windows,
   macOS, and Linux.

quotabot reads quota metadata from the safest source each provider exposes. Most
reads come from local files your existing AI tools already wrote; live providers
may call their own quota or model-list metadata endpoint with an existing local
token or key. Antigravity may also perform its provider-required account
onboarding request before reading quota. quotabot makes no model calls, so every
command here costs zero usage tokens.

## Fastest path: install, inspect, then repair

1. Install the prebuilt CLI with the one-line command in
   [Install the quotabot CLI](#2-install-the-quotabot-cli).
2. Restart the terminal so the new command is on `PATH`.
3. Run `quotabot doctor`.

`doctor` is both the first quota view and the setup diagnostic. You do not need
to configure every provider before running it: working providers show their
current state, and missing or signed-out providers show a reason and next step.
The one-line release installers install the CLI only. To install the desktop
widget and shortcut as well, use the full source setup described in
[Building from source](BUILDING.md).

The detailed sections below explain provider preparation, recovery, the optional
desktop widget, and routing.

---

## 1. Make provider evidence available

quotabot normally reuses the account state each provider's own app has already
saved. Grok and Antigravity also support an optional quotabot-owned OAuth grant
for longer-lived reads or account pinning. There is no quotabot account.

| Provider class | Default evidence | Optional quotabot action | Refresh and scope |
|---|---|---|---|
| Claude | Claude Code OAuth token | none | live while the host credential is valid |
| Codex | Codex OAuth token, then newest local session snapshot | none | live when possible; fallback is visibly this-machine |
| Grok | current Grok CLI token and account file | `quotabot login grok` | own grant refreshes a matching locally discovered account and can pin it |
| Antigravity | signed-in IDE account and refresh material, then local state fallback | `quotabot login antigravity` | own grant refreshes a matching locally discovered account and can pin it |
| Cursor, Windsurf/Devin, Kiro | passive local application state | none | opportunistic this-machine evidence |
| NVIDIA NIM | `NVIDIA_API_KEY` or `nvapi` | set the environment key | status-only; numeric quota remains unknown |
| Ollama, LM Studio, Lemonade | reachable local server | start the runtime server | live inventory only; never served from cache |
| Manual entries | user-supplied local window | `quotabot manual set` | self-reported and never refreshed automatically |

If a tool has never run here, that provider simply shows "no live data" until you
use it once.

### Key-based status-only providers

NVIDIA NIM is optional. Create an API key on build.nvidia.com, then set either
`NVIDIA_API_KEY` or `nvapi` in the environment before running quotabot. quotabot
only calls the OpenAI-compatible `/v1/models` metadata endpoint to confirm the
key works. It never calls inference, does not invent a balance, and does not use
NIM as a model-budget route while no measured quota windows are known.

### Local models (Ollama, LM Studio, Lemonade)

A local runtime only appears in quotabot while its **local server** is running,
because quotabot reads its models over a local HTTP API. If you have one
installed but do not see it, start its server:

- **Ollama:** runs as a background service once installed (port 11434). Honors
  `OLLAMA_HOST`. Ollama cloud models can be reached through the local daemon;
  version 0.5.14 does not yet treat those as proof of local-only execution, so do
  not use them to satisfy a strict local budget.
- **LM Studio:** loading a model in the chat window is not enough; you must start
  the **local server** (the Developer tab, toggle "Start Server", or run
  `lms server start`). It listens on port 1234.
- **Lemonade:** desktop packages start the service automatically; confirm it
  with `lemonade status`. Headless installations run `lemond`. The server
  listens on port 13305 by default and honors `LEMONADE_HOST` and
  `LEMONADE_PORT`.

Additional OpenAI-compatible runtimes can use the same normalized adapter shape,
but they must have a supported discovery adapter before quotabot will list them.

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

The installer downloads a prebuilt CLI bundle, verifies its checksum, and exposes
`quotabot` on your PATH from `~/.local/bin` (macOS/Linux) or
`%LOCALAPPDATA%\quotabot\bin` (Windows). To install from a fork, set
`QUOTABOT_REPO=owner/quotabot` first.

### Inspect before running the installer

The one-line commands trust the mutable bootstrap script delivered from GitHub
over TLS. The script then verifies the downloaded release archive against its
published SHA-256 sidecar. If you prefer to inspect the bootstrap first:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh
less install.sh
bash install.sh
```

PowerShell:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/blisspixel/quotabot/main/install.ps1 -OutFile install.ps1
Get-Content .\install.ps1
& .\install.ps1
```

Release archives also carry GitHub artifact attestations. After downloading an
archive from the release page, verify it, for example, with `gh attestation
verify quotabot-windows-x64.zip --repo blisspixel/quotabot`. Use the matching
archive name on macOS or Linux. The checksum proves the archive matches the
published sidecar; this basic attestation command verifies repository provenance
but does not by itself constrain the signer workflow or expected tag. The release
smoke workflow adds `--signer-workflow`, `--source-ref`, `--source-digest`, and
`--deny-self-hosted-runners` for the strict release gate.

> No prebuilt binary for your platform yet, or you would rather not run one? Skip
> to [Run everything from source](#run-everything-from-source) at the bottom.

## 3. See your quota

```bash
quotabot doctor
```

Each row shows a state and, when useful, the exact next step:

| State           | Meaning                                                        |
|-----------------|---------------------------------------------------------------|
| `live`          | Working now; for Claude/Codex this means the host app is signed in. |
| `cached`        | Last good read (age shown in the row); reopen that app or connect quotabot (step 4). |
| `PROVIDER DRIFT` | A fresh read was rejected; the row is unavailable for routing and shows stale last-trusted quota only when one exists. |
| `no live data`  | That tool is not installed, not signed in, or has not run on this machine yet. |
| `OUT OF QUOTA`  | The binding window is spent; the row shows when it resets.     |

Rows can also include compact trust context: live versus cached state, spend
class, account label when the provider exposes one, this-machine scope for
local-only fallback data, and capture age. Treat those labels as part of the
number; a cached or this-machine read can still be useful, but it is not the
same evidence as a fresh account-level live read. Cached cloud quota is shown as
last-known evidence and is not treated as currently available for routing.

`doctor` ends with a one-line routing suggestion. Other useful commands:

```bash
quotabot doctor --json    # same data as JSON, for scripts
quotabot stats            # per-provider history and analytics
quotabot suggest          # where to send the next request (step 6)
```

## 4. Keep Grok and Antigravity live or pin an account (optional)

Claude and Codex read with their host credentials and do not have a quotabot
login flow. Codex can fall back to this-machine session snapshots. Grok can use
the CLI's current token, and Antigravity can use refresh material from a signed-
in IDE. A one-time quotabot login creates a separate refreshable grant when the
host credential is too short-lived or a specific account must be pinned. It does
not replace initial account discovery: run the provider app on this machine
first, and retain its local account identity state.

```bash
quotabot login grok          # device-code flow; confirm in the browser
quotabot login antigravity   # opens a browser; sign in with the account you want
quotabot doctor              # confirm they now read "live"
quotabot logout grok         # or: quotabot logout antigravity
```

Neither needs any cloud setup. quotabot stores its own refreshing grant for the
account you pick, separate from the host apps, so it never disturbs their
credentials. When an account-specific grant exists, quotabot prefers it for that
account; otherwise it falls back to the provider-default grant or the host app's
current token. Grok and Antigravity login save both when the provider returns an
account email. (Advanced: override the Antigravity OAuth client with
`QUOTABOT_GOOGLE_CLIENT_ID` and `QUOTABOT_GOOGLE_CLIENT_SECRET`.)

## 5. Run the desktop widget (optional)

The widget builds from source on all three platforms. You need the
[Flutter SDK](https://docs.flutter.dev/get-started/install) (it includes Dart),
plus the per-OS build tools:

| OS      | Build tools                                                          |
|---------|---------------------------------------------------------------------|
| Windows | Visual Studio with "Desktop development with C++" plus C++ ATL       |
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
taskbar or dock and launch without a terminal, see
[Building from source](BUILDING.md).

## 6. Route work to the freest provider (optional)

```bash
quotabot suggest          # recommended provider + ranked alternatives
quotabot suggest --json   # the same decision as JSON, for scripts and agents
```

To route a whole fleet of coding agents automatically, use the LiteLLM proxy
plugin in [../integrations/litellm/](../integrations/litellm/). It reads this
recommendation in a pre-call hook and sends each request to whichever deployment
has safe budget, falling back to a local model when your subscriptions are low.
By default, request-metered API-key deployments are skipped unless explicitly
enabled; use `spend: quota_plan` only for included quota plans with overages
disabled, and add `overages_disabled: true` or `overages: disabled` to make that
route eligible. It runs the same on all three platforms.

---

## Update, uninstall, and rollback

### Update the release CLI

Re-run the same one-line installer. It replaces the CLI bundle and preserves
quotabot's separate config, history, grants, profiles, and manual entries. Close
`quotabot top`, MCP, and other running quotabot processes first on Windows so the
executable can be replaced. Then run `quotabot --version` and `quotabot doctor`.

### Uninstall the release CLI but preserve data

macOS and Linux:

```bash
rm -f "$HOME/.local/bin/quotabot"
rm -rf "$HOME/.local/share/quotabot"
```

Windows PowerShell removes only the installed bundle and its user PATH entry,
leaving other `%LOCALAPPDATA%\quotabot` metadata intact:

```powershell
$installDir = Join-Path $env:LOCALAPPDATA 'quotabot\bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$kept = @($userPath -split ';' | Where-Object { $_ -and $_ -ne $installDir })
[Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'quotabot\bin') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'quotabot\lib') -Recurse -Force -ErrorAction SilentlyContinue
```

Open a new terminal after uninstalling. Source-built desktop shortcuts and app
bundles are separate from the release CLI. Source setup does not yet provide a
single cross-platform uninstaller; [BUILDING.md](BUILDING.md) describes its
build outputs and launcher behavior.

### Roll back

Version 0.5.14 has no automatic rollback command. Download the previous release
archive and its `.sha256` sidecar from GitHub Releases, verify both, stop running
quotabot processes, and restore that bundle in the same install location. Keep
the local metadata directory: public cache and profile formats are additive
within the 0.5 line. Run `quotabot --version` and `quotabot doctor` after the
replacement.

### Reset all local quotabot data

This is destructive and is not required for uninstall. Sign out any quotabot-
owned provider grants if possible. On macOS or Linux, remove the per-user data
directory in the table below. On Windows, the same root also contains the
release CLI, so preserve `bin` and `lib` when resetting data in place:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'quotabot'
Get-ChildItem -LiteralPath $root -Force |
  Where-Object { $_.Name -notin @('bin', 'lib') } |
  Remove-Item -Recurse -Force
```

This deletes cache, history, preferences, profiles, manual entries, grants,
leases, and alert state while leaving the Windows CLI on PATH. For a complete
Windows removal, run the PATH-aware uninstall first, then remove the remaining
`%LOCALAPPDATA%\quotabot` directory.

## Where quotabot stores its data

quotabot writes bounded local metadata: cache, history, preferences, profiles,
manual entries, OAuth grants and rotations, routing leases, and alert state.
Everything is per-user:

| OS      | Location                                              |
|---------|------------------------------------------------------|
| Windows | `%LOCALAPPDATA%\quotabot` (shared data and release root) |
| macOS   | `~/.config/quotabot`                                  |
| Linux   | `$XDG_CONFIG_HOME/quotabot` (or `~/.config/quotabot`) |

New and rotated quotabot-owned login tokens are written only after owner-only
directory and file permission hardening succeeds on macOS, Linux, or Windows.
If hardening fails for a credential file, that file is not written and login or
refresh reports the failure. Default and account-scoped slots are separate
atomic writes, not one cross-file transaction. Non-secret cache and history
metadata retain best-effort permission hardening. The desktop's secret-capable
webhook preferences use a bounded, asynchronous fail-closed storage boundary.
If an existing `prefs.json` cannot be protected, the desktop ignores it, uses
safe defaults, and shows a warning. It does not delete the file automatically;
secure or remove that file before retrying. The same warning distinguishes an
invalid, unreadable, non-regular, or oversized preferences file instead of
misreporting every load failure as a permission problem.
The Windows directory also contains the release `bin` and `lib` folders, so
reset and uninstall require the separate procedures above.

## Troubleshooting

- **"no live data" for a provider you use:** open that provider's app once so it
  writes local state, then re-run `quotabot doctor`.
- **NVIDIA NIM stays missing:** make sure `NVIDIA_API_KEY` or `nvapi` is visible
  in the same shell that starts quotabot. A valid key shows availability with
  unknown numeric quota, not a percentage window.
- **Everything reads as "cached":** your machine was offline or asleep; reopen a
  provider app, or connect Grok/Antigravity once (step 4).
- **A row says "PROVIDER DRIFT":** run `quotabot verify`, then compare the named
  provider and any reported windows with the provider's own usage view. quotabot
  keeps last-trusted quota visible when it exists, but will not route to it or
  record the rejected read in measured analytics. An upgraded legacy quarantine
  intentionally has no windows because it cannot prove a trusted baseline. A
  later clean read clears a normal warning; legacy quarantine recovers after a
  read proves every retained quota reset advanced, or the evidence class
  changes. If the provider-owned view
  changed shape or semantics, retain the verification output and report the
  mismatch rather than deleting the cache.
- **`quotabot` not found after install:** restart your terminal so the new PATH
  entry is picked up. On Windows, open a fresh PowerShell window.
- **Windows blocks the downloaded exe:** it is unsigned for now. Verify the
  release `.sha256`, or run from source instead (below).
- **Windows widget build reports `atlbase.h` missing:** modify Visual Studio
  Build Tools and add C++ ATL support for your installed MSVC toolset.
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

Quota and routing reads cost zero usage tokens. Login, logout, manual-entry,
preference, cache/history, and lease operations can write bounded local metadata.
Some live providers contact their own metadata endpoint, and Antigravity may
perform its provider-required account onboarding request. quotabot never sends
prompts, source code, model output, or inference requests.
