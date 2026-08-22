<#
.SYNOPSIS
  Executa o POC-02 (Janela X11 / OpenGL via EGL) no Linux (Ubuntu) utilizando o WSLg.

.DESCRIPTION
  Este script executa dart pub get no Linux, recompila bin/main_linux.dart para AOT
  e executa o ELF resultante diretamente no WSL / Ubuntu. Também oferece GDB.

.PARAMETER Aot
  Mantido por compatibilidade. A execução agora sempre usa AOT.

.PARAMETER Compile
  Executa dart pub get e compila o AOT, sem iniciar a aplicação.

.PARAMETER Gdb
  Inicia a execução dentro do depurador GDB no WSL. A compilação gera
  bin/main_linux.aot.debug para simbolizar o código AOT.

.PARAMETER Distro
  Nome da distribuição WSL. O padrão é Ubuntu.

.PARAMETER Display
  DISPLAY X11 explícito. Quando omitido, usa WSLg normalmente e seleciona
  automaticamente o VcXsrv em :1 se o Weston estiver em COPY MODE.

.PARAMETER WslgOnly
  Não usa o fallback automático do VcXsrv, mesmo em COPY MODE.

.PARAMETER GalliumDriver
  Driver Mesa: auto, d3d12 ou llvmpipe. O modo auto só usa D3D12 quando o
  servidor X11 anuncia DRI3 ou quando a build Mesa corrigida está disponível.

.PARAMETER MesaPrefix
  Prefixo de uma instalação Mesa isolada. O padrão auto usa
  /opt/mesa-26.3-git quando disponível e nunca substitui os pacotes da distro.

.PARAMETER D3D12FrontbufferThreads
  Quantidade de trabalhadores persistentes usada pela correção experimental do
  frontbuffer D3D12. O padrão 32 foi o melhor resultado nesta máquina.

.EXAMPLE
  .\bin\run_linux.ps1
  .\bin\run_linux.ps1 --continuous
  .\bin\run_linux.ps1 -Aot --continuous
  .\bin\run_linux.ps1 -Compile
  .\bin\run_linux.ps1 -Gdb --frames 10
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Aot,
    [switch]$Compile,
    [switch]$Gdb,
    [switch]$WslgOnly,
    [string]$Distro = "Ubuntu",
    [string]$Display,
    [ValidateSet("auto", "d3d12", "llvmpipe")]
    [string]$GalliumDriver = "auto",
    [string]$MesaPrefix = "auto",
    [ValidateRange(1, 64)]
    [int]$D3D12FrontbufferThreads = 32,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$DartArgs
)

$ErrorActionPreference = "Stop"

# Localiza o diretório raiz da POC (onde fica o pubspec.yaml)
$pocDir = Split-Path -Parent $PSScriptRoot
$repoDir = (Resolve-Path (Join-Path $pocDir "..\..")).Path

function ConvertTo-BashLiteral([string]$Value) {
    $quote = [string][char]39
    $escapedQuote = $quote + '"' + $quote + '"' + $quote
    return $quote + $Value.Replace($quote, $escapedQuote) + $quote
}

