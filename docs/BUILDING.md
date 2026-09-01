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
install the desktop app. On Windows that is Visual Studio C++ ATL plus plugin
symlink permission from Windows Developer Mode or an elevated terminal; on
macOS, Xcode command-line tools; on Linux, clang, cmake, ninja, pkg-config, and
GTK 3. Setup checks both Windows conditions before compiling and uses the exact
checksum-verified portable release matching the checkout when source desktop
prerequisites are unavailable and that release has been published. Setup also
enables the matching Flutter desktop target before building.
`dart build cli` native-asset hooks fail when the Dart SDK path contains spaces
(a typical `C:\Users\First Last\...` or `/Users/First Last/...` profile);
setup and the packagers hardlink or copy the Dart SDK into a space-free
directory for that compile. Desktop packagers on every OS also remap a Flutter
SDK whose path contains spaces: Windows uses a junction view, and macOS/Linux
copy the launcher scripts and dart-sdk into a space-free tree. Junctions, subst
drives, and 8.3 short names are not enough, because Dart reports the long path.

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
  ATL support for your installed MSVC toolset. If Flutter reports that building
  with plugins requires symlink support, enable Windows Developer Mode or use an
  elevated terminal. `-PackageOnly` archives that exact existing bundle without
  resolving Flutter or rebuilding it. `-NoArchive` and `-PackageOnly` are
  mutually exclusive.
- **macOS:** `bash tools/package-macos.sh` verifies the committed lockfile, then
  runs `flutter build macos --release --no-pub`
  on a macOS host, verifies the `.app` bundle, and writes a portable desktop ZIP
  plus its checksum sidecar. `--no-archive` leaves the built app available for a
  later signing step, while `--package-only` archives that exact existing app
  without resolving Flutter or rebuilding it. The two options are mutually
  exclusive. The helper itself does not sign. The tag workflow can place
  Developer ID signing, notarization, desktop stapling, and native verification
  between those two phases when its protected macOS mode is activated.
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

### Native signing inventories

Before platform signing, inventory the candidate with the read-only,
standard-library-only scanner. It covers every shipped PE module on Windows and
every thin or fat macOS Mach-O module, including code nested inside app,
framework, plugin, and other native bundles. The command validates headers by
content, requires the expected x64 or arm64 architecture, rejects malformed
expected code, and emits normalized relative paths plus candidate and inventory
SHA-256 digests. The complete candidate digest also covers non-native files and
safe in-tree macOS framework links. Escaping, absolute, cyclic, broken, or
otherwise unsafe links fail closed. The scanner does not sign or verify a
platform identity.

The gate runs on an isolated release runner and assumes no other local process
is concurrently replacing candidate paths. It detects ordinary candidate
mutations, but it is not a sandbox against a concurrent local attacker racing
candidate-path replacement.

```powershell
python tools/native_code_inventory.py --platform windows --surface cli --architecture x64 collector/build/quotabot_cli_release/bundle
python tools/native_code_inventory.py --platform windows --surface desktop --architecture x64 app/build/windows/x64/runner/Release
```

```bash
python tools/native_code_inventory.py --platform macos --surface cli --architecture arm64 collector/build/quotabot_cli_release/bundle
python tools/native_code_inventory.py --platform macos --surface desktop --architecture arm64 app/build/macos/Build/Products/Release
```

Add `--json` for the deterministic `quotabot.signing-inventory.v1` object. It
contains no generated timestamp or absolute candidate root. The complete
candidate digest covers the complete tree, while the native inventory lists the
bounded executable-code subset. Windows CI and the Windows and macOS release
paths capture that manifest after the build-only phase, package without
rebuilding, verify the archive shape and checksum, extract the archive, and
require `--expect-manifest` to match before attestation or publication. The
manifest is retained with the workflow evidence.

### Windows Authenticode verification

Authenticode changes PE bytes, so a signed candidate needs a new post-signing
inventory. For an Azure Artifact Signing release candidate, set the non-secret
durable subscriber identity EKU from the approved Public Trust profile, then
verify that inventory with the credential-free policy checker:

