<# 
.SYNOPSIS
    One-command installer for the quotabot CLI on Windows.

.DESCRIPTION
    Downloads the latest Windows CLI release asset from GitHub.
    Requires and verifies the release asset's .sha256 sidecar.

.EXAMPLE
    # From PowerShell (run as normal user):
    irm https://raw.githubusercontent.com/blisspixel/quotabot/main/install.ps1 | iex
#>

$ErrorActionPreference = 'Stop'

Write-Host "=== quotabot installer ==="

$repo = if ($env:QUOTABOT_REPO) { $env:QUOTABOT_REPO } else { "blisspixel/quotabot" }
if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    Write-Error "Invalid QUOTABOT_REPO value. Expected owner/repo."
    exit 1
}
$installRoot = "$env:LOCALAPPDATA\quotabot"
$installDir = Join-Path $installRoot "bin"
$assetName = "quotabot-windows-x64.zip"
$downloadPath = Join-Path $env:TEMP "$assetName.download"
$checksumPath = Join-Path $env:TEMP "$assetName.sha256"
$extractPath = Join-Path $env:TEMP "quotabot-install-$([guid]::NewGuid())"

Write-Host "Installing quotabot CLI for Windows (via prebuilt bundle)..."

# Ensure install root exists.
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null

# Download URL (GitHub latest release)
$downloadUrl = "https://github.com/$repo/releases/latest/download/$assetName"

try {
    Write-Host "Downloading $downloadUrl"
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
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
    # Replace the old install. Do NOT swallow a removal failure: if a running
    # quotabot holds the exe open, a silenced Remove-Item would leave the old
    # bin/ in place and Copy-Item would nest the new bundle at bin\bin, so PATH
    # would keep resolving the stale binary while the installer reports success.
    $binDst = Join-Path $installRoot "bin"
    $libDst = Join-Path $installRoot "lib"
    try {
        if (Test-Path -LiteralPath $binDst) { Remove-Item -LiteralPath $binDst -Recurse -Force }
        if (Test-Path -LiteralPath $libDst) { Remove-Item -LiteralPath $libDst -Recurse -Force }
    } catch {
        throw "Could not replace the existing install. Close any running quotabot (for example 'quotabot top' or the MCP server) and re-run. ($($_.Exception.Message))"
    }
    Copy-Item -LiteralPath (Join-Path $extractPath "bin") -Destination $installRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $extractPath "lib") -Destination $installRoot -Recurse
    Write-Host "Installed to $installRoot"
} catch {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Error "Install failed: $($_.Exception.Message). Make sure the release publishes '$assetName' and its required .sha256 sidecar at https://github.com/$repo/releases"
    exit 1
} finally {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
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
