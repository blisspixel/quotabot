<# 
.SYNOPSIS
    One-command installer for the quotabot CLI on Windows.

.DESCRIPTION
    Downloads the latest Windows CLI release asset from GitHub.
    Requires and verifies the release asset's .sha256 sidecar.
    Set QUOTABOT_VERSION to an exact vMAJOR.MINOR.PATCH tag for rollback.

.EXAMPLE
    # From PowerShell (run as normal user):
    irm https://raw.githubusercontent.com/blisspixel/quotabot/main/install.ps1 | iex
#>

$ErrorActionPreference = 'Stop'

Write-Host "=== quotabot installer ==="

function Install-QuotabotPayload {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    $transaction = [guid]::NewGuid().ToString('N')
    $binDst = Join-Path $InstallRoot 'bin'
    $libDst = Join-Path $InstallRoot 'lib'
    $versionsRoot = Join-Path $InstallRoot 'cli-versions'
    $stagedPayload = Join-Path $InstallRoot ".quotabot-payload-new-$transaction"
    $versionRoot = Join-Path $versionsRoot $transaction
    $versionBin = Join-Path $versionRoot 'bin'
    $versionLib = Join-Path $versionRoot 'lib'
    $stagedBinLink = Join-Path $InstallRoot ".quotabot-bin-link-new-$transaction"
    $stagedLibLink = Join-Path $InstallRoot ".quotabot-lib-link-new-$transaction"
    $backupBin = Join-Path $InstallRoot ".quotabot-bin-previous-$transaction"
    $backupLib = Join-Path $InstallRoot ".quotabot-lib-previous-$transaction"
    $binBackedUp = $false
    $libBackedUp = $false
    $binActivated = $false
    $libActivated = $false
    $versionStaged = $false
    $activationSucceeded = $false
    $rollbackComplete = $false
    $lockPath = Join-Path $InstallRoot '.quotabot-install.lock'
    $installLock = $null

    try {
        try {
            $installLock = [IO.File]::Open(
                $lockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        } catch {
            throw 'Another quotabot install is already activating a bundle. Re-run after it finishes.'
        }

        if (Test-Path -LiteralPath $versionsRoot) {
            $versionsItem = Get-Item -LiteralPath $versionsRoot -Force
            if ($versionsItem.LinkType) {
                throw "Refusing to use a link as the CLI generation directory: $versionsRoot"
            }
        } else {
            New-Item -ItemType Directory -Path $versionsRoot | Out-Null
        }
        New-Item -ItemType Directory -Force -Path $stagedPayload | Out-Null
        Copy-Item -LiteralPath (Join-Path $SourceRoot 'bin') -Destination $stagedPayload -Recurse
        Copy-Item -LiteralPath (Join-Path $SourceRoot 'lib') -Destination $stagedPayload -Recurse
        if (-not (Test-Path -LiteralPath (Join-Path $stagedPayload 'bin\quotabot.exe') -PathType Leaf)) {
            throw 'Staged payload is missing bin\quotabot.exe'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $stagedPayload 'lib\sqlite3.dll') -PathType Leaf)) {
            throw 'Staged payload is missing lib\sqlite3.dll'
        }
        Move-Item -LiteralPath $stagedPayload -Destination $versionRoot
        $versionStaged = $true
        # Dart resolves native assets through the final target of the bin
        # junction. Each invocation therefore sees the executable and sibling
        # lib directory from one complete generation, even while the
        # compatibility lib junction is being aligned.
        New-Item -ItemType Junction -Path $stagedBinLink -Target $versionBin | Out-Null
        New-Item -ItemType Junction -Path $stagedLibLink -Target $versionLib | Out-Null

        if (Test-Path -LiteralPath $binDst) {
            Move-Item -LiteralPath $binDst -Destination $backupBin
            $binBackedUp = $true
        }
        Move-Item -LiteralPath $stagedBinLink -Destination $binDst
        $binActivated = $true
        if (Test-Path -LiteralPath $libDst) {
            Move-Item -LiteralPath $libDst -Destination $backupLib
            $libBackedUp = $true
        }
        Move-Item -LiteralPath $stagedLibLink -Destination $libDst
        $libActivated = $true
        $activationSucceeded = $true
    } catch {
        $installError = $_.Exception.Message
        try {
            if ($binActivated -and (Test-Path -LiteralPath $binDst)) {
                Remove-Item -LiteralPath $binDst -Force
            }
            if ($libActivated -and (Test-Path -LiteralPath $libDst)) {
                Remove-Item -LiteralPath $libDst -Force
            }
            if ($binBackedUp -and (Test-Path -LiteralPath $backupBin)) {
                Move-Item -LiteralPath $backupBin -Destination $binDst
                $binBackedUp = $false
            }
            if ($libBackedUp -and (Test-Path -LiteralPath $backupLib)) {
                Move-Item -LiteralPath $backupLib -Destination $libDst
                $libBackedUp = $false
            }
            $rollbackComplete = $true
        } catch {
            throw "Install failed and rollback was incomplete. Recovery payloads remain under $InstallRoot. Original error: $installError. Rollback error: $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $stagedBinLink -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stagedLibLink -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stagedPayload -Recurse -Force -ErrorAction SilentlyContinue
            if ($rollbackComplete -and $versionStaged -and (Test-Path -LiteralPath $versionRoot)) {
                Remove-Item -LiteralPath $versionRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        throw "Could not replace the existing install; it was left intact or restored. Close any running quotabot process and re-run. ($installError)"
    } finally {
        if ($installLock) {
            if ($activationSucceeded) {
                foreach ($candidate in Get-ChildItem -LiteralPath $versionsRoot -Directory -Force -ErrorAction SilentlyContinue) {
                    if ($candidate.FullName -ine $versionRoot) {
                        if ($candidate.LinkType -or $candidate.Name -notmatch '^[0-9a-f]{32}$') {
                            Write-Warning "Skipping an unexpected entry under the CLI generation directory: $($candidate.FullName)"
                            continue
                        }
                        try {
                            $candidateExe = Join-Path $candidate.FullName 'bin\quotabot.exe'
                            if (Test-Path -LiteralPath $candidateExe -PathType Leaf) {
                                $exclusiveExe = [IO.File]::Open(
                                    $candidateExe,
                                    [IO.FileMode]::Open,
                                    [IO.FileAccess]::ReadWrite,
                                    [IO.FileShare]::None
                                )
                                $exclusiveExe.Dispose()
                            }
                            Remove-Item -LiteralPath $candidate.FullName -Recurse -Force
                        } catch {
                            Write-Warning "The old CLI generation is still in use and could not be removed: $($candidate.FullName)"
                        }
                    }
                }
            }
            $installLock.Dispose()
        }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }

    foreach ($backup in @($backupBin, $backupLib)) {
        if (Test-Path -LiteralPath $backup) {
            try {
                $backupItem = Get-Item -LiteralPath $backup -Force
                if ($backupItem.LinkType) {
                    Remove-Item -LiteralPath $backup -Force
                } else {
                    Remove-Item -LiteralPath $backup -Recurse -Force
                }
            } catch {
                Write-Warning "The new install is active, but the previous payload could not be removed: $backup"
            }
        }
    }
}

$repo = if ($env:QUOTABOT_REPO) { $env:QUOTABOT_REPO } else { "blisspixel/quotabot" }
$version = if ($env:QUOTABOT_VERSION) { $env:QUOTABOT_VERSION } else { 'latest' }
if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    Write-Error "Invalid QUOTABOT_REPO value. Expected owner/repo."
    exit 1
}
if ($version -ne 'latest' -and $version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
    Write-Error "Invalid QUOTABOT_VERSION value. Expected vMAJOR.MINOR.PATCH."
    exit 1
}
$installRoot = "$env:LOCALAPPDATA\quotabot"
$installDir = Join-Path $installRoot "bin"
$assetName = "quotabot-windows-x64.zip"
$workPath = Join-Path ([IO.Path]::GetTempPath()) "quotabot-install-$([guid]::NewGuid())"
$downloadPath = Join-Path $workPath "$assetName.download"
$checksumPath = Join-Path $workPath "$assetName.sha256"
$extractPath = Join-Path $workPath 'expanded'

