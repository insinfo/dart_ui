# Relatório POC-22 - apresentação X11, MIT-SHM, EGL/OpenGL e Vulkan no WSLg

Data da validação: 22 de agosto de 2026.

## Conclusão

As POCs podem ser executadas diretamente em
`/mnt/c/MyDartProjects/dart_ui`, usando o servidor X11 do WSLg em `DISPLAY=:0`.
Não é necessário copiar o repositório e não se deve usar Xvfb para esta
comparação: Xvfb é um servidor em memória sem o caminho gráfico D3D12 do WSLg.

Os quatro caminhos foram implementados:

1. `xcb_put_image` com memória nativa alocada por Dart FFI;
2. `xcb_shm_put_image` com dois buffers compartilhados e eventos de conclusão;
3. EGL/OpenGL sobre uma janela XCB;
4. Vulkan com surface XCB e swapchain.

No WSLg desta máquina, MIT-SHM por System V retorna `BadAccess`. A variante
moderna com `memfd_create` e `xcb_shm_attach_fd` funciona e é o caminho usado
pela POC. Isso também evita tratar um buffer Dart movível como memória nativa.

## Ambiente observado

- WSL 2.7.12, WSLg 1.0.73.2 e kernel 6.18.33.2;
- Ubuntu 24.04;
- Intel UHD Graphics, driver Windows 30.0.101.2079 de 25/05/2022;
- `/dev/dxg` e as bibliotecas D3D12/DXCore do WSL presentes;
- Mesa inicialmente 24.0.9; atualizado com pacotes oficiais do Ubuntu para
  25.2.8;
- Dart Linux 3.6.2 em `/opt/dart-sdk-3.6.2`.

## Resultado funcional e amostra de desempenho

Uma execução curta de 120 quadros, antes da atualização do Mesa, produziu:

| Backend | Dispositivo | FPS | Latência média | Observação |
|---|---|---:|---:|---|
| PutImage | CPU/XCB | 1.015 | 985 us | cópia da requisição X11 |
| MIT-SHM | CPU + memória compartilhada | 10.731 | 93 us | `attach_fd`, dois buffers |
| EGL/OpenGL | D3D12 Intel UHD | 12,5 | 79.834 us | acelerado, mas anormalmente lento |
| Vulkan | llvmpipe | 1.481 | 675 us | Vulkan em CPU |

É uma amostra de diagnóstico, não um benchmark estatístico. WSLg, compositor,
JIT/AOT e carga do host influenciam o resultado. A diferença consistente é que
MIT-SHM elimina a cópia do payload pelo socket X11 e foi muito mais rápido que
PutImage nesta máquina.

Depois da atualização para Mesa 25.2.8, uma execução AOT de 600 quadros com a
seleção padrão produziu:

| Backend | Dispositivo | FPS | Latência média |
|---|---|---:|---:|
| PutImage | CPU/XCB | 2.379 | 420 us |
| MIT-SHM | CPU + `memfd` compartilhado | 16.772 | 59,6 us |
| EGL/OpenGL | llvmpipe | 1.424 | 702 us |
| Vulkan | llvmpipe | 4.153 | 241 us |

Todos os quatro backends concluíram em AOT. Os valores de EGL e Vulkan nessa
tabela são CPU e não devem ser comparados como desempenho de GPU.

## OpenGL: seleção do driver e crash no encerramento

Após a atualização para Mesa 25.2.8, a seleção automática passou a usar
`llvmpipe`. Isto não significa que o Gallium D3D12 desapareceu: o comando
abaixo confirmou `Accelerated: yes` e `D3D12 (Intel(R) UHD Graphics)`:

```bash
DISPLAY=:0 GALLIUM_DRIVER=d3d12 glxinfo -B
```

`MESA_LOADER_DRIVER_OVERRIDE=d3d12` não é equivalente neste caso e continuou
selecionando llvmpipe. A variável apropriada é `GALLIUM_DRIVER=d3d12`.

Com Mesa 24.0.9, a POC renderizava na GPU, mas o processo falhava depois da
destruição explícita de surface/contexto EGL. A POC, portanto, posterga a
desmontagem explícita quando detecta renderer D3D12; o processo curto deixa o
sistema operacional recuperar os recursos.

Há evidência pública relacionada:

- o issue WSLg #1131 permanece aberto e registra `d3d12_fence_finish()` com
  ponteiro nulo após uma falha de sincronização `dxgkrnl`;
- o Mesa 26.2.0 adicionou uma lista de liberações pendentes no driver D3D12,
  transfere referências de BOs submetidos para a tela e limpa estado de BO por
  contexto durante `context destroy`.

Essas mudanças do 26.2.0 tratam BOs em voo, mas o GDB mostrou que o crash desta
POC tem um mecanismo mais específico: descarregamento prematuro de código com
estado TLS. Portanto, as release notes do 26.2.0 **não comprovam** uma correção
para este caso.

O reteste AOT no Mesa 25.2.8 separou dois problemas:

1. como `root`, EGL/D3D12 entra em fallback sem DRI3, repete
   `MESA: error: Failed to attach to x11 shm` e não progride;
2. com UID 1000, EGL/D3D12 renderiza normalmente, porém a desmontagem explícita
   ainda termina com código 134/SIGSEGV.

Com GDB 15.1, os breakpoints mostraram esta sequência:

1. `eglDestroyContext`;
2. `eglDestroySurface`;
3. `eglTerminate`;
4. vários `dlclose` iniciados por `libgallium`, atravessando
   `libd3d12.so`, `libd3d12core.so` e os módulos Intel;