```powershell
$subscriberEku = $env:QUOTABOT_WINDOWS_SUBSCRIBER_EKU
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
  --expected-subscriber-eku $subscriberEku `
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
temporary candidate. A legacy exact-certificate test seam proves the local
adapter can accept a real policy-valid embedded signature. Release workflows do
not use that seam, and it does not establish or substitute for the quotabot
subscriber identity.

Use `desktop` and `app/build/windows/x64/runner/Release` for the desktop bundle.
The verifier does not accept native-tool overrides. It finds SignTool only from
registered Windows SDK roots and uses the fixed Windows system PowerShell. It
requires every inventoried PE module to have exactly one valid embedded
Authenticode signature. SignTool runs with `/pa /all /tw`, and its policy table
must prove a SHA-256 file digest and RFC 3161 timestamp. A structured
`Get-AuthenticodeSignature` read independently confirms the embedded signature
type, OS trust result, signer and timestamp certificates, and signer EKUs. The
release policy requires the standard code-signing EKU
`1.3.6.1.5.5.7.3.3`, Artifact Signing Public Trust marker
`1.3.6.1.4.1.311.97.1.0`, and exactly one configured durable subscriber
identity EKU under `1.3.6.1.4.1.311.97.`. It records each daily leaf subject and
thumbprint as evidence but does not pin either value. Native verifier processes
have bounded time and live-captured output, receive a minimal environment, and
run from their own directories rather than the candidate directory.

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
The credential-bearing signing command sets `/fd SHA256` and `/tr`
followed by `/td SHA256`, retains the bounded receipt, and must pass this
independent verifier. If `timestamp_policy_unproven` follows a wrong or uncertain signing
policy, sign a fresh candidate with those exact options, re-inventory because
signing changes PE bytes, and re-verify. Do not reuse the prior post-signing
inventory. If the result repeats after the expected policy was used, retain the
candidate, manifest, and failure receipt and stop publication. The same bounded
code also covers malformed, ambiguous, unsupported, resource-limited, or
signature-unbound timestamp evidence that another signing retry may not repair.

The final full-tree inventory must still equal the supplied post-signing
manifest. The deterministic `quotabot.windows-signature-verification.v2` receipt
covers the candidate and inventory digests, relative PE paths and digests,
signer and timestamp identities, signer EKUs, the durable subscriber identity
EKU, each timestamp message-imprint algorithm and value, and stable hashes of
SignTool and PowerShell. It emits no generated timestamp, absolute candidate
root, or raw native diagnostic.
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

The release workflow uses only the pinned Azure login and Artifact Signing
actions. `tools/create_windows_signing_catalog.py` first requires the complete
current candidate tree to equal the unsigned inventory, rejects links, path
escapes, duplicate native entries, and an output inside the candidate, then
writes the exact relative PE catalog beside the candidate. The protected
`release-signing` environment supplies only OIDC identifiers and the one
signing endpoint, account, and profile. The expected public subscriber EKU is a
non-secret repository variable so packaging and fresh-download verification do
not enter the signing environment. No client secret, certificate file,
password, or exportable private key enters GitHub. The Entra identity must have
only the `Artifact Signing Certificate Profile Signer` role on that profile
and trust the environment-bound GitHub OIDC subject.

The action receives only `files-catalog`, SHA-256 file and timestamp digests,
`http://timestamp.acs.microsoft.com`, `append-signature: false`, and zero
batch size. The workflow fails closed without those values when
`QUOTABOT_WINDOWS_SIGNING_BACKEND` is `azure-artifact-signing`. Its Windows
order is a credential-free build and immutable unsigned handoff, complete-tree
and catalog revalidation in an isolated environment-bound signer,
authentication with short-lived OIDC, signing, a new post-signing inventory and
full-tree delta validation, native verification, then a second immutable
handoff to packaging. The credential-free packaging job repeats the delta gate
against the trusted unsigned inventory and exact action catalog. Packaging,
attestation, release upload, and fresh-download verification have no access to
the signing environment. The archive must match the selected inventory, and
the clean release-verification jobs download each exact draft Windows archive,
inventory the extracted payload again, rerun the complete native signature
verifier, and retain its bounded receipt before publication can continue.

