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
Credential-related failures for Claude, Codex, Grok, and Antigravity name the
exact `quotabot login PROVIDER` command. Temporary provider timeouts, rate
limits, and service failures remain retry states and do not recommend login.
Its exit code confirms that the status rendered truthfully, not that every row
is a fresh live adapter read. Automation that requires fresh evidence should use
`quotabot verify --require-live`; an unfiltered strict run covers the whole
built-in fleet, so use `--profile=NAME` or `--exclude=PROVIDER,...` to select the
intended adapter contact and verdict scope. A strict run that selects no adapter
fails with exit 65 instead of passing vacuously.
The one-line release installers install the CLI only. Tagged releases built by
the current workflow also attach verified portable desktop bundles; follow
[Desktop release bundles](DESKTOP-DISTRIBUTION.md) for checksum and provenance
verification plus update, rollback, and uninstall behavior. To build and install
from a clone, including the optional desktop widget, use
[Building from source](BUILDING.md) or the one-command source setup below.

### From a source checkout

If you cloned the repository, or you are an agent setting this machine up from
source, run the idempotent setup script from the repo root. It builds the CLI
from this checkout, installs it onto your PATH, runs `quotabot doctor`, prints
what already works without extra login, and opens the app. The desktop tray app
is built from source when OS build tools are present; otherwise setup installs
the portable desktop release and launches it.

```powershell
pwsh tools/setup.ps1          # Windows; add -CliOnly for just the CLI
```

```bash
bash tools/setup.sh           # macOS / Linux; add --cli-only for just the CLI
```

