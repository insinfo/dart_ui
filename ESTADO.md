# Estado do projeto

**Atualizado em 13/10/2026, no fim do dia.** Framework de interface 100% Dart,
sem Flutter e sem depender do engine do Flutter. Trabalho só na branch `main`.

Para retomar, leia nesta ordem:

1. este arquivo;
2. [`doc/DIARIO_FLUTTER.md`](doc/DIARIO_FLUTTER.md) e
   [`doc/AGENTS_FLUTTER.md`](doc/AGENTS_FLUTTER.md), para a compatibilidade
   com o Flutter, e [`doc/paridade_flutter.md`](doc/paridade_flutter.md), a
   tabela gerada;
3. [`examples/vector_editor_demo/DIARIO.md`](examples/vector_editor_demo/DIARIO.md)
   e o `AGENTS.md` dele, para o editor vetorial;
4. [`doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md`](doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md),
   o roteiro completo, e [`doc/MIGRACAO_DO_FLUTTER.md`](doc/MIGRACAO_DO_FLUTTER.md).

---

## Números de hoje

| O quê | Valor |
|---|---|
| Commits em 13/10/2026 | mais de 120 |
| Testes da raiz | 7 871 passando (831 pulados, de plataforma); 18 exemplos analisam limpos |
| Editor vetorial | P0 100% (63 de 63); 163 testes |
| File explorer | 42 testes; alinhamento medido contra a referência |
| Paridade com o Flutter, P0 | 68% (era 53% de manhã, na primeira medida) |
| Paridade com o Flutter, total | 26% de 2 613 nomes públicos (era 16%) |

---

## O que foi feito hoje

### File explorer (`examples/file_explorer`)
- Verificado nos 8 cenários, claro e escuro, e comparado pixel a pixel com a
  referência do Files: texto centrado na barra lateral e nas abas, lupa,
  toolbar, grade de ícones com 6 colunas, "Configurações" na linha do status.
- "Novo" desabilitado onde nada pode ser criado; motivos de comando
  desabilitado em português nos tooltips.
- Fechar a janela pelo X encerra o processo (um `Directory.watch` o
  prendia); o `runApp` agora garante isso para qualquer app.
- Arrastar a largura de uma coluna: de 4-9 para 55 quadros por segundo
  (quadro típico de ~80 ms para ~6 ms).
- Sondas no host real do macOS em `tool/macos_*_probe.dart` (menus,
  submenus, tooltips, fechar, arrastar coluna, redimensionar).

### Editor vetorial (`examples/vector_editor_demo`)
- Pena caligráfica e preenchimento de padrão e textura (hachura, pontos,
  grade, xadrez; nuvens, papel, ruído), com SVG que guarda e relê.
- Corrigido no framework: polígono de n cantos virava 2n lados.
- **P0 em 100%.**

### Framework
- **Compatibilidade com o Flutter, medida:** `tool/flutter_parity.dart` gera
  `doc/paridade_flutter.md`; um teste exige a tabela atualizada.
- **P0 do Flutter, em lotes:**
  - pintura (`BorderRadius`, `Border`, `BoxShadow`, `Canvas`/`Paint`,
    `CustomPainter`, `ClipOval`/`ClipPath`/`ClipRRect` com cantos de verdade);
  - app (`WidgetsBinding`, `WidgetsApp`, `ErrorWidget`, chaves,
    `InheritedNotifier`/`InheritedModel`);
  - rolagem (`ScrollController`, `scrollDirection:`, `ScrollPhysics` com
    mola, `PageView`, `NotificationListener`);
  - entrada (`Listener`, `Draggable`/`DragTarget`, `Dismissible`,
    `InteractiveViewer`, `Focus`, `Shortcuts`/`Actions`/`Intent`,
    `LogicalKeyboardKey`);
  - formulários (`Form`, `TextFormField`, `InputDecoration`, formatadores);
  - animação (`Ticker`, `AnimationController(vsync: this)`,
    `AnimatedScale`/`Rotation`/`Slide`).
- **`package:dart_ui/material.dart`**, primeira parte: tema do Material 3
  (`ThemeData`, `ColorScheme.fromSeed`, `Colors`, `TextTheme`, `Icons`) e o
  widget `Material`.
- **Widgets novos:** `Flow`, `SliverAppBar`/`FlexibleSpaceBar`,
  `NestedScrollView`, `Ribbon` do Office.
- **Popups em janela nativa no macOS:** submenu no lugar certo (abria no
  canto da janela), uma borda só com a sombra do sistema, aparência dos menus
  do Finder, ordem z presa à janela dona quando o app está em segundo plano.
- **Redimensionar no macOS:** a janela não fica mais branca; o host espera o
  quadro no tamanho novo.
- **Quarto backend do macOS, `appkitEmbedded`:** o Dart convidado do
  processo, num `dartaotruntime` compilado do código-fonte com patch (como no
  iOS). Um processo para todas as janelas; menu abre em 6-10 ms (243 ms no
  host nativo); partida em 275 ms (406 ms). Ver
  [`doc/MACOS_TRES_BACKENDS.md`](doc/MACOS_TRES_BACKENDS.md) e
  `dart run tool/macos/build_app.dart <entrada.dart> -o build/App.app`.
