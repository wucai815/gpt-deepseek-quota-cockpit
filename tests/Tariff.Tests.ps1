$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'DeepSeekTariff.ps1')
$checks=0
function Assert-Tariff([string]$At,[string]$Expected) {
    if ((Get-DeepSeekTariffState ([DateTimeOffset]::Parse($At))) -ne $Expected) { throw ('Wrong tariff at '+$At) }
    $script:checks++
}
Assert-Tariff '2026-09-28T08:59:59+08:00' 'offPeak'
Assert-Tariff '2026-09-28T09:00:00+08:00' 'peak'
Assert-Tariff '2026-09-28T11:59:59+08:00' 'peak'
Assert-Tariff '2026-09-28T12:00:00+08:00' 'offPeak'
Assert-Tariff '2026-09-28T13:59:59+08:00' 'offPeak'
Assert-Tariff '2026-09-28T14:00:00+08:00' 'peak'
Assert-Tariff '2026-09-28T18:00:00+08:00' 'offPeak'
Assert-Tariff '2026-09-28T01:00:00Z' 'peak'
Assert-Tariff '2026-10-01T10:00:00+08:00' 'offPeak'
Assert-Tariff '2026-10-07T15:00:00+08:00' 'offPeak'
Assert-Tariff '2026-10-08T10:00:00+08:00' 'peak'
Assert-Tariff '2026-10-10T10:00:00+08:00' 'offPeak'
Assert-Tariff '2026-09-25T15:00:00+08:00' 'offPeak'
Assert-Tariff '2027-01-04T10:00:00+08:00' 'unknown'
$result=Get-DeepSeekTariff ([DateTimeOffset]::Parse('2026-09-30T18:00:00+08:00'))
if ($result.nextChange -ne [DateTimeOffset]::Parse('2026-10-08T09:00:00+08:00')) { throw 'Holiday transition is incorrect.' }; $checks++
$result=Get-DeepSeekTariff ([DateTimeOffset]::Parse('2026-09-28T09:00:00+08:00'))
if ($result.nextChange -ne [DateTimeOffset]::Parse('2026-09-28T12:00:00+08:00')) { throw 'Peak end is incorrect.' }; $checks++
Write-Output ('PASS: '+$checks+' tariff boundary, holiday, timezone and unknown-calendar checks.')
