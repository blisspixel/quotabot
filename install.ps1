<# 
.SYNOPSIS
    One-command installer for the quotabot CLI on Windows.

.DESCRIPTION
    Downloads the latest Windows CLI release asset from GitHub.
    If the release publishes a .sha256 sidecar, the installer verifies it.

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
$installDir = "$env:LOCALAPPDATA\quotabot\bin"
$assetName = "quotabot-windows-x64.exe"
$exePath = Join-Path $installDir "quotabot.exe"
$downloadPath = Join-Path $installDir "$assetName.download"
$checksumPath = Join-Path $installDir "$assetName.sha256"

Write-Host "Installing quotabot CLI for Windows (via prebuilt exe)..."

# Ensure install directory exists
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# Download URL (GitHub latest release)
$downloadUrl = "https://github.com/$repo/releases/latest/download/$assetName"

try {
    Write-Host "Downloading $downloadUrl"
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadPath -UseBasicParsing
    $checksumUrl = "$downloadUrl.sha256"
    try {
        Invoke-WebRequest -Uri $checksumUrl -OutFile $checksumPath -UseBasicParsing
        $expected = ((Get-Content $checksumPath -Raw) -split '\s+')[0].ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$') {
            throw "Invalid checksum file for $assetName"
        }
        $actual = (Get-FileHash -Algorithm SHA256 $downloadPath).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "Checksum mismatch for $assetName"
        }
    } catch {
        if ($_.Exception.Message -like '*Checksum mismatch*' -or $_.Exception.Message -like '*Invalid checksum*') { throw }
        Write-Host "No checksum asset found at $checksumUrl; continuing with HTTPS verification only."
    } finally {
        Remove-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $downloadPath -Destination $exePath -Force
    Write-Host "Downloaded to $exePath"
} catch {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Write-Error "Download failed: $($_.Exception.Message). Make sure a release with '$assetName' exists at https://github.com/$repo/releases"
    exit 1
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
Write-Host "To uninstall, delete the folder:"
Write-Host "  Remove-Item -Recurse -Force '$installDir'"
