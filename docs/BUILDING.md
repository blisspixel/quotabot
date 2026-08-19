# Building from source

Prerequisites: Flutter 3.44.6 with Dart 3.12.2, the exact toolchain pinned in CI
and release builds. Install it from the
[Flutter SDK archive](https://docs.flutter.dev/install/archive); Flutter includes
Dart. Per-OS build tools: Visual Studio with "Desktop development
with C++" plus C++ ATL support for your installed MSVC toolset (Windows), Xcode
and CocoaPods (macOS), or
`clang cmake ninja-build pkg-config libgtk-3-dev libayatana-appindicator3-dev`
(Linux).

## One-command setup

From a fresh clone, a single idempotent script builds and installs the CLI and
the desktop app, then finishes by running `quotabot doctor`:

```powershell
pwsh tools/setup.ps1          # Windows; add -CliOnly for just the CLI
```
```bash
bash tools/setup.sh           # macOS / Linux; add --cli-only for just the CLI
```

The CLI does not need the desktop OS toolchain. If those tools are missing, or
the desktop build fails, setup still installs the CLI, skips the tray app, and
prints the repair step. If Dart is missing or `dart build cli` fails, setup
downloads the checksum-verified release CLI instead of exiting. If that
download also fails and Dart is present, it installs a `dart run` shim from
this checkout. Re-run the same command after adding the tools to
install the desktop app. On Windows that is Visual Studio C++ ATL; on macOS,
Xcode command-line tools; on Linux, clang, cmake, ninja, pkg-config, and GTK 3.
Setup also enables the matching Flutter desktop target before building.
`dart build cli` native-asset hooks fail when the Dart SDK path contains spaces
(a typical `C:\Users\First Last\...` or `/Users/First Last/...` profile);
setup and the CLI packagers hardlink or copy the Dart SDK into a space-free
directory for that compile. Junctions, subst drives, and 8.3 short names are
not enough, because Dart reports the long path.

The CLI command is exposed through your per-user bin
(`%LOCALAPPDATA%\quotabot\bin` on Windows, `~/.local/bin` on macOS and Linux).
On macOS and Linux, that command shim launches the stable complete payload at
`~/.local/share/quotabot`. Windows setup adds its bin directory to the user
PATH. On macOS and Linux, setup adds `~/.local/bin` to the user's shell profile
when it is not already on PATH. Windows creates a Desktop
shortcut to `%LOCALAPPDATA%\quotabot\desktop`, Linux installs the app under
`~/.local/share/quotabot-desktop` with an application-menu entry, and macOS
installs `~/Applications/quotabot.app`. These launchers remain valid if the
source checkout moves or is removed. Re-run after a `git pull` to update. On
Windows, setup restarts a running installed desktop app after activation so the
tray app is not left on old code. The manual steps below are the same thing by
hand.

Setup stages each CLI or desktop payload as one complete versioned generation
before switching its stable entry path. On macOS and Linux, the active target is
a relative symlink and its private sibling version store retains the immediate
predecessor for recovery. Uninstall must remove both paths; the exact commands
are in [SETUP.md](SETUP.md#uninstall-the-release-cli-but-preserve-data).
On macOS and Linux, full source setup stages and validates both payload
generations before activating either stable target. If either payload activation
fails, setup restores both prior stable targets before returning an error. The
CLI-only path remains one versioned transaction.

## Run from source

```bash
# CLI
cd collector
dart run bin/collect.dart doctor
dart run bin/collect.dart login grok

# Desktop widget
cd app
flutter run -d windows   # or macos / linux
```

## Build a release binary

```bash
cd app
flutter pub get --enforce-lockfile
flutter build windows --release --no-pub   # or macos / linux, on the target OS
```

Notes:

- Enable desktop targets once: `flutter config --enable-windows-desktop
  --enable-macos-desktop --enable-linux-desktop`.
- Build on the target OS; cross-compilation is not supported.
- **Windows:** the exe, data, and plugins land in
  `app/build/windows/x64/runner/Release/quotabot.exe`. `tools/package-windows.ps1`
  runs the build and writes `release/quotabot-windows-x64-desktop.zip` plus its
  checksum sidecar. The packager refuses non-x64 hosts so it cannot mislabel a
  different native build as that x64 asset. Add `-NoArchive` for a build-only
  check. The desktop notification plugin uses Visual Studio ATL headers; if a
  build reports `atlbase.h` missing, modify Visual Studio Build Tools and add C++
  ATL support for your installed MSVC toolset. `-PackageOnly` archives that exact
  existing bundle without resolving Flutter or rebuilding it. `-NoArchive` and
  `-PackageOnly` are mutually exclusive.
- **macOS:** `bash tools/package-macos.sh` verifies the committed lockfile, then
  runs `flutter build macos --release --no-pub`
  on a macOS host, verifies the `.app` bundle, and writes a portable desktop ZIP
  plus its checksum sidecar. `--no-archive` leaves the built app available for a
  later signing step, while `--package-only` archives that exact existing app
  without resolving Flutter or rebuilding it. The two options are mutually
  exclusive. Production distribution still needs Developer ID signing,
  notarization, and stapling.
- **Linux:** `bash tools/package-linux.sh` verifies the committed lockfile, then
  runs `flutter build linux --release --no-pub`
  on a Linux host, verifies the executable bundle plus `.desktop` and icon
  assets, and creates a portable tarball plus its checksum sidecar. You can also
  repackage that bundle as an AppImage (`appimagetool`) or deb/rpm.
- **CLI release archives** for the one-command installers are built with
  `tools/package-cli.ps1` (Windows) or `tools/package-cli.sh` (macOS/Linux), each
  writing a `dart build cli` bundle archive plus a `.sha256` sidecar. PowerShell
  `-NoArchive` and shell `--no-archive` stop after producing the normalized
  `bin/quotabot` bundle. `-PackageOnly` and `--package-only` archive that existing
  bundle without resolving Dart or rebuilding it. Build-only and package-only
  are mutually exclusive, and package-only fails when the normalized executable
  is missing. These phase controls create a stable local signing seam; they do
  not sign or verify the candidate themselves. The
  GitHub `Release` workflow runs the CLI and desktop helpers on `v*` tags,
  validates every CLI and desktop archive, and attests each exact archive path.
  Clean native runners then redownload all four draft CLI archives, reverify
  checksum and provenance, and require the packaged version and demo-mode
  `doctor --json` to run. Three more native runners reverify the desktop
  archives and exercise their portable lifecycle before the exact-asset audit
  allows publication. The separate `Install smoke` workflow tests the published
  one-line installer, a versioned upgrade, persistent data, and source setup.

Before Windows platform signing, inventory the native candidate with the
read-only, standard-library-only scanner. It covers every shipped PE module,
including EXE and DLL files. The command validates PE headers by
content, requires the expected x64 or arm64 architecture, rejects links and
malformed expected code, and emits normalized relative paths plus candidate and
inventory SHA-256 digests. It does not sign or verify a platform identity.
The gate runs on an isolated release runner and assumes no other local process
is concurrently replacing candidate paths. It rejects links present during each
scan and detects ordinary candidate mutations, but it is not a sandbox against a
concurrent local attacker racing Windows reparse-point changes.

```powershell
python tools/native_code_inventory.py --platform windows --surface cli --architecture x64 collector/build/quotabot_cli_release/bundle
python tools/native_code_inventory.py --platform windows --surface desktop --architecture x64 app/build/windows/x64/runner/Release
```

Add `--json` for the deterministic `quotabot.signing-inventory.v1` object. It
contains no generated timestamp or absolute candidate root. The complete
candidate digest covers every regular file, while the native inventory lists the
bounded executable-code subset. Windows CI and release builds capture that
manifest after the build-only phase, package without rebuilding, verify the
archive shape and checksum, extract the archive, and require `--expect-manifest`
to match before attestation or publication. The manifest is retained with the
workflow evidence.

Authenticode changes PE bytes, so a signed candidate needs a new post-signing
inventory. For a future release candidate, set the two non-secret environment
values below to the exact owner-approved publisher identity, then verify that
inventory with the credential-free policy checker:

```powershell
$subject = $env:QUOTABOT_WINDOWS_SIGNER_SUBJECT
$thumbprint = $env:QUOTABOT_WINDOWS_SIGNER_THUMBPRINT
$candidate = 'collector/build/quotabot_cli_release/bundle'
$manifest = '.agent/windows-cli-post-sign-inventory.json'
$receipt = '.agent/windows-cli-signature-verification.json'
New-Item -ItemType Directory -Force -Path '.agent' | Out-Null
$inventory = python tools/native_code_inventory.py `
  --platform windows --surface cli --architecture x64 --json $candidate
if ($LASTEXITCODE -ne 0) { throw "Post-signing native inventory failed" }
Set-Content -LiteralPath $manifest -Value $inventory `
  -Encoding utf8NoBOM -NoNewline
python tools/verify_windows_signatures.py `
  --manifest $manifest --surface cli --architecture x64 `
  --expected-signer-subject $subject `
  --expected-signer-thumbprint $thumbprint `
  --receipt $receipt $candidate
if ($LASTEXITCODE -ne 0) {
  throw "Verification failed; receipt_output_invalid means $receipt is not current, may contain prior evidence, or may not exist; capture the terminal fallback and stop"
}
```

Keep the manifest and receipt outside the candidate tree. Adding either file to
the tree correctly invalidates the inventory comparison.
The receipt path atomically replaces prior evidence only after a complete
success or handled-failure payload is ready. If publication itself fails, the
verifier exits nonzero, prints bounded fallback JSON, and leaves any prior
complete receipt untouched. The receipt path must have an existing parent,
must differ from the inventory manifest, and must stay outside the candidate.
Handled verification failures write the named receipt silently. Terminal
fallback JSON appears only when the receipt itself cannot be published.
Before a quotabot signing identity exists, exercise the same native adapter with
the repository's real embedded-signed Windows fixture test:

```powershell
python -m unittest `
  tools.test_verify_windows_signatures.NativeWindowsSignatureTests
```

That readiness test copies the installed, Microsoft-signed `pwsh.exe` into a
temporary candidate and supplies its observed public identity to the verifier.
It proves the local adapter can accept a real policy-valid embedded signature;
it does not establish or substitute for the future quotabot publisher identity.

Use `desktop` and `app/build/windows/x64/runner/Release` for the desktop bundle.
The verifier does not accept native-tool overrides. It finds SignTool only from
registered Windows SDK roots and uses the fixed Windows system PowerShell. It
requires every inventoried PE module to have exactly one valid embedded
Authenticode signature from the exact expected subject and certificate
thumbprint. SignTool runs with `/pa /all /tw /sha1`, and its policy table must
prove a SHA-256 file digest and RFC 3161 timestamp. A structured
`Get-AuthenticodeSignature` read independently confirms the embedded signature
type, OS trust result, signer identity, and timestamp certificate. Native
verifier processes have bounded time and live-captured output, receive a minimal
environment, and run from their own directories rather than the candidate
directory.

SignTool's `/sha1` value is the expected certificate's 40-hex SHA-1
thumbprint, used to select and match publisher identity. It is not an accepted
file or timestamp content-digest policy. Both content properties must still use
SHA-256.

After those Windows checks succeed, a separate standard-library parser reads
only the bounded PE certificate table. It requires one current PKCS SignedData
`WIN_CERTIFICATE`, one publisher signer, one Microsoft RFC 3161 timestamp
attribute and value, and one timestamp signer. Along the exact signed TSTInfo
path, DER lengths, depth, element count, offsets, table size, trailing data, and
cardinality fail closed. The TSTInfo `messageImprint` must use the SHA-256 OID
and contain 32 bytes. The verifier also hashes the outer Authenticode signature
with SHA-256 and requires that value to equal the message imprint. Windows
remains the authority for certificate and signature trust; the local parser
proves the timestamp algorithm and binding that the native summary does not
expose.

The policy follows Microsoft's current
[SignTool verification contract](https://learn.microsoft.com/en-us/dotnet/framework/tools/signtool-exe)
and
[`Get-AuthenticodeSignature` contract](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-authenticodesignature),
[Microsoft Authenticode timestamping guidance](https://learn.microsoft.com/en-us/windows/win32/seccrypto/time-stamping-authenticode-signatures),
and [RFC 3161](https://www.rfc-editor.org/rfc/rfc3161), checked 2026-07-28.
The future credential-bearing signing command must set `/fd SHA256` and `/tr`
followed by `/td SHA256`, retain the bounded receipt, and pass this independent
verifier. If `timestamp_policy_unproven` follows a wrong or uncertain signing
policy, sign a fresh candidate with those exact options, re-inventory because
signing changes PE bytes, and re-verify. Do not reuse the prior post-signing
inventory. If the result repeats after the expected policy was used, retain the
candidate, manifest, and failure receipt and stop publication. The same bounded
code also covers malformed, ambiguous, unsupported, resource-limited, or
signature-unbound timestamp evidence that another signing retry may not repair.

The final full-tree inventory must still equal the supplied post-signing
manifest. The deterministic `quotabot.windows-signature-verification.v1` receipt
covers the candidate and inventory digests, relative PE paths and digests, signer
and timestamp identities, each timestamp message-imprint algorithm and value,
and stable hashes of SignTool and PowerShell. It emits no generated timestamp,
absolute candidate root, or raw native diagnostic.
With `--json`, a failure emits the bounded
`quotabot.windows-signature-verification-error.v1` object with a stable reason
code, surface, architecture, allowlisted failure stage, and, when applicable,
one relative PE path. Use `--receipt PATH` instead of `--json` to atomically
retain that same canonical success or handled-failure JSON.

Every success and bounded failure object includes `receipt_body_sha256`, a
comparison-only SHA-256 over all other receipt fields. To recompute it, parse the
object, remove `receipt_body_sha256`, serialize the remaining object with sorted
keys, compact separators, and ASCII escaping, encode those ASCII-compatible JSON
bytes as UTF-8, then hash those bytes. The digest detects a different canonical
evidence body, but it is not a signature, MAC, attestation, or proof of origin.
Anyone who replaces the receipt can recompute it. On success, use the candidate
and inventory digests to correlate the receipt with the supplied post-signing
manifest and canonical candidate tree. The archive checksum and independent
workflow provenance separately establish the packaged release asset. The
receipt-body hash also covers the SignTool and PowerShell hashes, so it can
differ across verifier environments even when the candidate is identical.

A consumer must check the verifier exit status before treating a retained
receipt as evidence. A `receipt_output_invalid` fallback means the receipt file
must not be treated as current: capture the terminal fallback, retain the
candidate and manifest with the trusted workflow record, and stop publication.
A prior complete receipt remains on disk when publication of a newer receipt
fails. Other failure receipts likewise require their nonzero exit status,
retained candidate and manifest, and trusted workflow record for correlation.

The before and after inventories prove snapshot equality, not continuous
filesystem immutability. This verifier shares the isolated-runner assumption
stated above; no untrusted local process may race candidate-path replacement.

This checker does not sign code, select a certificate, handle credentials, or
authorize publication. It is deliberately not called by the current release
workflow, and current release artifacts remain unsigned. Activation still needs
the owner-approved publisher identity, certificate custody, timestamp service,
release environment, cost, and channel decisions. The intended Windows order is
build, capture the unsigned sign set, sign every inventoried PE, capture a new
post-signing inventory, verify it, package without rebuilding, then require the
extracted archive to match that post-signing inventory.

The current scanner is intentionally Windows-only. The roadmap still requires
the standalone macOS CLI, app, nested Mach-O code, and native code bundles to be
inventoried and verified using native macOS evidence before Developer ID signing
and notarization are enabled. Linux remains outside the current platform-signing
scope.

The CI workflow runs the Windows, macOS, and Linux desktop package scripts on
their native runners and validates each resulting archive plus checksum, so
every change exercises the same portable bundle shape without publishing release
assets. Build-only and package-only flags bind Windows archives to the exact
inventoried build tree. The other native CI legs continue to exercise the
default build-and-package path.
It then launches the packaged Windows and Linux apps and requires native window
setup plus every supported tray-registration call to complete. Windows verifies
the native `Shell_NotifyIconGetRect` result and rectangle independently of the
tray plugin. The app exposes that integration-only signal when
`QUOTABOT_DESKTOP_READINESS_FILE` names an output path; normal application runs
do not write a readiness file. Readiness launches use isolated quotabot
configuration and an ephemeral single-instance guard, so they do not read the
user's quotabot settings or ring, replace, hide, or stop an installed tray
instance.

Keep the machine-readable readiness report with the release evidence:

```powershell
python tools/desktop_readiness_smoke.py `
  --executable app/build/windows/x64/runner/Release/quotabot.exe `
  --report .agent/windows-readiness.json
```

The v3 report includes pass or failure status, the completed stage, a UTC
timestamp, launch PID, narrow runner executable SHA-256, isolated-config state,
app-authored window and tray readiness, and confirmed launch-process cleanup.
Unreached checks remain null. Failure evidence is intentionally bounded and
contains no raw error, log, or filesystem path. It also records a
domain-separated SHA-256, entry count,
and regular-file byte count for the complete platform bundle. Relative paths,
regular-file contents, and link targets are hashed in deterministic order;
links are never followed, traversal is bounded, and the before-launch identity
must match the after-cleanup identity. These fields use the
`quotabot.desktop-bundle.v1` identity schema. Write the report outside the
candidate bundle. On Windows, the tray result is independently backed by the
native Shell rectangle check.

CI and release workflows upload the Windows and Linux report on both success and
failure, so a failed readiness gate retains diagnostic evidence without exposing
host details.

This bundle identity proves which extracted product payload passed readiness. It
does not replace the archive checksum and provenance checks, application
signing, or native accessibility evidence. The Flutter widget suite enforces
labeled controls, 28 by 28 desktop targets, and text contrast across expanded,
compact, and Analytics surfaces in light, dark, and Hacker themes. A release
candidate still requires keyboard-only focus-order and visible-focus review plus
a basic Narrator workflow on a native interactive Windows session.

GitHub-hosted macOS runners build the app, but direct and LaunchServices bundle
launches did not publish an app-authored window or status-item readiness
transition. That environment therefore is not used as evidence of interactive
macOS readiness. On an interactive macOS host, run the same bundle-aware
readiness harness after packaging:

```bash
python tools/desktop_readiness_smoke.py \
  --executable app/build/macos/Build/Products/Release/quotabot.app/Contents/MacOS/quotabot
```

The harness launches the `.app` through LaunchServices, not by invoking its
inner executable directly. Automated startup gates do not replace the release
candidate's interactive launcher, visible-tray, close-to-tray, and reopen check
on clean desktop sessions.

## Release dry run

Before cutting a public tag, verify the release exactly the way an installer and
maintainer will consume it:

1. Align every public version marker, including the collector package, CLI and
   MCP constants, desktop package and lockfile, changelog, roadmap, README,
   agent guidance, documentation index, and setup guide. Run
   `python tools/check_release_version.py --tag vX.Y.Z`; it must confirm the
   intended tag and one consistent version. The release workflow enforces the
   same exact tag-to-source check before creating a draft.
2. Build the current platform's archive with `tools\package-cli.ps1` on Windows
   or `tools/package-cli.sh` on macOS/Linux.
3. Confirm the `.sha256` sidecar contains a 64 character SHA-256 hash and the
   archive filename, then compare it with the archive's actual hash.
4. Expand the archive in an isolated temporary directory and run the packaged
   CLI (`bin\quotabot.exe` on Windows or `bin/quotabot` on macOS/Linux) with
   `--version` plus demo-mode `doctor --json` under an isolated config
   directory.
5. Commit the release metadata on `main`, push it, and wait for hosted Windows,
   macOS, and Ubuntu CI plus CodeQL and secret scanning to pass before tagging.
6. Before tagging, repeat the package and execution smoke on each claimed native
   host. Retain the bounded readiness report, then complete the Narrator,
   keyboard-only focus-order, visible-focus, launcher, and tray checks that it
   does not prove. Complete equivalent native interactive checks on macOS and
   Linux. Record an unavailable cell explicitly rather than treating a
   shared-code test as native evidence.
7. Verify the official repository still has the active `v*` tag ruleset that
   blocks updates and deletion, plus GitHub release immutability. Immutability
   applies only to releases published after the setting was enabled on July 18,
   2026. v0.9.4 and later releases are locked under that policy; v0.9.2 and
   earlier releases were not changed retroactively.
8. Push an annotated `vX.Y.Z` tag. Wait for every `Release` workflow job,
   including its reusable CI quality gate, four CLI builds, four clean CLI
   execution legs, three desktop builds, and three clean desktop
   archive-verification legs, to pass.
9. Confirm that the published stable release is neither draft nor prerelease,
   is marked immutable, and has
   these CLI archive and `.sha256` sidecar pairs:
   `quotabot-windows-x64.zip`, `quotabot-darwin-arm64.tar.gz`,
   `quotabot-linux-x64.tar.gz`, and `quotabot-linux-arm64.tar.gz`.
   Confirm the three desktop pairs are also present:
   `quotabot-windows-x64-desktop.zip`,
   `quotabot-darwin-arm64-desktop.zip`, and
   `quotabot-linux-x64-desktop.tar.gz`.
10. Download every archive, compare it with its SHA-256 sidecar, and verify its
   repository provenance with `gh attestation verify <archive> --repo
   blisspixel/quotabot`. That basic command does not constrain the signer or tag;
   the release and install-smoke workflows add signer-workflow, source-ref,
   source-digest, and self-hosted-runner restrictions.
   The release workflow creates the attestation before uploading each pair.
11. After publication, dispatch `Install smoke` immediately and require its
    clean install, prior-version upgrade, persistent-state, and source-setup
    matrix to pass on Windows, macOS, and Linux.
12. Confirm GitHub security signals are clear: CI, CodeQL, secret scanning,
    Dependabot alerts, and the dependency-review PR gate.

The `Install smoke` workflow automates the post-release clean-host portion of
this checklist on native Windows, macOS, and Linux runners. It resolves the
latest published release and prior 0.x release, pins checkout to the release-tag
commit, verifies checksums and provenance, exercises a clean one-line install,
then tests the prior-release upgrade plus CLI-only and full source setup with a
persistent-state sentinel. Its final checks cover the packaged CLI, demo doctor
schema, Windows shortcut target, macOS app bundle, and Linux desktop entry. It
runs weekly and can be dispatched with explicit tags for repeatable published
release regression evidence. A pre-publication candidate dry run and interactive
tray-readiness check remain separate release-candidate requirements.

### Baseline release evidence

The 0.9.8 rehearsal completed the full automated path. Its
[release workflow](https://github.com/blisspixel/quotabot/actions/runs/30692524913)
passed the native quality, build, execution, checksum, restricted-provenance,
and exact 14-asset gates before publishing the immutable
[v0.9.8 release](https://github.com/blisspixel/quotabot/releases/tag/v0.9.8).
The immediately dispatched
[install smoke](https://github.com/blisspixel/quotabot/actions/runs/30693794794)
then passed clean install, upgrade from the actual prior stable v0.9.7,
persistent-state, and source-setup checks on Windows, macOS, and Ubuntu. This is
the rehearsal baseline; the complete checklist, signing, notarization, and
interactive evidence must run again on the exact 1.0 candidate.

## Icon and dev launcher

The application icon (`app/windows/runner/resources/app_icon.ico` on Windows,
`tools/quotabot.png` on Linux, sourced from `tools/quotabot-icon-1024.png`) is a
custom monochrome rune-style logo, distinct from the in-app pool gauge and "Quota"
wordmark. During development, `tools/local-setup.ps1` installs a `quotabot-gui`
command that launches from source with a deep clean and a visible console.

On Windows, OneDrive-synced folders can cause flaky builds (file locks on
generated directories); move the project outside OneDrive for reliable builds.