Until the owner completes Public Trust identity validation, the explicit
`unsigned` transition mode packages the unchanged candidate only after its
complete inventory matches. The release notes must disclose that Windows
publisher identity is not established. The published v0.9.9 release artifacts
remain unsigned, as do the stable v0.10.1 transition artifacts. Ordinary CI
packaging stays unsigned and cannot access the protected release environment.

The manually dispatched `.github/workflows/windows-signing-rehearsal.yml`
builds the CLI and desktop candidates outside `release-signing`, signs and
verifies both inside it with short-lived OIDC, and uploads one-day signed
handoffs. A separate credential-free job independently downloads the original
unsigned and signed candidates, regenerates the catalog, repeats the byte-level
delta and native verification, deletes both local payloads, and retains bounded
JSON evidence for 14 days. It never publishes a release asset and must be
dispatched from protected `main`. The workflow is implemented but cannot
complete until the owner provisions the Azure identity, environment values,
Public Trust profile, and subscriber EKU.

### macOS Developer ID and notarization verification

The release workflow now implements the protected path for the standalone macOS CLI,
desktop app, nested Mach-O code, and native bundles. It remains inactive while
`QUOTABOT_MACOS_SIGNING_MODE=unsigned`; current published artifacts are unsigned.
Owner provisioning and a successful protected rehearsal are required before the
mode can change to `developer-id`.

The manually dispatched `.github/workflows/macos-signing-rehearsal.yml` builds
unsigned CLI and desktop candidates outside the protected environment, then runs
the same signing and verification contract inside `release-signing-macos`. It
must be dispatched from protected `main` and never publishes a candidate:
unsigned handoffs expire after two days, protected jobs delete candidate
payloads and credentials, and only bounded receipts and digest records are
retained for 14 days. The workflow is implemented but has not completed
successfully because owner identities and the required environment values and
secrets are still absent.

Every macOS CI, release, and rehearsal job selects the explicit `macos-15` arm64
runner and `/Applications/Xcode_16.4.app/Contents/Developer`. The
`tools/require-macos-toolchain.sh` gate requires Xcode 16.4 build 16F6 and the
expected Apple security tools. Credential-free CI also compiles minimal arm64
CLI and app fixtures, signs them ad hoc with hardened runtime in the generated
inside-out order, and exercises real `codesign` entitlement and code-directory
output parsing. Developer ID identity, secure timestamp, notarization,
Gatekeeper, and stapling still require the protected rehearsal.

`tools/create_macos_signing_plan.py` first requires the complete candidate to
match its unsigned inventory, then derives a bounded
`quotabot.macos-signing-plan.v1` target list. Native targets and their containing
bundles are ordered inside out. The desktop plan requires `quotabot.app` as its
outer bundle; a CLI plan rejects bundle and entitlement state.

The isolated `release-signing-macos` job downloads the immutable unsigned
handoff, regenerates the inventory and plan, and stops if either differs. It
imports `QUOTABOT_MACOS_CERTIFICATE_P12_BASE64` with
`QUOTABOT_MACOS_CERTIFICATE_PASSWORD` into an ephemeral keychain, then
`tools/sign_macos_candidate.py` signs every exact target with the configured
`QUOTABOT_MACOS_DEVELOPER_IDENTITY`, `QUOTABOT_MACOS_TEAM_ID`, hardened runtime,
and a secure timestamp. Only the outer app receives the exact committed
`app/macos/Runner/DeveloperID.entitlements`; every other target, including the
CLI, must have no entitlements.

The signer then inventories the complete tree again and runs
`tools/validate_macos_signing_delta.py`. Signing must change every planned
Mach-O target, preserve its mode, add or change only planned bundle
`_CodeSignature` metadata beyond those targets, and remove nothing. The bounded
success receipt is `quotabot.macos-signing-delta.v1`; handled failures use
`quotabot.macos-signing-delta-error.v1` and stop the release.