Missing desktop OS build tools skip the tray app and still install the CLI on
Windows, macOS, and Linux. If Dart is missing or this checkout cannot compile,
setup installs the checksum-verified release CLI instead of failing. A dart-run
shim from this checkout is the last resort when a release download is also
unavailable. The script prints the repair step; re-run the same setup command
after adding desktop tools to install the tray app. End users who only want a
release binary should keep using the one-liner in
[Install the quotabot CLI](#2-install-the-quotabot-cli).

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
| Antigravity | signed-in `agy` CLI or IDE account and refresh material, then local state fallback | `quotabot login antigravity` | own grant refreshes a matching locally discovered account and can pin it |
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
  `LEMONADE_PORT`. Configured cloud-provider models remain visible for
  inspection but carry `cloud_offloaded` and stay out of local and free budgets.

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
release. `QUOTABOT_VERSION=vMAJOR.MINOR.PATCH` or
`vMAJOR.MINOR.PATCH-rc.N` selects one exact tag for a reproducible rollback.

The current stable release is
[v0.9.9](https://github.com/blisspixel/quotabot/releases/tag/v0.9.9). Its
[install smoke](https://github.com/blisspixel/quotabot/actions/runs/32299292058)
passed the one-line install, upgrade from the actual prior stable v0.9.8,
persistent-state, and source-setup matrix on Windows, macOS, and Ubuntu. Every
patch release follows the same published-artifact path.

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
interval remains a tracked 1.0 acceptance item. Always inspect the actual machine
with `quotabot doctor`. Grok and Antigravity account pinning still relies on
locally discovered account identity, so run that provider app on this machine
first and retain its local account state.

```bash
quotabot login claude        # opens a browser; paste back the code#state value
quotabot login codex         # opens a browser; loopback capture
quotabot login grok          # device-code flow; confirm in the browser
quotabot login antigravity   # opens a browser; sign in with the account you want
quotabot doctor              # inspect status and repair guidance
quotabot verify --require-live --profile=NAME  # strict automation gate
quotabot logout claude       # or: codex | grok | antigravity
```

For Claude, the login succeeds only after the callback page displays the
`code#state` value. Loading the consent page alone does not validate the request.
If the browser reports an authorization error after you select Authorize, no
code was issued: cancel the waiting CLI with Ctrl+C, confirm that quotabot is
current, and retry the login rather than pasting another value.

These flows need no manual cloud project setup. Antigravity performs its
provider-required account onboarding request automatically. quotabot stores its
refreshing grant separately and never writes a host app's credentials. Claude
and Codex try a current host token first, then their independent grant when
needed. Grok and Antigravity can use an account-scoped grant when its discovered
identity matches; their login saves the account slot when the provider returns
an email.

`quotabot logout` disconnects that provider from quotabot without signing the
host app out or changing its credential files. The disconnect applies to every
account for the provider, removes quotabot's stored grants, and makes collection
ignore host credentials until an explicit `quotabot login PROVIDER` succeeds.
This prevents a host login from reconnecting the provider immediately after
logout. A failed or cancelled login leaves the disconnect in place.
If the exact marker path is unreadable or contains an unexpected filesystem
entry, collection fails closed and does not fall through to host credentials.

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
curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/uninstall.sh | bash
```

Windows (PowerShell) removes the installed bundle and its user PATH entry:

```powershell
irm https://raw.githubusercontent.com/blisspixel/quotabot/main/uninstall.ps1 | iex
```

By default, the uninstall scripts preserve your local configuration and history. To perform a complete removal including all local metadata, add the `--purge` or `-Purge` flag when executing the scripts locally, or append it to the remote execution (e.g. `| bash -s -- --purge`).

Open a new terminal after uninstalling. The scripts stop only quotabot
processes launched from the recognized install roots, then remove the release
CLI, source or portable desktop payload, private generation stores, shortcut,
and Linux menu entry. They fail visibly and name any retained payload. Local
configuration, history, grants, profiles, and manual entries remain unless
purge is requested. Portable desktop lifecycle details are in
[DESKTOP-DISTRIBUTION.md](DESKTOP-DISTRIBUTION.md); source build and launcher
behavior remain in [BUILDING.md](BUILDING.md).

### Roll back

Stop running quotabot processes, then run the current installer with the exact
previous release tag. The installer downloads that version, verifies its
`.sha256` sidecar, and uses the same staged replacement and failure rollback as
an update. For a compatible rollback, keep the local metadata directory. If the
target release may predate an analytics-storage migration, first stop every
quotabot process and make a restorable copy of that directory.

Do not let a release from before the opaque account-key migration collect
against the only copy of current metadata, even if the two releases never run
at the same time. It can write recent history and hourly analytics to legacy
filenames while the current release uses canonical filenames. Before returning
to the current release, stop every older `top`, desktop, MCP, and server process,
then either restore the backup made before rollback or accept that the current
release will quarantine any affected history. Its migration checkpoint fails
closed when legacy and canonical generations diverge: both are preserved, but
the affected tier is excluded from displayed analytics, and ambiguous legacy
data cannot influence burn-aware routing. A frozen canonical account baseline
or validated pre-divergence checkpoint remains eligible for burn estimation. If
neither exists, the existing provider-only compatibility series remains eligible
only for an unambiguous single-account snapshot. Conflict evaluation uses the
more conservative post-pooling result from both possible hourly cutoff sets.
Healthy providers keep the pooled result matching the current hour offset, so
the conflict cannot penalize a route competitor. Analytics and `doctor` show a
warning, while `stats` reports bucket-tier conflicts on the rows that consume
those buckets. The default unfiltered JSON snapshot keeps a bounded incident
inventory even when an affected account is no longer current. A partial
inventory is not proof of a clean cache, and filtered views never reintroduce
out-of-scope incidents. Closing the older process stops further divergence but
does not restore quarantined history. Current quota snapshots, provider
credentials, and the **Now** view remain available. quotabot does not guess at
an ambiguous analytics delta.

To recover without deleting unrelated local state, obtain the exact account
value from the matching current provider row in `quotabot --json`, then inspect
each affected tier named by `doctor`:

```bash
quotabot verify --recover-analytics=PROVIDER --account=EXACT_ACCOUNT --tier=history
quotabot verify --recover-analytics=PROVIDER --account=EXACT_ACCOUNT --tier=buckets
```

If the incident says the exact account is not in the snapshot, reconnect that
account and rerun `doctor` first. The inventory deliberately omits unavailable
account identities and its random incident reference is not recovery authority.
For a provider with several current accounts, use the inventory's
`provider_row_index` to select the exact row instead of guessing.

Inspection is read-only and makes no provider call. After stopping every older
process and reviewing the reported impact, rerun the selected command with
`--yes`. quotabot moves only that exact tier's canonical and legacy files into
an owner-only evidence bundle under the local `analytics-recovery` directory,
and verifies SHA-256 digests. When strict row checks and one unique ordered
checkpoint overlap prove both raw-history deltas, it installs and verifies their
capped chronological merge. For aggregate buckets, it requires unique aligned
starts, a complete retained checkpoint suffix, and valid bounded count,
histogram, moment, exhausted-count, and extrema fields before installing
canonical plus legacy minus the shared checkpoint once. Unprovable evidence
restarts the selected tier empty. It preserves current quota, credentials, profiles,
preferences, manual entries, leases, alerts, other provider accounts,
provider-only compatibility analytics, and the unselected tier. If both tiers
are quarantined, recover them separately. It refuses a legacy file shared by
colliding account identities, and a retry after success returns the retained
bundle receipt. Portable
desktop bundles do not perform this recovery; install the CLI first if only the
desktop is present. Use the full local-data reset below only when deleting all
local state is actually intended.

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

Exact `vMAJOR.MINOR.PATCH` tags and release-candidate tags of the form
`vMAJOR.MINOR.PATCH-rc.N` are accepted. Run `quotabot --version` and
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
  separately refreshable path, inspect the account-wide row with
  `quotabot doctor`, and use scoped `quotabot verify --require-live` when a
  script must enforce freshness.
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
- **Analytics says its incident inventory is incomplete:** current quota and
  routing remain available, but an empty incident list is not a clean result.
  Stop older quotabot processes, rerun an unfiltered `quotabot doctor`, and
  inspect its invalid, unverifiable, or truncation evidence. Reconnect an
  unavailable affected account before using the exact scoped recovery command.
  Do not delete the cache merely to silence the warning; retained generations
  are the recovery evidence.
- **`quotabot` not found after install:** restart your terminal so the new PATH
  entry is picked up. On Windows, open a fresh PowerShell window.
- **Windows blocks the downloaded exe:** it is unsigned for now. Verify the
  release `.sha256`, or run from source instead (below).
- **Source setup skips the desktop app:** the CLI is still installed. On
  Windows, add Visual Studio C++ ATL support for your MSVC toolset. On macOS,
  install Xcode command-line tools (`xcode-select --install`). On Linux, install
  `clang cmake ninja-build pkg-config libgtk-3-dev` and the Ayatana app-indicator
  headers. Then re-run `pwsh tools/setup.ps1` or `bash tools/setup.sh`. Use
  `-CliOnly` / `--cli-only` when you only want the routing CLI.
- **Windows source setup fails with `'C:\Users\First' is not recognized`:**
  Dart's native-asset hooks break when the Flutter/Dart path contains spaces, as
  in `C:\Users\First Last\...`. Current setup and CLI packagers hardlink or copy
  the Dart SDK into a space-free directory for that compile. Junctions, subst
  drives, and 8.3 short names are not enough, because Dart reports the long
  path. If an older checkout still fails, install the prebuilt CLI, or install
  Flutter in a path without spaces.
- **`quotabot` not found after macOS or Linux install:** setup and the one-line
  installer add `~/.local/bin` to your shell profile when it is missing from
  PATH. Open a new terminal, or run `export PATH="$HOME/.local/bin:$PATH"`.
- **Windows widget build reports `atlbase.h` missing:** modify Visual Studio
  Build Tools and add C++ ATL support for your installed MSVC toolset.
- **Widget build fails on Windows inside OneDrive:** OneDrive file locks break
  Flutter builds; move the repo outside OneDrive (e.g. `%USERPROFILE%\dev`).

## Run everything from source

From a clone, prefer the one-command setup so the CLI lands on your PATH:

```powershell
pwsh tools/setup.ps1          # Windows
```

```bash
bash tools/setup.sh           # macOS / Linux
```

That needs the [Flutter SDK](https://docs.flutter.dev/get-started/install) (it
includes Dart). Desktop OS build tools are required only for the tray app; see
[Building from source](BUILDING.md). To run without installing:

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
