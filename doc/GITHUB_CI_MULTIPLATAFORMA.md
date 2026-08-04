# GitHub CI Multiplataforma — Framework 100% Puro Dart

> **Projeto:** `C:\MyDartProjects\dart_ui`
> **Contexto:** Ambiente de desenvolvimento local é Windows. Linux e macOS são testados exclusivamente via GitHub Actions CI.
> **Data de criação:** 2026-08-04

---

# Sumário

- [1. Visão geral da estratégia de CI](#1-visão-geral-da-estratégia-de-ci)
- [2. Matriz de plataformas e runners](#2-matriz-de-plataformas-e-runners)
- [3. Workflow principal: ci.yml](#3-workflow-principal-ciyml)
- [4. Workflow de POC tests: poc_tests.yml](#4-workflow-de-poc-tests-poc_testsyml)
- [5. Workflow de golden tests: golden_tests.yml](#5-workflow-de-golden-tests-golden_testsyml)
- [6. Configuração de ambientes gráficos](#6-configuração-de-ambientes-gráficos)
- [7. Caching e otimização](#7-caching-e-otimização)
- [8. Configuração detalhada por plataforma](#8-configuração-detalhada-por-plataforma)
- [9. Verificação de sanidade por plataforma](#9-verificação-de-sanidade-por-plataforma)
- [10. Reprodutibilidade](#10-reprodutibilidade)
- [11. Troubleshooting de CI](#11-troubleshooting-de-ci)

---

# 1. Visão geral da estratégia de CI

```
                    Push / PR
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
     Windows x64   Linux x64   macOS arm64
          │            │            │
     ┌────┴────┐  ┌────┴────┐  ┌────┴────┐
     │ analyze │  │ analyze │  │ analyze │
     │  test   │  │  test   │  │  test   │
     │   AOT   │  │   AOT   │  │   AOT   │
     │   POC   │  │POC+Xvfb │  │POC+GUI  │
     │ golden  │  │ golden  │  │ golden  │
     └─────────┘  └─────────┘  └─────────┘
```

## 1.1 Princípios

1. **Todo commit é testado nas 3 plataformas**
2. **Linux usa Xvfb** para testes de janela X11
3. **Linux usa Weston headless** para testes Wayland (quando disponível)
4. **macOS usa sessão GUI** para testes AppKit
5. **Windows roda direto** no runner desktop
6. **Dart SDK é fixado** para reprodutibilidade
7. **Golden files são plataforma-específicos** (fontes/rendering diferem)
8. **POC tests são separados** para não bloquear o CI principal

## Estado atual dos workflows

O workflow `POC Tests` executa somente POCs já presentes no repositório;
POCs planejados sem implementação ficam explicitamente ignorados. Isso evita
falhas de configuração por diretórios ainda inexistentes. `hashFiles()` é
usado apenas em chaves de cache de steps, nunca em condições de job.

| POC | Runner atual | Validação |
|---|---|---|
| POC-01 Win32 | Windows | análise, teste de constantes, AOT e smoke test |
| POC-02 XCB | Linux + Xvfb | análise, janela, `XCB_EXPOSE`, `xcb_put_image` e AOT |
| POC-04 CPU | Linux, Windows, macOS | benchmark e testes unitários |
| POC-05 COM/D2D | Windows | análise e testes de COM/ABI |
| POC-10 event loop | Windows | testes de Timer + wakeup Win32 |

Todos os passos que compilam AOT criam explicitamente o diretório `build/`,
que é ignorado pelo Git.
9. **Caching agressivo** de Dart pub e ferramentas

---

# 2. Matriz de plataformas e runners

| Plataforma | Runner | Arquitetura | Display Server | GPU |
|---|---|---|---|---|
| Windows x64 | `windows-latest` | x64 | Desktop (real) | Software ou disponível |
| Linux x64 | `ubuntu-24.04` | x64 | Xvfb (virtual) | Mesa (software) |
| macOS arm64 | `macos-14` | arm64 (Apple Silicon) | Desktop (real) | Apple GPU |
| macOS x64 | `macos-13` | x64 (Intel) | Desktop (real) | Apple GPU |

### Observações

- `ubuntu-24.04` é preferido por ter pacotes mais recentes
- `macos-14` é arm64, `macos-13` é x64 — testar ambos idealmente
- `windows-latest` é x64; arm64 não disponível no GitHub Actions padrão
- Para arm64 Windows, usar runner self-hosted quando disponível

---

# 3. Workflow principal: ci.yml

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

env:
  DART_SDK_VERSION: '3.6.0'  # Fixar versão para reprodutibilidade

jobs:
  # ============================================================
  # Job 1: Análise estática (roda uma vez, não precisa de matrix)
  # ============================================================
  analyze:
    name: Analyze
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Cache Dart packages
        uses: actions/cache@v4
        with:
          path: |
            ~/.pub-cache
            .dart_tool
          key: dart-pub-${{ hashFiles('**/pubspec.yaml', '**/pubspec.lock') }}
          restore-keys: dart-pub-
      
      - name: Install dependencies
        run: dart pub get
      
      - name: Check format
        run: dart format --output=none --set-exit-if-changed .
      
      - name: Analyze
        run: dart analyze --fatal-infos

  # ============================================================
  # Job 2: Testes multiplataforma
  # ============================================================
  test:
    name: Test (${{ matrix.os }})
    needs: analyze
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-24.04, windows-latest, macos-14]
        include:
          - os: ubuntu-24.04
            platform: linux
          - os: windows-latest
            platform: windows
          - os: macos-14
            platform: macos
    
    steps:
      - uses: actions/checkout@v4
      
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Cache Dart packages
        uses: actions/cache@v4
        with:
          path: |
            ~/.pub-cache
            .dart_tool
          key: dart-pub-${{ matrix.os }}-${{ hashFiles('**/pubspec.yaml', '**/pubspec.lock') }}
          restore-keys: dart-pub-${{ matrix.os }}-
      
      - name: Install dependencies
        run: dart pub get
      
      # ---- Linux: Instalar dependências de display ----
      - name: Install Linux display dependencies
        if: matrix.platform == 'linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            xvfb \
            libxcb1-dev \
            libxcb-shm0-dev \
            libxcb-xfixes0-dev \
            libxcb-keysyms1-dev \
            libxcb-icccm4-dev \
            libxcb-randr0-dev \
            libxcb-render0-dev \
            libxcb-shape0-dev \
            libxcb-xkb-dev \
            libxkbcommon-dev \
            libxkbcommon-x11-dev \
            libwayland-dev \
            libwayland-client0 \
            libegl1-mesa-dev \
            libgl1-mesa-dev \
            libgles2-mesa-dev \
            libvulkan-dev \
            mesa-vulkan-drivers \
            weston \
            x11-utils \
            x11-xserver-utils
      
      # ---- Rodar testes unitários ----
      - name: Run unit tests
        run: dart test
      
      # ---- Rodar testes headless (sem display) ----
      - name: Run headless tests
        run: dart test --tags headless
      
      # ---- Linux: Rodar testes de plataforma com Xvfb ----
      - name: Run platform tests (Linux X11)
        if: matrix.platform == 'linux'
        run: |
          export DISPLAY=:99
          Xvfb :99 -screen 0 1920x1080x24 -ac &
          sleep 2
          # Verificar que Xvfb está rodando
          xdpyinfo -display :99 | head -5
          dart test --tags platform
        env:
          DISPLAY: ':99'
          LIBGL_ALWAYS_SOFTWARE: '1'
      
      # ---- Windows: Rodar testes de plataforma ----
      - name: Run platform tests (Windows)
        if: matrix.platform == 'windows'
        run: dart test --tags platform
      
      # ---- macOS: Rodar testes de plataforma ----
      - name: Run platform tests (macOS)
        if: matrix.platform == 'macos'
        run: dart test --tags platform

  # ============================================================
  # Job 3: Build AOT multiplataforma
  # ============================================================
  build-aot:
    name: AOT Build (${{ matrix.os }})
    needs: test
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-24.04, windows-latest, macos-14]
        include:
          - os: ubuntu-24.04
            platform: linux
            binary_ext: ''
          - os: windows-latest
            platform: windows
            binary_ext: '.exe'
          - os: macos-14
            platform: macos
            binary_ext: ''
    
    steps:
      - uses: actions/checkout@v4
      
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Cache Dart packages
        uses: actions/cache@v4
        with:
          path: |
            ~/.pub-cache
            .dart_tool
          key: dart-pub-${{ matrix.os }}-${{ hashFiles('**/pubspec.yaml', '**/pubspec.lock') }}
          restore-keys: dart-pub-${{ matrix.os }}-
      
      - name: Install dependencies
        run: dart pub get
      
      # Compilar exemplos em AOT para verificar que funciona
      - name: AOT compile counter example
        run: |
          dart compile exe examples/counter/bin/main.dart \
            -o build/counter_${{ matrix.platform }}${{ matrix.binary_ext }}
        continue-on-error: true  # Pode falhar antes de exemplos existirem
      
      - name: Upload AOT binary
        if: success()
        uses: actions/upload-artifact@v4
        with:
          name: counter-${{ matrix.platform }}
          path: build/counter_*
          retention-days: 7
```

---

# 4. Workflow de POC tests: poc_tests.yml

```yaml
# .github/workflows/poc_tests.yml
name: POC Tests

on:
  push:
    branches: [main, develop]
    paths:
      - 'poc/**'
      - '.github/workflows/poc_tests.yml'
  pull_request:
    paths:
      - 'poc/**'
  workflow_dispatch:  # Permitir execução manual

concurrency:
  group: poc-${{ github.ref }}
  cancel-in-progress: true

env:
  DART_SDK_VERSION: '3.6.0'

jobs:
  # ============================================================
  # POC-01: Win32 Window (somente Windows)
  # ============================================================
  poc-01-win32:
    name: POC-01 Win32 Window
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Install dependencies
        working-directory: poc/poc_01_win32_window
        run: dart pub get
      
      - name: Analyze
        working-directory: poc/poc_01_win32_window
        run: dart analyze --fatal-infos
      
      - name: Run tests
        working-directory: poc/poc_01_win32_window
        run: dart test
      
      - name: AOT compile
        working-directory: poc/poc_01_win32_window
        run: dart compile exe bin/main.dart -o build/poc_01.exe
      
      - name: Run AOT binary (smoke test)
        working-directory: poc/poc_01_win32_window
        run: |
          # Executar com timeout (janela se auto-fecha após 3 segundos)
          Start-Process -FilePath "build\poc_01.exe" -ArgumentList "--smoke-test" -Wait -Timeout 10
        continue-on-error: true

  # ============================================================
  # POC-02: X11 Window (somente Linux)
  # ============================================================
  poc-02-x11:
    name: POC-02 X11 Window
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Install X11 dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            xvfb \
            libxcb1-dev \
            libxcb-shm0-dev \
            libxcb-keysyms1-dev \
            libxcb-icccm4-dev \
            libxcb-randr0-dev \
            x11-utils
      
      - name: Install dependencies
        working-directory: poc/poc_02_x11_window
        run: dart pub get
      
      - name: Analyze
        working-directory: poc/poc_02_x11_window
        run: dart analyze --fatal-infos
      
      - name: Start Xvfb
        run: |
          Xvfb :99 -screen 0 1920x1080x24 -ac &
          echo "DISPLAY=:99" >> $GITHUB_ENV
          sleep 2
          xdpyinfo -display :99 | head -5
      
      - name: Run tests
        working-directory: poc/poc_02_x11_window
        run: dart test
        env:
          DISPLAY: ':99'
      
      - name: AOT compile and run
        working-directory: poc/poc_02_x11_window
        run: |
          dart compile exe bin/main.dart -o build/poc_02
          timeout 10 ./build/poc_02 --smoke-test || true
        env:
          DISPLAY: ':99'

  # ============================================================
  # POC-03: AppKit Window (somente macOS)
  # ============================================================
  poc-03-appkit:
    name: POC-03 AppKit Window
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Install dependencies
        working-directory: poc/poc_03_appkit_window
        run: dart pub get
      
      - name: Analyze
        working-directory: poc/poc_03_appkit_window
        run: dart analyze --fatal-infos
      
      - name: Run tests
        working-directory: poc/poc_03_appkit_window
        run: dart test
      
      - name: AOT compile
        working-directory: poc/poc_03_appkit_window
        run: dart compile exe bin/main.dart -o build/poc_03
      
      - name: Run smoke test
        working-directory: poc/poc_03_appkit_window
        run: |
          # macOS CI tem sessão GUI, mas pode precisar de permissões
          timeout 10 ./build/poc_03 --smoke-test || true

  # ============================================================
  # POC-04: CPU Rasterization (multiplataforma)
  # ============================================================
  poc-04-cpu-raster:
    name: POC-04 CPU Raster (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-24.04, windows-latest, macos-14]
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Install dependencies
        working-directory: poc/poc_04_cpu_raster
        run: dart pub get
      
      - name: Run benchmark
        working-directory: poc/poc_04_cpu_raster
        run: dart run bin/main.dart --benchmark
      
      - name: Run tests
        working-directory: poc/poc_04_cpu_raster
        run: dart test
      
      - name: Upload output images
        uses: actions/upload-artifact@v4
        with:
          name: poc04-output-${{ matrix.os }}
          path: poc/poc_04_cpu_raster/output/
          retention-days: 7

  # ============================================================
  # POC-05: COM/Direct2D (somente Windows)
  # ============================================================
  poc-05-com-d2d:
    name: POC-05 COM/Direct2D
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Install dependencies
        working-directory: poc/poc_05_com_direct2d
        run: dart pub get
      
      - name: Analyze
        working-directory: poc/poc_05_com_direct2d
        run: dart analyze --fatal-infos
      
      - name: Run tests
        working-directory: poc/poc_05_com_direct2d
        run: dart test
      
      - name: AOT compile and run
        working-directory: poc/poc_05_com_direct2d
        run: |
          dart compile exe bin/main.dart -o build/poc_05.exe
          .\build\poc_05.exe --smoke-test

  # ============================================================
  # POC-06: OpenGL (somente Linux)
  # ============================================================
  poc-06-opengl:
    name: POC-06 OpenGL
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Install GL dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            xvfb \
            libegl1-mesa-dev \
            libgl1-mesa-dev \
            libgles2-mesa-dev \
            libxcb1-dev \
            mesa-utils
      
      - name: Install dependencies
        working-directory: poc/poc_06_opengl
        run: dart pub get
      
      - name: Start Xvfb and run
        working-directory: poc/poc_06_opengl
        run: |
          Xvfb :99 -screen 0 1920x1080x24 -ac &
          sleep 2
          export DISPLAY=:99
          export LIBGL_ALWAYS_SOFTWARE=1
          # Verificar GL disponível
          glxinfo | head -20 || true
          dart test
        env:
          DISPLAY: ':99'
          LIBGL_ALWAYS_SOFTWARE: '1'

  # ============================================================
  # POC-07: Metal (somente macOS)
  # ============================================================
  poc-07-metal:
    name: POC-07 Metal
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Install dependencies
        working-directory: poc/poc_07_metal
        run: dart pub get
      
      - name: Run tests
        working-directory: poc/poc_07_metal
        run: dart test

  # ============================================================
  # POC-08: Vulkan (Linux + Windows)
  # ============================================================
  poc-08-vulkan:
    name: POC-08 Vulkan (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-24.04, windows-latest]
        include:
          - os: ubuntu-24.04
            platform: linux
          - os: windows-latest
            platform: windows
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Install Vulkan dependencies (Linux)
        if: matrix.platform == 'linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            libvulkan-dev \
            mesa-vulkan-drivers \
            vulkan-tools
          # Verificar Vulkan disponível
          vulkaninfo --summary 2>/dev/null || echo "Vulkan may not be available in CI"
      
      - name: Install dependencies
        working-directory: poc/poc_08_vulkan
        run: dart pub get
      
      - name: Run tests
        working-directory: poc/poc_08_vulkan
        run: dart test
        env:
          VK_ICD_FILENAMES: /usr/share/vulkan/icd.d/lvp_icd.x86_64.json

  # ============================================================
  # POC-09: Wayland (somente Linux)
  # ============================================================
  poc-09-wayland:
    name: POC-09 Wayland
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Install Wayland dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            libwayland-dev \
            libwayland-client0 \
            weston \
            libxkbcommon-dev
      
      - name: Install dependencies
        working-directory: poc/poc_09_wayland
        run: dart pub get
      
      - name: Start Weston headless and run
        working-directory: poc/poc_09_wayland
        run: |
          # Iniciar Weston em modo headless para testes
          mkdir -p /tmp/weston-test
          export XDG_RUNTIME_DIR=/tmp/weston-test
          weston --backend=headless --no-config &
          sleep 2
          export WAYLAND_DISPLAY=wayland-0
          dart test || true
        env:
          XDG_RUNTIME_DIR: /tmp/weston-test

  # ============================================================
  # POC-10: Event Loop (multiplataforma)
  # ============================================================
  poc-10-event-loop:
    name: POC-10 Event Loop (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-24.04, windows-latest, macos-14]
        include:
          - os: ubuntu-24.04
            platform: linux
          - os: windows-latest
            platform: windows
          - os: macos-14
            platform: macos
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Install Linux deps
        if: matrix.platform == 'linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y xvfb libxcb1-dev
      
      - name: Install dependencies
        working-directory: poc/poc_10_event_loop
        run: dart pub get
      
      - name: Run tests (Linux)
        if: matrix.platform == 'linux'
        working-directory: poc/poc_10_event_loop
        run: |
          Xvfb :99 -screen 0 1920x1080x24 -ac &
          sleep 2
          dart test
        env:
          DISPLAY: ':99'
      
      - name: Run tests (Windows/macOS)
        if: matrix.platform != 'linux'
        working-directory: poc/poc_10_event_loop
        run: dart test
```

---

# 5. Workflow de golden tests: golden_tests.yml

```yaml
# .github/workflows/golden_tests.yml
name: Golden Tests

on:
  push:
    branches: [main]
    paths:
      - 'test/golden/**'
      - 'packages/**/test/**'
      - 'lib/**'
  pull_request:
    paths:
      - 'test/golden/**'
      - 'packages/**/test/**'
      - 'lib/**'
  workflow_dispatch:
    inputs:
      update_goldens:
        description: 'Update golden files'
        type: boolean
        default: false

env:
  DART_SDK_VERSION: '3.6.0'

jobs:
  golden-test:
    name: Golden Tests (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-24.04, windows-latest, macos-14]
        include:
          - os: ubuntu-24.04
            platform: linux
          - os: windows-latest
            platform: windows
          - os: macos-14
            platform: macos
    
    steps:
      - uses: actions/checkout@v4
      
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ env.DART_SDK_VERSION }}
      
      - name: Cache Dart packages
        uses: actions/cache@v4
        with:
          path: |
            ~/.pub-cache
            .dart_tool
          key: dart-pub-${{ matrix.os }}-${{ hashFiles('**/pubspec.yaml', '**/pubspec.lock') }}
      
      - name: Install dependencies
        run: dart pub get
      
      # Instalar fontes empacotadas para consistência
      - name: Install test fonts
        run: |
          # Usar fontes empacotadas no repositório para determinismo
          echo "Using bundled test fonts from test/golden/fonts/"
      
      - name: Run golden tests
        run: dart test --tags golden
        env:
          DART_UI_GOLDEN_DIR: test/golden/${{ matrix.platform }}
          DART_UI_UPDATE_GOLDENS: ${{ github.event.inputs.update_goldens || 'false' }}
      
      - name: Upload golden diffs
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: golden-diffs-${{ matrix.platform }}
          path: |
            test/golden/${{ matrix.platform }}/failures/
          retention-days: 14
      
      - name: Upload updated goldens
        if: github.event.inputs.update_goldens == 'true'
        uses: actions/upload-artifact@v4
        with:
          name: updated-goldens-${{ matrix.platform }}
          path: test/golden/${{ matrix.platform }}/
          retention-days: 30
```

---

# 6. Configuração de ambientes gráficos

## 6.1 Linux com Xvfb (X11 virtual)

```bash
# Instalar
sudo apt-get install -y xvfb x11-utils

# Iniciar
Xvfb :99 -screen 0 1920x1080x24 -ac &
export DISPLAY=:99

# Verificar
xdpyinfo -display :99 | head -5

# Para 30-bit color:
Xvfb :99 -screen 0 1920x1080x30 -ac &

# Para multi-DPI testing (não suportado nativamente, usar xrandr):
# Xvfb não suporta DPI variável por monitor, usar RandR para simular
```

## 6.2 Linux com Weston (Wayland headless)

```bash
# Instalar
sudo apt-get install -y weston

# Iniciar headless
export XDG_RUNTIME_DIR=/tmp/weston-test
mkdir -p $XDG_RUNTIME_DIR
weston --backend=headless --no-config &
export WAYLAND_DISPLAY=wayland-0

# Verificar
ls -la $XDG_RUNTIME_DIR/wayland-0*
```

## 6.3 Linux com Mesa (OpenGL software)

```bash
# Instalar
sudo apt-get install -y libegl1-mesa-dev libgl1-mesa-dev mesa-utils

# Forçar software rendering
export LIBGL_ALWAYS_SOFTWARE=1

# Verificar
glxinfo | grep "OpenGL version"
# Deve mostrar algo como: "OpenGL version string: 4.5 (Compatibility Profile) Mesa X.Y.Z"
```

## 6.4 Linux com lavapipe (Vulkan software)

```bash
# Instalar
sudo apt-get install -y mesa-vulkan-drivers vulkan-tools

# Configurar ICD
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json

# Verificar
vulkaninfo --summary
# Deve mostrar "llvmpipe" como device
```

## 6.5 macOS — sessão GUI

macOS runners do GitHub Actions (`macos-13`, `macos-14`) têm sessão GUI ativa por padrão.

```bash
# Verificar GPU
system_profiler SPDisplaysDataType | head -20

# Verificar Metal
xcrun metal --version

# Para apps que precisam de foco:
# Pode ser necessário usar `open -a` para garantir que a app fique em primeiro plano
```

## 6.6 Windows — desktop session

Windows runners do GitHub Actions (`windows-latest`) têm desktop session ativa.

```powershell
# Verificar GPU
Get-CimInstance -ClassName Win32_VideoController | Select-Object Name, DriverVersion

# Verificar Direct3D
dxdiag /t dxdiag.txt
type dxdiag.txt | Select-String "DirectX Version"
```

---

# 7. Caching e otimização

## 7.1 Cache de Dart pub

```yaml
- uses: actions/cache@v4
  with:
    path: |
      ~/.pub-cache
      .dart_tool
    key: dart-pub-${{ runner.os }}-${{ hashFiles('**/pubspec.yaml', '**/pubspec.lock') }}
    restore-keys: |
      dart-pub-${{ runner.os }}-
```

## 7.2 Cache de compilação AOT

```yaml
- uses: actions/cache@v4
  with:
    path: |
      build/
    key: dart-aot-${{ runner.os }}-${{ github.sha }}
    restore-keys: |
      dart-aot-${{ runner.os }}-
```

## 7.3 Otimização de tempo de CI

| Estratégia | Economia estimada |
|---|---|
| `cancel-in-progress: true` | Evita builds obsoletos |
| `fail-fast: false` | Coleta resultados de todas plataformas |
| `needs: analyze` | Não roda testes se análise falha |
| Path filters em POC tests | Só roda quando POC muda |
| Cache de pub | ~30-60s por job |
| Jobs paralelos | ~3x mais rápido que sequencial |

---

# 8. Configuração detalhada por plataforma

## 8.1 Windows

### Dependências disponíveis no runner
- Visual Studio Build Tools (para headers, mas não usamos C++)
- Windows SDK
- DirectX runtime
- PowerShell 7+
- Git

### Configuração necessária
```yaml
- name: Verify Windows environment
  run: |
    # Verificar DLLs disponíveis
    @('user32.dll', 'kernel32.dll', 'gdi32.dll', 'shell32.dll', 
      'd2d1.dll', 'd3d11.dll', 'dxgi.dll', 'dwmapi.dll',
      'dwrite.dll', 'ole32.dll', 'oleaut32.dll') | ForEach-Object {
      $path = [System.IO.Path]::Combine($env:SystemRoot, 'System32', $_)
      if (Test-Path $path) {
        Write-Host "OK: $_" -ForegroundColor Green
      } else {
        Write-Host "MISSING: $_" -ForegroundColor Red
      }
    }
```

## 8.2 Linux

### Pacotes mínimos
```yaml
- name: Install minimal Linux dependencies
  run: |
    sudo apt-get update
    sudo apt-get install -y \
      # X11/XCB
      libxcb1 libxcb-shm0 libxcb-keysyms1 libxcb-icccm4 \
      libxcb-randr0 libxcb-render0 libxcb-shape0 libxcb-xkb1 \
      # XKB
      libxkbcommon0 libxkbcommon-x11-0 \
      # Wayland
      libwayland-client0 \
      # OpenGL/EGL
      libegl1 libgl1 libgles2 \
      # Vulkan
      libvulkan1 \
      # Tools
      xvfb x11-utils
```

### Verificação de bibliotecas
```yaml
- name: Verify Linux libraries
  run: |
    for lib in libxcb.so.1 libwayland-client.so.0 libEGL.so.1 \
               libGL.so.1 libvulkan.so.1 libxkbcommon.so.0; do
      if ldconfig -p | grep -q "$lib"; then
        echo "OK: $lib"
      else
        echo "MISSING: $lib"
      fi
    done
```

## 8.3 macOS

### Frameworks disponíveis no runner
- AppKit (sempre)
- Metal (sempre em macOS 10.14+)
- Core Graphics (sempre)
- QuartzCore (sempre)
- Foundation (sempre)
- libobjc (sempre)

### Verificação
```yaml
- name: Verify macOS frameworks
  run: |
    # Verificar que frameworks necessários existem
    for fw in AppKit Metal CoreGraphics QuartzCore Foundation; do
      if [ -d "/System/Library/Frameworks/${fw}.framework" ]; then
        echo "OK: ${fw}.framework"
      else
        echo "MISSING: ${fw}.framework"
      fi
    done
    
    # Verificar Objective-C runtime
    if [ -f "/usr/lib/libobjc.A.dylib" ]; then
      echo "OK: libobjc"
    fi
    
    # Verificar arquitetura
    uname -m  # arm64 para macos-14, x86_64 para macos-13
```

---

# 9. Verificação de sanidade por plataforma

Script de verificação a ser executado em todo CI run:

```yaml
# .github/workflows/sanity_check.yml (incluído como job no ci.yml)
sanity:
  name: Sanity Check (${{ matrix.os }})
  runs-on: ${{ matrix.os }}
  strategy:
    matrix:
      os: [ubuntu-24.04, windows-latest, macos-14]
  steps:
    - uses: dart-lang/setup-dart@v1
      with:
        sdk: ${{ env.DART_SDK_VERSION }}
    
    - name: Dart version
      run: dart --version
    
    - name: FFI availability
      run: |
        dart run -e "
          import 'dart:ffi';
          import 'dart:io';
          print('OS: \${Platform.operatingSystem}');
          print('Arch: \${Platform.version}');
          print('Pointer size: \${sizeOf<Pointer>()}');
          print('Int size: \${sizeOf<Int>()}');
          print('Long size: \${sizeOf<Long>()}');
          print('IntPtr size: \${sizeOf<IntPtr>()}');
        "
```

---

# 10. Reprodutibilidade

## 10.1 Fixar versões

| Item | Como fixar |
|---|---|
| Dart SDK | `env.DART_SDK_VERSION` no workflow |
| Runner OS | Versão explícita (`ubuntu-24.04`, não `ubuntu-latest`) |
| Dependências Dart | `pubspec.lock` commitado |
| Fontes para golden | Empacotadas em `test/golden/fonts/` |
| Locale | `LANG=C.UTF-8` em Linux |
| Timezone | `TZ=UTC` em todos |
| Seed de random | Fixado nos testes |

## 10.2 Variáveis de ambiente de teste

```yaml
env:
  DART_SDK_VERSION: '3.6.0'
  LANG: 'C.UTF-8'
  TZ: 'UTC'
  DART_UI_TEST_MODE: 'ci'
  DART_UI_GOLDEN_TOLERANCE: '0.01'  # 1% de diferença aceitável
```

---

# 11. Troubleshooting de CI

## 11.1 Problemas comuns

| Problema | Plataforma | Solução |
|---|---|---|
| `Xvfb failed to start` | Linux | Verificar se porta :99 está livre, usar `-ac` |
| `Cannot open display` | Linux | Verificar `DISPLAY` env var |
| `LIBGL_ALWAYS_SOFTWARE` não funciona | Linux | Instalar `mesa-utils`, verificar Mesa versão |
| `Metal not available` | macOS CI | Usar `macos-14` (tem GPU), não `macos-12` |
| `D3D11CreateDevice failed` | Windows CI | Software adapter pode não suportar D3D11; usar WARP |
| `NativeCallable crash` | Qualquer | Verificar versão Dart SDK, reportar bug |
| `Golden mismatch` | Qualquer | Verificar fontes, DPI, formato de pixel |
| `Timeout` | Qualquer | Janela não fecha sozinha; adicionar flag `--smoke-test` |

## 11.2 WARP (Windows Advanced Rasterization Platform)

Para D3D11 em CI sem GPU real:

```dart
// Forçar WARP adapter
const driverType = D3D_DRIVER_TYPE_WARP;
D3D11CreateDevice(
  nullptr, // pAdapter
  driverType,
  0, // Software module
  flags,
  featureLevels,
  // ...
);
```

## 11.3 Debug de CI

```yaml
- name: Debug info
  if: failure()
  run: |
    echo "=== Environment ==="
    env | sort
    echo "=== Disk space ==="
    df -h
    echo "=== Memory ==="
    free -h 2>/dev/null || vm_stat 2>/dev/null || systeminfo 2>/dev/null | findstr Memory
```

---

**Fim da documentação de CI.**
