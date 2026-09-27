#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputPath = '')
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) { $OutputPath=Join-Path (Split-Path -Parent $project) 'QuotaCockpit.exe' }
$payload=Join-Path $PSScriptRoot 'payload.zip'
$runtimeFiles=@('Monitor.ps1','Dashboard.xaml','QuotaSource.ps1','RefreshPolicy.ps1','DeepSeekSource.ps1','DeepSeekPanel.ps1','DeepSeekTariff.ps1','pricing-rules.json','Set-DeepSeekKey.ps1','README.md')
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem,System.Drawing
$stream=[IO.File]::Open($payload,[IO.FileMode]::Create)
$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in $runtimeFiles) {
        $path=Join-Path $project $name
        if ([IO.File]::ReadAllText($path) -match 'sk-[A-Za-z0-9]{16,}') { throw 'Key-like material found in payload; build stopped.' }
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$path,$name,[IO.Compression.CompressionLevel]::Optimal)
    }
    $defaultConfig=Join-Path $project 'config.example.json'
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$defaultConfig,'config.json',[IO.Compression.CompressionLevel]::Optimal)
} finally { $archive.Dispose(); $stream.Dispose() }
# Draw a native app icon with the same cyan/violet gauge motif as the dashboard.
$bitmap=[Drawing.Bitmap]::new(64,64)
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([Drawing.ColorTranslator]::FromHtml('#101923'))
$cyan=[Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml('#83E2C9'),6)
$violet=[Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml('#B9B9F5'),6)
try {
    $graphics.DrawArc($cyan,10,10,44,44,145,155)
    $graphics.DrawArc($violet,10,10,44,44,305,90)
    $graphics.FillEllipse([Drawing.Brushes]::White,26,26,12,12)
    $icon=[Drawing.Icon]::FromHandle($bitmap.GetHicon())
    $iconPath=Join-Path $PSScriptRoot 'cockpit.ico'
    $file=[IO.File]::Create($iconPath)
    try { $icon.Save($file) } finally { $file.Dispose(); $icon.Dispose() }
} finally { $cyan.Dispose(); $violet.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$args=@('/nologo','/target:winexe','/platform:anycpu','/optimize+',('/out:'+$OutputPath),('/win32icon:'+$iconPath),('/win32manifest:'+(Join-Path $PSScriptRoot 'app.manifest')),('/resource:'+$payload+',Cockpit.Payload'),'/reference:System.Windows.Forms.dll','/reference:System.IO.Compression.dll','/reference:System.IO.Compression.FileSystem.dll',(Join-Path $PSScriptRoot 'Launcher.cs'))
& $compiler @args
if ($LASTEXITCODE -ne 0) { throw 'EXE compilation failed.' }
Get-Item -LiteralPath $OutputPath | Select-Object FullName,Length