- **Correções:** retângulos girados pintados como caixa alinhada aos eixos;
  `ValueNotifier` agora é `Listenable`; `Offset`/`Size`/`Rect` com a API do
  `dart:ui`; `Scrollbar(controller:)`; janelas do modo imediato
  redimensionáveis.

---

## O que falta fazer

### Primeiro (bugs que o usuário vê)
1. **Clicar num item de submenu fecha os menus sem rodar o comando**, nos
   dois backends do macOS. Suspeita: o `MenuItemButton` lê `onPressed` depois
   de `closeChain()` desmontar o item (`lib/src/widgets/menu_anchor.dart`).
2. **Redimensionar no macOS** ainda perde o quadro em parte dos passos: a
   troca de superfícies leva cinco idas e voltas ao host e cria IOSurfaces a
   cada passo. Alocar com folga; implementar `EventLoopWaitingBackend` no
   backend macOS (hoje o laço gira em `Future.delayed(0)` e gasta CPU parado).
3. **Popups no Windows 11:** provavelmente quadrados e opacos por fora da
   superfície arredondada; pedir cantos arredondados ao DWM. Não verificado
   (não há Windows aqui).
4. Combo box, flyout e ribbon em janela nativa ainda pintam o próprio
   contorno (a borda dupla dos menus, já resolvida, volta neles).
5. `ClipPath` vaza alguns pixels nas pontas de uma estrela.

### Compatibilidade com o Flutter (P0 em 68%)
1. **Material, esqueleto do app:** `MaterialApp`, `Scaffold`,
   `ScaffoldMessenger`/`SnackBar`, `AppBar`/`PreferredSize`, `InkWell`,
   `IconButton`, `FloatingActionButton`, `Drawer`, `NavigationBar`,
   `NavigationRail`, `BottomNavigationBar`, `TabBar`/`TabBarView`. Meta:
   `examples/material_counter`, o contador do Flutter com só o import trocado.
2. **Material, controles:** botões (`ElevatedButton`, `FilledButton`,
   `OutlinedButton`, `TextButton`), `ListTile`, `Card`, `Checkbox`, `Radio`,
   `Switch`, `Slider`, `DropdownButton`, `PopupMenuButton`, diálogos,
   `showModalBottomSheet`, indicadores de progresso, `DataTable`, `Stepper`,
   `showDatePicker`/`showTimePicker`.
3. **Fora do Material:** imagens (`ImageProvider`, `AssetImage`,
   `NetworkImage`, `Image(image:)`; pede `widgets → assets` no teste de
   camadas e migrar `Image(decodedImage)` para `RawImage`),
   `AnimatedCrossFade`, `ModalRoute`, `OverlayPortal`, `Clipboard`,
   `HapticFeedback`, `SystemChrome`, `ShaderMask(blendMode: BlendMode)`.
4. **Decisão pendente:** `TextEditingController(text: 'x')`,
   `TextSelection.collapsed(offset:)` e `TextRange(start:, end:)` com
   parâmetros nomeados, como no Flutter. Quebra uns 40 usos; fazer numa
   mudança só.
5. Depois: o resto do P1 (21%) e o Cupertino (P2, 0%).

### Quarto backend do macOS
IME, área de transferência, arrastar e soltar, acessibilidade, barra de menu
nativa, desenho durante o live resize, pacing por vsync, um job de CI com
`tool/macos/embedded_demo.dart`. Só arm64; notarização não testada.

### Outros pendentes do roteiro
- Um host por aplicação no backend padrão do macOS (hoje um processo por
  janela, inclusive por menu).
- Bandeja do sistema e notificações; recurso de ícone no Windows; lacunas do
  modo imediato (copiar/colar e IME no campo de texto, acessibilidade por
  controle); virtualização de colunas no `DataGrid`.
- Itens desmarcados do roteiro: monitores em runtime, XKB/XInput2 no X11,
  EGL/Vulkan no Wayland, AT-SPI, Retina no CI, testes no Windows 10.

---

## Como trabalhar

- **Regras:** [`AGENTS.md`](AGENTS.md) (só `main`, sem branches nem
  worktrees), [`doc/AGENTS_FLUTTER.md`](doc/AGENTS_FLUTTER.md) e o `AGENTS.md`
  de cada exemplo.
- **Antes de cada commit:**
  ```sh
  dart format <arquivos>
  dart analyze lib test tool
  dart test
  dart run tool/flutter_parity.dart   # regenera doc/paridade_flutter.md
  ```
  Os exemplos têm `pubspec` e testes próprios (`cd examples/<x> && dart test`).
- **Olhe o resultado:** toda mudança visual tem captura sem janela
  (`tool/*_shot.dart`, `examples/*/tool/headless_shot.dart`) ou sonda no host
  real do macOS (`DART_UI_MACOS_HOST=lib/src/backends/macos/native/build/dart_ui_macos_host`;
  compile o host com `bash lib/src/backends/macos/native/build_host.sh`).
- **Depois do push:** `gh run list` e conferir o CI.
