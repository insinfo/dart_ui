# Relatório técnico: WSL, WSLg, Mesa, OpenGL, Vulkan e transportes de janela

Data da investigação: 22 de agosto de 2026

Status: investigação e correções em andamento. Este documento deve ser atualizado
quando uma nova medição confirmar ou rejeitar uma hipótese.

## 1. Objetivo

Investigar a execução das POCs gráficas Dart FFI no WSL2/WSLg e separar problemas
da aplicação, do Mesa, do WSLg, do `virtio-fs`, do Xwayland, do Wayland e dos
drivers do Windows. As correções do lado Dart devem continuar portáveis para
distribuições Linux padrão e selecionar backends por capacidades detectadas.

## 2. Ambiente reproduzido

| Componente | Valor observado |
|---|---|
| Windows | build 26200.9168 |
| WSL | 2.9.4.0 |
| Kernel WSL | 6.18.35.2-1 |
| WSLg | 1.0.79 |
| GPU | Intel UHD Graphics, PCI `8086:46B3` |
| Driver Intel inicial | 30.0.101.2079, 25/05/2022 |
| Driver Intel atualizado | 32.0.101.7088, 17/06/2026 |
| Mesa da distribuição | 25.2.8 |
| Mesa compilado | 26.3.0-devel, commit `ebcfbe601daeb0eb2854e5a3da7f6f3b597b4976` |
| Dispositivos Linux | `/dev/dxg` presente; `/dev/dri` ausente |
| Xwayland | `Present` e `MIT-SHM` presentes; DRI3 ausente |

## 3. Defeito 1: janela invisível e `virtio-fs`/`gfxredir`

### Sintomas

- O ícone da aplicação aparecia na barra de tarefas, mas a janela ficava invisível
  ou transparente.
- O log do Weston mostrava falha ao abrir `/mnt/shared_memory` com `EIO`.
- O WSLg entrava em `[WARN:COPY MODE]` e desativava `gfxredir` durante toda a sessão.

### Causa confirmada

O identificador FUSE reservado para a raiz era restaurado incorretamente para `1`.
Depois da destruição e criação assíncrona de sessões, a primeira abertura do
compartilhamento podia receber `nodeid=1`, que o kernel rejeitava. O Weston testava
o compartilhamento apenas uma vez e mantinha o fallback após a falha transitória.

Montar manualmente um `tmpfs` em `/mnt/shared_memory` dentro da distribuição do
usuário não resolve. Essa montagem pertence a outro namespace e não substitui a
ponte gerenciada pela distribuição de sistema do WSLg.

### Correções construídas

- OpenVMM: preservar/restaurar o próximo identificador correto em vez de reiniciar
  o contador em `1`.
- Weston/WSLg: repetir a abertura de memória compartilhada depois do `EIO`
  transitório.
- VHD privado validado:
  `D:\wslg-dev\artifacts\system_x64-wslg-1.0.79-weston-retry.vhd`.
- SHA-256:
  `ED168DE3D1608A926D4B279314FF6D759D2EE7985A1A6763AA10E0FF92E7395B`.

### Resultado

O log passou a mostrar uma primeira falha seguida de sucesso, com
`RDP backend: use_gfxredir = 1`. A janela voltou a aparecer pelo WSLg nativo.

## 4. Defeito 2: tela preta no Mesa D3D12/EGL

### Sintoma

O contexto OpenGL era criado com renderer `D3D12 (Intel(R) UHD Graphics)`, mas a
janela X11 podia permanecer preta. O mesmo desenho via `llvmpipe` aparecia.

### Resultado da atualização do Mesa

O Mesa 26.3.0-devel compilado localmente passou a produzir os pixels corretos no
teste direto. Portanto, a parte funcional da tela preta foi corrigida entre o Mesa
25.2.8 da distribuição e o Mesa 26.3 em desenvolvimento.

A atualização não resolveu o problema de desempenho descrito a seguir.

## 5. Defeito 3: readback D3D12 extremamente lento em buffers maiores

### Local do código

