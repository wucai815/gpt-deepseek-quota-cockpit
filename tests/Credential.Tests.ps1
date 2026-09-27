$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'DeepSeekSource.ps1')
$script:fixturePath=Join-Path ([IO.Path]::GetTempPath()) ('quota-credential-fixture-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
function Get-DeepSeekCredentialPath { return $script:fixturePath }
try {
    $secure=ConvertTo-SecureString 'fixture-not-a-real-api-key' -AsPlainText -Force
    Save-DeepSeekCredential -SecureKey $secure
    $serialized=[IO.File]::ReadAllText($script:fixturePath)
    if ($serialized.Contains('fixture-not-a-real-api-key')) { throw 'Plaintext credential stored.' }
    if ((Get-DeepSeekApiKey) -ne 'fixture-not-a-real-api-key') { throw 'Credential roundtrip failed.' }
    Save-DeepSeekCredential -SecureKey (ConvertTo-SecureString 'replacement-fixture' -AsPlainText -Force)
    if ((Get-DeepSeekApiKey) -ne 'replacement-fixture') { throw 'Credential replacement failed.' }
} finally {
    if (Test-Path -LiteralPath $script:fixturePath) { Remove-Item -LiteralPath $script:fixturePath -Force }
}
# Exercise the actual dialog callback with a save stub; never touch the user's credential.
$source=[IO.File]::ReadAllText((Join-Path $root 'Set-DeepSeekKey.ps1'))
$source=$source.Replace('$PSScriptRoot', ("'"+$root.Replace("'","''")+"'"))
$source=$source.Replace('Save-DeepSeekCredential -SecureKey $secure', '$script:callbackLength=$secure.Length')
$source=$source.Replace('[void]$dialog.ShowDialog()', @'
$keyBox.Password='dialog-fixture'
$dialog.FindName('Save').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
if ($script:callbackLength -ne 14 -or $keyBox.Password.Length -ne 0) { throw 'Dialog save callback failed.' }
'@)
& ([scriptblock]::Create($source))
Write-Output 'PASS: encrypted save, decrypt, replacement, and dialog save callback. No real key printed or changed.'
