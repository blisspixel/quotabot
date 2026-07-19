# Getting started with quotabot

quotabot has two parts, and you can use either on its own:

1. A **CLI** you install with one command. It prints your quota in the terminal
   and powers routing. Works on Windows, macOS, and Linux.
2. A **desktop widget** (a small always-available card per provider). You run it
   from a verified portable release bundle, or build and install it from source
   on Windows, macOS, and Linux.

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
The one-line release installers install the CLI only. Tagged releases built by
the current workflow also attach verified portable desktop bundles; follow
[Desktop release bundles](DESKTOP-DISTRIBUTION.md) for checksum and provenance
verification plus update, rollback, and uninstall behavior. To build and install
the desktop widget with the platform-specific launcher from source instead, use
[Building from source](BUILDING.md).

The detailed sections below explain provider preparation, recovery, the optional
desktop widget, and routing.

---

## 1. Make provider evidence available

quotabot normally reuses the account state each provider's own app has already
saved. Claude, Codex, Grok, and Antigravity also support an optional
quotabot-owned OAuth grant for longer-lived reads on an idle machine or account
pinning. There is no quotabot account.

| Provider class | Default evidence | Optional quotabot action | Refresh and scope |
|---|---|---|---|
| Claude | Claude Code OAuth token | `quotabot login claude` | live while the host credential is valid; the grant is designed to keep the account-wide read live on an idle machine |
| Codex | Account-wide Codex OAuth usage metadata | `quotabot login codex` | the grant is designed to keep the account-wide read live on an idle machine; mixed session files are never read |
| Grok | current Grok CLI token and account file | `quotabot login grok` | own grant refreshes a matching locally discovered account and can pin it |
| Antigravity | signed-in IDE account and refresh material, then local state fallback | `quotabot login antigravity` | own grant refreshes a matching locally discovered account and can pin it |
| Cursor, Windsurf/Devin, Kiro | passive local application state | none | opportunistic this-machine evidence |
| NVIDIA NIM | `NVIDIA_API_KEY` or `nvapi` | set the environment key | status-only; numeric quota remains unknown |
| Ollama, LM Studio, Lemonade | reachable local server | start the runtime server | live inventory only; never served from cache |
| Manual entries | user-supplied local window | `quotabot manual set` | self-reported and never refreshed automatically |

Quotabot-owned grants are stored locally and are not synchronized. Run the
relevant `quotabot login` once on each idle machine that needs its own live read.

Providers that depend on local host-app account discovery show "no live data"
until that app has run on this machine. A quotabot-owned grant is also local to
the machine where it was created; it is not synchronized from another computer.
Grok and Antigravity still need a locally discovered account before a matching
grant can be selected.

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

Host overrides must name an exact loopback destination: `localhost`, an IPv4
loopback address, or `::1`. quotabot does not contact credential-bearing, LAN,
or public values supplied through `OLLAMA_HOST`, `LMSTUDIO_HOST`, or
`LEMONADE_HOST`; it keeps the runtime visible as an unavailable configuration
error so the setting can be repaired.

- **Ollama:** runs as a background service once installed (port 11434). Honors
  `OLLAMA_HOST`. Ollama cloud models (a `-cloud` tag) can be reached through the
  local daemon but run on ollama.com; quotabot flags them `cloud_offloaded` and
  keeps them out of `--budget=local` and free budgets automatically.
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
`QUOTABOT_REPO=owner/quotabot` first. The default is the latest published
release. `QUOTABOT_VERSION=vMAJOR.MINOR.PATCH` selects one exact tag for a
reproducible rollback.

For a one-line macOS or Linux fork install, pass the repository override to the
installer process, not only to `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/owner/quotabot/main/install.sh \
  | QUOTABOT_REPO=owner/quotabot bash
```

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
and install-smoke workflows add `--signer-workflow`, `--source-ref`,
`--source-digest`, and `--deny-self-hosted-runners` for their strict gates.

