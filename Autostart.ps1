#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Enable', 'Disable', 'Status')]
    [string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'
$shortcutName = 'GPT Quota Monitor.lnk'
$startupFolder = [Environment]::GetFolderPath('Startup')
if ([string]::IsNullOrWhiteSpace($startupFolder)) {
    throw 'Windows did not provide a current-user Startup folder.'
}
$shortcutPath = Join-Path $startupFolder $shortcutName
$launchPath = Join-Path $PSScriptRoot 'Launch.ps1'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if ($Action -eq 'Status') {
    if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
        Write-Host ('Autostart is enabled: {0}' -f $shortcutPath)
    }
    else {
        Write-Host 'Autostart is disabled.'
    }
    return
}

if ($Action -eq 'Enable') {
    if (-not (Test-Path -LiteralPath $launchPath -PathType Leaf)) {
        throw 'Launch.ps1 is missing. Keep all project files in the same folder.'
    }
    [void][IO.Directory]::CreateDirectory($startupFolder)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $null
    try {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $powerShellPath
        $shortcut.Arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $launchPath
        $shortcut.WorkingDirectory = $PSScriptRoot
        $shortcut.Description = 'GPT Quota Monitor - current user sign-in'
        $shortcut.WindowStyle = 7
        $shortcut.Save()
    }
    finally {
        if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    }
    Write-Host 'Autostart enabled for the current Windows user. The panel will start at your next sign-in.'
    Write-Host ('Shortcut: {0}' -f $shortcutPath)
    Write-Host 'If you move this project folder, run Enable-Autostart.cmd again.'
    return
}

# Delete only this project's explicitly named shortcut, never the Startup folder.
if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Host 'Autostart disabled. The current panel, if open, is still running.'
}
else {
    Write-Host 'Autostart is already disabled.'
}
