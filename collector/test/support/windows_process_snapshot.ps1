param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int]$LauncherId,
    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int]$VmId
)

$ErrorActionPreference = 'Stop'
$filter = "ProcessId = $LauncherId OR ProcessId = $VmId OR ParentProcessId = $LauncherId"
$rows = @(Get-CimInstance -ClassName Win32_Process -Filter $filter `
    -Property Name, ProcessId, ParentProcessId -OperationTimeoutSec 2 |
    Sort-Object ProcessId | Select-Object -First 8)
$result = @{
    launcher_present = @($rows | Where-Object ProcessId -EQ $LauncherId).Count -gt 0
    vm_present = @($rows | Where-Object ProcessId -EQ $VmId).Count -gt 0
    processes = @($rows | ForEach-Object {
        @{ pid = [int]$_.ProcessId; parent = [int]$_.ParentProcessId; name = $_.Name }
    })
}
$result | ConvertTo-Json -Depth 4 -Compress
