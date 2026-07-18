function Publish-QuotabotPackagePair {
  param(
    [Parameter(Mandatory)][string]$TemporaryArchive,
    [Parameter(Mandatory)][string]$TemporarySidecar,
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Sidecar,
    [Parameter(Mandatory)][string]$Workspace
  )

  $backupArchive = Join-Path $Workspace 'previous-archive'
  $backupSidecar = Join-Path $Workspace 'previous-sidecar'
  $preserveMarker = Join-Path $Workspace '.preserve'
  $lockPath = "$Archive.quotabot-package.lock"
  $packageLock = $null

  try {
    try {
      $packageLock = [IO.File]::Open(
        $lockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
      )
    } catch {
      throw "Another package operation is already publishing $Archive"
    }

    try {
      if (Test-Path -LiteralPath $Archive) {
        Move-Item -LiteralPath $Archive -Destination $backupArchive
      }
      if (Test-Path -LiteralPath $Sidecar) {
        Move-Item -LiteralPath $Sidecar -Destination $backupSidecar
      }
      Move-Item -LiteralPath $TemporaryArchive -Destination $Archive
      Move-Item -LiteralPath $TemporarySidecar -Destination $Sidecar
    } catch {
      $activationError = $_.Exception.Message
      $rollbackErrors = [Collections.Generic.List[string]]::new()

      if (
        -not (Test-Path -LiteralPath $TemporaryArchive) -and
        (Test-Path -LiteralPath $Archive)
      ) {
        try {
          Remove-Item -LiteralPath $Archive -Force
        } catch {
          $rollbackErrors.Add($_.Exception.Message)
        }
      }
      if (
        -not (Test-Path -LiteralPath $TemporarySidecar) -and
        (Test-Path -LiteralPath $Sidecar)
      ) {
        try {
          Remove-Item -LiteralPath $Sidecar -Force
        } catch {
          $rollbackErrors.Add($_.Exception.Message)
        }
      }
      if (Test-Path -LiteralPath $backupArchive) {
        try {
          Move-Item -LiteralPath $backupArchive -Destination $Archive
        } catch {
          $rollbackErrors.Add($_.Exception.Message)
        }
      }
      if (Test-Path -LiteralPath $backupSidecar) {
        try {
          Move-Item -LiteralPath $backupSidecar -Destination $Sidecar
        } catch {
          $rollbackErrors.Add($_.Exception.Message)
        }
      }

      if ($rollbackErrors.Count -gt 0) {
        New-Item -ItemType File -Force -Path $preserveMarker | Out-Null
        throw "Package activation failed and rollback was incomplete. Recovery files remain in $Workspace. Original error: $activationError. Rollback errors: $($rollbackErrors -join '; ')"
      }
      throw "Package activation failed; the previous archive and checksum were restored. ($activationError)"
    }
  } finally {
    if ($packageLock) {
      $packageLock.Dispose()
      Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
  }

  Remove-Item -LiteralPath $backupArchive -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $backupSidecar -Force -ErrorAction SilentlyContinue
}
