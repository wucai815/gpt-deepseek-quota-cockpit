function Get-DeepSeekCredentialPath {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GptQuotaMonitor\deepseek-key.dpapi'
}

function Save-DeepSeekCredential([Security.SecureString]$SecureKey) {
    if ($null -eq $SecureKey -or $SecureKey.Length -eq 0) { throw 'EMPTY_KEY' }
    $path=Get-DeepSeekCredentialPath
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    $temporary=$path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $encrypted=ConvertFrom-SecureString -SecureString $SecureKey -ErrorAction Stop
        [IO.File]::WriteAllText($temporary,$encrypted,[Text.Encoding]::UTF8)
        $verified=[IO.File]::ReadAllText($temporary) | ConvertTo-SecureString -ErrorAction Stop
        if ($verified.Length -ne $SecureKey.Length) { throw 'VERIFY_FAILED' }
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-DeepSeekApiKey {
    $path = Get-DeepSeekCredentialPath
    if (Test-Path -LiteralPath $path) {
        try {
            $secure = [IO.File]::ReadAllText($path) | ConvertTo-SecureString -ErrorAction Stop
            return [Net.NetworkCredential]::new('', $secure).Password
        } catch { throw 'SAVED_KEY_UNREADABLE' }
    }
    foreach ($scope in @('Process', 'User')) {
        $value = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return $null
}

function ConvertTo-DeepSeekAmount($Value) {
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    $number = [decimal]0
    if (-not [decimal]::TryParse([string]$Value, [Globalization.NumberStyles]::AllowLeadingSign -bor [Globalization.NumberStyles]::AllowDecimalPoint, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
    return $number
}

function ConvertTo-DeepSeekBalance($Response) {
    if ($null -eq $Response -or $Response.is_available -isnot [bool]) { throw 'INVALID_BALANCE_RESPONSE' }
    $rows = @()
    foreach ($row in @($Response.balance_infos)) {
        if ($null -eq $row -or $row.currency -notin @('CNY','USD')) { continue }
        if (@($rows | Where-Object { $_.currency -eq $row.currency }).Count -gt 0) { throw 'DUPLICATE_CURRENCY' }
        $rows += [pscustomobject]@{
            currency = [string]$row.currency
            total = ConvertTo-DeepSeekAmount $row.total_balance
            granted = ConvertTo-DeepSeekAmount $row.granted_balance
            toppedUp = ConvertTo-DeepSeekAmount $row.topped_up_balance
        }
    }
    [pscustomobject]@{ status='ok'; isAvailable=$Response.is_available; balances=@($rows); fetchedAt=[DateTimeOffset]::UtcNow.ToString('o') }
}

function Invoke-DeepSeekBalanceRequest([string]$Key) {
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    $cancel = New-Object Threading.CancellationTokenSource
    $response = $null
    try {
        $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Key)
        $client.DefaultRequestHeaders.Accept.ParseAdd('application/json')
        # Fixed official endpoint. Never forward credentials to redirects or configurable hosts.
        $task = $client.GetAsync('https://api.deepseek.com/user/balance', $cancel.Token)
        while (-not $task.Wait(100)) { }
        $response = $task.Result
        $code = [int]$response.StatusCode
        if ($code -eq 401 -or $code -eq 403) { return [pscustomobject]@{status='authError'} }
        if ($code -eq 429) { return [pscustomobject]@{status='rateLimited'} }
        if (-not $response.IsSuccessStatusCode) { return [pscustomobject]@{status='serviceError'} }
        $bodyTask = $response.Content.ReadAsStringAsync()
        while (-not $bodyTask.Wait(100)) { }
        try { return ConvertTo-DeepSeekBalance ($bodyTask.Result | ConvertFrom-Json -ErrorAction Stop) }
        catch { return [pscustomobject]@{status='invalidData'} }
    } catch {
        # Never propagate raw HTTP errors, headers, response bodies or keys to UI/logs.
        return [pscustomobject]@{status='networkError'}
    } finally {
        $cancel.Cancel()
        if ($response) { $response.Dispose() }
        $client.Dispose(); $handler.Dispose(); $cancel.Dispose()
    }
}

function Get-DeepSeekBalance {
    $key = $null
    try {
        try { $key = Get-DeepSeekApiKey } catch { return [pscustomobject]@{status='keyError'} }
        if ([string]::IsNullOrWhiteSpace($key)) { return [pscustomobject]@{status='missingKey'} }
        return Invoke-DeepSeekBalanceRequest -Key $key
    } finally { $key = $null }
}
