param([switch]$Live, [switch]$SkipProcessTests)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'QuotaSource.ps1')
$script:assertions = 0

function Assert-Equal($Actual, $Expected, [string]$Label) {
    $script:assertions++
    if ($Actual -cne $Expected) { throw "FAIL: $Label (expected '$Expected', got '$Actual')" }
}
function Assert-True($Condition, [string]$Label) {
    $script:assertions++
    if (-not $Condition) { throw "FAIL: $Label" }
}
function Assert-Throws([scriptblock]$Action, [string]$Fragment, [string]$Label) {
    $script:assertions++
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught -or -not $caught.Contains($Fragment)) { throw "FAIL: $Label (expected sanitized error containing '$Fragment')" }
    return $caught
}
function New-TestResponse($Primary, $Secondary) {
    return @{ rateLimitsByLimitId = @{ codex = @{ limitId = 'codex'; planType = 'plus'; primary = $Primary; secondary = $Secondary } } }
}

$response = New-TestResponse @{ usedPercent = 0; windowDurationMins = 300; resetsAt = 1790495423 } @{ usedPercent = 100; windowDurationMins = 10080; resetsAt = 1791082223 }
$snapshot = ConvertTo-QuotaSnapshot -Response $response
Assert-Equal $snapshot.primary.usedPercent 0 'zero usage is a real value'
Assert-Equal $snapshot.primary.remainingPercent 100 'zero usage gives 100 percent remaining'
Assert-Equal $snapshot.secondary.remainingPercent 0 'full usage gives zero remaining'
Assert-Equal $snapshot.primary.resetsAt 1790495423 'reset timestamps stay in Unix seconds'
Assert-Equal $snapshot.primary.windowDurationMins 300 'duration is preserved'
Assert-Equal $snapshot.planType 'plus' 'selected plan is preserved'
Assert-True ($snapshot.fetchedAt.EndsWith('Z')) 'fetch time is UTC'

$snapshot = ConvertTo-QuotaSnapshot -Response (New-TestResponse @{ usedPercent = $null; resetsAt = $null } $null)
Assert-Equal $snapshot.primary.remainingPercent $null 'unknown usage is not reported as 100 percent'
Assert-Equal $snapshot.primary.usedPercent $null 'unknown used percentage remains null'
Assert-Equal $snapshot.primary.resetsAt $null 'unknown reset remains null'
Assert-Equal $snapshot.primary.windowDurationMins $null 'unknown duration remains null'
Assert-Equal $snapshot.secondary $null 'missing window remains null'
Assert-Equal $snapshot.availableResetCredits $null 'missing reset credits remain unknown'

$snapshot = ConvertTo-QuotaSnapshot -Response (New-TestResponse @{ usedPercent = 5; windowDurationMins = 10080 } @{ usedPercent = 12; windowDurationMins = 300 })
Assert-Equal $snapshot.primary.windowDurationMins 10080 'swapped server windows retain their real duration'
Assert-Equal $snapshot.secondary.windowDurationMins 300 'UI can choose five hours by duration'
Assert-Equal $snapshot.secondary.remainingPercent 88 'swapped windows retain their usage'

