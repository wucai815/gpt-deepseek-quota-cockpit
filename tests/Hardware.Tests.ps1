$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'HardwareSource.ps1')
$count=0
function Check($Condition,[string]$Label){if(-not $Condition){throw $Label};$script:count++}
$static=Get-HardwareStaticInfo
Check (-not [string]::IsNullOrWhiteSpace($static.cpuName)) 'CPU name available.'
Check ($static.cpuCores -gt 0) 'CPU core count available.'
Check ($static.cpuThreads -ge $static.cpuCores) 'CPU thread count valid.'
Check ($static.memoryTotalGb -gt 0) 'Memory capacity available.'
$computer=New-HardwareMonitor
try {
    $snapshot=Get-HardwareSnapshot $computer
    Check ($snapshot.cpu.usage -ge 0 -and $snapshot.cpu.usage -le 100) 'CPU usage bounded.'
    Check ($snapshot.memory.usage -ge 0 -and $snapshot.memory.usage -le 100) 'Memory usage bounded.'
    Check ($snapshot.memory.usedGb -gt 0) 'Memory used available.'
    Check ($snapshot.memory.totalGb -gt $snapshot.memory.usedGb) 'Memory total exceeds used.'
    Check ([math]::Abs($snapshot.memory.usage - 100 * $snapshot.memory.usedGb / $snapshot.memory.totalGb) -lt 2) 'Memory percentage matches physical capacity.'
    Check ($null -eq $snapshot.gpu.usage -or ($snapshot.gpu.usage -ge 0 -and $snapshot.gpu.usage -le 100)) 'GPU usage missing or bounded.'
    Check ($null -eq $snapshot.gpu.temperature -or ($snapshot.gpu.temperature -gt 0 -and $snapshot.gpu.temperature -lt 120)) 'GPU temperature missing or plausible.'
    Check ($null -eq $snapshot.gpu.memoryTotalGb -or $snapshot.gpu.memoryTotalGb -gt 0) 'GPU memory total missing or available.'
    Check (-not [string]::IsNullOrWhiteSpace($snapshot.gpu.name)) 'GPU name available.'
} finally { Close-HardwareMonitor $computer }
Write-Output ('PASS: {0} hardware sensor assertions.' -f $count)
