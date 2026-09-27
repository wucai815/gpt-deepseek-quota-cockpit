# Windows PowerShell 5.1 compatible. This file only reads account rate limits.
# It never reads authentication files or requests a usage reset.

function Get-QuotaProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-QuotaNumber {
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    $number = 0.0
    $parsed = [double]::TryParse([string]$Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number)
    if (-not $parsed -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        return $null
    }
    return $number
}

function ConvertTo-QuotaWindow {
    param($Window)
    if ($null -eq $Window) { return $null }
    $used = ConvertTo-QuotaNumber (Get-QuotaProperty $Window 'usedPercent')
    $remaining = $null
    if ($null -ne $used) { $remaining = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - $used)) }
    $duration = ConvertTo-QuotaNumber (Get-QuotaProperty $Window 'windowDurationMins')
    if ($null -ne $duration -and $duration -le 0) { $duration = $null }
    $reset = ConvertTo-QuotaNumber (Get-QuotaProperty $Window 'resetsAt')
    if ($null -ne $reset -and ($reset -lt 0 -or $reset -gt 253402300799)) { $reset = $null }
    [pscustomobject][ordered]@{
        usedPercent = $used
        remainingPercent = $remaining
        windowDurationMins = $duration
        resetsAt = $reset
    }
}

function ConvertTo-QuotaSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Response,
        [ValidateNotNullOrEmpty()][string]$LimitId = 'codex'
    )
    # Accept either the JSON-RPC envelope or its result, to simplify diagnostics.
    $result = Get-QuotaProperty $Response 'result'
    if ($null -ne $result) { $Response = $result }
    $buckets = Get-QuotaProperty $Response 'rateLimitsByLimitId'
    $selected = $null
    if ($null -ne $buckets) {
        $selected = Get-QuotaProperty $buckets $LimitId
        if ($null -eq $selected) {
            throw "Requested quota bucket '$LimitId' is unavailable. Check limitId in config.json."
        }
    } else {
        $selected = Get-QuotaProperty $Response 'rateLimits'
        if ($null -eq $selected) { throw 'The account returned no quota data. Sign in to Codex with a ChatGPT account and try again.' }
        $legacyId = Get-QuotaProperty $selected 'limitId'
        # Old servers did not label the single Codex bucket. Never use it for a custom id.
        if (($null -ne $legacyId -and [string]$legacyId -ne $LimitId) -or
            ($null -eq $legacyId -and $LimitId -ne 'codex')) {
            throw "Requested quota bucket '$LimitId' is unavailable in this Codex version."
        }
    }
    $selectedId = Get-QuotaProperty $selected 'limitId'
    if ($null -ne $selectedId -and [string]$selectedId -ne $LimitId) {
        throw 'The returned quota bucket does not match the requested limitId.'
    }
    $plan = Get-QuotaProperty $selected 'planType'
    if ($null -eq $plan) { $plan = Get-QuotaProperty $Response 'planType' }
    $resetCredits = Get-QuotaProperty $Response 'rateLimitResetCredits'
    $credits = Get-QuotaProperty $resetCredits 'availableCount'
    if ($null -eq $credits) { $credits = Get-QuotaProperty $Response 'availableResetCredits' }
    if ($null -eq $credits) { $credits = Get-QuotaProperty $selected 'availableResetCredits' }
    $credits = ConvertTo-QuotaNumber $credits
    [pscustomobject][ordered]@{
        limitId = $LimitId
        limitName = Get-QuotaProperty $selected 'limitName'
        planType = $plan
        fetchedAt = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        primary = ConvertTo-QuotaWindow (Get-QuotaProperty $selected 'primary')
        secondary = ConvertTo-QuotaWindow (Get-QuotaProperty $selected 'secondary')
        availableResetCredits = $credits
    }
}

function Resolve-QuotaCodexExecutable {
    [CmdletBinding()]
    param([string]$CodexPath = '')
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($CodexPath)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($CodexPath)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            $candidates.Add((Get-Item -LiteralPath $expanded).FullName)
        } else {
            $command = Get-Command -Name $expanded -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $command) { $candidates.Add($command.Source) }
        }
    } else {
        foreach ($commandName in @('codex.exe', 'codex.cmd', 'codex.ps1', 'codex')) {
            $commands = @(Get-Command -Name $commandName -CommandType Application,ExternalScript -ErrorAction SilentlyContinue)
            foreach ($command in $commands) { $candidates.Add($command.Source) }
        }
        if ($env:LOCALAPPDATA) {
            $desktopBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
            if (Test-Path -LiteralPath $desktopBin -PathType Container) {
                foreach ($folder in @(Get-ChildItem -LiteralPath $desktopBin -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
                    $candidates.Add((Join-Path $folder.FullName 'codex.exe'))
                }
            }
        }
        if ($env:APPDATA) { $candidates.Add((Join-Path $env:APPDATA 'npm\codex.cmd')) }
        if ($env:USERPROFILE) {
            $candidates.Add((Join-Path $env:USERPROFILE '.local\bin\codex.exe'))
            $candidates.Add((Join-Path $env:USERPROFILE '.cargo\bin\codex.exe'))
            $candidates.Add((Join-Path $env:USERPROFILE 'scoop\apps\codex\current\codex.exe'))
        }
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        if ([IO.Path]::GetExtension($candidate) -ieq '.exe') {
            return (Get-Item -LiteralPath $candidate).FullName
        }
        # Resolve standard npm shims to the shipped native executable. Do not run
        # shell strings or inspect credentials, and do not execute arbitrary .ps1 files.
        if ([IO.Path]::GetFileName($candidate) -notmatch '^codex\.(cmd|ps1)$') { continue }
        $npmRoot = Join-Path (Split-Path -Parent $candidate) 'node_modules\@openai'
        $architecture = 'x86_64-pc-windows-msvc'
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
            $architecture = 'aarch64-pc-windows-msvc'
        }
        $nativePackages = @('codex', 'codex-win32-x64', 'codex-win32-arm64', 'codex\node_modules\@openai\codex-win32-x64', 'codex\node_modules\@openai\codex-win32-arm64')
        foreach ($package in $nativePackages) {
            $native = Join-Path $npmRoot "$package\vendor\$architecture\codex\codex.exe"
            if (Test-Path -LiteralPath $native -PathType Leaf) { return (Get-Item -LiteralPath $native).FullName }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexPath)) {
        throw 'The configured codexPath could not be resolved to codex.exe. Set the full native executable path in config.json.'
    }
    throw 'Codex was not found. Install or open the Codex desktop app, or set codexPath in config.json.'
}

