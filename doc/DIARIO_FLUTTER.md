# Diário: compatibilidade com o Flutter

Uma entrada por sessão, a mais recente no fim. Data, o que mudou, o que ficou
pela metade e o próximo passo. Ver [`AGENTS_FLUTTER.md`](AGENTS_FLUTTER.md).

## 13/10/2026

**Mudou**
- Antes da medição, no mesmo dia: `Flow` (com `FlowDelegate`), `SliverAppBar`
  com `FlexibleSpaceBar`, `NestedScrollView` (roda, arrasto, inércia e teclado
  coordenados por um `ScrollDeltaCoordinator` na `ScrollPosition`) e, fora do
  Flutter, o `Ribbon` do Office.
- Paridade medida: `tool/flutter_parity.dart` lê a API pública do Flutter
  (snapshot em `tool/flutter_parity/flutter_api.tsv`) e a do `dart_ui`
  (`lib/*.dart`, seguindo `export` com `show`/`hide`) e gera
  `doc/paridade_flutter.md`. Primeira medida: **P0 53%**, P1 11%, P2
  (Cupertino) 0%, **16% no total** (2.611 nomes contados, 144 que não se
  aplicam).
- Regras em `AGENTS_FLUTTER.md`.

**Achados da medição**
- Falta o ponto de entrada: `runApp`, `WidgetsApp`, `MaterialApp`,
  `WidgetsBinding`.
- Faltam tipos básicos com o nome do Flutter: `BorderRadius`, `Border`,
  `BoxShadow`, `Radius`, `RRect`, `Paint`, `Canvas`, `Clip`, `BlendMode`,
  `VoidCallback`, `ValueChanged`, `UniqueKey`, `ObjectKey`. O `dart_ui` tem
  equivalentes com outra forma (um `double radius` no `BoxDecoration`, o
  `DisplayList` no lugar do `Canvas`), e é aí que uma migração mais esbarra.
- Faltam famílias inteiras: `Actions`/`Shortcuts`/`Intent` completos, `Form`/
  `FormField`, `Draggable`/`DragTarget`, `Dismissible`, `PageView`,
  `InteractiveViewer`, `NotificationListener`, `ScrollPhysics`/
  `ScrollController`, `CustomPainter`/`CustomClipper`/`ClipPath`/`ClipOval`.
- Material: só 7%. `Scaffold`, `AppBar`, os botões, `ListTile`, `Card` com a
  API do Material, diálogos e `showModalBottomSheet`.

**Próximo passo**
- P0 em lotes por afinidade, cada um com testes, captura e entrada aqui:
  1. Tipos básicos de pintura e decoração com os nomes do Flutter
     (`BorderRadius`, `Border`, `BoxShadow`, `Radius`, `RRect`, `Clip`...) e
     `CustomPainter`/`Canvas`/`Paint` sobre o display list.
  2. Ponto de entrada: `runApp`, `WidgetsApp`, `WidgetsBinding`.
  3. Rolagem do Flutter: `ScrollController`, `ScrollPhysics`, `PageView`,
     `NotificationListener`/`ScrollNotification`, e `scrollDirection:`.
  4. Entrada: `Listener`, `Draggable`/`DragTarget`, `Dismissible`,
     `InteractiveViewer`, `Focus`, `KeyboardListener`, `Actions`/`Intent`.
  5. `Form`/`FormField`/`TextFormField` e formatadores de texto.
  6. Material essencial (`MaterialApp`, `Scaffold`, `AppBar`, botões,
     `ListTile`, `Card`, diálogos).

### Mais tarde, no mesmo dia

**Mudou**
- Os cinco lotes do P0, em paralelo, cada um com testes e capturas:
  1. **Pintura e decoração:** `Radius`, `RRect`, `BorderRadius`(`Directional`),
     `Border`, `BorderSide`, `BoxShadow`, `ShapeDecoration` com
     `RoundedRectangleBorder`/`CircleBorder`/`StadiumBorder`, `SweepGradient`,
     `Canvas`/`Paint`/`PictureRecorder`, `CustomPainter`/`CustomClipper`,
     `ClipOval`/`ClipPath` e `ClipRRect(borderRadius:)`, e o `Path` com a
     edição do Flutter. Clips não retangulares são camada mais máscara
     (`dstIn`/`dstOut`): os cantos agora são cortados de verdade, inclusive no
     Metal.
  2. **App e binding:** `WidgetsBinding`/`WidgetsFlutterBinding`,
     `WidgetsBindingObserver`, `WidgetsApp`, `ErrorWidget` (um build que lança
     vira o widget de erro), `UniqueKey`, `ObjectKey`, `GlobalObjectKey`,
     `PageStorageKey`, `KeyedSubtree`, `InheritedNotifier`, `InheritedModel`,
     `VoidCallback`/`ValueChanged`..., `kDebugMode`, `debugPrint`.
     `void main() => runApp(const MyApp());` abre uma janela Metal no macOS.
  3. **Rolagem:** `ScrollController`, `scrollDirection:`, `ScrollPhysics`
     (Clamping, Bouncing com mola, Never, Always, Page), `PageView`/
     `PageController`, `NotificationListener` e a família `ScrollNotification`,
     `ListView.separated`, `shrinkWrap`, `GridView` com `gridDelegate`.
  4. **Entrada:** `Listener`, `Draggable`/`LongPressDraggable`/`DragTarget`,
     `Dismissible`, `InteractiveViewer`, `Focus`, `KeyboardListener`,
     `ExcludeFocus`, `FocusTraversalGroup` e as políticas, `Shortcuts`/
     `Actions`/`Intent`, `SingleActivator`, `CharacterActivator`,
     `LogicalKeySet`, `LogicalKeyboardKey`, `HardwareKeyboard`.
  5. **Formulários:** `Form`/`FormField`/`TextFormField`, `InputDecoration`
     com `OutlineInputBorder`/`UnderlineInputBorder`, formatadores
     (`FilteringTextInputFormatter`, `LengthLimitingTextInputFormatter`),
     `TextInputType`/`TextInputAction` (Enter com `next` passa o foco),
     `SelectableText`.
