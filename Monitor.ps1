[CmdletBinding()]
param(
    [switch]$Demo,
    [switch]$Windowed,
    [int]$ScreenIndex = -1,
    [string]$ConfigPath = '',
    [switch]$Diagnose,
    [string]$RenderPath = '',
    [string]$SnapshotPath = '',
    [ValidateSet('', 'Offline', 'Unknown', 'Expired', 'Low', 'Full', 'Fractional')][string]$TestState = '',
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$script:root = $PSScriptRoot
$script:window = $null
$script:worker = $null
$script:mutex = $null
$script:ownsMutex = $false

try {
    if (($TestState -or $SnapshotPath) -and -not $RenderPath) {
        throw '测试数据只允许用于导出预览图片。'
    }
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw '请使用 Windows PowerShell 5.1 运行；双击 Start.cmd 即可。'
    }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw '程序需要 STA 模式；请双击 Start.cmd。'
    }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class QuotaDisplay {
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
}
'@
    try { [void][QuotaDisplay]::SetThreadDpiAwarenessContext([IntPtr](-4)) } catch { }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    . (Join-Path $script:root 'QuotaSource.ps1')
    . (Join-Path $script:root 'RefreshPolicy.ps1')

    $script:config = [ordered]@{ pollSeconds = 60; codexPath = ''; limitId = 'codex'; screenIndex = -1; topmost = $false; windowed = $false }
    if (-not $ConfigPath) { $ConfigPath = Join-Path $script:root 'config.json' }
    if (Test-Path -LiteralPath $ConfigPath) {
        $custom = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @($script:config.Keys)) {
            if ($null -ne $custom.PSObject.Properties[$key]) { $script:config[$key] = $custom.$key }
        }
    }
    $script:config.pollSeconds = [Math]::Max(15, [Math]::Min(3600, [int]$script:config.pollSeconds))
    if ([string]::IsNullOrWhiteSpace($script:config.limitId)) { $script:config.limitId = 'codex' }
    if ($PSBoundParameters.ContainsKey('ScreenIndex')) { $script:config.screenIndex = $ScreenIndex }
    if ($Windowed) { $script:config.windowed = $true }
    $script:screens = @([Windows.Forms.Screen]::AllScreens)

    if ($Diagnose) {
        Write-Output ('Windows PowerShell {0} / {1}' -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
        for ($i = 0; $i -lt $script:screens.Count; $i++) {
            Write-Output ('屏幕 {0}: {1} {2} Primary={3}' -f $i, $script:screens[$i].DeviceName, $script:screens[$i].Bounds, $script:screens[$i].Primary)
        }
        $result = Get-QuotaSnapshot -CodexPath $script:config.codexPath -LimitId $script:config.limitId
        Write-Output ('读取成功 / 额度组: {0} / 套餐: {1}' -f $result.limitId, $result.planType)
        @($result.primary, $result.secondary) | Where-Object { $null -ne $_ } | Select-Object windowDurationMins, usedPercent, remainingPercent, resetsAt | Format-Table | Out-String | Write-Output
        exit 0
    }

    if (-not $RenderPath -and -not $SmokeTest) {
        $mutexName = 'Local\GptHardwareCockpit_v1'
        if ($Demo) { $mutexName += '_Demo' }
        $created = $false
        $script:mutex = New-Object Threading.Mutex($true, $mutexName, [ref]$created)
        $script:ownsMutex = $created
        if (-not $created) {
            [void][Windows.MessageBox]::Show('硬件驾驶舱已在运行，请查看副屏或任务栏。', '硬件驾驶舱')
            exit 0
        }
    }

    [xml]$markup = Get-Content -LiteralPath (Join-Path $script:root 'Dashboard.xaml') -Raw -Encoding UTF8
    $reader = New-Object Xml.XmlNodeReader($markup)
    $script:window = [Windows.Markup.XamlReader]::Load($reader)
    $reader.Close()
    $script:ui = @{}
    $namespaces = New-Object Xml.XmlNamespaceManager($markup.NameTable)
    $namespaces.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    foreach ($node in $markup.SelectNodes('//*[@x:Name]', $namespaces)) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $script:ui[$name] = $script:window.FindName($name)
    }
    $script:lastSnapshot = $null
    $script:lastError = ''
    $script:lastSuccess = $null
    $script:nextFetch = [DateTimeOffset]::UtcNow
    $script:shortWindow = $null
    $script:weekWindow = $null
    $script:isFullscreen = -not $script:config.windowed
    $script:activeScreen = -1
    $script:lastResetRefresh = [DateTimeOffset]::MinValue
    $script:smokeTicks = 0

    function Get-Brush([string]$Color) {
        return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    }
    function Get-GaugePoint([double]$Percent, [double]$Radius = 146) {
        $angle = (150 + 2.4 * $Percent) * [Math]::PI / 180
        return [Windows.Point]::new((199 + $Radius * [Math]::Cos($angle)), (164 + $Radius * [Math]::Sin($angle)))
    }
    function Get-GaugeGeometry([double]$Percent) {
        $figure = New-Object Windows.Media.PathFigure
        $figure.StartPoint = Get-GaugePoint 0
        $arc = New-Object Windows.Media.ArcSegment
        $arc.Point = Get-GaugePoint $Percent
        $arc.Size = [Windows.Size]::new(146,146)
        $arc.IsLargeArc = $Percent -gt 75
        $arc.SweepDirection = 'Clockwise'
        $figure.Segments.Add($arc)
        $geometry = New-Object Windows.Media.PathGeometry
        $geometry.Figures.Add($figure)
        return $geometry
    }
    foreach ($prefix in @('Short', 'Week')) {
        $script:ui[($prefix + 'Track')].Data = Get-GaugeGeometry 100
        for ($i = 0; $i -le 20; $i++) {
            $a = Get-GaugePoint ($i * 5) 158
            $b = Get-GaugePoint ($i * 5) $(if (($i % 5) -eq 0) { 167 } else { 162 })
            $tick = New-Object Windows.Shapes.Line
            $tick.X1 = $a.X; $tick.Y1 = $a.Y; $tick.X2 = $b.X; $tick.Y2 = $b.Y
            $tick.Stroke = Get-Brush '#7D91A8'
            $tick.StrokeThickness = if (($i % 5) -eq 0) { 2 } else { 1 }
            [void]$script:ui[($prefix + 'Ticks')].Children.Add($tick)
        }
    }

    function Get-WindowLabel($QuotaWindow, [string]$Default) {
        if ($null -eq $QuotaWindow) { return $Default }
        if ($null -eq $QuotaWindow.windowDurationMins) { return '额度 / 周期未提供' }
        $minutes = [double]$QuotaWindow.windowDurationMins
        if ($minutes -eq 300) { return '5 小时额度' }
        if ($minutes -eq 10080) { return '每周额度' }
        if (($minutes % 1440) -eq 0) { return ('{0:g} 天额度' -f ($minutes / 1440)) }
        if (($minutes % 60) -eq 0) { return ('{0:g} 小时额度' -f ($minutes / 60)) }
        return ('{0:g} 分钟额度' -f $minutes)
    }

    function Set-QuotaCard([string]$Prefix, $QuotaWindow, [string]$Default, [string]$Color) {
        $script:ui[($Prefix + 'Title')].Text = Get-WindowLabel $QuotaWindow $Default
        $remaining = $null
        if ($null -ne $QuotaWindow) { $remaining = $QuotaWindow.remainingPercent }
        $hint = '未提供'
        if ($null -ne $QuotaWindow -and $null -ne $QuotaWindow.windowDurationMins) {
            $hint = ('{0:g} MIN' -f $QuotaWindow.windowDurationMins)
            if ($QuotaWindow.windowDurationMins -eq 300) { $hint = '5H' }
            if ($QuotaWindow.windowDurationMins -eq 10080) { $hint = '7D' }
        }
        $script:ui[($Prefix + 'Hint')].Text = $hint
        if ($null -eq $remaining) {
            $script:ui[($Prefix + 'Value')].Text = '--'
            $script:ui[($Prefix + 'Used')].Text = '服务尚未提供该窗口数据'
        } else {
            $script:ui[($Prefix + 'Value')].Text = ('{0:0.#}' -f $remaining)
            $script:ui[($Prefix + 'Used')].Text = ('已使用 {0:0.#}%' -f $QuotaWindow.usedPercent)
            if ($remaining -le 5) { $Color = '#FF9494' }
            elseif ($remaining -le 20) { $Color = '#EEC27D' }
        }
        $brush = Get-Brush $Color
        $script:ui[($Prefix + 'Value')].FontSize = if ($script:ui[($Prefix + 'Value')].Text.Length -gt 3) { 116 } else { 140 }
        $script:ui[($Prefix + 'Value')].Foreground = $brush
        $script:ui[($Prefix + 'Arc')].Stroke = $brush
        $script:ui[($Prefix + 'Arc')].Data = $null
        $marker = $script:ui[($Prefix + 'Marker')]
        $marker.Visibility = 'Collapsed'
        if ($null -ne $remaining) {
            if ($remaining -gt 0) { $script:ui[($Prefix + 'Arc')].Data = Get-GaugeGeometry $remaining }
            $point = Get-GaugePoint $remaining
            [Windows.Controls.Canvas]::SetLeft($marker, $point.X - 8.5)
            [Windows.Controls.Canvas]::SetTop($marker, $point.Y - 8.5)
            $marker.Stroke = $brush
            $marker.Visibility = 'Visible'
        }
    }

    function Set-Snapshot($Snapshot) {
        $script:lastSnapshot = $Snapshot
        $script:lastSuccess = [DateTimeOffset]::UtcNow
        $fetched = [DateTimeOffset]::MinValue
        if ($Snapshot.fetchedAt -and [DateTimeOffset]::TryParse([string]$Snapshot.fetchedAt, [ref]$fetched)) { $script:lastSuccess = $fetched }
        $script:lastError = ''
        $windows = @($Snapshot.primary, $Snapshot.secondary) | Where-Object { $null -ne $_ }
        $script:shortWindow = $windows | Where-Object { $_.windowDurationMins -eq 300 } | Select-Object -First 1
        $script:weekWindow = $windows | Where-Object { $_.windowDurationMins -eq 10080 } | Select-Object -First 1
        # Preserve actual service durations if a future plan uses different windows.
        $other = @($windows | Where-Object { $_.windowDurationMins -ne 300 -and $_.windowDurationMins -ne 10080 })
        if ($null -eq $script:shortWindow -and $other.Count -gt 0) { $script:shortWindow = $other[0]; $other = @($other | Select-Object -Skip 1) }
        if ($null -eq $script:weekWindow -and $other.Count -gt 0) { $script:weekWindow = $other[0] }
        Set-QuotaCard 'Short' $script:shortWindow '5 小时额度' '#83E2C9'
        Set-QuotaCard 'Week' $script:weekWindow '每周额度' '#B9B9F5'
        $plan = if ($Snapshot.planType) { ([string]$Snapshot.planType).ToUpperInvariant() } else { 'CODEX' }
        $script:ui.PlanLabel.Text = $plan + ' / 账号额度'
        $script:ui.SyncLabel.Text = '上次同步  ' + $script:lastSuccess.ToLocalTime().ToString('HH:mm:ss')
    }

    function Set-Countdown([string]$Prefix, $QuotaWindow, [DateTimeOffset]$Now) {
        $script:ui[($Prefix + 'CountdownLead')].Text = '还有'
        if ($null -eq $QuotaWindow -or $null -eq $QuotaWindow.resetsAt) {
            $script:ui[($Prefix + 'Countdown')].Text = '-- : -- : --'
            $script:ui[($Prefix + 'Reset')].Text = '--:--'
            $script:ui[($Prefix + 'ResetDate')].Text = '等待同步'
            if ($Prefix -eq 'Week') { $script:ui.WeekReset.Text='待同步'; $script:ui.WeekCountdown.Text='-- 天' }
            $script:ui[($Prefix + 'CountdownLead')].Text = ''
            return
        }
        $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$QuotaWindow.resetsAt)
        $script:ui[($Prefix + 'Reset')].Text = $reset.ToLocalTime().ToString('HH:mm')
        $script:ui[($Prefix + 'ResetDate')].Text = $reset.ToLocalTime().ToString('MM月dd日 ddd', [Globalization.CultureInfo]::GetCultureInfo('zh-CN'))
        if ($Prefix -eq 'Week') {
            $script:ui.WeekReset.Text = $reset.ToLocalTime().ToString('MM月dd日')
            $script:ui.WeekResetDate.Text = $reset.ToLocalTime().ToString('dddd', [Globalization.CultureInfo]::GetCultureInfo('zh-CN'))
        }
        $span = $reset - $Now
        if ($span.TotalSeconds -le 0) {
            $script:ui[($Prefix + 'Countdown')].Text = '等待服务确认重置'
            $script:ui[($Prefix + 'CountdownLead')].Text = ''
            # A countdown reaching zero never fabricates a new quota balance.

        } elseif ($Prefix -eq 'Week') {
            $days = ($reset.ToLocalTime().Date - $Now.ToLocalTime().Date).Days
            $script:ui.WeekCountdownLead.Text = ''
            $script:ui.WeekCountdown.Text = if ($days -gt 0) { '还有 ' + $days + ' 天' } else { '今天重置' }
        } elseif ($span.TotalDays -ge 1) {
            $script:ui[($Prefix + 'Countdown')].Text = ('{0} 天 {1:00}:{2:00}:{3:00}' -f $span.Days, $span.Hours, $span.Minutes, $span.Seconds)
        } else {
            $script:ui[($Prefix + 'Countdown')].Text = ('{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
        }
    }

    function Update-Status([DateTimeOffset]$Now) {
        $script:ui.Clock.Text = $Now.ToLocalTime().ToString('HH:mm:ss')
        $script:ui.DateLabel.Text = $Now.ToLocalTime().ToString('MM月dd日 dddd', [Globalization.CultureInfo]::GetCultureInfo('zh-CN'))
        Set-Countdown 'Short' $script:shortWindow $Now
        Set-Countdown 'Week' $script:weekWindow $Now
        $policy = Get-CodexRefreshPolicy $script:lastSnapshot $Now
        $stale = -not $policy.paused -and $null -ne $script:lastSuccess -and ($Now - $script:lastSuccess).TotalSeconds -gt ($script:config.pollSeconds * 2 + 25)
        $color = '#83E2C9'
        if ($Demo) {
            $title = '演示模式 · 非真实额度'
            $detail = '仅用于查看副屏效果；双击 Start.cmd 连接真实账号。'
            $color = '#EEC27D'
            $script:ui.NextLabel.Text = '演示数据 / 不连接账号'
        } elseif ($script:lastError -or $stale) {
            $title = if ($null -ne $script:lastSnapshot) { '同步中断 · 保留上次读数' } else { '暂时无法获取额度' }
            $detail = if ($script:lastError) { $script:lastError } else { '数据已过期，正在尝试重新同步。' }
            $color = '#EEC27D'
        } elseif ($null -eq $script:lastSnapshot) {
            $title = '正在连接 Codex'
            $detail = '通过本机已登录账号读取额度，请稍候。'
            $color = '#8DA5C9'
        } else {
            $known = @($script:shortWindow, $script:weekWindow) | Where-Object { $null -ne $_ -and $null -ne $_.remainingPercent }
            $low = @($known | Where-Object { $_.remainingPercent -le 20 })
            $expired = @(@($script:shortWindow, $script:weekWindow) | Where-Object { $null -ne $_ -and $null -ne $_.resetsAt -and $_.resetsAt -le $Now.ToUnixTimeSeconds() })
            $title = '已连接 · 额度充足'
            $detail = 'Codex 账号额度 · 重置时间按本地时区显示'
            if ($known.Count -lt 2) { $title = '已同步 · 部分额度未提供'; $detail = '缺失数据以 -- 显示；不会推算剩余额度。' }
            if ($low.Count -gt 0) { $title = '额度偏低 · 留意剩余用量'; $color = '#EEC27D' }
            if ($expired.Count -gt 0) { $title = '已到重置时间 · 等待服务更新'; $detail = '保留最后一次读数，刷新成功后更新额度。'; $color = '#EEC27D' }
            if ($script:lastSnapshot.availableResetCredits -gt 0) { $detail += (' · 可用重置 {0} 次' -f $script:lastSnapshot.availableResetCredits) }
        }
        if ($policy.paused -and -not $Demo) {
            $title = '额度耗尽 · 自动同步已暂停'
            $detail = if ($policy.resumeAt) { '恢复同步：' + $policy.resumeAt.ToLocalTime().ToString('MM月dd日 HH:mm') } else { '未提供重置时间；按 R 手动刷新。' }
            $detail += ' · 两项额度均保留上次读数'
        }
        $script:ui.ModeBadge.ToolTip = $title + "`n" + $detail + "`n右键打开操作菜单"
        $script:ui.StatusTitle.Text = $title
        $script:ui.StatusDetail.Text = $detail
        $script:ui.StatusDetail.ToolTip = $detail
        $script:ui.StatusTitle.ToolTip = $detail
        $script:ui.StatusDot.Fill = Get-Brush $color
        if (-not $Demo) {
            $script:ui.NextLabel.Text = if ($null -ne $script:worker) { '正在同步…' } else { '下次更新 / ' + [Math]::Max(0, [int][Math]::Ceiling(($script:nextFetch - $Now).TotalSeconds)) + ' 秒' }
        }
    }

    function Start-Refresh([switch]$Force) {
        if ($Demo -or $null -ne $script:worker) { return }
        if (-not $Force -and (Get-CodexRefreshPolicy $script:lastSnapshot).paused) { return }
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript('param($source, $exe, $bucket); $ErrorActionPreference = "Stop"; . $source; Get-QuotaSnapshot -CodexPath $exe -LimitId $bucket -TimeoutSeconds 20').AddArgument((Join-Path $script:root 'QuotaSource.ps1')).AddArgument($script:config.codexPath).AddArgument($script:config.limitId)
        $script:worker = @{ ps = $ps; handle = $ps.BeginInvoke(); started = [DateTimeOffset]::UtcNow }
        $script:ui.RefreshButton.IsEnabled = $false
    }

    function Complete-Refresh {
        if ($null -eq $script:worker -or -not $script:worker.handle.IsCompleted) { return }
        try {
            $output = $script:worker.ps.EndInvoke($script:worker.handle)
            if ($script:worker.ps.HadErrors -or $output.Count -eq 0) {
                throw '请检查 Codex 是否已登录、网络是否正常；可运行 Diagnose.cmd 查看详情。'
            }
            Set-Snapshot $output[$output.Count - 1]
        } catch {
            $script:lastError = '请检查 Codex 登录和网络；可运行 Diagnose.cmd 查看详情。'
        } finally {
            $script:worker.ps.Dispose()
            $script:worker = $null
            $script:ui.RefreshButton.IsEnabled = $true
            $script:nextFetch = [DateTimeOffset]::UtcNow.AddSeconds($script:config.pollSeconds)
            $policy = Get-CodexRefreshPolicy $script:lastSnapshot
            if ($policy.paused -and $null -ne $policy.resumeAt) { $script:nextFetch = $policy.resumeAt }
        }
    }

    function Set-Display([int]$Index = -1) {
        $script:screens = @([Windows.Forms.Screen]::AllScreens)
        if ($Index -lt 0 -or $Index -ge $script:screens.Count) {
            $Index = 0
            for ($i = 0; $i -lt $script:screens.Count; $i++) {
                if (-not $script:screens[$i].Primary) { $Index = $i; break }
            }
            for ($i = 0; $i -lt $script:screens.Count; $i++) {
                $b = $script:screens[$i].Bounds
                if (-not $script:screens[$i].Primary -and $b.Width -eq 960 -and $b.Height -eq 640) { $Index = $i; break }
            }
        }
        $script:activeScreen = $Index
        $screen = $script:screens[$Index]
        $b = if ($script:isFullscreen) { $screen.Bounds } else { $screen.WorkingArea }
        $script:window.WindowState = 'Normal'
        if ($script:isFullscreen) {
            $script:window.WindowStyle = 'None'; $script:window.ResizeMode = 'NoResize'
            $w = $b.Width; $h = $b.Height; $x = $b.X; $y = $b.Y
        } else {
            $script:window.WindowStyle = 'SingleBorderWindow'; $script:window.ResizeMode = 'CanResize'
            $w = [Math]::Min(976, $b.Width - 20); $h = [Math]::Min(680, $b.Height - 20)
            $x = $b.X + [int](($b.Width - $w) / 2); $y = $b.Y + [int](($b.Height - $h) / 2)
        }
        $handle = [Windows.Interop.WindowInteropHelper]::new($script:window).Handle
        if ($handle -ne [IntPtr]::Zero) { [void][QuotaDisplay]::SetWindowPos($handle, [IntPtr]::Zero, $x, $y, $w, $h, 0x0014) }
        $script:ui.WindowButton.Content = if ($script:isFullscreen) { '窗口' } else { '全屏' }
        $script:ui.ScreenLabel.Text = ('CODEX / 屏幕 {0} · {1} × {2}' -f ($Index + 1), $screen.Bounds.Width, $screen.Bounds.Height)
    }
    function Toggle-Fullscreen { $script:isFullscreen = -not $script:isFullscreen; Set-Display $script:activeScreen }
    function Toggle-Pin {
        $script:window.Topmost = -not $script:window.Topmost
        $script:ui.PinButton.Content = if ($script:window.Topmost) { '已置顶' } else { '置顶' }
    }
    function Next-Screen { Set-Display (($script:activeScreen + 1) % @([Windows.Forms.Screen]::AllScreens).Count) }

    $script:window.Topmost = [bool]$script:config.topmost
    $script:ui.PinButton.Content = if ($script:window.Topmost) { '已置顶' } else { '置顶' }
    . (Join-Path $script:root 'HardwarePanel.ps1')
    $script:ui.RefreshButton.Add_Click({ Start-Refresh -Force; Update-HardwarePanel -Force })
    $script:ui.ScreenButton.Add_Click({ Next-Screen })
    $script:ui.PinButton.Add_Click({ Toggle-Pin })
    $script:ui.WindowButton.Add_Click({ Toggle-Fullscreen })
    $script:ui.CloseButton.Add_Click({ $script:window.Close() })
    $script:ui.Header.Add_MouseLeftButtonDown({ if (-not $script:isFullscreen -and $_.ClickCount -eq 1) { $script:window.DragMove() } })
    $menu = [Windows.Controls.ContextMenu]::new()
    foreach ($entry in @(@('刷新数据  R','Refresh'),@('切换屏幕  Ctrl+Tab','Screen'),@('切换置顶  T','Pin'),@('窗口 / 全屏  F11','Window'),@('退出  Q','Exit'))) {
        $item = [Windows.Controls.MenuItem]::new()
        $item.Header = $entry[0]; $item.Tag = $entry[1]
        $item.Add_Click({
            param($sender, $args)
            switch ($sender.Tag) {
                'Refresh' { Start-Refresh -Force; Update-HardwarePanel -Force }
                'Screen' { Next-Screen }
                'Pin' { Toggle-Pin }
                'Window' { Toggle-Fullscreen }
                'Exit' { $script:window.Close() }
            }
        })
        [void]$menu.Items.Add($item)
    }
    $script:window.ContextMenu = $menu
    $script:window.Add_KeyDown({
        if ($_.Key -eq 'F11') { Toggle-Fullscreen; $_.Handled = $true }
        elseif ($_.Key -eq 'Escape' -and $script:isFullscreen) { Toggle-Fullscreen; $_.Handled = $true }
        elseif ($_.Key -eq 'R') { Start-Refresh -Force; Update-HardwarePanel -Force; $_.Handled = $true }
        elseif ($_.Key -eq 'T') { Toggle-Pin; $_.Handled = $true }
        elseif ($_.Key -eq 'Q') { $script:window.Close(); $_.Handled = $true }
        elseif ($_.Key -eq 'Tab' -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)) { Next-Screen; $_.Handled = $true }
    })

    if ($Demo -or $TestState) {
        $now = [DateTimeOffset]::UtcNow
        $sample = [pscustomobject]@{ rateLimits = [pscustomobject]@{
            limitId = 'codex'; planType = 'demo';
            primary = [pscustomobject]@{ usedPercent = 23; windowDurationMins = 300; resetsAt = $now.AddHours(3).AddMinutes(42).ToUnixTimeSeconds() };
            secondary = [pscustomobject]@{ usedPercent = 38; windowDurationMins = 10080; resetsAt = $now.AddDays(4).AddHours(16).AddMinutes(25).ToUnixTimeSeconds() }
        } }
        if ($TestState -eq 'Unknown') { $sample.rateLimits.primary.usedPercent = $null; $sample.rateLimits.secondary = $null }
        if ($TestState -eq 'Expired') { $sample.rateLimits.primary.resetsAt = $now.AddSeconds(-1).ToUnixTimeSeconds() }
        if ($TestState -eq 'Low') { $sample.rateLimits.primary.usedPercent = 99; $sample.rateLimits.secondary.usedPercent = 82 }
        if ($TestState -eq 'Full') { $sample.rateLimits.primary.usedPercent = 0; $sample.rateLimits.secondary.usedPercent = 100 }
        if ($TestState -eq 'Fractional') { $sample.rateLimits.primary.usedPercent = 0.1; $sample.rateLimits.secondary.usedPercent = 99.9 }
        Set-Snapshot (ConvertTo-QuotaSnapshot -Response $sample -LimitId 'codex')
        if ($Demo) {
            $script:ui.ModeLabel.Text = 'DEMO / 演示'
            $script:ui.ModeLabel.Foreground = Get-Brush '#EEC27D'
            $script:ui.ModeBadge.Background = Get-Brush '#3B3227'
            $script:ui.PlanLabel.Text = '预览界面'
            $script:ui.RefreshButton.IsEnabled = $false
        }
        if ($TestState -eq 'Offline') { $script:lastError = '网络连接失败；正在保留上次读数，稍后自动重试。' }
        if ($TestState) {
            $script:ui.ModeLabel.Text = 'TEST / 状态测试'
            $script:ui.ModeLabel.Foreground = Get-Brush '#EEC27D'
            $script:ui.ModeBadge.Background = Get-Brush '#3B3227'
            $script:ui.PlanLabel.Text = '状态测试 / 非真实额度'
        }
    } elseif ($SnapshotPath) {
        Set-Snapshot (Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } elseif ($RenderPath) {
        Set-Snapshot (Get-QuotaSnapshot -CodexPath $script:config.codexPath -LimitId $script:config.limitId)
    }
    Update-Status ([DateTimeOffset]::UtcNow)

    if ($RenderPath) {
        $panel = $script:ui.Dashboard
        $panel.Measure([Windows.Size]::new(960, 640))
        $panel.Arrange([Windows.Rect]::new(0, 0, 960, 640))
        $panel.UpdateLayout()
        $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(960, 640, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($panel)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Create([IO.Path]::GetFullPath($RenderPath))
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        Write-Output ('Rendered 960 x 640: ' + $RenderPath)
        exit 0
    }

    $script:timer = New-Object Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromSeconds(1)
    $script:timer.Add_Tick({
        try {
            $now = [DateTimeOffset]::UtcNow
            Complete-Refresh
            Update-HardwarePanel
            if ($now -ge $script:nextFetch) { Start-Refresh }
            Update-Status $now
            # Re-evaluate only when the attached display layout changes.
            $layout = (@([Windows.Forms.Screen]::AllScreens) | ForEach-Object { $_.DeviceName + $_.Bounds.ToString() }) -join ';'
            if ($script:lastLayout -and $layout -ne $script:lastLayout) { Set-Display -1 }
            $script:lastLayout = $layout
            if ($SmokeTest) {
                $script:smokeTicks++
                if ($script:smokeTicks -ge 30) { throw 'UI smoke timed out waiting for live data.' }
                if ($script:smokeTicks -ge 2 -and ($Demo -or $script:lastSnapshot -or $script:lastError)) {
                    if (-not $Demo -and -not $script:lastSnapshot) { throw 'UI live quota fetch failed.' }
                    $handle = [Windows.Interop.WindowInteropHelper]::new($script:window).Handle
                    $rect = New-Object QuotaDisplay+RECT
                    [void][QuotaDisplay]::GetWindowRect($handle, [ref]$rect)
                    $b = $script:screens[$script:activeScreen].Bounds
                    if ($rect.Left -ne $b.X -or $rect.Top -ne $b.Y -or ($rect.Right - $rect.Left) -ne $b.Width -or ($rect.Bottom - $rect.Top) -ne $b.Height) { throw 'Fullscreen bounds mismatch.' }
                    Toggle-Fullscreen
                    if ($script:isFullscreen) { throw 'Window toggle failed.' }
                    Toggle-Pin
                    Toggle-Pin
                    Toggle-Fullscreen
                    $script:smokeResult = 'UI smoke PASS: fullscreen {0}; window/fullscreen and pin toggles; source={1}.' -f $b, $(if ($Demo) { 'Demo' } else { 'Live' })
                    $script:window.Close()
                }
            }
        } catch {
            $script:lastError = '面板发生错误，请重新启动或运行 Diagnose.cmd。'
            if ($SmokeTest) { $script:smokeFailure = $_.Exception.Message; $script:window.Close() }
        }
    })
    $script:window.Add_SourceInitialized({ Set-Display ([int]$script:config.screenIndex) })
    $script:window.Add_ContentRendered({ Set-Display $script:activeScreen; Start-Refresh })
    $script:timer.Start()
    [void]$script:window.ShowDialog()
    if ($script:smokeFailure) { throw $script:smokeFailure }
    if ($SmokeTest) {
        if (-not $script:smokeResult) { throw 'UI smoke closed before verification finished.' }
        Write-Output $script:smokeResult
    }
} catch {
    $message = $_.Exception.Message
    $logDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GptHardwareCockpit'
    [void][IO.Directory]::CreateDirectory($logDirectory)
    [IO.File]::WriteAllText((Join-Path $logDirectory 'startup-error.txt'), ([DateTime]::Now.ToString('s') + "`r`n" + $message), [Text.Encoding]::UTF8)
    if ($Diagnose -or $RenderPath -or $SmokeTest) {
        Write-Error $message -ErrorAction Continue
    } else {
        try { [void][Windows.MessageBox]::Show(('启动失败：' + $message + "`n可双击 Diagnose.cmd 检查。"), '硬件驾驶舱') } catch { }
    }
    exit 1
} finally {
    if ($script:timer) { $script:timer.Stop() }
    if ($script:worker) { $script:worker.ps.Stop(); $script:worker.ps.Dispose() }
    if (Get-Command Close-HardwarePanel -ErrorAction SilentlyContinue) { Close-HardwarePanel }
    if ($script:ownsMutex) { $script:mutex.ReleaseMutex() }
    if ($script:mutex) { $script:mutex.Dispose() }
}
