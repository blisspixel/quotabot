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

function Test-QuotabotArchiveRequiresUpdater {
    param([Parameter(Mandatory)][string]$Version)

    if ($Version -eq 'latest') {
        return $false
    }
    $parsed = [regex]::Match(
        $Version,
        '^v(?<major>[0-9]+)\.(?<minor>[0-9]+)\.(?<patch>[0-9]+)(?:-rc\.(?<rc>[0-9]+))?$'
    )
    if (-not $parsed.Success) {
        throw 'Cannot classify the requested quotabot release version.'
    }
    $major = [int64]$parsed.Groups['major'].Value
    $minor = [int64]$parsed.Groups['minor'].Value
    $patch = [int64]$parsed.Groups['patch'].Value
    if ($major -gt 0 -or $minor -gt 10 -or ($minor -eq 10 -and $patch -gt 0)) {
        return $true
    }
    if ($major -lt 0 -or $minor -lt 10 -or $patch -lt 0) {
        return $false
    }
    if (-not $parsed.Groups['rc'].Success) {
        return $true
    }
    return [int64]$parsed.Groups['rc'].Value -ge 16
}

function Get-QuotabotFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $hasher = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        } finally {
            $hasher.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Stop-ManagedQuotabotDesktopProcesses {
    param([Parameter(Mandatory)][string]$ExePath)

    $resolved = [IO.Path]::GetFullPath($ExePath)
    $stopped = @()
    foreach ($proc in Get-Process -Name quotabot -ErrorAction SilentlyContinue) {
        try {
            if ($proc.Path -and ([IO.Path]::GetFullPath($proc.Path) -ieq $resolved)) {
                Stop-Process -Id $proc.Id -Force
                $stopped += $proc.Id
            }
        } catch {
            # An inaccessible process path belongs to some other quotabot binary.
        }
    }
    foreach ($id in $stopped) {
        try { Wait-Process -Id $id -Timeout 10 } catch {}
    }
    return $stopped.Count -gt 0
}

function Install-ManagedQuotabotDesktop {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    $transaction = [guid]::NewGuid().ToString('N')
    $destination = Join-Path $InstallRoot 'desktop'
    $staged = Join-Path $InstallRoot ".quotabot-desktop-new-$transaction"
    $backup = Join-Path $InstallRoot ".quotabot-desktop-previous-$transaction"
    $lockPath = Join-Path $InstallRoot '.quotabot-desktop-install.lock'
    $installLock = $null
    $backedUp = $false
    $activated = $false

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

        Copy-Item -LiteralPath $SourceRoot -Destination $staged -Recurse
        if (-not (Test-Path -LiteralPath (Join-Path $staged 'quotabot.exe') -PathType Leaf)) {
            throw 'Staged desktop payload is missing quotabot.exe'
        }
        if (Test-Path -LiteralPath $destination) {
            Move-Item -LiteralPath $destination -Destination $backup
            $backedUp = $true
        }
        Move-Item -LiteralPath $staged -Destination $destination
        $activated = $true
        if ($backedUp) { return $backup }
        return $null
    } catch {
        $installError = $_.Exception.Message
        if ($activated -and (Test-Path -LiteralPath $destination)) {
            Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
            $activated = $false
        }
        if ($backedUp -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $destination)) {
            Move-Item -LiteralPath $backup -Destination $destination
            $backedUp = $false
        }
        if (Test-Path -LiteralPath $staged) {
            Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw "Could not replace the managed desktop app; it was left intact or restored. Close it and re-run. ($installError)"
    } finally {
        if ($installLock) { $installLock.Dispose() }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

function Restore-ManagedQuotabotDesktop {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$BackupPath
    )

    $destination = Join-Path $InstallRoot 'desktop'
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    Move-Item -LiteralPath $BackupPath -Destination $destination
}

# portable-desktop-skew: begin
function Read-QuotabotFlutterVersion {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType) { return $null }
    if ($item.Length -lt 1 -or $item.Length -gt 4096) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($item.FullName)
    if ($bytes.Length -gt 4096) { return $null }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $parsed = $text | ConvertFrom-Json
    $version = [string]$parsed.version
    if ([string]::IsNullOrWhiteSpace($version)) { return $null }
    if ($version -match '\+') { $version = ($version -split '\+', 2)[0] }
    if ($version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$') {
        return $null
    }
    return $version
}

