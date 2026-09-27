$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'DeepSeekSource.ps1')
$script:checks=0
function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
$data=[pscustomobject]@{is_available=$true; balance_infos=@(
    [pscustomobject]@{currency='CNY';total_balance='128.500001';granted_balance='8.50';topped_up_balance='120.000001'},
    [pscustomobject]@{currency='USD';total_balance='0.00';granted_balance=$null;topped_up_balance='0'}
)}
$result=ConvertTo-DeepSeekBalance $data
Check ($result.balances.Count -eq 2) 'Do not combine currencies.'
Check ($result.balances[0].total -eq [decimal]'128.500001') 'Preserve balance precision.'
Check ($result.balances[1].total -eq 0) 'Zero balance must remain zero.'
Check ($null -eq $result.balances[1].granted) 'Missing grants are not zero.'
Check ($result.isAvailable -eq $true) 'Preserve service availability.'
$data.is_available=$false
Check ((ConvertTo-DeepSeekBalance $data).isAvailable -eq $false) 'Insufficient availability is preserved.'
Check ($null -eq (ConvertTo-DeepSeekAmount 'NaN')) 'NaN is unknown.'
Check ($null -eq (ConvertTo-DeepSeekAmount $true)) 'Boolean is not a balance.'
Check ((ConvertTo-DeepSeekAmount '-0.03') -eq [decimal]'-0.03') 'Preserve service-reported negative balance.'
Check ($null -eq (ConvertTo-DeepSeekAmount '')) 'Empty amount is unknown.'
$data.balance_infos=@()
Check (@((ConvertTo-DeepSeekBalance $data).balances).Count -eq 0) 'No rows is not a fake CNY zero.'
$failed=$false
try { ConvertTo-DeepSeekBalance ([pscustomobject]@{is_available='true';balance_infos=@()}) | Out-Null } catch { $failed=$true }
Check $failed 'Malformed availability must be rejected.'
$failed=$false
try { ConvertTo-DeepSeekBalance ([pscustomobject]@{is_available=$true;balance_infos=@([pscustomobject]@{currency='CNY'},[pscustomobject]@{currency='CNY'})}) | Out-Null } catch { $failed=$true }
Check $failed 'Duplicate currencies must be rejected.'
# Test the provider boundary without a real key or any network request.
function Get-DeepSeekApiKey { return $null }
Check ((Get-DeepSeekBalance).status -eq 'missingKey') 'No key is an explicit disconnected state.'
function Get-DeepSeekApiKey { throw 'PRIVATE_DETAILS' }
$result=Get-DeepSeekBalance
Check ($result.status -eq 'keyError') 'Unreadable credential has a safe error state.'
Check (($result | ConvertTo-Json) -notmatch 'PRIVATE_DETAILS') 'Credential error is sanitized.'
function Get-DeepSeekApiKey { return 'test-placeholder-not-a-real-key' }
function Invoke-DeepSeekBalanceRequest([string]$Key) { [pscustomobject]@{status='authError'} }
Check ((Get-DeepSeekBalance).status -eq 'authError') 'Authentication failure is retained.'
function Invoke-DeepSeekBalanceRequest([string]$Key) { [pscustomobject]@{status='networkError'} }
Check ((Get-DeepSeekBalance).status -eq 'networkError') 'Network failure is retained.'
Write-Output ('PASS: {0} DeepSeek assertions; no network or real credentials used.' -f $script:checks)
