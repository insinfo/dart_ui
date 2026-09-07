$ErrorActionPreference = 'Stop'
$registryKeys = @(
  'HKCU:\Software\Google\Chrome\NativeMessagingHosts\br.com.dartui.icp_signer',
  'HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\br.com.dartui.icp_signer',
  'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\br.com.dartui.icp_signer'
)
foreach ($key in $registryKeys) {
  if (Test-Path $key) { Remove-Item -LiteralPath $key -Force }
}
Write-Host 'Registro do host nativo removido. Os binários foram preservados.'
