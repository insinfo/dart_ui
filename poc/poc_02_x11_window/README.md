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
```

Se apenas o ícone surgir na barra de tarefas, com miniatura vazia e título
`[WARN:COPY MODE]`, a janela foi mapeada corretamente mas o transporte gráfico
do WSLg falhou. Esse problema é acompanhado em
[microsoft/wslg#1456](https://github.com/microsoft/wslg/issues/1456) e também
ocorre com aplicações X11 que não usam Dart ou OpenGL.

Quando detecta esse estado, o script procura o VcXsrv instalado no Windows,
inicia o servidor no display `:1`, descobre o gateway atual da distribuição
e redireciona a POC automaticamente. O Mesa continua no WSL com
`GALLIUM_DRIVER=d3d12`; no ambiente validado o renderer permaneceu
`D3D12 (Intel(R) UHD Graphics)`, sem fallback para `llvmpipe`.
