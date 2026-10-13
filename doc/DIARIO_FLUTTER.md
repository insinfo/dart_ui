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