The signer submits a bounded ZIP with `notarytool` using
`QUOTABOT_MACOS_NOTARY_ISSUER_ID`, `QUOTABOT_MACOS_NOTARY_KEY_ID`, and the
protected `QUOTABOT_MACOS_NOTARY_KEY_P8`. Both Apple's submission and log must
say `Accepted`; `tools/record_macos_notarization.py` converts them to a bounded
`quotabot.macos-notarization.v1` receipt. It rejects any error issue, requires
Apple's logged archive name and SHA-256 to match the submitted ZIP, and requires
the notarization ticket to cover every signed code directory recorded for the
  candidate. Before submission, the workflow extracts that exact ZIP and requires
  its complete inventory to match the signed candidate. The receipt tool extracts
  and inventories the Apple-accepted ZIP again, rejects any change during that
  validation, and records the extracted inventory. The desktop app is then
  stapled. A second
delta check permits only signature metadata changes and requires no native-code
change. When Apple attaches the ticket only as extended metadata, the file
inventory remains unchanged and `stapler validate` supplies the ticket proof.
Apple does not support stapling the standalone CLI, so the CLI retains accepted
notarization evidence without a staple.

After a new post-signing inventory,
`tools/verify_macos_signatures.py` loads the original signing plan and verifies
every planned target with strict
`codesign`, confirms the Developer ID authority, team id, timestamp, and
hardened-runtime flag, compares each target's embedded entitlements with the
exact expected policy. For the CLI it requires current candidate and inventory
digests to equal the notarized state. For desktop it chains the notarized state
through the exact stapling-delta receipt to the current inventory. It also binds
current code-directory hashes to the accepted notarization receipt, runs `spctl
--assess --type execute` against the CLI or app, and requires
`source=Notarized Developer ID`. The desktop additionally runs `stapler
validate`. Its bounded
`quotabot.macos-signature-verification.v1` receipt records inventory and plan
digests, entitlements and code-directory digests, target count, notarization
submission id, Gatekeeper source, and whether a staple was required and valid.

The signer deletes the P12, P8, raw notarization files, submission archive, and
temporary keychain on success or failure. Packaging, attestation, upload, and
fresh-download verification receive no Apple credentials. They revalidate the
post-signing inventory and accepted notarization receipt before publication.
Release preflight captures one validated native signing policy for the entire
run, including the Windows subscriber EKU and the macOS identity, team, and
notary identifiers when their signing modes are active. Inactive policy fields
are cleared instead of forwarded. Final audit requires the signed Windows and macOS archive digests and mode
records emitted by fresh native verification to match the assets immediately
before their immutable asset manifest is approved for publication. A
missing credential, changed candidate or plan, signature failure, non-accepted
or unbound notarization result, unexpected signing or stapling delta,
entitlements mismatch, missing desktop staple, Gatekeeper rejection, or invalid
receipt fails closed and leaves the release unpublished. Linux remains outside
the current platform-signing scope.

Owner provisioning and activation details for the protected environment, Entra
federated subject, profile-scoped role, durable subscriber EKU, and transition
mode are in [RELEASE-SIGNING.md](RELEASE-SIGNING.md).

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
6. For a release that changes provider-ID continuity, require the ordinary
   three-OS collector suite to exercise a synthetic alias without adding one to
   the shipped map. The matrix must cover a released older writer, coordinator
   contention, killed-process recovery at prepared, target, and receipt
   boundaries, malformed roots, records, targets, and receipts, bounded partial
   resume, filename limits, and cache reads that fail closed after a late
   retired write.
7. Before tagging, repeat the package and execution smoke on each claimed native
   host. Retain the bounded readiness report, then complete the Narrator,
   keyboard-only focus-order, visible-focus, launcher, and tray checks that it
   does not prove. Complete equivalent native interactive checks on macOS and
   Linux. Record an unavailable cell explicitly rather than treating a
   shared-code test as native evidence.
8. Verify the official repository still has the active `v*` tag ruleset that
   blocks updates and deletion, plus GitHub release immutability. Immutability
   applies only to releases published after the setting was enabled on July 18,
   2026. v0.9.4 and later releases are locked under that policy; v0.9.2 and
   earlier releases were not changed retroactively.
9. Push an annotated `vX.Y.Z` or `vX.Y.Z-rc.N` tag. Wait for every `Release` workflow job,
   including its reusable CI quality gate, four CLI builds, four clean CLI
   execution legs, three desktop builds, and three clean desktop
   archive-verification legs, to pass.
