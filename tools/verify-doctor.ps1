param(
  [Parameter(Mandatory)][string]$Executable
)

$ErrorActionPreference = 'Stop'

$output = & $Executable doctor --json
$doctorExitCode = $LASTEXITCODE
if ($doctorExitCode -ne 0) {
  throw "quotabot doctor exited with code $doctorExitCode"
}

try {
  $doctor = $output | ConvertFrom-Json
} catch {
  throw "quotabot doctor returned invalid JSON: $($_.Exception.Message)"
}
if ($doctor.schema -ne 'quotabot.v1') {
  throw "Unexpected doctor schema: $($doctor.schema)"
}

Write-Host 'quotabot doctor returned quotabot.v1 with exit code 0.'
