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
    # Only the checksum download itself is allowed to fail (asset genuinely
    # absent). Once the sidecar is present, every parse and hash step is fatal
    # on failure, so a lock, IO error, or malformed file cannot be misread as
    # "no checksum" and let an unverified bundle install.
    $checksumFound = $true
    try {
        Invoke-WebRequest -Uri $checksumUrl -OutFile $checksumPath -UseBasicParsing
    } catch {
        $checksumFound = $false
        Write-Host "No checksum asset found at $checksumUrl; continuing with HTTPS verification only."
    }
    if ($checksumFound) {
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
    Remove-Item -LiteralPath (Join-Path $installRoot "bin") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $installRoot "lib") -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $extractPath "bin") -Destination $installRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $extractPath "lib") -Destination $installRoot -Recurse
    Write-Host "Installed to $installRoot"
} catch {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Error "Download failed: $($_.Exception.Message). Make sure a release with '$assetName' exists at https://github.com/$repo/releases"
    exit 1
} finally {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
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
Write-Host "To uninstall, delete the folder:"
Write-Host "  Remove-Item -Recurse -Force '$installRoot'"
