. (Join-Path $PSScriptRoot 'HardwareSource.ps1')
$script:hardwareComputer = $null
$script:hardwareSnapshot = $null
$script:hardwareLastUpdate = [DateTimeOffset]::MinValue

function Format-HardwareValue($Value, [string]$Suffix, [string]$Pattern = '0') {
    if ($null -eq $Value) { return '--' }
    return ([double]$Value).ToString($Pattern, [Globalization.CultureInfo]::InvariantCulture) + $Suffix
}

function Set-HardwareBar([string]$Name, $Value) {
    $percent = if ($null -eq $Value) { 0 } else { [math]::Max(0, [math]::Min(100, [double]$Value)) }
    $script:ui[$Name].Width = 2.38 * $percent
}

function Show-HardwareSnapshot($Snapshot) {
    if ($null -eq $Snapshot) { return }
    $script:ui.CpuUsage.Text = Format-HardwareValue $Snapshot.cpu.usage ''
    $script:ui.CpuTemp.Text = '温度  ' + $(if ($null -eq $Snapshot.cpu.temperature) { '-- ℃' } else { (Format-HardwareValue $Snapshot.cpu.temperature ' ℃') })
    $script:ui.CpuClock.Text = '频率  ' + $(if ($null -eq $Snapshot.cpu.clockGHz) { '-- GHz' } else { (Format-HardwareValue $Snapshot.cpu.clockGHz ' GHz' '0.0') })
    $script:ui.CpuTemp.ToolTip = if ($null -eq $Snapshot.cpu.temperature) { 'CPU 温度需要 PawnIO 驱动和管理员权限。请以管理员身份启动硬件版。' } else { 'CPU 封装温度 · 实时传感器' }
    Set-HardwareBar 'CpuFill' $Snapshot.cpu.usage

    $script:ui.GpuUsage.Text = Format-HardwareValue $Snapshot.gpu.usage ''
    $script:ui.GpuTemp.Text = '温度  ' + $(if ($null -eq $Snapshot.gpu.temperature) { '-- ℃' } else { (Format-HardwareValue $Snapshot.gpu.temperature ' ℃') })
    $script:ui.GpuMemory.Text = if ($null -eq $Snapshot.gpu.memoryUsedGb) { '显存  --' } else { '显存  {0:0.0} / {1:0.0} GB' -f $Snapshot.gpu.memoryUsedGb, $Snapshot.gpu.memoryTotalGb }
    Set-HardwareBar 'GpuFill' $Snapshot.gpu.usage

    $script:ui.RamUsage.Text = Format-HardwareValue $Snapshot.memory.usage ''
    $script:ui.RamUsed.Text = if ($null -eq $Snapshot.memory.usedGb) { '已用  --' } else { '已用  {0:0.0} / {1:0.0} GB' -f $Snapshot.memory.usedGb, $Snapshot.memory.totalGb }
    $script:ui.RamAvailable.Text = if ($null -eq $Snapshot.memory.availableGb) { '可用  --' } else { '可用  {0:0.0} GB' -f $Snapshot.memory.availableGb }
    Set-HardwareBar 'RamFill' $Snapshot.memory.usage
}

function Get-DemoHardwareSnapshot {
    [pscustomobject]@{
        cpu=[pscustomobject]@{name='Intel Core i5-12490F';cores=6;threads=12;usage=34;temperature=58;clockGHz=4.1}
        gpu=[pscustomobject]@{name='RTX 4070 SUPER';usage=47;temperature=52;memoryUsedGb=4.3;memoryTotalGb=12.0;powerWatts=96;fanRpm=1120}
        memory=[pscustomobject]@{usage=68;usedGb=10.8;totalGb=15.8;availableGb=5.0}
    }
}

function Update-HardwarePanel([switch]$Force) {
    $now = [DateTimeOffset]::UtcNow
    if (-not $Force -and ($now - $script:hardwareLastUpdate).TotalMilliseconds -lt 900) { return }
    $script:hardwareLastUpdate = $now
    if ($Demo -or $TestState) {
        $script:hardwareSnapshot = Get-DemoHardwareSnapshot
    } else {
        if ($null -eq $script:hardwareComputer) { $script:hardwareComputer = New-HardwareMonitor }
        try { $script:hardwareSnapshot = Get-HardwareSnapshot $script:hardwareComputer } catch { }
    }
    Show-HardwareSnapshot $script:hardwareSnapshot
}

function Close-HardwarePanel {
    Close-HardwareMonitor $script:hardwareComputer
    $script:hardwareComputer = $null
}

Update-HardwarePanel -Force