10. Confirm that every CLI archive contains `lib/install.ps1` and
   `lib/install.sh`, so `quotabot update` uses an installer authenticated by the
   archive checksum and provenance rather than a mutable branch copy.
11. Confirm that a stable tag is published as neither draft nor prerelease, or
   that an RC tag is published as a prerelease and does not replace the latest
   stable release. Confirm it is marked immutable and has
   these CLI archive and `.sha256` sidecar pairs:
   `quotabot-windows-x64.zip`, `quotabot-darwin-arm64.tar.gz`,
   `quotabot-linux-x64.tar.gz`, and `quotabot-linux-arm64.tar.gz`.
   Confirm the three desktop pairs are also present:
   `quotabot-windows-x64-desktop.zip`,
   `quotabot-darwin-arm64-desktop.zip`, and
   `quotabot-linux-x64-desktop.tar.gz`.
12. Download every archive, compare it with its SHA-256 sidecar, and verify its
    exact repository provenance. Resolve the protected tag commit, then require
    the release workflow, exact tag, exact commit, and GitHub-hosted runner:

    ```bash
    tag=vX.Y.Z  # or the exact vX.Y.Z-rc.N tag
    source_digest="$(git rev-parse "$tag^{commit}")"
    gh attestation verify <archive> \
      --repo blisspixel/quotabot \
      --signer-workflow blisspixel/quotabot/.github/workflows/release.yml \
      --source-ref "refs/tags/$tag" \
      --source-digest "$source_digest" \
      --deny-self-hosted-runners
    ```

    The release workflow creates the attestation before uploading each pair.
13. After publication, dispatch `Install smoke` immediately. For an RC, set the
    `target_tag` input to the exact `vX.Y.Z-rc.N` tag; leaving it blank resolves
    the latest stable release instead. Require the clean install, prior-version
    upgrade, persistent-state, and source-setup matrix to pass on Windows,
    macOS, and Linux.
14. Confirm GitHub security signals are clear: CI, CodeQL, secret scanning,
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

The current tagged rehearsal baseline is the immutable
[v0.10.1 release](https://github.com/blisspixel/quotabot/releases/tag/v0.10.1)
with its exact 14-asset set. The native
[candidate release run](https://github.com/blisspixel/quotabot/actions/runs/33557788567)
builds, checksums, shape-checks, attests, freshly downloads, and reverifies every
archive before publication. The separate
[published install smoke](https://github.com/blisspixel/quotabot/actions/runs/33562140830)
then covers exact-tag installation and self-update, upgrade from the actual prior
stable, persistent state, source setup, and desktop run checks on Windows,
macOS, and Ubuntu. Stable publication binds GitHub Latest and its follow-up
smoke repeats canonical unversioned acquisition. Stable 0.10.1 promotes the
exact provider-ID continuity candidate after that lifecycle passed. The
[stable v0.10.0 release](https://github.com/blisspixel/quotabot/releases/tag/v0.10.0),
the earlier
[v0.9.9 release](https://github.com/blisspixel/quotabot/releases/tag/v0.9.9)
and
[0.10.0-rc.12 install smoke](https://github.com/blisspixel/quotabot/actions/runs/33312529854)
remain the preceding acquisition records. All used unsigned Windows and macOS
artifacts.
The complete checklist, successful protected signing rehearsals, signed
fresh-download verification, and interactive evidence must run again on the
signed 0.10.x rehearsal and exact 1.0 candidate.

## Icon and dev launcher

The application icon (`app/windows/runner/resources/app_icon.ico` on Windows,
`tools/quotabot.png` on Linux, sourced from `tools/quotabot-icon-1024.png`) is a
custom monochrome rune-style logo, distinct from the in-app pool gauge and "Quota"
wordmark. During development, `tools/local-setup.ps1` installs a `quotabot-gui`
command that launches from source with a deep clean and a visible console.

On Windows, OneDrive-synced folders can cause flaky builds (file locks on
generated directories); move the project outside OneDrive for reliable builds.
