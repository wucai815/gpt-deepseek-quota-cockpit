#requires -Version 5.1
[CmdletBinding()]
param([switch]$Console)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
. (Join-Path $PSScriptRoot 'DeepSeekSource.ps1')
if ($Console) {
    $inputKey=Read-Host 'DeepSeek API Key (hidden)' -AsSecureString
    try { Save-DeepSeekCredential -SecureKey $inputKey; Write-Output 'Encrypted credential saved and verified.' }
    finally { $inputKey.Dispose() }
    exit
}
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="连接 DeepSeek 余额" Width="510" Height="340" ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Background="#141E2E" Foreground="#EDF3FA" FontFamily="Microsoft YaHei UI">
 <Grid Margin="26"><Grid.RowDefinitions><RowDefinition Height="43"/><RowDefinition Height="55"/><RowDefinition Height="42"/><RowDefinition Height="50"/><RowDefinition Height="*"/></Grid.RowDefinitions>
 <TextBlock Text="连接 DeepSeek 开放平台" FontSize="23" FontWeight="SemiBold"/>
 <TextBlock Grid.Row="1" Text="在下方粘贴 API Key。密钥仅保存在本机当前用户的加密存储中，用于读取官方余额接口。" FontSize="14" TextWrapping="Wrap" Foreground="#A9BBD2"/>
 <PasswordBox x:Name="KeyBox" Grid.Row="2" FontSize="18" Padding="9" Background="#22314A" Foreground="White" BorderBrush="#4065A4"/>
 <TextBlock x:Name="Message" Grid.Row="3" Text="保存后，面板会自动读取余额。密钥不会放入项目或 ZIP。" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center" Foreground="#9CAEC6"/>
 <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom">
 <Button x:Name="Cancel" Content="取消" Padding="16,8" Margin="0,0,10,0"/>
 <Button x:Name="Save" Content="保存并连接" Padding="16,8" Background="#548DFF" Foreground="White" BorderThickness="0"/>
 </StackPanel></Grid>
</Window>
'@
$reader = New-Object Xml.XmlNodeReader($xaml)
$dialog = [Windows.Markup.XamlReader]::Load($reader)
$reader.Close()
$keyBox = $dialog.FindName('KeyBox')
$message = $dialog.FindName('Message')
$dialog.FindName('Cancel').Add_Click({ $dialog.Close() })
$dialog.FindName('Save').Add_Click({
    $secret = $null
    try {
        $secret = $keyBox.Password.Trim()
        if ([string]::IsNullOrWhiteSpace($secret) -or $secret -match '\s') {
            $message.Text = '请粘贴完整的 API Key，不能包含空格或换行。'
            return
        }
        $secure = ConvertTo-SecureString -String $secret -AsPlainText -Force
        Save-DeepSeekCredential -SecureKey $secure
        $keyBox.Clear()
        $dialog.Close()
    } catch { $message.Text = '保存失败（' + $_.Exception.GetType().Name + '）。请重试或使用控制台设置入口。' }
    finally { $secret = $null }
})
[void]$dialog.ShowDialog()