$multi = @{
    rateLimits = @{ limitId = 'codex'; primary = @{ usedPercent = 99 } }
    rateLimitsByLimitId = @{
        codex = @{ limitId = 'codex'; primary = @{ usedPercent = 30 } }
        'codex_other' = @{ limitId = 'codex_other'; limitName = 'Other'; primary = @{ usedPercent = 80 } }
    }
    availableResetCredits = 0
}
Assert-Equal (ConvertTo-QuotaSnapshot -Response $multi).primary.remainingPercent 70 'map takes precedence over legacy'
$snapshot = ConvertTo-QuotaSnapshot -Response $multi -LimitId 'codex_other'
Assert-Equal $snapshot.primary.remainingPercent 20 'requested bucket is selected'
Assert-Equal $snapshot.limitName 'Other' 'bucket label is preserved'
Assert-Equal $snapshot.availableResetCredits 0 'zero reset credits remains zero'
$multi.rateLimitResetCredits = @{ availableCount = 3 }
Assert-Equal (ConvertTo-QuotaSnapshot -Response $multi).availableResetCredits 3 'official rateLimitResetCredits.availableCount is normalized'
$multi.rateLimitResetCredits.availableCount = 0
Assert-Equal (ConvertTo-QuotaSnapshot -Response $multi).availableResetCredits 0 'official zero reset credits remains zero'
$null = Assert-Throws { ConvertTo-QuotaSnapshot -Response $multi -LimitId 'missing' } 'unavailable' 'missing bucket cannot fall back'
$null = Assert-Throws { ConvertTo-QuotaSnapshot -Response @{ rateLimitsByLimitId = @{}; rateLimits = $multi.rateLimits } } 'unavailable' 'empty map does not silently use legacy'
$null = Assert-Throws { ConvertTo-QuotaSnapshot -Response @{ rateLimits = @{ limitId = 'other' } } } 'unavailable' 'wrong legacy bucket is rejected'
$null = Assert-Throws { ConvertTo-QuotaSnapshot -Response @{ rateLimits = @{ primary = @{ usedPercent = 10 } } } -LimitId 'other' } 'unavailable' 'unlabelled legacy is not used for custom ids'
$null = Assert-Throws { ConvertTo-QuotaSnapshot -Response @{ rateLimitsByLimitId = @{ codex = @{ limitId = 'other' } } } } 'does not match' 'conflicting returned bucket id is rejected'
$null = Assert-Throws { ConvertTo-QuotaSnapshot -Response @{} } 'no quota data' 'missing quota is reported clearly'
Assert-Equal (ConvertTo-QuotaSnapshot -Response @{ rateLimits = @{ primary = @{ usedPercent = 12 } } }).primary.remainingPercent 88 'old unlabelled Codex response is supported'
Assert-Equal (ConvertTo-QuotaSnapshot -Response @{ result = $response }).primary.remainingPercent 100 'JSON-RPC envelope is accepted'
$json = '{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":0,"windowDurationMins":300}}}}' | ConvertFrom-Json
Assert-Equal (ConvertTo-QuotaSnapshot -Response $json).primary.remainingPercent 100 'PSCustomObject responses work'
$snapshot = ConvertTo-QuotaSnapshot -Response (New-TestResponse @{ usedPercent = 150; resetsAt = -2; windowDurationMins = 0 } @{ usedPercent = -20 })
Assert-Equal $snapshot.primary.remainingPercent 0 'remaining percentage is clamped at zero'
Assert-Equal $snapshot.secondary.remainingPercent 100 'remaining percentage is clamped at 100'
Assert-Equal $snapshot.primary.resetsAt $null 'invalid reset time stays unknown'
Assert-Equal $snapshot.primary.windowDurationMins $null 'invalid duration stays unknown'
foreach ($bad in @('NaN', 'Infinity', 'invalid', $true)) {
    Assert-Equal (ConvertTo-QuotaWindow @{ usedPercent = $bad }).remainingPercent $null 'invalid usage stays unknown'
}

