# Desktop release bundles

Tagged releases built from the current release workflow attach one native,
portable desktop bundle and one SHA-256 sidecar for each supported desktop OS:

| OS | Asset |
|---|---|
| Windows x64 | `quotabot-windows-x64-desktop.zip` |
| macOS Apple Silicon | `quotabot-darwin-arm64-desktop.zip` |
| Linux x64 | `quotabot-linux-x64-desktop.tar.gz` |

Each archive is built on its native GitHub-hosted runner, checked for its
expected Flutter bundle shape and checksum, and given restricted GitHub workflow
provenance. CI verifies native CLI and desktop archives and preserves an attested
handoff. It creates no GitHub draft or release and holds no owner token.

The owner runs `tools/publish_release.py` from the exact clean tagged source.
That helper checks the successful workflow, current protected main and tag,
attested handoff, provenance, and exact fourteen-file inventory before creating
a draft. It uploads through the same owner login, freshly downloads and verifies
every draft asset, then publishes immutably. Failed build or verification gates
prevent publication; a failed owner attempt leaves its draft unpublished.

The Windows candidate check isolates configuration and singleton state, binds a
structured v3 pass or failure report to the launched process and complete-bundle
digest, verifies unchanged bytes after cleanup, preserves bounded failure
evidence, and leaves an installed tray instance untouched. Native lifecycle
checks exercise versioned copies, rollback, removal, and persistent-state
preservation before publication. Published install smoke repeats acquisition on
all three platforms and Windows/Linux startup against the immutable release.

The official repository's active tag rules block updates and deletion of `v*`
tags. Owner drafts remain writable during upload and fresh-download verification.
GitHub release immutability locks the associated tag and assets at publication.
Immutability applies prospectively to releases published after
it was enabled on July 18, 2026. v0.9.4 and later releases are locked under that
policy; v0.9.2 and earlier releases were not changed retroactively.