5. durante `Dart_ShutdownIsolate`, uma `DartWorker` entra em
   `__nptl_deallocate_tsd` e tenta executar um destrutor TLS em endereço não
   mapeado;
6. esse endereço pertence à faixa ocupada por `libd3d12core.so` antes dos
   `dlclose`.

Isto confirma um problema de vida útil DLL/TLS: `eglTerminate` descarrega o
código D3D12 antes de sair a thread que ainda possui TLS daquele código. Não é
um erro de ordem entre `eglDestroyContext` e `eglDestroySurface`. A mitigação
da POC é não executar `eglTerminate` no renderer D3D12; o modo explícito pode
ser reativado com `POC22_EGL_TEARDOWN=explicit` para testar versões futuras.

## Vulkan: por que só aparece llvmpipe

`VK_KHR_xcb_surface` e `VK_KHR_swapchain` são extensões de apresentação. Elas
não garantem que o dispositivo físico seja uma GPU. O pacote
`mesa-vulkan-drivers` do Ubuntu 24.04 inclui Lavapipe (`lvp`) mas não inclui o
ICD Dozen (`dzn`). Por isso a surface e a swapchain funcionam, porém o único
`VkPhysicalDevice` é llvmpipe.

Não falta uma opção de kernel nem uma configuração X11. Para Vulkan em GPU via
WSLg/D3D12 é necessário instalar um build de Mesa que inclua:

- `libvulkan_dzn.so`;
- `dzn_icd*.json` em `/usr/share/vulkan/icd.d`;
- `spirv2dxil`/bibliotecas compatíveis;
- e manter `/usr/lib/wsl/lib` acessível ao loader.

Dozen ainda se identifica como implementação não conformante e há relatos
recentes de crash em alguns drivers Windows. Deve ser tratado como backend
experimental e validado na GPU real antes de ser adotado.

## Distribuição WSL recomendada para o experimento

A melhor candidata encontrada para **testar Vulkan em GPU** é
**openSUSE Tumbleweed**:

- está disponível nesta máquina por
  `wsl.exe --install openSUSE-Tumbleweed`;
- possui pacote `libvulkan_dzn`;
- o repositório X11:XOrg já publica Mesa 26.2.0.

**Fedora Linux 44** é a segunda opção e é mais simples para obter D3D12 + Dozen
em pacotes oficiais. Nesta data fornece Mesa 26.1.6, anterior ao conjunto de
mudanças de destruição do 26.2.0. Arch Linux também empacota `d3d12_dri.so` e
`vulkan-dzn`, mas a versão estável observada era 26.1.7.

Não há evidência de que trocar a distribuição, sozinho, resolva o crash TLS de
EGL. Todas as distros usam as mesmas bibliotecas D3D12 e o mesmo driver de GPU
fornecidos pelo Windows/WSL. O ganho comprovado de openSUSE/Fedora/Arch é ter um
Mesa mais novo e o ICD Dozen empacotado.

O driver Intel instalado é 30.0.101.2079, de 25/05/2022. A Intel publica o
32.0.101.7088, de 22/06/2026, para gráficos integrados de 11ª a 14ª geração,
incluindo Alder Lake. Atualizar primeiro pelo suporte da Samsung/OEM, ou usar o
driver genérico Intel ciente de que ele substitui customizações OEM, é a ação
mais importante antes de repetir o teste TLS e experimentar Dozen.

## Comandos de validação em uma nova distribuição

```bash
test -e /dev/dxg && echo dxg-ok
ls -l /usr/lib/wsl/lib/libd3d12.so /usr/lib/wsl/lib/libdxcore.so
GALLIUM_DRIVER=d3d12 glxinfo -B
ls /usr/share/vulkan/icd.d/*dzn*
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/dzn_icd.x86_64.json \
  vulkaninfo --summary
```

O nome exato do JSON varia por distribuição. Só force `VK_ICD_FILENAMES`
depois de confirmar o arquivo; caso contrário, use `vulkaninfo --summary` sem a
variável e confira o `deviceName`.

## Fontes

- [WSLg: aceleração OpenGL via Gallium D3D12](https://github.com/microsoft/wslg)
- [WSLg #1131: falha em d3d12_fence_finish](https://github.com/microsoft/wslg/issues/1131)
- [WSLg #1283: Failed to attach to x11 shm](https://github.com/microsoft/wslg/issues/1283)
- [Mesa 26.2.0 release notes](https://docs.mesa3d.org/relnotes/26.2.0.html)
- [Driver D3D12 do Mesa](https://docs.mesa3d.org/drivers/d3d12.html)
- [Pacote Vulkan do Ubuntu 24.04](https://packages.ubuntu.com/noble/amd64/mesa-vulkan-drivers/filelist)
- [Fedora 44: mesa-vulkan-drivers](https://packages.fedoraproject.org/pkgs/mesa/mesa-vulkan-drivers/fedora-44-updates.html)
- [Arch Linux: vulkan-dzn](https://archlinux.org/packages/extra/x86_64/vulkan-dzn/)
- [openSUSE X11:XOrg: Mesa 26.2.0 e libvulkan_dzn](https://download.opensuse.org/repositories/X11:/XOrg/openSUSE_Tumbleweed/x86_64/)
- [Intel: driver 32.0.101.7088 para gráficos de 11ª a 14ª geração](https://www.intel.com/content/www/us/en/support/products/211968/graphics/processor-graphics/intel-uhd-graphics-family.html)
