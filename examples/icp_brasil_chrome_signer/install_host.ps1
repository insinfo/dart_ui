param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[a-p]{32}$')]
  [string]$ExtensionId
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostExe = (Resolve-Path (Join-Path $project 'native_host\dist\dart_ui_icp_signer.exe')).Path
$installDir = Join-Path $env:LOCALAPPDATA 'DartUiIcpBrasil'
New-Item -ItemType Directory -Force $installDir | Out-Null
$installedExe = Join-Path $installDir 'dart_ui_icp_signer.exe'
Copy-Item -LiteralPath $hostExe -Destination $installedExe -Force

$manifestPath = Join-Path $installDir 'br.com.dartui.icp_signer.json'
$manifest = [ordered]@{
  name = 'br.com.dartui.icp_signer'
  description = 'Host Dart UI para certificados ICP-Brasil'
  path = $installedExe
  type = 'stdio'
  allowed_origins = @("chrome-extension://$ExtensionId/")
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8

$key = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\br.com.dartui.icp_signer'
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name '(default)' -Value $manifestPath
Write-Host "Host instalado para a extensão $ExtensionId"
