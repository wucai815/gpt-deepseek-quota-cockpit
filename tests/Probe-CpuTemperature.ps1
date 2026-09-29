param([Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'HardwareSource.ps1')
$computer=$null
try {
    $computer=New-HardwareMonitor
    $snapshot=Get-HardwareSnapshot $computer
    $snapshot.cpu | ConvertTo-Json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
} catch {
    [pscustomobject]@{error=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
} finally { Close-HardwareMonitor $computer }
