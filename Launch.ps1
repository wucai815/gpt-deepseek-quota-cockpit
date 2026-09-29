#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Demo,
    [switch]$Windowed,
    [ValidateRange(-1, 99)]
    [int]$ScreenIndex = -1,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

try {
    $monitorPath = Join-Path $PSScriptRoot 'Monitor.ps1'
    if (-not (Test-Path -LiteralPath $monitorPath -PathType Leaf)) {
        throw 'Monitor.ps1 is missing. Extract the complete project folder before starting.'
    }

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Windows file names cannot contain a double quote; quote each full path separately.
    $launchArgs = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-STA',
        '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $monitorPath)
    )
    if ($Demo) { $launchArgs += '-Demo' }
    if ($Windowed) { $launchArgs += '-Windowed' }
    if ($PSBoundParameters.ContainsKey('ScreenIndex')) {
        $launchArgs += @('-ScreenIndex', [string]$ScreenIndex)
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        if (-not [IO.Path]::IsPathRooted($ConfigPath)) {
            $ConfigPath = Join-Path $PSScriptRoot $ConfigPath
        }
        $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            throw ('Configuration file does not exist: {0}' -f $ConfigPath)
        }
        $launchArgs += @('-ConfigPath', ('"{0}"' -f $ConfigPath))
    }

    $options = @{ FilePath=$powerShellPath; ArgumentList=$launchArgs; WorkingDirectory=$PSScriptRoot; WindowStyle='Hidden' }
    if (-not $Demo) { $options.Verb='RunAs' }
    Start-Process @options | Out-Null
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        ($_.Exception.Message + "`r`n`r`nRun Diagnose.cmd for more information."),
        'GPT Quota Monitor - launch failed',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}
