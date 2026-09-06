# Migrando do Flutter para o `dart_ui`

Data: 6 de setembro de 2026.

Este documento existe por uma razão prática: **quem vem do Flutter já sabe
escrever esta interface.** O `dart_ui` não é um clone do Flutter e não tenta
ser — ele é 100% Dart puro, fala Win32/XCB/Wayland/AppKit por FFI, não tem
engine em C++ e não tem *platform channels*. Mas o modelo de programação é o
mesmo: widgets imutáveis, elementos, render objects, `setState`, árvore de
inherited widgets. Onde um nome do Flutter cabe sem mentir sobre o que a classe
faz, **o nome do Flutter é o nome usado**.

Onde há diferença, este documento diz qual é e por quê. Uma tabela que
prometesse paridade que não existe seria pior que nenhuma tabela.

---

## 1. O que é idêntico

Isto compila quase sem edição vindo do Flutter:

| Área | Nomes |
|---|---|
| Widgets base | `StatelessWidget`, `StatefulWidget`, `State`, `InheritedWidget`, `Widget`, `BuildContext`, `Key`, `ValueKey`, `GlobalKey` |
| Layout | `Row`, `Column`, `Stack`, `Positioned`, `Padding`, `Center`, `Align`, `SizedBox`, `Expanded`, `Flexible`, `Wrap`, `ClipRect`, `Opacity` |
| Conteúdo | `Text`, `Icon`, `Image`, `ListView`, `Card` |
| Controles | `TextField`, `Radio`, `Switch`, `Slider`, `IconButton`, `Tooltip` |
| Ambiente | `Theme`, `ThemeData`, `MediaQuery`, `Directionality`, `Navigator`, `Overlay`, `OverlayEntry` |
| Foco e gestos | `FocusNode`, `FocusScope`, `GestureDetector` |
| Animação | `AnimationController`, `CurvedAnimation`, `ColorTween`, `RectTween`, `SizeTween`, `OffsetTween`, `Interval`, `Cubic` |
| Geometria | `Offset`, `Size`, `Rect`, `EdgeInsets`, `BoxConstraints`, `RelativeRect`, `Alignment` |
| Estado | `ValueNotifier` |

`Overlay` e `OverlayEntry` têm a assinatura do Flutter inclusive em
`OverlayEntry(builder:, opaque:, maintainState:)` e `Overlay.of(context)`.

---

## 2. Menus, dropdowns e tooltips