> No prebuilt binary for your platform yet, or you would rather not run one? Skip
> to [Run everything from source](#run-everything-from-source) at the bottom.

## 3. See your quota

```bash
quotabot doctor
```

Each row shows a state and, when useful, the exact next step:

| State           | Meaning                                                        |
|-----------------|---------------------------------------------------------------|
| `live`          | Working now; Claude/Codex have a usable host credential or quotabot grant. |
| `cached`        | Last good read (age shown in the row); reopen that app or connect quotabot (step 4). |
| `PROVIDER DRIFT` | A fresh read was rejected; the row is unavailable for routing and shows stale last-trusted quota only when one exists. |
| `no live data`  | That tool is not installed, not signed in, or has not run on this machine yet. |
| `OUT OF QUOTA`  | The binding window is spent; the row shows when it resets.     |

Rows can also include compact trust context: live versus cached state, normalized
source class, spend class, account label when the provider exposes one, and
capture age. Treat those labels as part of the number; a cached or
machine-scoped read can still be useful, but it is not the same evidence as a
fresh account-level live read. Cached cloud quota is shown as last-known evidence
and is not treated as currently available for routing.

For Claude, read the shared session and weekly windows separately from any
model-scoped Fable row. A spent or missing Fable pool does not mean the whole
Claude plan is spent, and quotabot never turns a shared healthy window into
Fable availability without current scoped evidence. The no-surprise quota budget
also requires a Max or Team Premium entitlement returned by current provider
metadata captured on or after July 20, 2026 UTC. The local Claude credential's
plan label is diagnostic only and never
proves current included spend or credit-backed classification. Pro, Team
Standard, host-label-only, and
plan-unknown Fable rows remain visible only under the unrestricted budget.

| Source label | What it proves |
|---|---|
| `authoritative` | CLI and report label for a provider-owned account-level quota read; the desktop says `account-wide`; freshness is reported separately |
| `this-machine fallback` | A local fallback that can miss use on another device |
| `passive local` | Opportunistic evidence from a local IDE or CLI state store |
| `local runtime` | A supported loopback runtime is reachable; not proof that every model executes locally |
| `status only` | Access can be checked, but no numeric quota window is known |
| `manual` | The user entered the quota; it is not measured provider telemetry |

Machine-readable outputs use the corresponding `source_class` values documented
in [DATA_SOURCES.md](DATA_SOURCES.md#source-classes). `quotabot verify` checks
that the class is valid for the provider and consistent with the data shape;
`quotabot check PROVIDER --json` returns the same class for a single-provider
decision.

`doctor` ends with a one-line routing suggestion. Other useful commands:

```bash
quotabot doctor --json    # same data as JSON, for scripts
quotabot stats            # per-provider history and analytics
quotabot suggest          # where to send the next request (step 6)
```

## 4. Keep a provider live on an idle machine or pin an account (optional)

Claude, Codex, Grok, and Antigravity can reuse a valid credential from their host
app for a zero-setup live read. Because a Claude or Codex host token refreshes
only while that app runs on the machine, its account-wide read can become stale
on an idle host. An optional quotabot login creates a separate refreshable grant
designed to keep the read live there. Refresh and expired-host fall-through have
deterministic automated coverage, but dated real-account evidence after an idle
interval remains a tracked 1.0 acceptance item. Always confirm the actual machine
with `quotabot doctor`. Grok and Antigravity account pinning still relies on
locally discovered account identity, so run that provider app on this machine
first and retain its local account state.

```bash
quotabot login claude        # opens a browser; paste back the code it shows
quotabot login codex         # opens a browser; loopback capture
quotabot login grok          # device-code flow; confirm in the browser
quotabot login antigravity   # opens a browser; sign in with the account you want
quotabot doctor              # confirm they now read "live"
quotabot logout claude       # or: codex | grok | antigravity
```

These flows need no manual cloud project setup. Antigravity performs its
provider-required account onboarding request automatically. quotabot stores its
refreshing grant separately and never writes a host app's credentials. Claude
and Codex try a current host token first, then their independent grant when
needed. Grok and Antigravity can use an account-scoped grant when its discovered
identity matches; their login saves the account slot when the provider returns
an email.
(Advanced: override the Antigravity OAuth client with
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
quotabot's separate config, history, grants, profiles, and manual entries. The
installer stages a complete versioned payload and switches the stable entry only
after validation. If activation fails, the previous entry is restored. A
long-running process can continue using its previous generation, so close and
restart `quotabot top`, MCP, and other servers before checking the new version.
Then run `quotabot --version` and `quotabot doctor`.

### Uninstall the release CLI but preserve data

macOS and Linux:

```bash
rm -f "$HOME/.local/bin/quotabot"
rm -rf "$HOME/.local/share/quotabot"
rm -rf "$HOME/.local/share/.quotabot-versions"
```

Windows PowerShell removes only the installed bundle and its user PATH entry,
leaving other `%LOCALAPPDATA%\quotabot` metadata intact:

```powershell
$installDir = Join-Path $env:LOCALAPPDATA 'quotabot\bin'
$installRoot = Join-Path $env:LOCALAPPDATA 'quotabot'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$kept = @($userPath -split ';' | Where-Object { $_ -and $_ -ne $installDir })
[Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
foreach ($name in @('bin', 'lib')) {
  $path = Join-Path $installRoot $name
  $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if (-not $item) { continue }
  if ($item.LinkType) {
    Remove-Item -LiteralPath $path -Force
  } else {
    Remove-Item -LiteralPath $path -Recurse -Force
  }
}
Remove-Item -LiteralPath (Join-Path $installRoot 'cli-versions') -Recurse -Force -ErrorAction SilentlyContinue
```

Open a new terminal after uninstalling. Desktop release bundles and source-setup
desktop installs are separate from the release CLI. The source setup locations
are `%LOCALAPPDATA%\quotabot\desktop` on Windows,
`~/.local/share/quotabot-desktop` on Linux, and
`~/Applications/quotabot.app` on macOS. Portable desktop lifecycle instructions
are in [DESKTOP-DISTRIBUTION.md](DESKTOP-DISTRIBUTION.md); source build and
launcher behavior remain in [BUILDING.md](BUILDING.md).

Source setup uses sibling version stores on macOS and Linux. To remove a source
desktop install while preserving quotabot data, close the app and remove both
its stable path and private generations. On Linux, also remove the menu entry:

```bash
# Linux
rm -rf "$HOME/.local/share/quotabot-desktop"
rm -rf "$HOME/.local/share/.quotabot-desktop-versions"
rm -f "$HOME/.local/share/applications/quotabot.desktop"

# macOS
rm -rf "$HOME/Applications/quotabot.app"
rm -rf "$HOME/Applications/.quotabot.app-versions"
```

On Windows, close the app, then remove its stable bundle and shortcut:

```powershell
Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'quotabot\desktop') -Recurse -Force -ErrorAction SilentlyContinue
$shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'quotabot.lnk'
Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
```

### Roll back

Stop running quotabot processes, then run the current installer with the exact
previous release tag. The installer downloads that version, verifies its
`.sha256` sidecar, and uses the same staged replacement and failure rollback as
an update. Keep the local metadata directory.

macOS or Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh \
  | QUOTABOT_VERSION=vX.Y.Z bash
```

Windows PowerShell:

```powershell
$env:QUOTABOT_VERSION = 'vX.Y.Z'
irm https://raw.githubusercontent.com/blisspixel/quotabot/main/install.ps1 | iex
Remove-Item Env:QUOTABOT_VERSION
```

Only exact `vMAJOR.MINOR.PATCH` tags are accepted. Run `quotabot --version` and
`quotabot doctor` after the replacement.

### Reset all local quotabot data

This is destructive and is not required for uninstall. Stop quotabot processes
and make sure setup is not running. Sign out any quotabot-owned provider grants
if possible. On macOS or Linux, remove the per-user data directory in the table
below. On Windows, the same root also contains installed binaries, so preserve
`bin`, `lib`, `cli-versions`, and `desktop` when resetting data in place:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'quotabot'
Get-ChildItem -LiteralPath $root -Force |
  Where-Object { $_.Name -notin @('bin', 'lib', 'cli-versions', 'desktop') } |
  Remove-Item -Recurse -Force
```

This deletes cache, history, preferences, profiles, manual entries, grants,
leases, and alert state while leaving the Windows CLI and source desktop install
in place. For a complete Windows removal, run the PATH-aware CLI uninstall and
the source desktop removal above, then remove the remaining
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
The Windows directory also contains the release `bin` and `lib` entry points and
the `cli-versions` payload store, so reset and uninstall require the separate
procedures above.

## Troubleshooting

- **"no live data" for a provider you use:** open that provider's app once so it
  writes or refreshes local state, then re-run `quotabot doctor`. On an idle
  machine, use `quotabot login claude` or `quotabot login codex` to establish a
  separately refreshable path, then confirm the account-wide read with
  `quotabot doctor`.
- **NVIDIA NIM stays missing:** make sure `NVIDIA_API_KEY` or `nvapi` is visible
  in the same shell that starts quotabot. A valid key shows availability with
  unknown numeric quota, not a percentage window.
- **Everything reads as "cached":** your machine was offline or asleep; reopen a
  provider app, or connect the affected live provider once (step 4).
- **Claude disagrees with interactive `/usage`:** check the row's source and age,
  then run `quotabot check claude --json` and `quotabot verify`. Compare the
  current-window bars and reset times, not `/usage`'s approximate contribution
  breakdown based on local sessions. On an idle machine, use `quotabot login
  claude` so quotabot can refresh its own account-wide grant. A cached value
  whose reset passed stays stale and unavailable; it never becomes an inferred
  100% free. Do not automate `claude -p /usage` or `/quota`, because print mode
  executes a prompt rather than exposing a stable quota API. If a fresh
  authoritative row still differs, retain the redacted verification output and
  report the mismatch.
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
