$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\DartUiAssinador'
$programs = [Environment]::GetFolderPath('Programs')
$startMenuLink = Join-Path $programs 'Dart UI\Dart UI Assinador.lnk'
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Dart UI Assinador.lnk'

foreach ($link in @($startMenuLink, $desktopLink)) {
  if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
}
if (Test-Path -LiteralPath $installDir) {
  $resolved = (Resolve-Path -LiteralPath $installDir).Path
  $expected = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\DartUiAssinador'))
  if ($resolved -ne $expected) { throw "Diretorio de instalacao inesperado: $resolved" }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DartUiAssinador'
if (Test-Path $uninstallKey) { Remove-Item -LiteralPath $uninstallKey -Force }
Write-Host 'Dart UI Assinador removido.'