Esta é a parte nova (setembro de 2026) e foi desenhada para casar com a API
moderna de menus do Flutter. **Todos funcionam com ou sem janela nativa**: o
framework escolhe, e o widget não sabe qual recebeu — que é exatamente a
promessa do trabalho de multijanela do Flutter desktop ("se a multijanela não
se aplica, o app volta ao comportamento tradicional").

| Flutter | `dart_ui` | Nota |
|---|---|---|
| `Tooltip(message:, child:)` | igual | passa a funcionar de verdade; antes devolvia o filho |
| `MenuAnchor(builder:, menuChildren:, controller:)` | igual | |
| `MenuController` (`open`, `close`, `isOpen`) | igual | |
| `MenuItemButton(onPressed:, child:)` | igual | `onPressed: null` desabilita, como no Flutter |
| `SubmenuButton(menuChildren:, child:)` | igual | abre por hover e por seta direita |
| `MenuBar(children: [...])` | igual | |
| `showMenu<T>(context:, position:, items:)` | igual | devolve `Future<T?>`, nulo quando descartado |
| `PopupMenuButton<T>(itemBuilder:, onSelected:)` | igual | |
| `PopupMenuItem<T>`, `PopupMenuDivider` | igual | |

### O que o Flutter não tem, e aqui existe

```dart
// Onde os popups desta janela vivem, e quem decide.
PopupPolicy.auto    // janela nativa quando o backend tem; overlay quando não
PopupPolicy.inTree  // sempre no overlay da janela dona
PopupPolicy.window  // sempre em janela nativa, e falha por nome se não der
```

`PopupHost` é a costura pública: um pacote de widgets de terceiros abre um
popup com `PopupHost.of(context).open(PopupSpec(...))` e recebe um
`PopupHandle`, sem saber se os pixels foram para a mesma superfície ou para uma
janela override-redirect. `PopupHost.maybeOf` responde null onde não há host, e
é assim que um `Tooltip` numa árvore nua continua sendo só o filho.

---

## 3. Diferenças de nome

Poucas, e cada uma tem motivo:

| Flutter | `dart_ui` | Por quê |
|---|---|---|
| `Checkbox` | `CheckBox` | herdado do vocabulário WinUI/Fluent do resto dos controles |
| `ElevatedButton`, `TextButton`, `OutlinedButton` | `Button` | um controle com variantes de estilo, em vez de três classes |
| `MaterialApp` / `WidgetsApp` | `DartUiApp` | não é Material; instala tema, direção de leitura, escopo de foco, relógio de animação e o host de popups |
| `Scaffold` / `AppBar` | — | não existem. Este framework é de aplicação desktop: a barra de menus é `MenuBar` e o chrome da janela é da janela |
| `runApp(Widget)` | `runApp(...)` | existe, e abre uma janela real; ver §5 |

---

## 4. O que **não** existe (e o que usar)

Ser honesto aqui é o ponto do documento.

- **`Container`** — não existe. Use a composição explícita: `Padding`,
  `Align`, `SizedBox`, `DecoratedBox`. `Container` no Flutter é um atalho para
  sete widgets, e o atalho é o que torna difícil ler o que uma tela faz.
- **`Divider`** — use uma caixa de 1 px com a cor `theme.border`.
- **Platform channels, plugins do pub.dev com código nativo** — não existem e
  não vão existir. O equivalente é FFI direto, em Dart, dentro do repositório.
- **`Hero`, `AnimatedContainer`, `ImplicitlyAnimatedWidget`** — o framework tem
  o motor de animação explícito (`AnimationController`, tweens, curvas), não os
  wrappers implícitos.
- **Widgets Material/Cupertino** (`ListTile`, `Chip`, `SnackBar`, `Drawer`…) —
  o conjunto de controles é de desktop: `DataGrid`, `TreeView`, `ListBox`,
  `ComboBox`, `Expander`, `SplitView`, `Tabs`, `Docking`, `ContextMenu`,
  `NumberBox`, `Calendar`, `InfoBar`, `Badge`, `Scrollbar`.

### O que existe aqui e não existe no Flutter

Vale saber, porque é o motivo de escolher este framework:

- **multijanela de verdade** — `Application.openWindow`, com dono, modal,
  `WindowKind.dialog/popup/tooltip`, e foco de teclado arbitrado entre janelas;
- **popups em janela nativa** — §2;
- **PDF** (leitura, render, assinatura PAdES), **CorelDRAW `.cdr`**, **SVG**,
  **JPEG 2000**;
- **áudio** (WASAPI, WAV, decodificação por Media Foundation) e **vídeo**;
- **acessibilidade UI Automation no Windows**, provada por um cliente
  `IUIAutomation` fora do processo;
- **editor vetorial** completo como biblioteca de widgets.

---

## 5. O `main` de uma aplicação

Flutter:

```dart
void main() => runApp(const MyApp());
```

`dart_ui` — o caso simples é igual:

```dart
void main() => runApp(const MyApp());
```

E o caso com opções:

```dart
Future<void> main(List<String> args) async {
  final Application app = await runApp(
    const MyApp(),
    options: const ApplicationOptions(
      title: 'Minha aplicação',
      size: Size(1024, 720),
      // Menus e tooltips em janelas nativas quando o backend permitir.
      popupPolicy: PopupPolicy.auto,
    ),
  );
  // `runApp` roda até a aplicação fechar. O que volta é a Application já
  // encerrada, para o resumo:
  print('${app.framesPresented} frames, ${app.eventsDropped} eventos caídos');
}
```

Três diferenças reais:

- `runApp` **roda até a aplicação fechar** e devolve a [Application] *depois*
  do teardown, para que se possa ler a telemetria de frames no fim. Não é o
  `void runApp` do Flutter, que retorna imediatamente;
- ele **seleciona um backend de janela e um caminho de apresentação**, e relata
  por nome cada candidato descartado e por quê, em vez de escolher em silêncio.
  Os parâmetros `backends:` e `presentations:` são a costura de injeção para
  teste e para plataformas novas; omitidos, você recebe os padrões de produção;
- **para mais de uma janela, use `Application.start` em vez de `runApp`** —
  `openWindow` precisa de uma aplicação já iniciada para abrir dentro. É a
  diferença que mais surpreende quem chega do Flutter, onde a segunda janela
  não existia.

---

## 6. Renderização: o que muda no seu modelo mental

O `dart_ui` é **acelerado por GPU com foco em GPU** (§8.1.1 do roteiro). Há um
rasterizador de CPU com paridade medida, e ele é a resposta em três casos e
nenhum outro: o hardware ou o SO não suportam, renderização off-screen, ou o
usuário da biblioteca forçou com `RenderingPolicy.cpuOnly`.

Consequência prática para quem migra: **nenhuma superfície nova escolhe o
caminho sozinha.** Uma janela nova, um popup, uma camada — todos herdam o
caminho já escolhido pela aplicação e adotam o dispositivo existente. Uma
janela na GPU com um menu na CPU mostraria, lado a lado na mesma tela, as
divergências de antialiasing e de texto entre os dois rasterizadores.

---

## 7. Onde a migração vai doer

Sem rodeios, para você planejar:

1. **`Container` e os atalhos Material.** É a edição mecânica mais volumosa.
2. **Qualquer plugin.** Se a sua aplicação depende de um pacote do pub.dev com
   código nativo, não há equivalente — a funcionalidade precisa existir aqui,
   em Dart, ou ser escrita.
3. **`Navigator` e rotas.** `Navigator` existe, mas o vocabulário de rotas é
   menor que o do Flutter; uma aplicação desktop costuma querer janelas, não
   rotas.
4. **Testes.** Não há `flutter_test`, `WidgetTester`, `pumpWidget` nem
   `testWidgets`. Testes montam uma árvore com `BuildOwner` + `PipelineOwner` e
   chamam `drawFrame` — mais explícito e sem mágica, mas é reescrita.
5. **Material/Cupertino visual.** Os controles seguem uma linguagem de desktop,
   não o Material Design. As telas vão *parecer* diferentes.

---

## 8. O que ainda não é verdade

Registrado aqui pela mesma razão que a §68 do roteiro existe: um documento que
só lista o que funciona é propaganda.

- popups em **janela nativa** foram provados no Windows e no headless; **X11 e
  Wayland** têm o suporte de backend escrito e verificado por testes de bytes,
  e os *smokes* contra servidor real só rodam no CI;
- **macOS** não tem host de popup nativo; cai no overlay;
- **web** cai no overlay por desenho e não vai mudar;
- a tabela da §1 é a superfície que existe hoje. Um nome do Flutter que não
  está aqui provavelmente não existe — procure em `lib/dart_ui.dart`, que é a
  lista completa do que é público.
