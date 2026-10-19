# Explorador de arquivos (estilo Windows 11), 100% Dart

Um explorador de arquivos com a cara e o comportamento do Explorador do
Windows 11, tendo o [Files](https://github.com/files-community/files) como
referência de recursos e layout (nenhum código copiado).

```
dart run bin/file_explorer.dart [pasta]
```

## Linux (Ubuntu/Debian)

Use Dart 3.6.2 e execute `dart pub get` na raiz do projeto e nesta pasta.
Para X11 com OpenGL, as bibliotecas de execução são:

```sh
sudo apt install libxcb1 libx11-6 libegl1 libgl1 libgl1-mesa-dri
cd examples/file_explorer
dart pub get
dart run bin/file_explorer.dart "$HOME" --backend=x11 --presentation=opengl
```

Para GNOME Wayland com OpenGL nativo:

```sh
sudo apt install libwayland-client0 libegl1 libgl1 libgbm1 libgl1-mesa-dri
dart run bin/file_explorer.dart "$HOME" --backend=wayland --presentation=wayland-opengl
```

Esse caminho usa EGL/GBM e compartilha buffers por `linux-dmabuf` v3,
sem ler os pixels da GPU para apresentá-los pela CPU. O compositor precisa
aceitar os formatos/modificadores exportados pelo driver. A seleção automática
prefere esse caminho e mantém `wayland-shm` como alternativa por CPU.
A validação em GNOME/Mesa virgl está em
[GNOME_WAYLAND_GPU_2026-10-18.md](../../doc/logs/GNOME_WAYLAND_GPU_2026-10-18.md).

Execute dentro da sessão gráfica, como o usuário conectado. Sem aceleração,
`--cpu` permite usar a apresentação por CPU. Vulkan não é necessário para
este caminho. `glxinfo -B` (`mesa-utils`) permite conferir o driver e a
aceleração disponíveis.

Em uma VM com pasta compartilhada do macOS, mantenha uma cópia de trabalho
local no Linux e rode `dart pub get` nela: `.dart_tool` contém caminhos
específicos do sistema. O executável AOT é gerado pelo comando de distribuição
abaixo. Depois, execute `./build/FileExplorer "$HOME"`.

A validação em Ubuntu ARM64, Xfce/Xorg e Mesa virgl está registrada em
[FILE_EXPLORER_LINUX_2026-10-18.md](../../doc/logs/FILE_EXPLORER_LINUX_2026-10-18.md).

## Opções e produtividade

Abra **Opções de Pasta** pelo menu `···` ou por Ctrl/Cmd+`,`.
As abas Geral, Modo de Exibição e Pesquisar controlam abertura, recentes,
restauração da sessão, vistas por pasta, miniaturas, caixas de seleção,
densidade e escopo da pesquisa. Cancelar descarta a cópia de edição;
Aplicar grava as preferências do usuário.

- Ctrl/Cmd+Shift+P: paleta de comandos.
- Alt+P: painel de prévia de texto/imagem; o menu Exibir oferece também Detalhes.
- F2 com vários itens: renomeação numerada, preservando extensões.
- Ctrl/Cmd+Z e Ctrl/Cmd+Shift+Z: desfazer/refazer renomeações e movimentações.
- Botão direito nas abas: duplicar, mover, restaurar e fechar grupos de abas.
- Botão direito nos arquivos: Favoritos, compactar ZIP e extrair ZIP para nova pasta.
- Pesquisa: `*.pdf`, `ext:dart`, `kind:image size:>10MB`, `modified:>=2026-01-01`;
  suporta frases entre aspas e AND / OR / NOT.

As preferências ficam em `StandardPaths.appData/dart_ui_file_explorer`,
fora das pastas navegadas. Para detalhes de suporte e limites, consulte
[EXPLORER_PORTABLE_FEATURES_2026-10-18.md](../../doc/logs/EXPLORER_PORTABLE_FEATURES_2026-10-18.md).

## Arquitetura

- `lib/src/engine/` - o motor, sem widgets: `FileSystem` (interface),
  `ExplorerModel` (abas, histórico, seleção, área de transferência de
  arquivos, operações), e os comandos em módulos (`commands/`). Tudo o que a
  janela faz é um comando executado pelo registro, como no editor vetorial.
- `lib/src/io/` - o adaptador para o disco (`dart:io`, lixeira, abrir com o
  aplicativo padrão, observar a pasta).
- `lib/src/ui/` - a janela.
- `test/` - o motor contra um `MemoryFileSystem`, e a janela sem tela.

## Distribuir

Um único executável, com as fontes e os ícones dentro:

```
dart run dart_ui build bin/file_explorer.dart --name "File Explorer" -o build/FileExplorer
```

No Windows sai `build/FileExplorer.exe`, sem console; no macOS,
`build/FileExplorer.app`, com o host AppKit dentro; no Linux, o binário e um
`.desktop`. Cada sistema compila o seu (`dart compile exe` não faz
cross-compilation).

## Ver sem tela

```
dart run tool/headless_shot.dart shot.png icons --dark --lang=pt
```

Cenários: `home`, `details`, `icons`, `tiles`, `rename`, `search`,
`thispc`, `details-pane`.

## Renomeação e menus

Para renomear no próprio lugar, selecione um item e clique novamente no nome,
com uma pausa entre os cliques. F2 continua disponível; duplo clique abre o item.
O comportamento funciona nos oito modos de exibição e respeita a opção de
abrir com clique único. Menus bloqueiam o hover da pasta enquanto estão abertos.

[Transparência dos popups e validação por plataforma](../../doc/logs/POPUP_ALPHA_HOVER_RENAME_2026-10-18.md).