- Fechar a última janela encerra o processo, como no Flutter desktop (um
  `Directory.watch` do explorer o prendia; o `runApp` agora garante).
- Medida: **P0 67%** (era 53%), P1 18%, **23% no total**. As divergências de
  cada nome estão no catálogo e as que mais pesam numa migração, em
  `MIGRACAO_DO_FLUTTER.md` §3.

**Ficou pela metade**
- `TextEditingController('x')`, `TextSelection.collapsed` e `TextRange` são
  posicionais; passar para os nomes do Flutter quebra uns 40 usos e pede uma
  mudança coordenada.
- `Scrollbar(controller:)`; `SelectionArea`; `KeyRepeatEvent`.
- Achados no caminho: o player desenha `drawRect`/`drawRRect` girados como a
  caixa alinhada aos eixos; o `ValueNotifier` daqui não é `Listenable`; `Rect`
  sem `shortestSide`/`fromCircle`/`expandToInclude`; pontas de um `ClipPath`
  em estrela vazam alguns pixels.

**Próximo passo**
- O que falta do P0 (79 nomes): Material essencial (`MaterialApp`,
  `Scaffold`, `AppBar`, botões, `ListTile`, `Card`, diálogos e
  `showModalBottomSheet`), imagens (`ImageProvider`, `AssetImage`,
  `NetworkImage`), `AnimatedCrossFade`/`AnimatedScale`/`AnimatedRotation`/
  `AnimatedSlide`, `Ticker`/`TickerProviderStateMixin`, `ModalRoute`,
  `OverlayPortal`, `Clipboard`/`HapticFeedback`/`SystemChrome`.

### Fim do dia

**Mudou**
- `Ticker`, `TickerProvider`, `SingleTickerProviderStateMixin`,
  `TickerProviderStateMixin`, `TickerMode`; `AnimationController(vsync: this)`
  como no Flutter (com `animateTo`, `repeat(reverse:)`, `fling`,
  `TickerFuture`); `AnimatedScale`, `AnimatedRotation`, `AnimatedSlide`,
  `AnimatedFractionallySizedBox`, `PositionedDirectional`.
- `package:dart_ui/material.dart`, primeira parte: `ThemeData` e
  `ColorScheme.fromSeed` do Material 3 (HCT e paletas tonais adaptados do
  material_color_utilities, Apache-2.0), `Colors` com os tons, `TextTheme` e
  `Typography` M3, 8 810 `Icons`, o widget `Material`, `WidgetState*`. O
  `dart_ui.dart` continua sem Material.
- Correções: retângulos girados ou inclinados eram pintados como a caixa
  alinhada aos eixos (CPU e Metal); `ValueNotifier` agora é `Listenable`;
  `Offset`/`Size`/`Rect` com a API do `dart:ui`; `Scrollbar(controller:)`.
- Medida: **P0 68%**, P1 21%, **26% no total**.

**Ficou pela metade**
- Material: falta o esqueleto do app (`MaterialApp`, `Scaffold`, `AppBar`,
  `InkWell`, `FloatingActionButton`, `IconButton`, `Drawer`, `SnackBar`,
  `NavigationBar`/`NavigationRail`/`BottomNavigationBar`, `TabBar`) e, depois,
  os botões e controles. O contador do Flutter ainda não compila com o import
  trocado.
- Do P0 fora do Material: `AnimatedCrossFade`, imagens (`ImageProvider`,
  `AssetImage`, `NetworkImage`, `Image(image:)`), `ModalRoute`,
  `OverlayPortal`, `Clipboard`/`HapticFeedback`/`SystemChrome`.
- `ClipPath` vazando nas pontas; `ShaderMask(blendMode: BlendMode)`.
- Clicar num item de submenu fecha os menus sem rodar o comando.

**Próximo passo**
- Na ordem: o bug do submenu; o esqueleto Material e o `examples/material_counter`
  (o contador do Flutter com só o import trocado); imagens; o resto do P0.
