$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'RefreshPolicy.ps1')
$now=[DateTimeOffset]::Parse('2026-09-27T12:00:00Z')
$short=$now.AddHours(2).ToUnixTimeSeconds()
$week=$now.AddDays(3).ToUnixTimeSeconds()
$count=0
function Check($Condition,[string]$Label) { if(-not $Condition){throw $Label};$script:count++ }
Check (-not (Get-CodexRefreshPolicy $null $now).paused) 'Initial fetch allowed.'
$snapshot=[pscustomobject]@{primary=[pscustomobject]@{remainingPercent=0;resetsAt=$short};secondary=[pscustomobject]@{remainingPercent=70;resetsAt=$week}}
$policy=Get-CodexRefreshPolicy $snapshot $now
Check $policy.paused 'One depleted window pauses the whole account.'
Check ($policy.resumeAt.ToUnixTimeSeconds() -eq $short) 'Resume at depleted window reset.'
Check (Get-CodexRefreshPolicy $snapshot $now.AddHours(2).AddSeconds(-1)).paused 'No polling before reset.'
Check (-not (Get-CodexRefreshPolicy $snapshot $now.AddHours(2)).paused) 'Resume exactly at reset.'
$snapshot.secondary.remainingPercent=0
$policy=Get-CodexRefreshPolicy $snapshot $now
Check ($policy.resumeAt.ToUnixTimeSeconds() -eq $week) 'Both exhausted: wait for both resets.'
$snapshot.primary.resetsAt=$null
$policy=Get-CodexRefreshPolicy $snapshot $now
Check ($policy.paused -and $null -eq $policy.resumeAt) 'Unknown reset requires manual refresh.'
$snapshot.primary.remainingPercent=$null
$snapshot.secondary.remainingPercent=70
Check (-not (Get-CodexRefreshPolicy $snapshot $now).paused) 'Missing quota is not depleted.'
$snapshot.primary.remainingPercent=1
Check (-not (Get-CodexRefreshPolicy $snapshot $now).paused) 'Low nonzero quota still refreshes.'
Check (-not (Test-DeepSeekDepleted $null)) 'Initial DS fetch allowed.'
Check (Test-DeepSeekDepleted ([pscustomobject]@{isAvailable=$false;balances=@()})) 'Server unavailable balance pauses DS.'
Check (Test-DeepSeekDepleted ([pscustomobject]@{isAvailable=$true;balances=@([pscustomobject]@{total=0})})) 'Zero balance pauses DS.'
Check (-not (Test-DeepSeekDepleted ([pscustomobject]@{isAvailable=$true;balances=@([pscustomobject]@{total=0},[pscustomobject]@{total=3})}))) 'Do not pause when another currency has funds.'
Check (-not (Test-DeepSeekDepleted ([pscustomobject]@{isAvailable=$true;balances=@([pscustomobject]@{total=$null})}))) 'Unknown balance must retry.'
Check (-not (Test-DeepSeekDepleted ([pscustomobject]@{isAvailable=$true;balances=@()}))) 'Missing balances must retry.'
Check (Test-DeepSeekDepleted ([pscustomobject]@{isAvailable=$true;balances=@([pscustomobject]@{total=-0.01})})) 'Negative service balance is depleted.'
Check (-not (Test-DeepSeekDepleted ([pscustomobject]@{isAvailable=$true;balances=@([pscustomobject]@{total=20})}))) 'Top-up resumes polling after manual refresh.'
Write-Output ('PASS: '+$count+' depletion/pause/resume policy checks.')