function Test-TcpPort([int]$Port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $client.Connect("127.0.0.1", $Port)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Start-VcXsrvDisplay {
    $port = 6001
    if (-not (Test-TcpPort $port)) {
        $candidates = @(
            (Join-Path $env:ProgramFiles "VcXsrv\vcxsrv.exe"),
            (Join-Path ${env:ProgramFiles(x86)} "VcXsrv\vcxsrv.exe")
        )
        $vcXsrv = $candidates |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
            Select-Object -First 1
        if (-not $vcXsrv) {
            throw "WSLg esta em COPY MODE e o VcXsrv nao foi encontrado. " +
                  "Instale com: winget install --id marha.VcXsrv --exact"
        }
        Write-Host "🖥️  Iniciando VcXsrv no display :1..." -ForegroundColor Yellow
        Start-Process -FilePath $vcXsrv `
            -ArgumentList @(':1', '-multiwindow', '-clipboard', '-wgl', '-ac',
                            '-silent-dup-error') `
            -WindowStyle Hidden | Out-Null
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            Start-Sleep -Milliseconds 250
            if (Test-TcpPort $port) { break }
        }
        if (-not (Test-TcpPort $port)) {
            throw "VcXsrv iniciou, mas nao abriu a porta X11 6001."
        }
    }

    $routes = (& wsl.exe -d "$Distro" -- ip route show default 2>$null) -join "`n"
    $gatewayMatch = [regex]::Match($routes, 'default\s+via\s+([0-9.]+)')
    if (-not $gatewayMatch.Success) {
        throw "Nao foi possivel descobrir o gateway do WSL para o VcXsrv."
    }
    return "$($gatewayMatch.Groups[1].Value):1.0"
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  POC-02: Executando no Linux (WSL / X11)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Diretorio: $pocDir" -ForegroundColor DarkGray

# Monta a string de argumentos para a aplicação
$filteredArgs = @()
foreach ($arg in $DartArgs) {
    if ($arg -in @('-a', '--aot', '-Aot')) {
        $Aot = $true
    } elseif ($arg -in @('--compile', '-Compile')) {
        $Compile = $true
    } elseif ($arg -in @('-g', '--gdb', '-Gdb')) {
        $Gdb = $true
    } else {
        $filteredArgs += $arg
    }
}

$argsStr = ""
if ($filteredArgs.Count -gt 0) {
    $argsStr = " " + (($filteredArgs | ForEach-Object { ConvertTo-BashLiteral $_ }) -join " ")
}

# Sempre resolva as dependências e recompile dentro do Linux. Como esta POC é
# membro de um pub workspace, o pub get atualiza o package_config.json da raiz.
# Preserve a versão do host para não quebrar dart analyze/test no Windows.
Write-Host "📦 Resolvendo dependencias com dart pub get no WSL..." -ForegroundColor Yellow
Write-Host "🔨 Compilando main_linux.dart para AOT no WSL..." -ForegroundColor Yellow
$packageConfigPath = Join-Path $repoDir ".dart_tool\package_config.json"
$hadPackageConfig = Test-Path -LiteralPath $packageConfigPath
$packageConfigBytes = if ($hadPackageConfig) {
    [System.IO.File]::ReadAllBytes($packageConfigPath)
} else {
    $null
}
$buildCmd = 'if command -v dart >/dev/null 2>&1; then DART=dart; ' +
            'elif [ -x /opt/dart-sdk-3.6.2/bin/dart ]; then DART=/opt/dart-sdk-3.6.2/bin/dart; ' +
            'elif [ -x /opt/dart-sdk/bin/dart ]; then DART=/opt/dart-sdk/bin/dart; ' +
            'elif [ -x "$HOME/dart-sdk/bin/dart" ]; then DART="$HOME/dart-sdk/bin/dart"; ' +
            'else echo "ERRO: Dart SDK nao encontrado no WSL."; exit 1; fi; ' +
            '$DART pub get && ' +
            '$DART compile exe bin/main_linux.dart ' +
            '--save-debugging-info=bin/main_linux.aot.debug ' +
            '-o bin/main_linux.aot'
$buildExitCode = 1
try {
    & wsl.exe -d "$Distro" --cd "$pocDir" -e bash -c $buildCmd
    $buildExitCode = $LASTEXITCODE
} finally {
    if ($hadPackageConfig) {
        [System.IO.File]::WriteAllBytes($packageConfigPath, $packageConfigBytes)
    } elseif (Test-Path -LiteralPath $packageConfigPath) {
        Remove-Item -LiteralPath $packageConfigPath -Force
    }
}
if ($buildExitCode -ne 0) {
    Write-Host "❌ Falha no dart pub get ou na compilacao AOT." -ForegroundColor Red
    exit $buildExitCode
}
Write-Host "✅ AOT atualizado: bin/main_linux.aot" -ForegroundColor Green
Write-Host "✅ Simbolos AOT: bin/main_linux.aot.debug" -ForegroundColor Green
if ($Compile -and -not $Gdb) {
    exit 0
}

$westonLog = (& wsl.exe -d "$Distro" -- cat /mnt/wslg/weston.log 2>$null) -join "`n"
$gfxredirMatches = [regex]::Matches(
    $westonLog,
    'RDP backend: use_gfxredir\s*=\s*([01])'
)
$copyMode = if ($gfxredirMatches.Count -gt 0) {
    $gfxredirMatches[$gfxredirMatches.Count - 1].Groups[1].Value -eq '0'
} else {
    $westonLog -match '\[WARN:COPY MODE\]'
}
if ($copyMode) {
    Write-Warning "WSLg iniciou em [WARN:COPY MODE]. A janela pode aparecer apenas como icone transparente; veja microsoft/wslg#1456."
} elseif ($gfxredirMatches.Count -gt 0) {
    Write-Host "✅ WSLg gfxredir ativo (memoria compartilhada funcionando)." -ForegroundColor Green
}

$selectedDisplay = $Display
$usingVcXsrvFallback = $false
if (-not $selectedDisplay -and $copyMode -and -not $WslgOnly) {
    $selectedDisplay = Start-VcXsrvDisplay
    $usingVcXsrvFallback = $true
    Write-Host "✅ Fallback X11 ativo: DISPLAY=$selectedDisplay" -ForegroundColor Green
}

$externalDisplay = $usingVcXsrvFallback -or
                   ($selectedDisplay -and -not $selectedDisplay.StartsWith(':'))
$displayToProbe = if ($selectedDisplay) { $selectedDisplay } else { ':0' }
$dri3ProbeCmd = 'DISPLAY=' + (ConvertTo-BashLiteral $displayToProbe) +
                ' xdpyinfo -queryExtensions 2>/dev/null'
$x11Extensions = (& wsl.exe -d "$Distro" -- bash -c $dri3ProbeCmd 2>$null) -join "`n"
$supportsDri3 = $x11Extensions -match '(?m)^\s*DRI3\b'

$mesaCandidate = if ($MesaPrefix -eq "auto") {
    "/opt/mesa-26.3-git"
} else {
    $MesaPrefix.TrimEnd('/')
}
$mesaManifest = "$mesaCandidate/share/glvnd/egl_vendor.d/50_mesa.json"
$mesaProbeCmd = 'test -f ' + (ConvertTo-BashLiteral $mesaManifest)
& wsl.exe -d "$Distro" -- bash -c $mesaProbeCmd 2>$null
$customMesaAvailable = $LASTEXITCODE -eq 0
if ($MesaPrefix -ne "auto" -and -not $customMesaAvailable) {
    throw "MesaPrefix invalido: nao existe $mesaManifest na distro $Distro."
}
$resolvedMesaPrefix = if ($customMesaAvailable) { $mesaCandidate } else { $null }

$resolvedGalliumDriver = if ($GalliumDriver -ne "auto") {
    $GalliumDriver
} elseif ($customMesaAvailable) {
    "d3d12"
} elseif ($externalDisplay -or -not $supportsDri3) {
    "llvmpipe"
} else {
    "d3d12"
}
$useX11ReadbackBridge = $resolvedGalliumDriver -eq "d3d12" -and
                        -not $supportsDri3 -and
                        -not $customMesaAvailable
if ($resolvedGalliumDriver -eq "llvmpipe" -and -not $supportsDri3) {
    Write-Host "✅ Mesa llvmpipe selecionado: X11 DISPLAY=$displayToProbe nao anuncia DRI3 " `
               "(evita quadro preto/readback lento do D3D12)." -ForegroundColor Green
} elseif ($useX11ReadbackBridge) {
    Write-Host "✅ D3D12 ativo com ponte GPU readback -> XCB PutImage: " `
               "X11 DISPLAY=$displayToProbe nao anuncia DRI3." -ForegroundColor Green
} else {
    Write-Host "🎨 Mesa GALLIUM_DRIVER=$resolvedGalliumDriver" -ForegroundColor Cyan
}
if ($resolvedMesaPrefix) {
    Write-Host "✅ Mesa isolado: $resolvedMesaPrefix" -ForegroundColor Green
    if ($resolvedGalliumDriver -eq "d3d12") {
        Write-Host "✅ Workaround D3D12: $D3D12FrontbufferThreads trabalhadores " `
                   "persistentes para o frontbuffer." -ForegroundColor Green
    }
}

# Monta o comando de execução
$displayExport = if ($selectedDisplay) {
    'export DISPLAY=' + (ConvertTo-BashLiteral $selectedDisplay) + '; '
} else {
    'export DISPLAY="${DISPLAY:-:0}"; '
}
$mesaEnvironment = if ($resolvedMesaPrefix) {
    $mesaLibDir = "$resolvedMesaPrefix/lib/x86_64-linux-gnu"
    'export LD_LIBRARY_PATH=' + (ConvertTo-BashLiteral "$mesaLibDir`:/usr/lib/wsl/lib") +
    ':"${LD_LIBRARY_PATH}"; ' +
    'export LIBGL_DRIVERS_PATH=' + (ConvertTo-BashLiteral "$mesaLibDir/dri") + '; ' +
    'export __EGL_VENDOR_LIBRARY_FILENAMES=' +
    (ConvertTo-BashLiteral "$resolvedMesaPrefix/share/glvnd/egl_vendor.d/50_mesa.json") + '; '
} else {
    'export LD_LIBRARY_PATH="/usr/lib/wsl/lib:${LD_LIBRARY_PATH}"; '
}
$envPrefix = $displayExport +
             $mesaEnvironment +
             'export GALLIUM_DRIVER=' +
             (ConvertTo-BashLiteral $resolvedGalliumDriver) + '; ' +
             'export MESA_LOG_FILE=/dev/null; '
if ($resolvedMesaPrefix -and $resolvedGalliumDriver -eq "d3d12") {
    $envPrefix += 'export D3D12_FRONTBUFFER_THREADS=' +
                  (ConvertTo-BashLiteral $D3D12FrontbufferThreads.ToString()) + '; '
}
if ($useX11ReadbackBridge) {
    $envPrefix += 'export POC02_X11_READBACK=1; '
}

if ($Gdb) {
    Write-Host "🐞 Iniciando no GDB..." -ForegroundColor Magenta
    $runCmd = $envPrefix + "gdb -ex run -ex bt --args bin/main_linux.aot$argsStr"
} else {
    $runCmd = "$envPrefix bin/main_linux.aot$argsStr"
}

# Executa via WSL
& wsl.exe -d "$Distro" --cd "$pocDir" -e bash -c $runCmd
$code = $LASTEXITCODE

exit $code