The current verified [0.11.11 release](https://github.com/blisspixel/quotabot/releases/tag/v0.11.11)
contains all three desktop archive/checksum pairs inside the exact fourteen-asset
set. Its [Release workflow](https://github.com/blisspixel/quotabot/actions/runs/38155116920) and
[published Install smoke](https://github.com/blisspixel/quotabot/actions/runs/38159387701) passed.
The unpinned Latest smoke covers clean installation, upgrade from 0.11.8,
persistent state, source setup, and stable-channel resolution on Windows, macOS,
and Linux. Desktop checks cover Windows/Linux startup and the macOS bundle.
Application signing and notarization remain pre-1.0 native trust gates.
Interactive native accessibility evidence remains a separate final 1.0 gate
and must run again on the exact signed candidate.

The bundles are portable applications, not system installers. They do not
replace the separately installed `quotabot` CLI and do not move or delete local
quota metadata.

## Verify before opening

Set the exact release tag and asset name for your platform, then download both
files. Using an exact tag makes update and rollback reproducible.

macOS or Linux:

```bash
tag=vX.Y.Z
asset=quotabot-linux-x64-desktop.tar.gz # use the darwin ZIP on macOS
gh release download "$tag" --repo blisspixel/quotabot \
  --pattern "$asset" --pattern "$asset.sha256"
```

Windows PowerShell:

```powershell
$tag = 'vX.Y.Z'
$asset = 'quotabot-windows-x64-desktop.zip'
gh release download $tag --repo blisspixel/quotabot `
  --pattern $asset --pattern "$asset.sha256"
```

Verify the sidecar against the archive:

```bash
# Linux
sha256sum --check "$asset.sha256"

# macOS
shasum -a 256 --check "$asset.sha256"
```

```powershell
$fields = (Get-Content -LiteralPath "$asset.sha256" -Raw).Trim() -split '\s+'
if ($fields.Count -ne 2 -or $fields[1] -ne $asset) {
  throw 'Desktop checksum sidecar names an unexpected archive.'
}
$expected = $fields[0]
$actual = (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw 'Desktop archive checksum mismatch.' }
```

For GitHub build provenance, install the GitHub CLI and verify the same archive
against the repository and tag workflow:

```bash
gh attestation verify "$asset" \
  --repo blisspixel/quotabot \
  --signer-workflow blisspixel/quotabot/.github/workflows/release.yml \
  --source-ref "refs/tags/$tag" \
  --deny-self-hosted-runners
```

```powershell
gh attestation verify $asset `
  --repo blisspixel/quotabot `
  --signer-workflow blisspixel/quotabot/.github/workflows/release.yml `
  --source-ref "refs/tags/$tag" `
  --deny-self-hosted-runners
```

The attestation proves which repository workflow built the archive. It is
separate from operating-system application signing.

## Run the portable desktop app

### Windows

Expand the archive into a versioned directory and run `quotabot.exe` from that
directory. Keep the adjacent `data` directory and DLL files with the executable.

```powershell
$destination = Join-Path $env:LOCALAPPDATA "quotabot-desktop\$tag"
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Expand-Archive -LiteralPath $asset -DestinationPath $destination
Start-Process (Join-Path $destination 'quotabot.exe')
```

Current Windows packages use unsigned transition mode. Each
release begins with a mandatory native signing status in its GitHub release
notes. `Windows: unsigned transition artifact` means SmartScreen publisher
identity is not established. Checksums and GitHub provenance do not establish
Windows publisher identity. Both remain required. Do not bypass SmartScreen. A
release marked as Azure Artifact Signing
must pass Windows trust, SHA-256 Authenticode and RFC 3161 policy, durable
subscriber identity, and fresh-download verification before publication.

### macOS

Expand the ZIP, place a versioned copy in your per-user Applications directory,
and open it through Finder or LaunchServices:

```bash
mkdir -p "$HOME/Applications"
tmp="$(mktemp -d)"
ditto -x -k "$asset" "$tmp"
destination="$HOME/Applications/quotabot-$tag.app"
ditto "$tmp/quotabot.app" "$destination"
rm -rf "$tmp"
open "$destination"
```

The release notes also state the macOS signing mode. Current transition bundles
are not Developer ID-signed or notarized, so Gatekeeper may refuse a normal
launch. Do not remove quarantine metadata merely to silence that warning. A
signed, notarized bundle remains a pre-1.0 completion criterion.

### Linux

Extract into a versioned per-user directory and launch the bundled executable:

```bash
destination="$HOME/.local/share/quotabot-desktop/$tag"
mkdir -p "$destination"
tar -xzf "$asset" -C "$destination"
"$destination/quotabot"
```

The portable bundle requires the normal GTK desktop runtime libraries. The
release build itself is produced and readiness-tested on Ubuntu. Other Linux
distributions may need equivalent GTK, AppIndicator, and system tray packages.

## Update, rollback, and uninstall

Updates install safely beside the previous version:

1. Download the new tag into a new versioned directory.
2. Verify its checksum and attestation.
3. Close the running desktop app and launch the new bundle.
4. Keep the prior directory until the new version has completed a refresh.

Rollback means closing the current app and launching the previously verified
version. The app stores profiles, history, preferences, leases, grants, and
cache outside these portable bundle directories, so switching binaries does not
erase that metadata.

To uninstall a source or release-installer copy while preserving data, run the
uninstall scripts in the repository root (`uninstall.ps1` for Windows,
`uninstall.sh` for macOS/Linux). Those scripts remove the managed CLI and the
managed desktop locations (`%LOCALAPPDATA%\quotabot\desktop`,
`~/Applications/quotabot.app`, `~/.local/share/quotabot-desktop`). They do not
delete a versioned portable extract such as
`%LOCALAPPDATA%\quotabot-desktop\<tag>` or `~/Applications/quotabot-<tag>.app`.
Remove that directory yourself after closing the app. Follow
[SETUP.md](SETUP.md#update-uninstall-and-rollback) for the one-line remote
execution commands. Deleting quotabot's local metadata is a separate destructive
action (`--purge`) and is never required for an update, rollback, or normal
uninstall.

## Maintainer verification

The platform package helpers write the same public assets locally:

```powershell
pwsh tools/package-windows.ps1
```

```bash
bash tools/package-macos.sh
bash tools/package-linux.sh
```

Validate the archive and sidecar before upload:

```bash
python tools/verify_desktop_archive.py release/quotabot-<os>-<arch>-desktop.<ext>
```

Clean native release jobs download exact workflow archive artifacts,
reverify checksum and provenance, and exercise side-by-side update, rollback,
and data-preserving uninstall mechanics. Windows and Linux also require the
native window and tray readiness contract to pass. The bounded v3 report records
pass or failure status and stage, a UTC timestamp, launch PID, narrow runner
digest, complete-bundle digest and aggregate counts, prelaunch/post-cleanup
stability, isolated-config state, readiness, and cleanup. Unreached checks are
null and failure evidence contains no raw errors, logs, or filesystem paths.
Archive checksum and provenance remain separately verified, and the
report is not signing or accessibility evidence. macOS hosted runners build,
extract, and validate the app archive, but the final
interactive launch, status item, signing, notarization, and accessibility
evidence must come from a native interactive release host.
