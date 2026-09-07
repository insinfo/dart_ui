param([switch]$Release)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path (Join-Path $project '..\..')
$dist = Join-Path $project 'extension\dist'
$firefoxDist = Join-Path $project 'extension\dist_firefox'
$nativeDist = Join-Path $project 'native_host\dist'
$appDist = Join-Path $project 'application\dist'
New-Item -ItemType Directory -Force $dist, $firefoxDist, $nativeDist, $appDist | Out-Null

Push-Location $root
try {
  dart pub get
  dart compile js "$project\extension\src\service_worker.dart" -O2 -o "$dist\service_worker.js"
  dart compile js "$project\extension\src\content_script.dart" -O2 -o "$dist\content_script.js"
  dart compile js "$project\extension\src\page_api.dart" -O2 -o "$dist\page_api.js"
  dart compile js "$project\extension\src\popup.dart" -O2 -o "$dist\popup.js"
  dart compile js "$project\web\main.dart" -O2 -o "$project\demo\main.dart.js"
  dart compile exe "$project\native_host\bin\main.dart" -o "$nativeDist\dart_ui_icp_signer.exe"
  dart run "$project\application\build.dart"

  $fontNames = @(
    'Inter-Regular.ttf',
    'Inter-Medium.ttf',
    'Inter-SemiBold.ttf',
    'MaterialIcons-Regular.ttf',
    'TablerIcons.ttf',
    'Phosphor.ttf'
  )
  $extensionFonts = Join-Path $dist 'assets\fonts'
  $demoFonts = Join-Path $project 'demo\assets\fonts'
  New-Item -ItemType Directory -Force $extensionFonts, $demoFonts | Out-Null
  foreach ($fontName in $fontNames) {
    $fontSource = Join-Path $root "assets\fonts\$fontName"
    Copy-Item -LiteralPath $fontSource -Destination $extensionFonts -Force
    Copy-Item -LiteralPath $fontSource -Destination $demoFonts -Force
  }

  $popupHtml = Get-Content -Raw -Encoding UTF8 "$project\extension\popup.html"
  $popupHtml = $popupHtml -replace 'src="dist/popup.js"', 'src="popup.js"'
  [IO.File]::WriteAllText(
    "$dist\popup.html",
    $popupHtml,
    [Text.UTF8Encoding]::new($false)
  )
  Copy-Item -LiteralPath "$project\extension\popup.css" -Destination "$dist\popup.css" -Force
  $manifest = Get-Content -Raw -Encoding UTF8 "$project\extension\manifest.json" | ConvertFrom-Json
  $manifest.background.service_worker = 'service_worker.js'
  $manifest.action.default_popup = 'popup.html'
  foreach ($entry in $manifest.content_scripts) {
    $entry.js = @($entry.js | ForEach-Object { $_ -replace '^dist/', '' })
  }
  $manifestJson = $manifest | ConvertTo-Json -Depth 10
  [IO.File]::WriteAllText(
    "$dist\manifest.json",
    $manifestJson,
    [Text.UTF8Encoding]::new($false)
  )
  Copy-Item -LiteralPath "$dist\service_worker.js" -Destination "$firefoxDist\service_worker.js" -Force
  Copy-Item -LiteralPath "$dist\content_script.js" -Destination "$firefoxDist\content_script.js" -Force
  Copy-Item -LiteralPath "$dist\page_api.js" -Destination "$firefoxDist\page_api.js" -Force
  Copy-Item -LiteralPath "$dist\popup.js" -Destination "$firefoxDist\popup.js" -Force
  $firefoxFonts = Join-Path $firefoxDist 'assets\fonts'
  New-Item -ItemType Directory -Force $firefoxFonts | Out-Null
  foreach ($fontName in $fontNames) {
    Copy-Item -LiteralPath (Join-Path $extensionFonts $fontName) -Destination $firefoxFonts -Force
  }
  [IO.File]::WriteAllText(
    "$firefoxDist\popup.html",
    $popupHtml,
    [Text.UTF8Encoding]::new($false)
  )
  Copy-Item -LiteralPath "$project\extension\popup.css" -Destination "$firefoxDist\popup.css" -Force
  Copy-Item -LiteralPath "$project\extension\manifest.firefox.json" -Destination "$firefoxDist\manifest.json" -Force
  $firefoxXpi = Join-Path $project 'extension\dart-ui-icp-brasil@insinfo.dev.xpi'
  $firefoxZip = Join-Path $project 'extension\dart-ui-icp-brasil@insinfo.dev.zip'
  if (Test-Path -LiteralPath $firefoxXpi) { Remove-Item -LiteralPath $firefoxXpi -Force }
  if (Test-Path -LiteralPath $firefoxZip) { Remove-Item -LiteralPath $firefoxZip -Force }
  Compress-Archive -Path "$firefoxDist\*" -DestinationPath $firefoxZip -CompressionLevel Optimal
  Move-Item -LiteralPath $firefoxZip -Destination $firefoxXpi
} finally {
  Pop-Location
}

Write-Host "Extensao pronta para carregar em $dist"
Write-Host "Extensao Firefox pronta em $firefoxDist"
Write-Host "Pacote Firefox pronto em $project\extension\dart-ui-icp-brasil@insinfo.dev.xpi"
Write-Host "Host pronto em $nativeDist\dart_ui_icp_signer.exe"
Write-Host "Aplicativo Windows pronto em $appDist\dart_ui_pdf_signer.exe"