if (-not $SkipProcessTests) {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('gpt-quota-backend-tests-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $testRoot
    $fakeExecutable = Join-Path $testRoot 'quota-fake.exe'
    $savedMode = $env:GPT_QUOTA_TEST_MODE
    $savedPidFile = $env:GPT_QUOTA_TEST_PIDFILE
    try {
        $fakeSource = @'
using System;
using System.IO;
using System.Threading;
public class QuotaProtocolFixture {
    public static void Main(string[] args) {
        File.WriteAllText(Environment.GetEnvironmentVariable("GPT_QUOTA_TEST_PIDFILE"), System.Diagnostics.Process.GetCurrentProcess().Id.ToString());
        if (args.Length != 3 || args[0] != "app-server" || args[1] != "--listen" || args[2] != "stdio://") Environment.Exit(20);
        string mode = Environment.GetEnvironmentVariable("GPT_QUOTA_TEST_MODE");
        if (mode == "hang") { Thread.Sleep(60000); return; }
        string initialize = Console.ReadLine();
        if (initialize == null || !initialize.Contains("initialize")) Environment.Exit(21);
        // Enough diagnostics to fill an undrained pipe, without any output to the test console.
        for (int i = 0; i < 256; i++) Console.Error.WriteLine(new string('x', 4096));
        Console.WriteLine("non-json diagnostic");
        Console.WriteLine("{\"method\":\"account/updated\",\"params\":{}}");
        Console.WriteLine("{\"id\":99,\"result\":{}}");
        Console.WriteLine("{\"id\":1,\"result\":{\"userAgent\":\"fixture\"}}");
        string initialized = Console.ReadLine();
        string read = Console.ReadLine();
        if (initialized == null || !initialized.Contains("initialized")) Environment.Exit(22);
        if (read == null || !read.Contains("account/rateLimits/read")) Environment.Exit(23);
        if (mode == "error") {
            Console.WriteLine("{\"id\":2,\"error\":{\"code\":-32000,\"message\":\"SECRET_TOKEN_ACCOUNT_DETAIL\"}}");
        } else {
            Console.WriteLine("{\"id\":2,\"result\":{\"rateLimitsByLimitId\":{\"codex\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":25,\"windowDurationMins\":300}}}}}");
        }
        Console.Out.Flush();
        // Forces the client's cleanup path to terminate this owned process.
        Thread.Sleep(60000);
    }
}
'@
        Add-Type -TypeDefinition $fakeSource -OutputAssembly $fakeExecutable -OutputType ConsoleApplication
        $env:GPT_QUOTA_TEST_PIDFILE = Join-Path $testRoot 'fixture.pid'
        $env:GPT_QUOTA_TEST_MODE = 'success'
        $snapshot = Get-QuotaSnapshot -CodexPath $fakeExecutable -TimeoutSeconds 8
        Assert-Equal $snapshot.primary.remainingPercent 75 'complete initialized protocol succeeds and stderr does not block'
        $fixturePid = [int](Get-Content -LiteralPath $env:GPT_QUOTA_TEST_PIDFILE)
        Assert-True ($null -eq (Get-Process -Id $fixturePid -ErrorAction SilentlyContinue)) 'success cleans up owned child process'

        $env:GPT_QUOTA_TEST_MODE = 'error'
        $caught = Assert-Throws { Get-QuotaSnapshot -CodexPath $fakeExecutable -TimeoutSeconds 8 } 'code -32000' 'upstream RPC error is sanitized'
        Assert-True (-not $caught.Contains('SECRET_TOKEN_ACCOUNT_DETAIL')) 'upstream account details are not exposed'
        $fixturePid = [int](Get-Content -LiteralPath $env:GPT_QUOTA_TEST_PIDFILE)
        Assert-True ($null -eq (Get-Process -Id $fixturePid -ErrorAction SilentlyContinue)) 'error cleans up owned child process'

        $env:GPT_QUOTA_TEST_MODE = 'hang'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $null = Assert-Throws { Get-QuotaSnapshot -CodexPath $fakeExecutable -TimeoutSeconds 1 } 'timed out' 'timeout is bounded'
        $clock.Stop()
        Assert-True ($clock.Elapsed.TotalSeconds -lt 5) 'timeout plus cleanup finishes promptly'
        $fixturePid = [int](Get-Content -LiteralPath $env:GPT_QUOTA_TEST_PIDFILE)
        Assert-True ($null -eq (Get-Process -Id $fixturePid -ErrorAction SilentlyContinue)) 'timeout cleans up owned child process'

        $env:GPT_QUOTA_TEST_PIDFILE = Join-Path $testRoot 'cancel.pid'
        $worker = [PowerShell]::Create()
        try {
            $sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'QuotaSource.ps1'
            $null = $worker.AddScript('param($source, $exe); . $source; Get-QuotaSnapshot -CodexPath $exe -TimeoutSeconds 20').AddArgument($sourcePath).AddArgument($fakeExecutable)
            $asyncHandle = $worker.BeginInvoke()
            $launchClock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $env:GPT_QUOTA_TEST_PIDFILE) -and $launchClock.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 30 }
            Assert-True (Test-Path -LiteralPath $env:GPT_QUOTA_TEST_PIDFILE) 'cancellation fixture started'
            $fixturePid = [int](Get-Content -LiteralPath $env:GPT_QUOTA_TEST_PIDFILE)
            $stopClock = [Diagnostics.Stopwatch]::StartNew()
            $worker.Stop()
            $stopClock.Stop()
            Assert-True ($stopClock.Elapsed.TotalSeconds -lt 3) 'runspace Stop is responsive during stalled response'
            Assert-True ($null -eq (Get-Process -Id $fixturePid -ErrorAction SilentlyContinue)) 'runspace cancellation cleans up owned child process'
        } finally { $worker.Dispose() }
    } finally {
        $env:GPT_QUOTA_TEST_MODE = $savedMode
        $env:GPT_QUOTA_TEST_PIDFILE = $savedPidFile
        # Only delete the exact unique directory this test created under TEMP.
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            ([IO.Path]::GetFileName($resolvedTestRoot) -like 'gpt-quota-backend-tests-*')) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
    }
}

if ($Live) {
    $snapshot = Get-QuotaSnapshot
    Assert-Equal $snapshot.limitId 'codex' 'live account responds with requested Codex bucket'
    Assert-True ($null -ne $snapshot.primary -or $null -ne $snapshot.secondary) 'live account has a quota window'
    Write-Host 'Live read succeeded. No credentials or raw upstream payload were printed.'
}
Write-Host "PASS: $script:assertions backend assertions."
