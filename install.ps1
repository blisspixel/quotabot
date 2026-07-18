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
    $stagedBin = Join-Path $InstallRoot ".quotabot-bin-new-$transaction"
    $stagedLib = Join-Path $InstallRoot ".quotabot-lib-new-$transaction"
    $backupBin = Join-Path $InstallRoot ".quotabot-bin-previous-$transaction"
    $backupLib = Join-Path $InstallRoot ".quotabot-lib-previous-$transaction"
    $binBackedUp = $false
    $libBackedUp = $false
    $binInstalled = $false
    $libInstalled = $false
    $lockPath = Join-Path $InstallRoot '.quotabot-install.lock'
    $installLock = $null

    try {
        Copy-Item -LiteralPath (Join-Path $SourceRoot 'bin') -Destination $stagedBin -Recurse
        Copy-Item -LiteralPath (Join-Path $SourceRoot 'lib') -Destination $stagedLib -Recurse
        if (-not (Test-Path -LiteralPath (Join-Path $stagedBin 'quotabot.exe') -PathType Leaf)) {
            throw 'Staged payload is missing bin\quotabot.exe'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $stagedLib 'sqlite3.dll') -PathType Leaf)) {
            throw 'Staged payload is missing lib\sqlite3.dll'
        }
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

        if (Test-Path -LiteralPath $binDst) {
            Move-Item -LiteralPath $binDst -Destination $backupBin
            $binBackedUp = $true
        }
        if (Test-Path -LiteralPath $libDst) {
            Move-Item -LiteralPath $libDst -Destination $backupLib
            $libBackedUp = $true
        }
        Move-Item -LiteralPath $stagedBin -Destination $binDst
        $binInstalled = $true
        Move-Item -LiteralPath $stagedLib -Destination $libDst
        $libInstalled = $true
    } catch {
        $installError = $_.Exception.Message
        try {
            if ($binInstalled -and (Test-Path -LiteralPath $binDst)) {
                Remove-Item -LiteralPath $binDst -Recurse -Force
            }
            if ($libInstalled -and (Test-Path -LiteralPath $libDst)) {
                Remove-Item -LiteralPath $libDst -Recurse -Force
            }
            if ($binBackedUp -and (Test-Path -LiteralPath $backupBin)) {
                Move-Item -LiteralPath $backupBin -Destination $binDst
                $binBackedUp = $false
            }
            if ($libBackedUp -and (Test-Path -LiteralPath $backupLib)) {
                Move-Item -LiteralPath $backupLib -Destination $libDst
                $libBackedUp = $false
            }
        } catch {
            throw "Install failed and rollback was incomplete. Recovery payloads remain under $InstallRoot. Original error: $installError. Rollback error: $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $stagedBin -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stagedLib -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw "Could not replace the existing install; it was left intact or restored. Close any running quotabot process and re-run. ($installError)"
    } finally {
        if ($installLock) {
            $installLock.Dispose()
        }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }

    foreach ($backup in @($backupBin, $backupLib)) {
        if (Test-Path -LiteralPath $backup) {
            try {
                Remove-Item -LiteralPath $backup -Recurse -Force
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
