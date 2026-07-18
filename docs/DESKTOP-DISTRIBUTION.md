# Desktop release bundles

Tagged releases built from the current release workflow attach one native,
portable desktop bundle and one SHA-256 sidecar for each supported desktop OS:

| OS | Asset |
|---|---|
| Windows x64 | `quotabot-windows-x64-desktop.zip` |
| macOS Apple Silicon | `quotabot-darwin-arm64-desktop.zip` |
| Linux x64 | `quotabot-linux-x64-desktop.tar.gz` |

Each archive is built on its native GitHub-hosted runner, checked for the
expected Flutter bundle shape, checksum-verified, and given a GitHub build
provenance attestation before the draft release can be published. The release
stays a draft if any CLI or desktop build, clean-host lifecycle check, readiness
check, attestation, or upload fails. The lifecycle check installs two versioned
copies, launches the Windows and Linux copies, exercises rollback, removes both
application directories, and proves a persistent-state sentinel remains. A final
asset audit rejects a draft with any missing, duplicate, or unexpected file,
then downloads every CLI and desktop asset again and reverifies every checksum
and provenance attestation immediately before publication.

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

For signed build provenance, install the GitHub CLI and verify the same archive
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

Windows packages are not Authenticode-signed yet, so SmartScreen may warn. Do
not bypass a warning until both checksum and attestation verification succeed.

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

The macOS bundle is not Developer ID-signed or notarized yet. Gatekeeper may
refuse a normal launch. Do not remove quarantine metadata merely to silence that
warning. A signed, notarized bundle remains a 1.0 release gate.

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

To uninstall while preserving data, close quotabot and remove only the extracted
desktop directory or `quotabot.app`. The CLI install is separate. Follow
[SETUP.md](SETUP.md#update-uninstall-and-rollback) only if the CLI should also be
removed. Deleting quotabot's local metadata is a separate destructive action and
is never required for an update, rollback, or normal uninstall.

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

Clean native release jobs download the draft assets by release asset id,
reverify checksum and provenance, and exercise side-by-side update, rollback,
and data-preserving uninstall mechanics. Windows and Linux also require the
native window and tray readiness contract to pass. macOS hosted runners build,
extract, and validate the app archive, but the final interactive launch, status
item, signing, notarization, and accessibility evidence must come from a native
interactive release host.
