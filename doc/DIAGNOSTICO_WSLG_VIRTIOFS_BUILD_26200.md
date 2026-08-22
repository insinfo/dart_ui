# Diagnóstico WSLg virtio-fs — Windows build 26200

Data da captura: 2026-08-22.

## Resultado

O problema não é ausência permanente do mount `/mnt/shared_memory`, nem falta
de aceleração D3D12. É o bug de reset do identificador de nós do SectionFs
descrito em
[`microsoft/openvmm#4274`](https://github.com/microsoft/openvmm/issues/4274).

O `SectionFs` reserva o identificador `1` para a raiz FUSE e inicialmente cria
seu `HandleMap` a partir de `2`. Depois de `FUSE_DESTROY`, porém,
`HandleMap::clear()` reinicia o próximo identificador em `1`. O primeiro
`CREATE` da sessão seguinte recebe, portanto, `nodeid: 1`. Embora o servidor
retorne sucesso, o kernel Linux rejeita esse valor reservado (`FUSE_ROOT_ID`)
e entrega `EIO` ao Weston.

No boot ruim, o Weston testa uma seção GUID logo após iniciar e recebe `EIO`:

```text
rdp_allocate_shared_memory: Failed to open
  "/mnt/shared_memory/{...}" with error: Input/output error
RDP backend: use_gfxredir = 0
RDP backend: enable_copy_warning_title = 1
```

Esse teste ocorre apenas na inicialização. Se falhar, o backend mantém
`use_gfxredir=0` durante toda a sessão e o WSLg entra em COPY MODE. O segundo
`CREATE` já recebe `nodeid: 2` e funciona; não é necessário esperar. O problema
é determinístico depois do `FUSE_DESTROY`, não uma corrida de inicialização.

Os cinco cold boots capturados anteriormente funcionaram porque cada
`wsl --shutdown` reconstruiu a VM e um novo `SectionFs` corretamente iniciado
em `2`. Encerrar e reiniciar somente a distribuição preserva o DeviceHost e
aciona o caminho defeituoso de `destroy()`.

## Ambiente reproduzido

```text
Windows                 10.0.26200.9168
WSL                     2.9.4.0
Kernel                  6.18.35.2-1
WSLg                    1.0.79
Ubuntu                  24.04.1 LTS
Mesa                    25.2.8-0ubuntu0.24.04.2
GPU                     Intel(R) UHD Graphics
Weston                  9.0.0-215-ga7e35fda
```

O problema foi observado tanto com Ubuntu quanto com openSUSE Tumbleweed, o
que também exclui os pacotes da distribuição de usuário como causa primária.

## Evidência do namespace correto

O mount relevante existe apenas na distribuição de sistema do WSLg:

```text
$ wsl --system -- findmnt -T /mnt/shared_memory
TARGET             SOURCE FSTYPE   OPTIONS
/mnt/shared_memory wslg   virtiofs rw,relatime,dax=always
```

No Ubuntu, `/mnt/shared_memory` é apenas um diretório do filesystem ext4 da
distribuição. Criar um `tmpfs` nesse diretório não conserta o endpoint do WSLg.

## Captura ETW oficial

Foi usado o perfil oficial
[`diagnostics/wsl.wprp!WSL`](https://github.com/microsoft/WSL/blob/master/diagnostics/wsl.wprp),
conforme o
[`debugging.md` do WSL](https://github.com/microsoft/WSL/blob/master/doc/docs/debugging.md).

Provedores relevantes encontrados no ETL:

```text
Microsoft.Windows.Lxss.Manager  450 eventos
Microsoft.WSL.DeviceHost        891 eventos
Microsoft.Windows.HyperV.Worker 236 eventos
```

No boot bem-sucedido, a sequência do DeviceHost foi:

```text
AddSharePath name = wslg,
  path = \Sessions\1\BaseNamedObjects\WSL\<VM-ID>\wslg
CreateVirtioDevice called
FUSE Init 7.45 -> 7.39
Lookup GUID -> ENOENT
Create GUID -> sucesso
FAllocate 4096 -> sucesso
SetupMapping 2 MiB DAX -> sucesso
Weston: use_gfxredir = 1
```

Uma captura controlada confirmou a sequência defeituosa no host:

```text
07:47:33.760  FUSE Destroy
07:47:35.840  Create "{GUID do Weston}"
07:47:35.840  CreateOut nodeid: 1
07:47:35.888  Weston: open(...) -> EIO; use_gfxredir = 0
07:47:40.338  segundo Create do probe
07:47:40.338  CreateOut nodeid: 2
07:47:40.339  fallocate/mmap/DAX -> sucesso
```

Isso reproduz exatamente o diagnóstico do OpenVMM: depois de `Destroy`, o
primeiro identificador inválido é `1`, e o pedido seguinte recebe `2` e
funciona. O `Microsoft.WSL.DeviceHost` é o componente Windows que atende essas
requisições FUSE/virtio-fs; Dart, EGL e o driver D3D12 não participam da falha.

## Respostas FUSE que não são a causa

O DeviceHost responde `ENOSYS` para `GETXATTR`, `FLUSH` e escrita tradicional.
Isso é esperado para este filesystem especializado em seções DAX:

```text
GetXAttr security.capability -> error=38 (ENOSYS)
Flush                         -> error=38 (ENOSYS)
Write tradicional            -> error=38 (ENOSYS)
```

No caso de `FUSE_FLUSH`, o kernel transforma `ENOSYS` em sucesso e passa a
marcar o filesystem como `no_flush`; veja
[`fuse_flush()` no kernel Linux](https://github.com/torvalds/linux/blob/master/fs/fuse/file.c).
Esses mesmos retornos apareceram nos cinco boots em que `gfxredir` funcionou.

Também foram vistos `STATUS_INSUFFICIENT_RESOURCES (0xC000009A)` e
`STATUS_HV_INVALID_PARAMETER (0xC0350005)` ao mapear páginas de estatística do
Hyper-V VID. Como esses eventos também ocorreram no boot bem-sucedido, não há
evidência suficiente para tratá-los como a causa do COPY MODE.

## Probe DAX nativo

Foi adicionado
`poc/poc_02_x11_window/native/virtiofs_dax_probe.c`. O ELF estático reproduz o
caminho do
[`rdp_allocate_shared_memory()` do Weston](https://github.com/microsoft/weston-mirror/blob/working/libweston/backend-rdp/rdputil.c):

```text
open(O_CREAT | O_RDWR | O_EXCL) -> ok
fallocate(4096)                 -> ok
mmap(MAP_SHARED, 2 MiB)         -> ok
escrita na primeira página      -> ok
msync / munmap / close          -> ok
unlink                          -> EINVAL
```

O resultado foi o mesmo como `root` e como usuário `wslg` (UID 1000). Isso
prova que DAX e permissões básicas funcionam nos boots bons.

Na captura controlada, o primeiro `open()` foi o probe do próprio Weston e
falhou com `EIO`; o probe nativo executado em seguida concluiu todo o caminho
DAX. Isso comprova que uma repetição imediata é suficiente, pois recebe o
próximo identificador válido.

## GDB no Dart AOT

O script `run_linux.ps1` agora compila sempre:

```text
bin/main_linux.aot        ELF PIE x86-64, stripped
bin/main_linux.aot.debug  ELF com DWARF debug_info e símbolos Dart
```

O GDB parou em `eglSwapBuffers` e confirmou o carregamento de:

```text
libEGL_mesa.so.0
libgallium-25.2.8-0ubuntu0.24.04.2.so
/usr/lib/wsl/lib/libd3d12.so
/usr/lib/wsl/lib/libdxcore.so
libigd12umd64.so
```

Renderer observado:

```text
D3D12 (Intel(R) UHD Graphics)
```

O executável terminou normalmente depois de destruir EGL/X11, sem SIGSEGV ou
falha de destruição assíncrona. A aplicação não causa o erro do virtio-fs; ela
recebe um servidor X já degradado pelo COPY MODE.

No boot ruim, a medição foi 9,4 FPS e cerca de 106 ms por `eglSwapBuffers`,
apesar do renderer D3D12. O gargalo é a apresentação/cópia do frame, não a
execução dos shaders.

Não se deve executar `objcopy` no `main_linux.aot` para adicionar um
`.gnu_debuglink`: isso altera offsets do trailer próprio do executável Dart.
O arquivo `.debug` deve permanecer separado para simbolização.

## Correção recomendada no WSL/WSLg

A correção primária deve ser feita no OpenVMM: `SectionFs::destroy()` precisa
restaurar o próximo identificador em `2`, preservando a reserva de
`FUSE_ROOT_ID`. Alternativamente, `HandleMap::clear()` deve restaurar a semente
com que o mapa foi construído, em vez de sempre usar `1`.

O retry proposto no
[`microsoft/weston-mirror#171`](https://github.com/microsoft/weston-mirror/pull/171)
é um contorno válido para versões antigas do host: basta repetir uma vez o
`rdp_allocate_shared_memory()` após `EIO`. A duração do `sleep` não é relevante,
porque o primeiro `CREATE` consome o identificador inválido e o segundo recebe
`2`. Esse PR foi fechado sem merge depois que a causa foi atribuída ao
OpenVMM #4274.

## Artefatos locais

Os ETLs não são versionados porque contêm caminhos e metadados da máquina:

```text
C:\Users\pmro\AppData\Local\Temp\wsl-official-20260822-072237\wsl.etl
C:\Users\pmro\AppData\Local\Temp\wsl-official-20260822-072237\wsl.xml
C:\Users\pmro\AppData\Local\Temp\wsl-official-20260822-072237\targeted-events.txt
C:\Users\pmro\AppData\Local\Temp\wsl-official-20260822-072237\gdb-aot.txt
C:\Users\pmro\AppData\Local\Temp\wsl-official-20260822-072237\weston-failing-after-trace.log
C:\Users\pmro\AppData\Local\Temp\wsl-devicehost-nodeid-20260822-074709\devicehost.etl
C:\Users\pmro\AppData\Local\Temp\wsl-devicehost-nodeid-20260822-074709\devicehost.xml
C:\Users\pmro\AppData\Local\Temp\wsl-devicehost-nodeid-20260822-074709\weston-before.log
C:\Users\pmro\AppData\Local\Temp\wsl-devicehost-nodeid-20260822-074709\weston-after.log
```

O ETL oficial teve zero indicação de perda de buffers. Antes de anexar
publicamente, ele deve ser compactado e revisado por conter PII, paths e IDs da
VM.

## Validação do WSLg privado com retry do Weston

Foi compilada a imagem oficial do `microsoft/wslg` 1.0.79 com um patch local no
Weston. O probe de memória compartilhada é repetido uma vez após falha e cada
tentativa usa um GUID novo. Isso evita tanto o `FUSE_ROOT_ID` inválido na
primeira tentativa quanto `EEXIST` caso o servidor tenha criado o nome apesar
do retorno `EIO`.

Artefato instalado como system distro:

```text
D:\wslg-dev\artifacts\system_x64-wslg-1.0.79-weston-retry.vhd
SHA256 ED168DE3D1608A926D4B279314FF6D759D2EE7985A1A6763AA10E0FF92E7395B
```

Configuração do host em `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
systemDistro=D:\\wslg-dev\\artifacts\\system_x64-wslg-1.0.79-weston-retry.vhd
```

Após `wsl --shutdown`, o log confirmou a sequência prevista:

```text
rdp_allocate_shared_memory: Failed to open ... Input/output error
RDP backend: use_gfxredir = 1
```

A janela RAIL tornou-se visível. Isso valida o retry como contorno funcional e
reforça que a correção definitiva pertence ao contador de handles do OpenVMM.

### EGL/X11 após restaurar gfxredir

O Xwayland dessa imagem anuncia `Present` e `MIT-SHM`, mas não `DRI3`. Há dois
resultados distintos para a mesma POC AOT:

```text
GALLIUM_DRIVER=d3d12     D3D12 (Intel UHD), quadro preto, ~8,9 FPS, swap ~112 ms
GALLIUM_DRIVER=llvmpipe  triângulo visível, ~63 FPS, swap ~1,6 ms
```

Logo, o quadro preto não é uma recaída do virtio-fs: é o caminho de apresentação
EGL/X11 do Mesa D3D12 sem DRI3. O `run_linux.ps1` agora usa o último valor de
`use_gfxredir` para detectar COPY MODE e, no modo `auto`, consulta as extensões
do DISPLAY antes de selecionar o driver. Sem DRI3 ele escolhe `llvmpipe`; o modo
`-GalliumDriver d3d12` continua disponível para reproduzir e comparar o caminho
experimental acelerado.
