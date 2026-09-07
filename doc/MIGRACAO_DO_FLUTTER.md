# Migrando do Flutter para o `dart_ui`

Data: 6 de setembro de 2026. Revisto em 7 de setembro de 2026, quando o
inventário foi conferido linha a linha contra o código e a animação
implícita passou a existir.

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
| Widgets base | `StatelessWidget`, `StatefulWidget`, `State`, `InheritedWidget`, `Widget`, `BuildContext`, `Key`, `ValueKey`, `GlobalKey`, `Builder`, `StatefulBuilder` |
| Layout | `Row`, `Column`, `Stack`, `Positioned`, `Padding`, `Center`, `Align`, `SizedBox`, `Expanded`, `Flexible`, `Spacer`, `Wrap`, `AspectRatio`, `ConstrainedBox`, `FractionallySizedBox`, `IntrinsicWidth`, `IntrinsicHeight`, `LimitedBox`, `OverflowBox`, `SizedOverflowBox`, `Baseline`, `LayoutBuilder`, `SafeArea` |
| Pintura | `Opacity`, `ClipRect`, `ClipRRect`, `DecoratedBox`, `BoxDecoration`, `ColoredBox`, `RepaintBoundary`, `IgnorePointer`, `AbsorbPointer` |
| Conteúdo | `Text`, `Icon`, `Image`, `ListView`, `GridView`, `SingleChildScrollView`, `Card`, `Divider`, `VerticalDivider` |
| Controles | `TextField`, `Radio`, `Switch`, `Slider`, `IconButton`, `Tooltip` |
| Ambiente | `Theme`, `ThemeData`, `MediaQuery`, `Directionality`, `Navigator`, `Overlay`, `OverlayEntry` |
| Foco e gestos | `FocusNode`, `FocusScope`, `GestureDetector` |
| Animação explícita | `AnimationController`, `CurvedAnimation`, `Tween`, `RectTween`, `SizeTween`, `OffsetTween`, `Curves`, `Interval`, `Cubic` |
| Animação implícita | `ImplicitlyAnimatedWidget`, `AnimatedOpacity`, `AnimatedAlign`, `AnimatedPadding`, `AnimatedPositioned`, `AnimatedDefaultTextStyle` |
| Geometria | `Offset`, `Size`, `Rect`, `EdgeInsets`, `EdgeInsetsDirectional`, `BoxConstraints`, `RelativeRect`, `Alignment`, `AlignmentDirectional` |
| Estado | `ValueNotifier` |

`Overlay` e `OverlayEntry` têm a assinatura do Flutter inclusive em
`OverlayEntry(builder:, opaque:, maintainState:)` e `Overlay.of(context)`.

Sobre a animação implícita, duas coisas que quem chega do Flutter precisa
saber e que não aparecem na assinatura:

- **não há relógio ambiente.** O tempo vem do `AnimationScope` mais próximo,
  que o `DartUiApp` instala. Sem escopo acima, o widget continua funcionando e
  simplesmente não anima — é o que permite montar um controle sozinho num
  teste. `ThemeData.reducedMotion` tem o mesmo efeito, por desenho;
- **`duration: Duration.zero` é legal** e significa "não anime". Nenhum
  `AnimationController` é criado, porque o controlador recusa duração zero por
  nome em vez de dividir por ela.

### Quase idêntico: os parâmetros que mudam

Estes têm o nome e o comportamento do Flutter, mas **um** argumento diferente,
e cada um diz isso no comentário da própria classe:

| Widget | Diferença |
|---|---|
| `Align`, `AnimatedAlign`, `FractionallySizedBox`, `OverflowBox`, `SizedOverflowBox` | recebem `Alignment` (físico), não `AlignmentGeometry`. `AlignmentDirectional` existe e é resolvido acima do widget |
| `Padding`, `AnimatedPadding` | recebem `EdgeInsets`, não `EdgeInsetsGeometry`, pela mesma razão |
| `AnimatedOpacity` | não tem `alwaysIncludeSemantics`: aqui `Opacity` nunca tira a subárvore da árvore semântica, então o parâmetro não teria efeito |
| `AnimatedDefaultTextStyle` | só anima `style`; o `DefaultTextStyle` daqui publica um estilo e mais nada |
| `LayoutBuilder` | sem filho, assume o **menor** tamanho permitido (o Flutter assume o maior, que é infinito num eixo sem limite — e um tamanho infinito aqui é erro com nome). Uma consulta de intrínseco é recusada por nome, e não apenas em modo debug |
| `FractionallySizedBox` | um fator num eixo sem limite é erro com nome, em vez de infinito propagado para cima |
| `OverflowBox` | num eixo sem limite colapsa para o mínimo (`BoxConstraints.largestFinite`) em vez de disparar uma asserção |
| `Divider` | a cor padrão é `theme.borderSubtle`, o divisor *dentro* de uma superfície |

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

