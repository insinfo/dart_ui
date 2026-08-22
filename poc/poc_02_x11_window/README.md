# POC-02 — Janela X11/XCB

Implementação mínima, 100% Dart FFI, para conectar ao X server, criar/mapear
uma janela, receber `XCB_EXPOSE` e enviar um buffer BGRA via `xcb_put_image`.
O smoke test também valida o protocolo completo `WM_DELETE_WINDOW`: interna os
atoms, configura a property e captura o `ClientMessage` de fechamento.

O teste é exclusivo de Linux e deve ser executado com `DISPLAY` configurado.
O workflow `POC Tests` já inicializa o Xvfb no GitHub Actions.

```bash
DISPLAY=:99 dart test poc/poc_02_x11_window
DISPLAY=:99 dart run poc/poc_02_x11_window/bin/main.dart --smoke-test
```

## Demonstração OpenGL com Janela X11 (WSLg / Ubuntu)

O executável `bin/main_linux.dart` demonstra a criação de uma janela nativa X11 via XCB com aceleração OpenGL / EGL 100% puro Dart FFI:

```bash
# Execução no Linux / Ubuntu no WSLg
export DISPLAY=:0
dart run poc/poc_02_x11_window/bin/main_linux.dart

# Opções adicionais:
dart run poc/poc_02_x11_window/bin/main_linux.dart --frames 300
dart run poc/poc_02_x11_window/bin/main_linux.dart --continuous
dart run poc/poc_02_x11_window/bin/main_linux.dart --width 800 --height 600
```

### Executando diretamente pelo Windows (PowerShell)

Você pode executar diretamente pelo terminal do Windows / PowerShell utilizando o script auxiliar:

O script sempre executa `dart pub get` dentro do Linux, recompila
`main_linux.dart` para AOT e executa o ELF recém-gerado. Isso evita reutilizar
o `package_config.json` do Dart para Windows ou um binário AOT desatualizado.

```powershell
# Execução padrão (300 frames)
.\poc\poc_02_x11_window\bin\run_linux.ps1

# Execução contínua
.\poc\poc_02_x11_window\bin\run_linux.ps1 --continuous

# -Aot continua aceito por compatibilidade, mas AOT já é o padrão
.\poc\poc_02_x11_window\bin\run_linux.ps1 -Aot --continuous

# Recompilar binário AOT
.\poc\poc_02_x11_window\bin\run_linux.ps1 -Compile

# Depurar com GDB no Linux/WSL
.\poc\poc_02_x11_window\bin\run_linux.ps1 -Aot -Gdb --frames 10

# Resolução customizada
.\poc\poc_02_x11_window\bin\run_linux.ps1 --width 800 --height 600

# Escolher outra distribuição WSL
.\poc\poc_02_x11_window\bin\run_linux.ps1 -Distro openSUSE-Tumbleweed --frames 60

# Forçar um DISPLAY específico ou impedir o fallback
.\poc\poc_02_x11_window\bin\run_linux.ps1 -Display 172.28.80.1:1.0 --continuous
.\poc\poc_02_x11_window\bin\run_linux.ps1 -WslgOnly --frames 60

# Comparar os drivers Mesa no mesmo VcXsrv
.\poc\poc_02_x11_window\bin\run_linux.ps1 -GalliumDriver d3d12 --frames 120 --uncapped
.\poc\poc_02_x11_window\bin\run_linux.ps1 -GalliumDriver llvmpipe --frames 120 --uncapped

# Usar o Mesa instrumentado/corrigido e controlar a copia paralela
.\poc\poc_02_x11_window\bin\run_linux.ps1 -MesaPrefix /opt/mesa-26.3-git -D3D12FrontbufferThreads 32 --frames 300
```

A compilação AOT também gera `bin/main_linux.aot.debug`, com os símbolos Dart
separados. O arquivo é local e não deve ser versionado. Ele pode ser usado para
simbolizar endereços AOT sem modificar o executável: aplicar `objcopy` depois da
compilação invalida o trailer interno do executável Dart.

Se apenas o ícone surgir na barra de tarefas, com miniatura vazia e título
`[WARN:COPY MODE]`, a janela foi mapeada corretamente mas o transporte gráfico
do WSLg falhou. Esse problema é acompanhado em
[microsoft/wslg#1456](https://github.com/microsoft/wslg/issues/1456) e também
ocorre com aplicações X11 que não usam Dart ou OpenGL.

Quando detecta esse estado, o script procura o VcXsrv instalado no Windows,
inicia o servidor no display `:1`, descobre o gateway atual da distribuição
e redireciona a POC automaticamente. O Mesa continua no WSL com
o renderer selecionado explicitamente no terminal.

No Mesa D3D12, tanto o EGL/X11 quanto o EGL/Wayland do WSLg terminam em um
frontbuffer de memória de sistema. A primeira leitura de cada recurso D3D12
mapeado custou 103–149 ms em 640×480; publicar o resultado no X11 custou apenas
0,7–2,5 ms. Portanto, DRI3 ausente expõe a limitação, mas o gargalo dominante
não está no protocolo X11 nem na versão do OpenGL.

O Mesa experimental instalado em `/opt/mesa-26.3-git` divide a cópia do
frontbuffer entre workers persistentes. Com 32 workers, a mesma POC atingiu
aproximadamente 30–40 FPS em 640×480, contra 7–9 FPS no caminho serial. O script
detecta esse prefixo automaticamente e configura `D3D12_FRONTBUFFER_THREADS`;
`-MesaPrefix system` força as bibliotecas da distribuição. Sem o Mesa corrigido,
o modo automático ainda pode selecionar `llvmpipe` como fallback funcional.

O diagnóstico ETW/GDB do reset incorreto de `node_id` do `virtiofs` está em
[`doc/DIAGNOSTICO_WSLG_VIRTIOFS_BUILD_26200.md`](../../doc/DIAGNOSTICO_WSLG_VIRTIOFS_BUILD_26200.md).
O relatório consolidado de WSL, WSLg, Mesa, OpenGL, Vulkan e dos experimentos de
compartilhamento está em
[`doc/RELATORIO_DIAGNOSTICO_WSL_WSLG_MESA.md`](../../doc/RELATORIO_DIAGNOSTICO_WSL_WSLG_MESA.md).