`src/gallium/drivers/d3d12/d3d12_screen.cpp`, função
`d3d12_flush_frontbuffer()`.

O caminho sem compartilhamento direto executa:

1. `pipe_texture_map(..., PIPE_MAP_READ, ...)`;
2. cópia do recurso D3D12 para memória visível à CPU;
3. `util_copy_rect()` para o `displaytarget` do winsys;
4. publicação pelo winsys X11 ou Wayland.

### Instrumentação

Foi compilado um Mesa 26.3 com tempos separados para `map`, cópia, `unmap` e
publicação. Em 640×480, um quadro típico da POC apresentou:

| Etapa | Tempo |
|---|---:|
| Map/espera D3D12 | 1–4 ms |
| leitura/cópia em `util_copy_rect` | 103–149 ms |
| Unmap | ~0,01 ms |
| publicação X11 com MIT-SHM | 0,7–2,5 ms |
| total | 106–153 ms |

O primeiro acesso às páginas mapeadas é o custo dominante. O comportamento é
compatível com materialização ou transferência serial de páginas do heap de
readback através de `/dev/dxg`/VMBus.

O GDB foi executado sobre o binário Dart AOT e interrompeu o Mesa compilado no
primeiro quadro. A pilha confirmou o caminho completo:

```text
Dart FFI
  eglSwapBuffers
    dri2_swap_buffers
      dri2_x11_swap_buffers
        drisw_swap_buffers
          d3d12_flush_frontbuffer
```

As threads auxiliares estavam em `libd3d12core.so`/driver Intel ou aguardando na
`util_queue`. Isso confirma no depurador nativo que o bloqueio ocorre depois do
desenho Dart, dentro da apresentação Gallium D3D12/DRISW.

### Dependência do tamanho

| Superfície | Resultado aproximado com uma thread |
|---|---:|
| 300×300 | 2–8 ms por quadro; ~50 FPS na POC |
| 640×480 | 106–153 ms; 7–9 FPS |
| 800×600 | 172–186 ms; ~5 FPS |
| 1280×720 | 327–359 ms; ~2,8 FPS |

O mesmo `eglgears_x11` é rápido no tamanho inicial pequeno e passa a cerca de
110 ms de cópia depois de ser redimensionado para 640×480. Isso elimina Dart
FFI e o desenho da POC como causas primárias.

### X11 versus Wayland

O `eglgears_wayland` também foi forçado a permanecer em 640×480. O readback levou
aproximadamente 107–140 ms, enquanto a publicação Wayland levou cerca de 0,16 ms.

Conclusão: X11 sem DRI3 adiciona uma camada e cerca de 1 ms neste teste, mas não é
o gargalo de 110 ms. Wayland/OpenGL com o mesmo Mesa D3D12 também sofre quando a
superfície é grande porque ambos chegam a `d3d12_flush_frontbuffer()`.

### Protótipo de correção no Mesa

A cópia foi dividida por faixas horizontais para colocar múltiplas leituras do
heap simultaneamente em voo. Em 640×480:

| Implementação | Resultado |
|---|---:|
| Mesa original, uma cópia serial | 7,7 FPS, ~110–130 ms de cópia |
| 8 faixas paralelas | 29,6–33,8 FPS |
| 32 faixas paralelas | 38,7–40,8 FPS em 120 quadros |

Isso confirma a serialização do acesso às páginas como causa. O primeiro teste
criava threads por quadro. A implementação atual usa a `util_queue` persistente
do próprio Mesa, é ativada por `D3D12_FRONTBUFFER_THREADS`, e só divide buffers
maiores que o limite configurável `D3D12_FRONTBUFFER_PARALLEL_MIN_BYTES`
(512 KiB por padrão). Em 300×300, abaixo do limite, atingiu aproximadamente
257 FPS sem VSync. Em 1920×1080, 32 trabalhadores foram o melhor ponto medido,
mas o resultado ainda foi apenas 6,7–7,1 FPS. Isso é uma mitigação útil; não é
substituto para compartilhamento direto da imagem.

