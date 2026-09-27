$script:tariffRules = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'pricing-rules.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-DeepSeekTariffState([DateTimeOffset]$At, $Rules = $script:tariffRules) {
    $utc=$At.ToUniversalTime()
    $china=$At.ToOffset([TimeSpan]::FromHours(8))
    if ($china.Year -ne $Rules.calendarYear) { return 'unknown' }
    $day=$china.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    foreach ($range in $Rules.holidayRanges) {
        if ([string]::CompareOrdinal($day,$range[0]) -ge 0 -and [string]::CompareOrdinal($day,$range[1]) -le 0) { return 'offPeak' }
    }
    if ($utc.DayOfWeek -eq [DayOfWeek]::Saturday -or $utc.DayOfWeek -eq [DayOfWeek]::Sunday) { return 'offPeak' }
    $minutes=$utc.Hour*60+$utc.Minute
    foreach ($window in $Rules.peakWindowsUtc) {
        if ($minutes -ge $window[0] -and $minutes -lt $window[1]) { return 'peak' }
    }
    return 'offPeak'
}

function Get-DeepSeekTariff([DateTimeOffset]$At = [DateTimeOffset]::UtcNow, $Rules = $script:tariffRules) {
    $state=Get-DeepSeekTariffState $At $Rules
    $next=$null
    if ($state -ne 'unknown') {
        $day=[DateTimeOffset]::new($At.UtcDateTime.Date,[TimeSpan]::Zero)
        for ($i=0; $i -lt 16 -and $null -eq $next; $i++) {
            foreach ($window in $Rules.peakWindowsUtc) {
                foreach ($minute in $window) {
                    $candidate=$day.AddDays($i).AddMinutes($minute)
                    if ($candidate -le $At) { continue }
                    $after=Get-DeepSeekTariffState $candidate $Rules
                    if ($after -ne 'unknown' -and $after -ne $state) { $next=$candidate; break }
                }
                if ($next) { break }
            }
        }
    }
    [pscustomobject]@{state=$state; nextChange=$next; verifiedOn=$Rules.verifiedOn; offPeakMultiplier=$Rules.offPeakMultiplier}
}

function Update-DeepSeekTariff {
    $now=[DateTimeOffset]::UtcNow
    # The result changes only at a window boundary. Cache the next boundary for countdown ticks.
    if (-not $script:tariffCache -or ($now - $script:tariffCacheAt).TotalSeconds -ge 60 -or ($script:tariffCache.nextChange -and $now -ge $script:tariffCache.nextChange)) {
        $script:tariffCache=Get-DeepSeekTariff $now
        $script:tariffCacheAt=$now
    }
    $tariff=$script:tariffCache
    if ($tariff.state -eq 'peak') {
        $script:ui.DsTariffTitle.Text='高峰时段 · 标准价'
        $script:ui.DsTariffTitle.Foreground=Get-Brush '#EBC48C'
        $script:ui.DsTariffBadge.Background=Get-Brush '#362E26'
        $destination='低谷'
    } elseif ($tariff.state -eq 'offPeak') {
        $script:ui.DsTariffTitle.Text='低谷时段 · 5 折'
        $script:ui.DsTariffTitle.Foreground=Get-Brush '#93DDC9'
        $script:ui.DsTariffBadge.Background=Get-Brush '#203A37'
        $destination='高峰'
    } else {
        $script:ui.DsTariffTitle.Text='计价日历待更新'
        $script:ui.DsTariffTitle.Foreground=Get-Brush '#EBC48C'
        $script:ui.DsTariffBadge.Background=Get-Brush '#362E26'
    }
    $script:ui.DsTariffNext.Text='请核对最新官网规则'
    if ($tariff.nextChange) {
        $span=$tariff.nextChange-$now
        $duration=if ($span.TotalDays -ge 1) { '{0}天 {1}小时' -f $span.Days,$span.Hours } else { '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($span.TotalHours),$span.Minutes,$span.Seconds }
        $script:ui.DsTariffNext.Text='距'+$destination+'  '+$duration
    }
    $script:ui.DsTariffBadge.ToolTip='北京时间周一至周五 09:00–12:00、14:00–18:00 为高峰；中国节假日与周末全天低谷。规则核对日期：'+$tariff.verifiedOn+'。按官网时段估算，以实际账单为准。'
}