Write-Host "Installing quotabot CLI for Windows (via prebuilt bundle)..."

# Ensure install root exists.
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null

# Download the latest release by default, or one validated exact tag for a
# reproducible rollback.
$downloadUrl = if ($version -eq 'latest') {
    "https://github.com/$repo/releases/latest/download/$assetName"
} else {
    "https://github.com/$repo/releases/download/$version/$assetName"
}

try {
    New-Item -ItemType Directory -Force -Path $workPath | Out-Null
    Write-Host "Downloading $assetName from $version"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadPath -UseBasicParsing
    $checksumUrl = "$downloadUrl.sha256"
    # A release without a valid checksum sidecar is incomplete. Fail closed
    # instead of silently degrading a security boundary in the convenience
    # installer.
    Invoke-WebRequest -Uri $checksumUrl -OutFile $checksumPath -UseBasicParsing
    try {
        $expected = ((Get-Content $checksumPath -Raw) -split '\s+')[0].ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$') {
            throw "Invalid checksum file for $assetName"
        }
        $actual = (Get-FileHash -Algorithm SHA256 $downloadPath).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "Checksum mismatch for $assetName"
        }
    } finally {
        Remove-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    }
    Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractPath -Force
    $downloadedExe = Join-Path $extractPath "bin\quotabot.exe"
    $downloadedSqlite = Join-Path $extractPath "lib\sqlite3.dll"
    if (-not (Test-Path -LiteralPath $downloadedExe)) {
        throw "Downloaded archive did not contain bin\quotabot.exe"
    }
    if (-not (Test-Path -LiteralPath $downloadedSqlite)) {
        throw "Downloaded archive did not contain lib\sqlite3.dll"
    }
    Install-QuotabotPayload -SourceRoot $extractPath -InstallRoot $installRoot
    Write-Host "Installed to $installRoot"
} catch {
    Write-Error "Install failed: $($_.Exception.Message). Make sure the release publishes '$assetName' and its required .sha256 sidecar at https://github.com/$repo/releases"
    exit 1
} finally {
    Remove-Item -LiteralPath $workPath -Recurse -Force -ErrorAction SilentlyContinue
}

# Add to user PATH if necessary
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$userPaths = @($userPath -split ';' | Where-Object { $_ })
if ($userPaths -notcontains $installDir) {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
    Write-Host ""
    Write-Host "Added $installDir to your user PATH."
    Write-Host "Restart your terminal (or run the following) for the change to take effect:"
    Write-Host '  $env:Path = [Environment]::GetEnvironmentVariable("Path", "User")'
}

Write-Host ""
Write-Host "quotabot installed (exe in PATH)."
Write-Host "Tip: For local/dev without any CLI exe, run local-setup.ps1 instead."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  quotabot doctor"
Write-Host "  quotabot login grok"
Write-Host "  quotabot login antigravity  # optional, keeps Antigravity live"
Write-Host ""
Write-Host "To uninstall without deleting local history, grants, or profiles, see:"
Write-Host "  https://github.com/$repo/blob/main/docs/SETUP.md#uninstall-the-release-cli-but-preserve-data"