### Correção estrutural desejável no WSLg

A solução ideal elimina o readback: o Xwayland/Weston deve importar uma alocação
compartilhável proveniente de `/dev/dxg`, ou o kernel deve oferecer uma ponte
equivalente a render node/dma-buf. Hoje não existe `/dev/dri`, e o Xwayland não
anuncia DRI3. Habilitar apenas o nome da extensão sem um mecanismo real de
compartilhamento não é uma correção válida.

O papel do `virtio-fs` precisa ser descrito com precisão. Ele disponibiliza ao
host o pool final VAIL/GFXREDIR em memória de sistema. No backend RDP do Weston,
`GFXREDIR_OPEN_POOL_PDU` transmite um nome de seção e
`GFXREDIR_CREATE_BUFFER_PDU` descreve offset, stride, largura, altura e formato.
Em seguida, `weston_surface_copy_content()` escreve os pixels nesse pool. O
protocolo atual não transporta um handle de `ID3D12Resource` nem uma fence.

O fluxo observado é, portanto:

```text
aplicativo -> Mesa/D3D12 (GPU) -> readback para RAM
           -> Weston -> pool SectionFs/virtio-fs -> mstsc/Windows
```

O `virtio-fs` otimiza o último trecho; ele não remove o readback anterior. Isso
coincide com a documentação oficial do WSLg, que informa que a primeira geração
da interoperabilidade vGPU com Weston ocorre por memória de sistema e tem custo
proporcional à taxa de apresentação: [arquitetura oficial do WSLg](https://github.com/microsoft/wslg#opengl-accelerated-rendering-in-wslg).

Uma implementação zero-copy completa precisa de três capacidades coordenadas:

1. Mesa exportar a imagem D3D12 e a fence como handles externos;
2. Wayland/Weston importar esses handles sem materializar os pixels na CPU;
3. o cliente Windows do GFXREDIR importar os mesmos recursos e sincronização.

O Dozen já contém suporte a external memory/fence sobre D3D12, o que torna
possível construir um protótipo entre processos Linux. Entretanto, a PDU
GFXREDIR pública termina em um pool SectionFs. O terceiro passo exige extensão
do protocolo e suporte do consumidor Windows (`mstsc`/integração WSLg), não
apenas recompilar os componentes Linux abertos.

Uma prova foi implementada em `D:\wslg-dev\dxg-external-memory-poc.c`. Dois
processos independentes, usando Dozen sobre a Intel, trocaram por `SCM_RIGHTS`
uma imagem `VK_FORMAT_B8G8R8A8_UNORM` 640×480 alocada como recurso D3D12 externo.
O segundo processo alocou e vinculou a memória importada com sucesso, sem
readback. Isso comprova que a imagem pode atravessar a fronteira entre o cliente
e um compositor Linux modificado.

A mesma prova encontrou um bloqueio de sincronização: a timeline semaphore foi
exportada, mas `vkImportSemaphoreFdKHR` no segundo processo retornou
`VK_ERROR_INVALID_EXTERNAL_HANDLE`. A tentativa falha também deixa o objeto de
sincronização do Dozen em estado inválido para destruição, causando uma chamada
virtual pura se a aplicação executar `vkDestroySemaphore` depois do erro. O
probe evita essa destruição apenas para continuar o diagnóstico; o comportamento
é um defeito separado que deve ser reportado ao Mesa.

Também foi testada a fronteira VM→host. Um patch experimental deu nome ao
`ID3D12Resource` criado pelo Dozen e manteve o exportador Linux vivo, enquanto
um programa D3D12 nativo do Windows abriu a mesma Intel UHD e chamou
`OpenSharedHandleByName()` para os namespaces simples, `Local` e `Global`. O
Windows não encontrou o recurso (`HRESULT 0x80070006`, handle inválido). Assim,
o compartilhamento atual funciona entre processos Linux na VM, mas o nome não
atravessa para um processo Windows comum; a integração exige suporte explícito
do DeviceHost/protocolo WSLg.

## 6. Integração EGL e XCB da POC Dart

A POC criava a janela por XCB e obtinha o display EGL com
`eglGetDisplay(nullptr)`, que normalmente usa o frontend X11/Xlib. Foi adicionada
a tentativa correta de usar
`eglGetPlatformDisplay(EGL_PLATFORM_XCB_EXT, xcb_connection, ...)`, com fallback
para o display padrão.

Essa correção melhora a coerência e a portabilidade do cliente, mas não removeu o
gargalo de 640×480. Ela deve permanecer por ser a associação correta entre a
conexão que criou a janela e o frontend EGL.

## 7. DRI3, `/dev/dri`, `/dev/dxg` e Linux padrão

- `/dev/dri` representa o modelo DRM usado normalmente pelos drivers Linux.
- DRI3 e dma-buf permitem compartilhar buffers com o servidor X sem cópia integral
  GPU→CPU por quadro.
- O WSL expõe a GPU do Windows por `/dev/dxg`, não como render node DRM comum.
- O Xwayland da sessão investigada não consegue obter um dispositivo DRI3.
- O driver Gallium D3D12 usa, então, um `sw_winsys` com frontbuffer em memória da
  CPU.

Em uma distribuição Linux padrão com `iris`, `radeonsi`, `nouveau`, `amdgpu` ou
outro driver DRM funcional, o backend Dart não deve ativar o workaround WSL. Deve
usar a apresentação direta disponível.

## 8. Vulkan/Dozen

O loader expor `VK_KHR_xcb_surface` ou `VK_KHR_wayland_surface` não prova que há
GPU. Inicialmente, a distro só possuía o ICD Lavapipe, portanto o único dispositivo
era CPU.

O Mesa 26.3 foi recompilado com o driver experimental Dozen e instalado
isoladamente em `/opt/mesa-26.3-dzn`. O `vulkaninfo` passou a reportar:

```text
deviceType = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
deviceName = Microsoft Direct3D12 (Intel(R) UHD Graphics)
driverName = Dozen
driverInfo = Mesa 26.3.0-devel
VK_KHR_wayland_surface, VK_KHR_xcb_surface, VK_KHR_swapchain
```

O Dozen ainda informa que não é uma implementação Vulkan conformante. Os testes
de 120 quadros com `vkcube` mostraram:

| WSI e tamanho | Tempo | Taxa aproximada |
|---|---:|---:|
| Wayland 300×300 | 4,92 s | 24,4 FPS |
| XCB 300×300 | 5,09 s | 23,6 FPS |
| Wayland 640×480 | 15,05 s | 8,0 FPS |
| XCB 640×480 | 14,69 s | 8,2 FPS |

Assim, Vulkan usa de fato a Intel/D3D12, mas não evita o gargalo de apresentação
em memória de sistema. A equivalência entre Wayland e XCB reforça que o custo
dominante não está no protocolo X11 nem na versão do OpenGL.

## 9. Driver Intel e Chrome

O driver Intel original era de 2022. O pacote oficial 32.0.101.7088 foi baixado e
seu SHA-256 coincidiu com o publicado pela Intel. O wrapper SFX mostrou erro de
integridade, embora o conteúdo estivesse correto e o `Installer.exe` interno
tivesse assinatura válida.

O instalador interno travou em `DiInstallDriver`. O INF assinado foi instalado
diretamente com `pnputil`, e o reboot ativou 32.0.101.7088. O readback lento
permaneceu, portanto o driver antigo não era a causa desse gargalo.

O Chrome apresentou `AppHangB1`. Um perfil limpo funcionou e o perfil principal
funcionou com extensões desativadas, indicando extensão ou estado do perfil como
causa mais provável. O perfil do usuário não foi apagado.

## 10. Política recomendada para os backends Dart

A seleção deve ser baseada em capacidades:

1. Enumerar `/dev/dri` e `/dev/dxg`.
2. Consultar DRI3, Wayland globals, EGL vendor/renderer e extensões.
3. Enumerar os dispositivos Vulkan e rejeitar Lavapipe quando o objetivo for GPU.
4. Executar ou usar cache de um microbenchmark de apresentação por combinação.
5. Preferir apresentação compartilhada/direta.
6. Aplicar workaround D3D12 somente quando o ambiente realmente exigir.
7. Manter raster/SHM como fallback explícito e mensurável.

Essa política preserva desempenho e compatibilidade em Ubuntu/Fedora/openSUSE e
outras distribuições Linux nativas, no WSLg e em servidores X externos.

## 11. Artefatos locais

- Mesa upstream: `D:\wslg-dev\mesa-upstream`.
- Mesa compilado na distribuição: `/opt/mesa-26.3-git`.
- Mesa com Dozen/Vulkan: `/opt/mesa-26.3-dzn`.
- OpenVMM: `D:\wslg-dev\openvmm`.
- WSLg/Weston: `D:\wslg-dev\wslg` e `D:\wslg-dev\weston-mirror`.
- VHD WSLg corrigido:
  `D:\wslg-dev\artifacts\system_x64-wslg-1.0.79-weston-retry.vhd`.
- Capturas: `D:\wslg-dev\artifacts\poc02-mesa-26.3-*.png`.
- Patch Mesa reproduzível:
  [`doc/propostas/mesa_d3d12_frontbuffer_parallel_copy.patch`](propostas/mesa_d3d12_frontbuffer_parallel_copy.patch).
- Log Intel:
  `C:\ProgramData\Intel\GFXInstaller\Installer\IntelGFX_20260822_173438_Install.log`.

## 12. Trabalho restante

- validar o protótipo `util_queue` do Mesa contra formatos, resize e teardown;
- medir latência, uso de CPU e imagem em 4K; 640×480 e 1080p já foram medidos;
- implementar e medir a POC Dart EGL/Wayland;
- completar a prova de sincronização: a imagem D3D12 já foi exportada/importada
  entre dois processos Linux sem readback, mas o semaphore externo falhou;
- obter, se necessário, rastreamento de `/dev/dxg` abaixo da pilha GDB já
  confirmada;
- avaliar uma extensão real de compartilhamento WSLg/Xwayland, sem simular DRI3;
- publicar no GitLab a issue do Mesa já preparada; a issue do WSLg foi publicada;
- separar, se solicitado pelos mantenedores, o defeito de teardown do semaphore
  Dozen em uma segunda issue.

## 13. Relatos públicos

- WSLg, readback D3D12 e proposta de external-image:
  [`microsoft/wslg#1498`](https://github.com/microsoft/wslg/issues/1498).
- Resultado do teste VM→host com `OpenSharedHandleByName`:
  [comentário em `microsoft/wslg#1498`](https://github.com/microsoft/wslg/issues/1498#issuecomment-5382899700).
- Complemento na issue de Vulkan do WSLg com os resultados Dozen:
  [`microsoft/wslg#40`](https://github.com/microsoft/wslg/issues/40#issuecomment-5382834263).
- Defeito `virtio-fs`/SectionFs:
  [`microsoft/openvmm#4274`](https://github.com/microsoft/openvmm/issues/4274).
- Evidência e diagnóstico do COPY MODE:
  [`microsoft/wslg#1456`](https://github.com/microsoft/wslg/issues/1456#issuecomment-5379845299).
- Retry defensivo do Weston:
  [`microsoft/weston-mirror#171`](https://github.com/microsoft/weston-mirror/pull/171).
- Rascunho completo para a issue do Mesa:
  [`doc/propostas/07_issue_mesa_d3d12_frontbuffer_readback_wslg_en.md`](propostas/07_issue_mesa_d3d12_frontbuffer_readback_wslg_en.md).

A issue do Mesa sobre o readback e a falha de external semaphore ainda precisa
ser submetida no GitLab.freedesktop. O texto reproduzível está pronto no arquivo
acima; a sessão autenticada visível no navegador não ficou acessível à automação
e o repositório não aceita publicação anônima.
