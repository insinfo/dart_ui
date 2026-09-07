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
$manifestJson = $manifest | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($manifestPath, $manifestJson, [Text.UTF8Encoding]::new($false))

$firefoxManifestPath = Join-Path $installDir 'br.com.dartui.icp_signer.firefox.json'
$firefoxManifest = [ordered]@{
  name = 'br.com.dartui.icp_signer'
  description = 'Host Dart UI para certificados ICP-Brasil'
  path = $installedExe
  type = 'stdio'
  allowed_extensions = @('dart-ui-icp-brasil@insinfo.dev')
}
$firefoxManifestJson = $firefoxManifest | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($firefoxManifestPath, $firefoxManifestJson, [Text.UTF8Encoding]::new($false))

$registryKeys = @(
  'HKCU:\Software\Google\Chrome\NativeMessagingHosts\br.com.dartui.icp_signer',
  'HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\br.com.dartui.icp_signer',
  'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\br.com.dartui.icp_signer'
)
foreach ($key in $registryKeys) {
  New-Item -Path $key -Force | Out-Null
  Set-ItemProperty -Path $key -Name '(default)' -Value $manifestPath
}
$firefoxKey = 'HKCU:\Software\Mozilla\NativeMessagingHosts\br.com.dartui.icp_signer'
New-Item -Path $firefoxKey -Force | Out-Null
Set-ItemProperty -Path $firefoxKey -Name '(default)' -Value $firefoxManifestPath
Write-Host "Host instalado para Chrome, Brave, Edge e Firefox; extensao $ExtensionId"
