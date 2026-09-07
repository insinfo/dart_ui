$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\br.com.dartui.icp_signer'
if (Test-Path $key) { Remove-Item -LiteralPath $key -Force }
Write-Host 'Registro do host nativo removido. Os binários foram preservados.'
