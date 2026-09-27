. (Join-Path $PSScriptRoot 'DeepSeekSource.ps1')
. (Join-Path $PSScriptRoot 'DeepSeekTariff.ps1')
$script:dsWorker = $null
$script:dsSnapshot = $null
$script:dsCurrency = ''
$script:dsState = 'missingKey'
$script:dsNextFetch = [DateTimeOffset]::UtcNow
$script:dsStamp = ''

function Format-DeepSeekMoney($Value) {
    if ($null -eq $Value) { return '--' }
    return ([decimal]$Value).ToString('0.00##########################', [Globalization.CultureInfo]::InvariantCulture)
}

function Show-DeepSeekBalance {
    Update-DeepSeekTariff
    $rows = @()
    if ($script:dsSnapshot) { $rows = @($script:dsSnapshot.balances) }
    $selected = $rows | Where-Object { $_.currency -eq $script:dsCurrency } | Select-Object -First 1
    if (-not $selected -and $rows.Count -gt 0) {
        $selected = $rows | Where-Object { $_.currency -eq 'CNY' } | Select-Object -First 1
        if (-not $selected) { $selected = $rows[0] }
        $script:dsCurrency = $selected.currency
    }
    $script:ui.DsCurrencyButton.IsEnabled = $rows.Count -gt 1
    $script:ui.DsCurrencyButton.Content = if ($selected) { $selected.currency + $(if ($rows.Count -gt 1) { ' ↔' } else { '' }) } else { '币种 --' }
    $script:ui.DsSymbol.Text = if ($selected) { if ($selected.currency -eq 'CNY') { '¥' } else { '$' } } else { '' }
    $script:ui.DsTotal.Text = Format-DeepSeekMoney $selected.total
    $messages = @{
        missingKey='尚未连接 · 点击「设置密钥」'; keyError='密钥无法解密 · 请重新设置';
        connecting='正在连接 DeepSeek…'; authError='密钥无效或无权限 · 请重新设置';
        networkError='连接失败 · 稍后自动重试'; serviceError='服务暂不可用 · 稍后自动重试';
        rateLimited='请求过于频繁 · 稍后重试'; invalidData='余额数据异常 · 稍后重试'
    }
    $color = '#A8BBD7'
    $text = $messages[$script:dsState]
    if ($script:dsState -eq 'ok') {
        if (-not $selected -or $null -eq $selected.total) { $text='已连接 · 服务未提供该项余额' }
        elseif (-not $script:dsSnapshot.isAvailable) { $text='余额不足 · 当前不可调用 API'; $color='#F0B485' }
        else { $text='已连接 · 可用于 API 调用'; $color='#96DCC8' }
    } elseif ($script:dsSnapshot) { $text += ' · 显示上次余额'; $color='#EEC27D' }
    if (Test-DeepSeekDepleted $script:dsSnapshot) { $text='余额耗尽 · 已暂停查询'; $color='#EEC27D' }
    if ($Demo -or $TestState) { $text='演示余额 · 非真实账户数据'; $color='#EEC27D' }
    if ($script:dsSnapshot) {
        $stamp = [DateTimeOffset]::Parse($script:dsSnapshot.fetchedAt)
        $script:ui.DsSync.Text = 'DS 同步 ' + $stamp.ToLocalTime().ToString('HH:mm:ss')
        if (([DateTimeOffset]::UtcNow - $stamp).TotalSeconds -gt 150 -and -not (Test-DeepSeekDepleted $script:dsSnapshot) -and -not ($Demo -or $TestState)) {
            $text = '余额已过期 · 正在重试'; $color='#EEC27D'
        }
    } else { $script:ui.DsSync.Text = '独立刷新 / 60 秒' }
    $script:ui.DsStatus.ToolTip = "充值后按 R 或右键刷新恢复同步。`n" + $script:ui.DsSync.Text
    $script:ui.DsStatus.Text = $text
    $script:ui.DsStatus.Foreground = Get-Brush $color
}

function Start-DeepSeekRefresh([switch]$Force) {
    if ($Demo -or $TestState -or $script:dsWorker) { return }
    if (-not $Force -and (Test-DeepSeekDepleted $script:dsSnapshot)) { return }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript('param($source); $ErrorActionPreference="Stop"; . $source; Get-DeepSeekBalance').AddArgument((Join-Path $script:root 'DeepSeekSource.ps1'))
    $script:dsWorker = @{ps=$ps; handle=$ps.BeginInvoke()}
    if (-not $script:dsSnapshot) { $script:dsState='connecting' }
    Show-DeepSeekBalance
}

function Update-DeepSeekPanel {
    if ($Demo -or $TestState) { Update-DeepSeekTariff; return }
    $path = Get-DeepSeekCredentialPath
    $stamp = if (Test-Path -LiteralPath $path) { [IO.File]::GetLastWriteTimeUtc($path).Ticks.ToString() } else { 'none' }
    if ($stamp -ne $script:dsStamp) {
        $script:dsStamp = $stamp
        if ($script:dsWorker) { $script:dsWorker.ps.Stop(); $script:dsWorker.ps.Dispose(); $script:dsWorker=$null }
        # A new key can belong to a different account. Never keep the previous account's balance.
        $script:dsSnapshot=$null
        $script:dsCurrency=''
        $script:dsNextFetch=[DateTimeOffset]::UtcNow
    }
    if ($script:dsWorker -and $script:dsWorker.handle.IsCompleted) {
        try {
            $result = $script:dsWorker.ps.EndInvoke($script:dsWorker.handle)
            if ($script:dsWorker.ps.HadErrors -or $result.Count -eq 0) { throw 'DS_READ_FAILED' }
            $data = $result[$result.Count - 1]
            $script:dsState = $data.status
            if ($data.status -eq 'ok') { $script:dsSnapshot=$data }
        } catch { $script:dsState='networkError' }
        finally {
            $script:dsWorker.ps.Dispose(); $script:dsWorker=$null
            $script:dsNextFetch=[DateTimeOffset]::UtcNow.AddSeconds(60)
        }
    }
    if ([DateTimeOffset]::UtcNow -ge $script:dsNextFetch) { Start-DeepSeekRefresh }
    Show-DeepSeekBalance
}

$script:ui.DsSetupButton.Add_Click({
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $file=Join-Path $script:root 'Set-DeepSeekKey.ps1'
    Start-Process -FilePath $exe -ArgumentList ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $file + '"') -WindowStyle Hidden
})
$script:ui.DsCurrencyButton.Add_Click({
    if ($script:dsSnapshot -and @($script:dsSnapshot.balances).Count -gt 1) {
        $currencies = @($script:dsSnapshot.balances | ForEach-Object { $_.currency })
        $index = [Array]::IndexOf($currencies,$script:dsCurrency)
        $script:dsCurrency=$currencies[(($index+1)%$currencies.Count)]
        Show-DeepSeekBalance
    }
})
if ($Demo -or $TestState) {
    $script:dsSnapshot=ConvertTo-DeepSeekBalance ([pscustomobject]@{is_available=$true; balance_infos=@([pscustomobject]@{currency='CNY'; total_balance='128.50'; granted_balance='8.50'; topped_up_balance='120.00'})})
    $script:dsState='ok'
} elseif ($RenderPath) {
    $result=Get-DeepSeekBalance
    $script:dsState=$result.status
    if ($result.status -eq 'ok') { $script:dsSnapshot=$result }
}
Show-DeepSeekBalance
