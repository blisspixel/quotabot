$ErrorActionPreference = 'Stop'

function Test-ReadyProvider {
  param(
    [Parameter(Mandatory)]$Provider,
    [Parameter(Mandatory)][long]$Now
  )

  if ($Provider.ok -ne $true -or $Provider.stale -eq $true) { return $false }
  if ([string]$Provider.suspect -or [string]$Provider.drift_reason) { return $false }
  if ([string]$Provider.error) { return $false }
  $kind = [string]$Provider.kind
  $sourceClass = [string]$Provider.source_class
  try { $capturedAt = [long]$Provider.as_of } catch { return $false }
  if ($capturedAt -le 0 -or $capturedAt -gt ($Now + 60)) { return $false }
  if ($kind -eq 'local') {
    if ($sourceClass -ne 'local_runtime') { return $false }
    return @($Provider.models | Where-Object { $_.cloud_offloaded -ne $true }).Count -gt 0
  }
  if ($sourceClass -eq 'status_only') { return $false }
  if (@('authoritative_live', 'this_machine_fallback', 'passive_local_evidence') -notcontains $sourceClass) {
    return $false
  }
  $windows = @($Provider.windows)
  if ($windows.Count -eq 0) { return $false }
  foreach ($window in $windows) {
    try {
      if ($null -ne $window.used_percent) {
        $percent = [double]$window.used_percent
      } elseif ($null -ne $window.used -and $null -ne $window.limit -and [double]$window.limit -gt 0) {
        $percent = [double]$window.used / [double]$window.limit * 100.0
      } else {
        return $false
      }
    } catch {
      return $false
    }
    if ([double]::IsNaN($percent) -or [double]::IsInfinity($percent) -or $percent -lt 0 -or $percent -gt 100) {
      return $false
    }
    if ($null -eq $window.resets_at) { continue }
    try { $resetsAt = [long]$window.resets_at } catch { return $false }
    if ($resetsAt -le $Now -or $resetsAt -gt ($Now + 34560000)) {
      return $false
    }
  }
  return $true
}

$raw = @($input) -join [Environment]::NewLine
if (-not $raw) { exit 0 }
try {
  $snapshot = $raw | ConvertFrom-Json
} catch {
  exit 0
}
if (-not $snapshot.providers) { exit 0 }

$ready = New-Object System.Collections.Generic.List[string]
$login = New-Object System.Collections.Generic.List[string]
$other = New-Object System.Collections.Generic.List[string]
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$grouped = @{}
foreach ($provider in @($snapshot.providers)) {
  $key = [string]$provider.provider
  if (-not $key) { continue }
  if (-not $grouped.ContainsKey($key)) {
    $grouped[$key] = New-Object System.Collections.Generic.List[object]
  }
  $grouped[$key].Add($provider) | Out-Null
}
foreach ($key in $grouped.Keys) {
  $rows = @($grouped[$key].ToArray())
  $name = if ($rows[0].display_name) { [string]$rows[0].display_name } else { $key }
  if (@($rows | Where-Object { Test-ReadyProvider -Provider $_ -Now $now }).Count -gt 0) {
    $ready.Add($name) | Out-Null
    continue
  }
  $loginAdded = $false
  foreach ($provider in $rows) {
    $errorText = [string]$provider.error
    if ($errorText -match 'invalid' -and $errorText -match 'usage') {
      $other.Add("$name - signed in, quota unreadable: $errorText") | Out-Null
      continue
    }
    if ($errorText -match '(?i)\bquotabot login ([a-z0-9_-]{1,64})\b') {
      if (-not $loginAdded) {
        $login.Add($Matches[1].ToLowerInvariant()) | Out-Null
        $loginAdded = $true
      }
      continue
    }
    if (
      (@('claude', 'codex', 'grok', 'antigravity') -contains $key) -and
      ($errorText -match 'token|login|auth|credential|signed out|unauthorized')
    ) {
      if (-not $loginAdded) {
        $login.Add($key) | Out-Null
        $loginAdded = $true
      }
      continue
    }
    if ($errorText) {
      $other.Add("$name - $errorText") | Out-Null
    } elseif ($provider.ok) {
      $other.Add("$name - no fresh quota evidence") | Out-Null
    }
  }
}

Write-Output ''
Write-Output 'First run'
$uniqueReady = @($ready | Select-Object -Unique)
if ($uniqueReady.Count -gt 0) {
  Write-Output "  Already live (no extra login): $($uniqueReady -join ', ')"
}
$uniqueLogin = @($login | Select-Object -Unique)
if ($uniqueLogin.Count -gt 0) {
  Write-Output '  Login only if a row is missing or stale on this machine:'
  foreach ($providerName in $uniqueLogin) {
    Write-Output "    quotabot login $providerName"
  }
} elseif ($other.Count -eq 0) {
  Write-Output '  No extra login required. Host apps already signed in on this machine are enough.'
}
foreach ($line in @($other | Select-Object -Unique)) {
  Write-Output "  $line"
}