function Report-HandExtractedDesktopSkew {
    param(
        [Parameter(Mandatory)][string]$CliVersion,
        [Parameter(Mandatory)][string]$Repository,
        [string]$LocalAppData
    )
    if ($CliVersion -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$') { return }
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) { return }
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { return }
    $asset = 'quotabot-windows-x64-desktop.zip'
    $releases = "https://github.com/$Repository/releases/tag/v$CliVersion"
    $shown = 0
    $matched = 0
    $managedRoot = Join-Path $LocalAppData 'quotabot\desktop'
    $managedExe = Join-Path $managedRoot 'quotabot.exe'
    if (Test-Path -LiteralPath $managedExe -PathType Leaf) {
        $managedVersion = $null
        try {
            $managedVersion = Read-QuotabotFlutterVersion -Path (Join-Path $managedRoot 'data\flutter_assets\version.json')
        } catch {
            $managedVersion = $null
        }
        if ($managedVersion -and $managedVersion -ne $CliVersion) {
            $matched++
            if ($shown -lt 8) {
                $shown++
                Write-Host "Managed desktop $managedVersion at $managedRoot differs from CLI $CliVersion. Run `"quotabot update --force`" to replace that managed install. Download $asset from $releases, verify the .sha256 sidecar, and replace only that managed copy."
            }
        }
    }
    $root = Join-Path $LocalAppData 'quotabot-desktop'
    if (Test-Path -LiteralPath $root -PathType Container) {
        $children = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | Sort-Object FullName)
        $examined = 0
        foreach ($child in $children) {
            if ($examined -ge 32) { break }
            $examined++
            if ($child.LinkType -or -not $child.PSIsContainer) { continue }
            if ($child.Name -notmatch '^[A-Za-z0-9._-]{1,128}$' -or $child.Name.StartsWith('.')) { continue }
            $version = $null
            try {
                $version = Read-QuotabotFlutterVersion -Path (Join-Path $child.FullName 'data\flutter_assets\version.json')
            } catch {
                $version = $null
            }
            if (-not $version -or $version -eq $CliVersion) { continue }
            $matched++
            if ($shown -ge 8) { continue }
            $shown++
            Write-Host "Hand-extracted desktop $version at $($child.FullName) differs from CLI $CliVersion and was left in place. Download $asset from $releases, verify the .sha256 sidecar, extract it into a new directory, quit the old copy, and launch the new executable."
        }
    }
    $omitted = $matched - $shown
    if ($omitted -eq 1) {
        Write-Host "1 more desktop copy differs from CLI $CliVersion and was left in place."
    } elseif ($omitted -gt 1) {
        Write-Host "$omitted more desktop copies differ from CLI $CliVersion and were left in place."
    }
}
# portable-desktop-skew: end

Write-Host "=== quotabot installer ==="

function Install-QuotabotPayload {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [switch]$RequiresPipeBridge
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
        if ($RequiresPipeBridge -and
            -not (Test-Path -LiteralPath (Join-Path $stagedPayload 'lib\quotabot_pipe_input.dll') -PathType Leaf)) {
            throw 'Staged payload is missing lib\quotabot_pipe_input.dll'
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
                $binItem = Get-Item -LiteralPath $binDst -Force
                if ($binItem.LinkType) {
                    Remove-Item -LiteralPath $binDst -Force
                } else {
                    Remove-Item -LiteralPath $binDst -Recurse -Force
                }
            }
            if ($libActivated -and (Test-Path -LiteralPath $libDst)) {
                $libItem = Get-Item -LiteralPath $libDst -Force
                if ($libItem.LinkType) {
                    Remove-Item -LiteralPath $libDst -Force
                } else {
                    Remove-Item -LiteralPath $libDst -Recurse -Force
                }
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
if ($version -ne 'latest' -and $version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$') {
    Write-Error "Invalid QUOTABOT_VERSION value. Expected vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N."
    exit 1
}
$requiresPackagedUpdater = Test-QuotabotArchiveRequiresUpdater -Version $version
$installRoot = "$env:LOCALAPPDATA\quotabot"
$installDir = Join-Path $installRoot "bin"
$assetName = "quotabot-windows-x64.zip"
$workPath = Join-Path ([IO.Path]::GetTempPath()) "quotabot-install-$([guid]::NewGuid())"
$downloadPath = Join-Path $workPath $assetName
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
        $actual = Get-QuotabotFileSha256 -Path $downloadPath
        if ($actual -ne $expected) {
            throw "Checksum mismatch for $assetName"
        }
    } finally {
        Remove-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    }
    Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractPath -Force
    $downloadedExe = Join-Path $extractPath "bin\quotabot.exe"
    $downloadedSqlite = Join-Path $extractPath "lib\sqlite3.dll"
    $downloadedWindowsUpdater = Join-Path $extractPath "lib\install.ps1"
    $downloadedPosixUpdater = Join-Path $extractPath "lib\install.sh"
    if (-not (Test-Path -LiteralPath $downloadedExe)) {
        throw "Downloaded archive did not contain bin\quotabot.exe"
    }
    if (-not (Test-Path -LiteralPath $downloadedSqlite)) {
        throw "Downloaded archive did not contain lib\sqlite3.dll"
    }
    if ($requiresPackagedUpdater -and
        (-not (Test-Path -LiteralPath $downloadedWindowsUpdater -PathType Leaf) -or
         -not (Test-Path -LiteralPath $downloadedPosixUpdater -PathType Leaf))) {
        throw "Downloaded archive did not contain the packaged updater scripts"
    }
    $reportedVersion = (& $downloadedExe --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Downloaded quotabot executable failed its pre-activation version check'
    }
    $expectedVersion = if ($version -eq 'latest') { $null } else { "quotabot $($version.Substring(1))" }
    if (($expectedVersion -and $reportedVersion -cne $expectedVersion) -or
        (-not $expectedVersion -and $reportedVersion -notmatch '^quotabot [0-9]+\.[0-9]+\.[0-9]+(?:-rc\.[0-9]+)?$')) {
        throw "Downloaded quotabot executable reported an unexpected version: $reportedVersion"
    }
    # Use the verified executable version, including for an unpinned latest
    # download. Older rollback payloads legitimately predate this native asset.
    $payloadVersion = [version](($reportedVersion.Substring(9) -split '-')[0])
    $managedDesktopExe = Join-Path $installRoot 'desktop\quotabot.exe'
    $desktopBackup = $null
    $restartDesktop = $false
    if (Test-Path -LiteralPath $managedDesktopExe -PathType Leaf) {
        $desktopAsset = 'quotabot-windows-x64-desktop.zip'
        $desktopDownload = Join-Path $workPath $desktopAsset
        $desktopChecksum = Join-Path $workPath "$desktopAsset.sha256"
        $desktopExtract = Join-Path $workPath 'desktop-expanded'
        $desktopUrl = "https://github.com/$repo/releases/download/v$($reportedVersion.Substring(9))/$desktopAsset"
        Write-Host "Updating the managed desktop app from $version"
        Invoke-WebRequest -Uri $desktopUrl -OutFile $desktopDownload -UseBasicParsing
        Invoke-WebRequest -Uri "$desktopUrl.sha256" -OutFile $desktopChecksum -UseBasicParsing
        try {
            $desktopExpected = ((Get-Content $desktopChecksum -Raw) -split '\s+')[0].ToLowerInvariant()
            if ($desktopExpected -notmatch '^[0-9a-f]{64}$') {
                throw "Invalid checksum file for $desktopAsset"
            }
            $desktopActual = Get-QuotabotFileSha256 -Path $desktopDownload
            if ($desktopActual -ne $desktopExpected) {
                throw "Checksum mismatch for $desktopAsset"
            }
        } finally {
            Remove-Item -LiteralPath $desktopChecksum -Force -ErrorAction SilentlyContinue
        }
        Expand-Archive -LiteralPath $desktopDownload -DestinationPath $desktopExtract -Force
        if (-not (Test-Path -LiteralPath (Join-Path $desktopExtract 'quotabot.exe') -PathType Leaf)) {
            throw 'Downloaded desktop archive did not contain quotabot.exe'
        }
        $restartDesktop = Stop-ManagedQuotabotDesktopProcesses -ExePath $managedDesktopExe
        $desktopBackup = Install-ManagedQuotabotDesktop -SourceRoot $desktopExtract -InstallRoot $installRoot
    }
    try {
        Install-QuotabotPayload -SourceRoot $extractPath -InstallRoot $installRoot `
            -RequiresPipeBridge:($payloadVersion -ge [version]'0.11.13')
    } catch {
        if ($desktopBackup -and (Test-Path -LiteralPath $desktopBackup)) {
            Restore-ManagedQuotabotDesktop -InstallRoot $installRoot -BackupPath $desktopBackup
        }
        throw
    }
    if ($desktopBackup -and (Test-Path -LiteralPath $desktopBackup)) {
        try {
            Remove-Item -LiteralPath $desktopBackup -Recurse -Force
        } catch {
            Write-Warning "The new desktop app is active, but the previous payload could not be removed: $desktopBackup"
        }
    }
    if ($restartDesktop -and (Test-Path -LiteralPath $managedDesktopExe -PathType Leaf)) {
        Start-Process -FilePath $managedDesktopExe -WorkingDirectory (Split-Path -Parent $managedDesktopExe) | Out-Null
        Write-Host "Restarted the managed desktop app."
    }
    try {
        if ($reportedVersion -like 'quotabot *') {
            Report-HandExtractedDesktopSkew `
                -CliVersion $reportedVersion.Substring(9) `
                -Repository $repo `
                -LocalAppData $env:LOCALAPPDATA
        }
    } catch {
        Write-Warning "Could not compare a portable desktop bundle with the installed CLI."
    }
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
Write-Host "Tip: From a clone, run pwsh tools/setup.ps1 -CliOnly to build this checkout, or pwsh tools/local-setup.ps1 for a dart-run shim."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  quotabot doctor"
Write-Host "  quotabot top"
Write-Host "  Host apps already signed in here need no extra login."
Write-Host "  Optional idle-machine grants: quotabot login claude|codex|grok|antigravity"
Write-Host ""
Write-Host "To uninstall without deleting local history, grants, or profiles, see:"
Write-Host "  https://github.com/$repo/blob/main/docs/SETUP.md#uninstall-the-release-cli-but-preserve-data"