## 3. Diferenças de nome e de tipo

Poucas, e cada uma tem motivo:

| Flutter | `dart_ui` | Por quê |
|---|---|---|
| `Checkbox` | `CheckBox` | herdado do vocabulário WinUI/Fluent do resto dos controles |
| `ElevatedButton`, `TextButton`, `OutlinedButton` | `Button` | um controle com variantes de estilo, em vez de três classes |
| `MaterialApp` / `WidgetsApp` | `DartUiApp` | não é Material; instala tema, direção de leitura, escopo de foco, relógio de animação e o host de popups |
| `Scaffold` / `AppBar` | — | não existem. Este framework é de aplicação desktop: a barra de menus é `MenuBar` e o chrome da janela é da janela |
| `runApp(Widget)` | `runApp(...)` | existe, e abre uma janela real; ver §5 |
| `GridView` com delegates | `Grid` | `Grid` é o layout de trilhas (`GridTrack.fixed/auto/fraction/minmax`), mais perto de CSS Grid que dos delegates. O `GridView` rolável também existe |
| `Transform(transform: Matrix4)` | `Transform(transform: Transform2D)` | a interface é 2D; não há matriz 4x4 no núcleo, e uma transformação 3D aplicada ao plano seria uma promessa que o rasterizador não cumpre |
| `Chip(label: Widget)` | `Chip(label: String)` | o rótulo é texto; o controle desenha o glifo de exclusão sozinho |
| `ColorTween extends Tween<Color?>` | `ColorTween extends Tween<int>` | interpola ARGB empacotado, com pré-multiplicação. No nível de widget, `lerpColor(a, b, t)` devolve `Color` |
| `TextStyle` | subconjunto | `color`, `fontSize`, `fontFamily`, `fontWeight`, `height` — e nada mais |

E uma diferença de **padrão**, que é a mais fácil de não notar porque compila:
`Visibility.maintainSize` aqui é `true` por omissão e no Flutter é `false`. Um
`Visibility(visible: false)` copiado do Flutter mantém o espaço aqui em vez de
devolvê-lo.

Uma nota sobre `ImplicitlyAnimatedWidget`: a *classe* tem o nome e os três
parâmetros do Flutter (`duration`, `curve`, `onEnd`), mas quem escreveu uma
subclasse própria no Flutter reescreve um método. O `forEachTween` de lá existe
para contornar campos `Tween` mutáveis e anuláveis; o `Tween` daqui é imutável
e não anulável, então o lugar dele é ocupado por `AnimatedProperty<V>` e por
`ImplicitlyAnimatedWidgetState.retarget`. Quem apenas *usa* os widgets não vê
diferença.

---

## 4. O que **não** existe (e o que usar)

Ser honesto aqui é o ponto do documento. A lista está separada entre o que é
**recusa de projeto** — não vai existir, e por quê — e o que é **ainda não
feito**, que é uma lista de trabalho e não uma posição.

### Recusas de projeto

- **`Container`** — não existe. Use a composição explícita: `Padding`,
  `Align`, `SizedBox`, `DecoratedBox`. `Container` no Flutter é um atalho para
  sete widgets, e o atalho é o que torna difícil ler o que uma tela faz.
- **`AnimatedContainer`** — consequência da anterior: não há `Container` para
  animar. Componha `AnimatedPadding`, `AnimatedAlign` e `AnimatedOpacity`, que
  é o que o `AnimatedContainer` faz por dentro de qualquer modo.
- **Platform channels, plugins do pub.dev com código nativo** — não existem e
  não vão existir. O equivalente é FFI direto, em Dart, dentro do repositório.
- **Widgets Material/Cupertino** (`ListTile`, `SnackBar`, `Drawer`,
  `FloatingActionButton`, `BottomNavigationBar`…) — o conjunto de controles é
  de desktop: `DataGrid`, `TreeView`, `ListBox`, `ComboBox`, `Expander`,
  `SplitView`, `Tabs`, `Docking`, `ContextMenu`, `NumberBox`, `Calendar`,
  `InfoBar`, `Badge`, `Chip`, `Card`, `Scrollbar`.

### Ainda não feito

Sem justificativa de projeto — simplesmente não escrito:

- **Layout**: `Table`, `Flow`, `CustomMultiChildLayout`, `FittedBox`,
  `UnconstrainedBox`, `Placeholder`.
- **Texto rico**: `RichText`, `TextSpan` no nível de widget, `WidgetSpan`. O
  motor de parágrafo já compõe estilos por trecho (`text/paragraph.dart`); o
  que falta é a fachada de widget sobre ele.
- **Animação**: `Hero`, `AnimatedSize`, `AnimatedSwitcher`, `AnimatedBuilder`,
  `TweenAnimationBuilder`, `ValueListenableBuilder`, `AnimatedList`.
- **Rolagem**: `CustomScrollView` e a família `Sliver*`, `NestedScrollView`.

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