function Wait-QuotaRpcResponse {
    param(
        [Diagnostics.Process]$Process,
        [Diagnostics.Stopwatch]$Clock,
        [int]$TimeoutMilliseconds,
        [int]$RequestId
    )
    while ($Clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        $lineTask = $Process.StandardOutput.ReadLineAsync()
        # Short waits let PowerShell observe Stop() promptly and run our finally
        # cleanup when the dashboard closes during a stalled network request.
        while (-not $lineTask.IsCompleted) {
            $remaining = [int]($TimeoutMilliseconds - $Clock.ElapsedMilliseconds)
            if ($remaining -le 0) { throw 'Quota refresh timed out. Check your network and Codex sign-in, then retry.' }
            $null = $lineTask.Wait([Math]::Min(100, $remaining))
        }
        $line = $lineTask.Result
        if ($null -eq $line) { throw 'The Codex quota service exited before returning data. Check Codex sign-in and update the app if needed.' }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $message = ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
        $id = Get-QuotaProperty $message 'id'
        if ($null -eq $id -or [string]$id -ne [string]$RequestId) { continue }
        $rpcError = Get-QuotaProperty $message 'error'
        if ($null -ne $rpcError) {
            # Upstream errors may contain account details. Return only a numeric code.
            $errorCode = ConvertTo-QuotaNumber (Get-QuotaProperty $rpcError 'code')
            $suffix = ''
            if ($null -ne $errorCode) { $suffix = " (code $errorCode)" }
            throw "Codex could not read account quota$suffix. Check ChatGPT sign-in and network access."
        }
        $result = Get-QuotaProperty $message 'result'
        if ($null -eq $result) { throw 'The Codex quota service returned an empty response.' }
        return $result
    }
    throw 'Quota refresh timed out. Check your network and Codex sign-in, then retry.'
}

function Get-QuotaSnapshot {
    [CmdletBinding()]
    param(
        [string]$CodexPath = '',
        [ValidateNotNullOrEmpty()][string]$LimitId = 'codex',
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20
    )
    $executable = Resolve-QuotaCodexExecutable -CodexPath $CodexPath
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $executable
    $process.StartInfo.Arguments = 'app-server --listen stdio://'
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $process.StartInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $started = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        try { $started = $process.Start() } catch { throw 'Could not start the Codex quota service. Check codexPath in config.json.' }
        if (-not $started) { throw 'Could not start the Codex quota service.' }
        # Drain stderr concurrently so diagnostic output cannot deadlock the process.
        # Never surface its contents: it can include local/account information.
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.AutoFlush = $true
        $initialize = @{
            id = 1
            method = 'initialize'
            params = @{
                clientInfo = @{ name = 'gpt_quota_monitor'; title = 'GPT Quota Monitor'; version = '1.0.0' }
                capabilities = @{ experimentalApi = $false }
            }
        } | ConvertTo-Json -Depth 8 -Compress
        $process.StandardInput.WriteLine($initialize)
        $null = Wait-QuotaRpcResponse -Process $process -Clock $clock -TimeoutMilliseconds ($TimeoutSeconds * 1000) -RequestId 1
        $process.StandardInput.WriteLine('{"method":"initialized","params":{}}')
        $process.StandardInput.WriteLine('{"id":2,"method":"account/rateLimits/read","params":{}}')
        $response = Wait-QuotaRpcResponse -Process $process -Clock $clock -TimeoutMilliseconds ($TimeoutSeconds * 1000) -RequestId 2
        return ConvertTo-QuotaSnapshot -Response $response -LimitId $LimitId
    } finally {
        $clock.Stop()
        if ($started) {
            try { $process.StandardInput.Close() } catch { }
            try {
                if (-not $process.WaitForExit(750)) {
                    $process.Kill()
                    $null = $process.WaitForExit(1000)
                }
            } catch { }
        }
        $process.Dispose()
    }
}
