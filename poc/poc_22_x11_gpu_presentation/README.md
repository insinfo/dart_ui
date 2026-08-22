# POC-22 - apresentação X11 por CPU, SHM, OpenGL e Vulkan

Esta POC compara quatro caminhos que desenham uma janela X11 de 640x360:

- `xcb_put_image`: dois buffers nativos FFI retidos, com divisão pelo limite de
  requisição do servidor X;
- `xcb_shm_put_image`: dois buffers nativos compartilhados com MIT-SHM,
  preferindo `xcb_shm_attach_fd`/`memfd` e usando System V SHM como fallback;
- EGL/OpenGL: `glClear` e `eglSwapBuffers` sobre a janela X11;
- Vulkan: `VK_KHR_xcb_surface`, `VK_KHR_swapchain` e
  `vkCmdClearColorImage`.

O projeto é executado diretamente pelo WSL em `/mnt/c`; não é necessário
copiar os fontes e não se usa Xvfb. Xvfb não representa o caminho WSLg/GPU.

## Preparação no Ubuntu 24.04

```bash
sudo apt update
sudo apt install mesa-utils vulkan-tools mesa-vulkan-drivers
cd /mnt/c/MyDartProjects/dart_ui
export PUB_CACHE=$HOME/.pub-cache
dart pub get
```

Execute aplicações WSLg com um usuário normal. Nesta máquina, a distro havia
sido configurada apenas com `root`; segmentos System V SHM criados por ele
foram rejeitados pelo Xwayland, causando repetição de
`Failed to attach to x11 shm` no caminho interno do Mesa. A POC MIT-SHM usa
`attach_fd` e não sofre essa limitação, mas EGL/D3D12 do Mesa sofre.

## Execução

Matriz estável com seleção padrão do Mesa:

```bash
DISPLAY=:0 dart run poc/poc_22_x11_gpu_presentation/bin/compare.dart --quick
```

OpenGL explicitamente sobre a GPU D3D12 do WSLg:

```bash
DISPLAY=:0 GALLIUM_DRIVER=d3d12 \
  dart run poc/poc_22_x11_gpu_presentation/bin/egl_opengl.dart --quick
```

Para escolher uma GPU em máquina com múltiplos adaptadores:

```bash
DISPLAY=:0 GALLIUM_DRIVER=d3d12 \
MESA_D3D12_DEFAULT_ADAPTER_NAME=Intel \
  dart run poc/poc_22_x11_gpu_presentation/bin/egl_opengl.dart --quick
```

Vulkan com o ICD disponível:

```bash
DISPLAY=:0 dart run poc/poc_22_x11_gpu_presentation/bin/vulkan.dart --quick
```

Use `--json` em qualquer comando para obter resultados estruturados. A opção
`--backend=put-image|mit-shm|egl|vulkan` também é aceita por `compare.dart`.

## Como confirmar o dispositivo real

```bash
DISPLAY=:0 GALLIUM_DRIVER=d3d12 glxinfo -B
vulkaninfo --summary
ls /usr/share/vulkan/icd.d
```

`Accelerated: yes` e um renderer `D3D12 (<GPU>)` confirmam OpenGL em hardware.
No Vulkan, `llvmpipe` é CPU mesmo quando as extensões XCB surface e swapchain
estão presentes. Para GPU via D3D12 é necessário que a distribuição forneça o
ICD Dozen (`dzn_icd*.json` e `libvulkan_dzn.so`).

Os números de MB/s são vazão equivalente de quadros RGBA, úteis para comparar
as execuções. Para EGL e Vulkan eles não representam bytes realmente copiados
pelo barramento.

## Depuração nativa AOT da desmontagem EGL

O ambiente validado usa GDB 15.1. Compile primeiro a POC e execute como usuário
normal (não como `root`):

```bash
dart compile exe \
  poc/poc_22_x11_gpu_presentation/bin/compare.dart \
  -o /tmp/poc22_compare

DISPLAY=:0 GALLIUM_DRIVER=d3d12 POC22_EGL_TEARDOWN=explicit \
  gdb -q -batch \
  -x poc/poc_22_x11_gpu_presentation/tool/debug_egl_teardown.gdb \
  --args /tmp/poc22_compare --quick --backend=egl
```

O script cria breakpoints em `eglDestroyContext`, `eglDestroySurface`,
`eglTerminate` e `dlclose`, e imprime os backtraces de todas as threads quando
o processo recebe o sinal fatal.

No ambiente testado, `eglTerminate` descarrega `libd3d12core.so`; quando a
thread Dart que usou EGL termina, a glibc tenta executar um destrutor TLS cujo
endereço pertencia à biblioteca já descarregada. O modo padrão da POC evita
essa chamada final; `POC22_EGL_TEARDOWN=explicit` é somente um reproducer.
