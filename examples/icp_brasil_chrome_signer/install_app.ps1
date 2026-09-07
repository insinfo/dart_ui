param(
  [string]$ExtensionId,
  [switch]$DesktopShortcut
)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $MyInvocation.MyCommand.Path
$appSource = Join-Path $project 'application\dist\dart_ui_pdf_signer.exe'
$hostSource = Join-Path $project 'native_host\dist\dart_ui_icp_signer.exe'
if (!(Test-Path -LiteralPath $appSource) -or !(Test-Path -LiteralPath $hostSource)) {
  throw 'Execute build.ps1 antes de instalar.'
}

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\DartUiAssinador'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$appTarget = Join-Path $installDir 'Dart UI Assinador.exe'
Copy-Item -LiteralPath $appSource -Destination $appTarget -Force

$shell = New-Object -ComObject WScript.Shell
$programs = [Environment]::GetFolderPath('Programs')
$startMenuDir = Join-Path $programs 'Dart UI'
New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null
$shortcut = $shell.CreateShortcut((Join-Path $startMenuDir 'Dart UI Assinador.lnk'))
$shortcut.TargetPath = $appTarget
$shortcut.WorkingDirectory = $installDir
$shortcut.Description = 'Assinador de PDF PAdES com certificados ICP-Brasil'
$shortcut.Save()

$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DartUiAssinador'
New-Item -Path $uninstallKey -Force | Out-Null
Set-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'Dart UI Assinador ICP-Brasil'
Set-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value '0.2.0'
Set-ItemProperty -Path $uninstallKey -Name Publisher -Value 'Dart UI'
Set-ItemProperty -Path $uninstallKey -Name DisplayIcon -Value $appTarget
Set-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $installDir
Set-ItemProperty -Path $uninstallKey -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $uninstallKey -Name NoRepair -Value 1 -Type DWord
$uninstallScript = Join-Path $installDir 'uninstall.ps1'
Copy-Item -LiteralPath (Join-Path $project 'uninstall_app.ps1') -Destination $uninstallScript -Force
Set-ItemProperty -Path $uninstallKey -Name UninstallString -Value "powershell.exe -ExecutionPolicy Bypass -File `"$uninstallScript`""

if ($DesktopShortcut) {
  $desktop = [Environment]::GetFolderPath('Desktop')
  $desktopLink = $shell.CreateShortcut((Join-Path $desktop 'Dart UI Assinador.lnk'))
  $desktopLink.TargetPath = $appTarget
  $desktopLink.WorkingDirectory = $installDir
  $desktopLink.Description = 'Assinador de PDF PAdES com certificados ICP-Brasil'
  $desktopLink.Save()
}

if ($ExtensionId) {
  & (Join-Path $project 'install_host.ps1') -ExtensionId $ExtensionId
}

Write-Host "Dart UI Assinador instalado em $appTarget"
Write-Host 'Atalho criado no Menu Iniciar.'
