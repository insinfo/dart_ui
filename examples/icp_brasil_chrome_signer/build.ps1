param([switch]$Release)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path (Join-Path $project '..\..')
$dist = Join-Path $project 'extension\dist'
$nativeDist = Join-Path $project 'native_host\dist'
New-Item -ItemType Directory -Force $dist, $nativeDist | Out-Null

Push-Location $root
try {
  dart pub get
  dart compile js "$project\extension\src\service_worker.dart" -O2 -o "$dist\service_worker.js"
  dart compile js "$project\extension\src\content_script.dart" -O2 -o "$dist\content_script.js"
  dart compile js "$project\extension\src\page_api.dart" -O2 -o "$dist\page_api.js"
  dart compile js "$project\extension\src\popup.dart" -O2 -o "$dist\popup.js"
  dart compile exe "$project\native_host\bin\main.dart" -o "$nativeDist\dart_ui_icp_signer.exe"
} finally {
  Pop-Location
}

Write-Host "Extensão pronta em $project\extension"
Write-Host "Host pronto em $nativeDist\dart_ui_icp_signer.exe"
