# Plano — popups em janelas nativas: menus de contexto, dropdowns, barra de menus e combo box "de verdade"

Data: 6 de setembro de 2026.
Base: código do `dart_ui` conferido nesta data (arquivos nomeados ao longo do
texto) e as referências locais em `referencias/` — Avalonia
(`src/Avalonia.Controls/Primitives/Popup.cs`, `src/Windows/Avalonia.Win32/PopupImpl.cs`,
`src/Avalonia.X11/X11Window.cs`, `src/Avalonia.Wayland/PopupImpl.cs`,
`native/Avalonia.Native/src/OSX/PopupImpl.mm`), o Flutter com o trabalho de
multijanela da Canonical (`flutter-master/packages/flutter/lib/src/widgets/_window.dart`
e `_window_win32.dart`) e o JavaFX (`com/sun/glass/ui/Window.java`,
`javafx/stage/PopupWindow.java`).

## Resposta curta

**Multijanela já existe no `dart_ui`; o que falta é usá-la para os popups.**
`Application` abre e fecha N janelas em tempo de execução, cada uma com o seu
`BuildOwner`, `PipelineOwner` e `FrameScheduler`; há `WindowKind.popup` e
`WindowKind.tooltip` com dono, sem ativação, descartados quando o foco sai; há
modal, cadeia de donos, e 24 casos em `test/app/multi_window_test.dart` que
provam isso no headless. O Win32 cria o popup com `WS_POPUP |
WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST` e `SW_SHOWNOACTIVATE`; o
Wayland cria um `xdg_popup` de verdade com `xdg_positioner`.

O que **nenhum widget faz** é abrir uma dessas janelas. O menu de contexto tem
uma costura (`ContextMenuPresentation`) com uma única implementação, a que
compõe o menu dentro da superfície da janela dona; o combo box desenha a lista
num overlay da mesma árvore; a barra de menus não existe no framework (o
`vector_editor_demo` monta uma com `Stack` + `Menu`); e o `Tooltip` não mostra
nada — `Tooltip.build` devolve o filho. É por isso que, como no Flutter antes
do trabalho da Canonical, um menu aberto perto da borda é cortado pela janela.

O plano abaixo fecha isso em cinco fases, e a decisão de desenho central é
copiada de quem já resolveu o problema: **uma abstração de hospedagem do popup
com duas implementações — na árvore, ou em janela nativa — escolhida por
capacidade do backend e por política da aplicação**, o `ShouldUseOverlayLayer`
do Avalonia e o `PopupWindow`/`PopupWindowController` do Flutter. O teclado
continua com a janela dona (o popup nunca ativa) e o framework redireciona as
teclas para o popup vivo, que é o modelo do Avalonia e o que preserva o caret
da janela de trás.

## 1. O que já existe, conferido no código

| Peça | Onde | Estado |
|---|---|---|
| N janelas por aplicação, donos separados por janela | `lib/src/app/application.dart` (cabeçalho explica por que os owners são por janela e não compartilhados) | **feito**; `example/gallery_multiwindow.dart` abre uma segunda janela e um diálogo com `owner:` |
| `WindowKind.normal/dialog/popup/tooltip` com `takesActivation`, `isDismissable`, `isTopLevel` | `lib/src/platform/native_window.dart` | **feito**; o cabeçalho do enum descreve exatamente as duas falhas que evita (popup contando como janela; popup roubando ativação) |
| Popup exige dono; fechar o dono fecha os donos; foco saindo descarta o popup; popup não é "a última janela" | `Application.openWindow`, `dismissPopups`, `_isSelfOrOwnerOf`, `focusWindow` | **feito e testado** (`multi_window_test.dart`: "a dismissed popup is not the last window closing", "moving focus away dismisses a popup", "a popup requires an owner", "closing an owner closes the windows it owns") |
| Modal: bloqueia o dono, devolve o foco ao fechar | `ApplicationWindow.activeModal`, `isBlockedByModal` | **feito e testado** |
| Win32: estilos de popup, sem ativação, topmost, sem entrada na taskbar | `backends/win32/win32_window.dart:164-200, 499` | **feito**; falta `CS_DROPSHADOW`, `WM_MOUSEACTIVATE → MA_NOACTIVATE` e `HTTRANSPARENT` para tooltip (o Avalonia faz os três em `PopupImpl.cs`) |
| Wayland: `xdg_popup` com `xdg_positioner`, `grab` só para `popup` (nunca para tooltip), `popup_done` | `backends/wayland/wayland_window.dart:77-120`, `wayland_connection.dart:63-71, 1041-1047, 1761` | **feito**, nunca exercitado por widget nenhum; o smoke do CI só abre toplevel |
| Headless honra o kind (recusa ativação) | `backends/headless/headless_backend.dart:264` | **feito** |
| X11 honra o kind | `backends/x11/x11_backend.dart:382` (`createWindow`), `x11_connection.dart:1336` | **não**: toda janela recebe `_NET_WM_WINDOW_TYPE_NORMAL`; não há override-redirect fora do ícone de arrasto (`x11_drag_drop.dart`) |
| macOS honra o kind | `backends/macos/macos_window.dart` | **não**: não há `NSPanel` sem ativação; o backend nem cita `WindowKind` |
| Posicionador de popup: flip → slide → resize, no formato do `xdg_positioner` | `lib/src/widgets/popup.dart` (`PopupRequest`, `PopupPositioner`, `PopupPlacement`, `PopupDismissPolicy`) | **feito**; usado pelo combo box e pelo menu de contexto *dentro* da janela |
| Camada de overlay na árvore (`Overlay`, `OverlayEntry.opaque`) | `lib/src/widgets/overlay.dart` | **feito**; é o recuo quando não há janela nativa |
| Costura de apresentação do menu de contexto | `context_menu.dart:262-320` (`ContextMenuPresentation.escapesOwnerWindow`, `present`) | **feita, com uma só implementação** (`InTreeContextMenuPresentation`); o comentário diz que a segunda "precisa de multijanela, que está sendo construída agora" — e a multijanela já está |
| Contrato do overlay do combo box | `combo_box.dart:143-245` (`ComboBoxOverlay.open(anchorRect, builder, width, dismissPolicy, onDismiss, onWorkAreaChanged)`) | **feito**, na árvore; a forma do contrato já é a de um popup nativo |
| Coordenadas de tela | `NativeWindow.clientToScreen/screenToClient`, implementado nos seis backends | **feito** |
| Monitores e área de trabalho | — | **não existe**: nada em `platform/` descreve monitores, área útil ou DPI por monitor; `win32_backend.dart:235` só avisa que o processo é *DPI aware* |
| `Tooltip` | `controls.dart:1520` | **vazio**: `build` devolve o filho; `TooltipSurface` existe e ninguém a mostra |
| Barra de menus, botão de menu, dropdown | — | **não existem no framework**; `examples/vector_editor_demo/menu_bar.dart` monta uma barra com `Stack` + `Positioned` + `Menu`, e o `Menu` não tem submenus |

O que falta, portanto, não é o modelo de janelas. É: (a) o **widget** que
decide abrir uma janela em vez de um overlay; (b) o **roteamento de teclado e
de descarte** entre a janela dona e o popup, que hoje só existe pela metade
(foco saindo descarta; clique na dona fora do popup, não); (c) **geometria de
tela** (monitor, área útil, DPI); (d) **dois backends** que não honram o kind;
e (e) os **widgets** que hoje nem em overlay existem (tooltip, barra de menus,
dropdown, submenus).

## 2. O que as referências fazem, e o que vale copiar

### Avalonia — a abstração certa

- `Popup.ShouldUseOverlayLayer` (por popup) e `OverlayPopups` (por
  plataforma) decidem entre `PopupRoot` (janela nativa via
  `IWindowImpl.CreatePopup()`) e `OverlayPopupHost` (camada na árvore).
  `OverlayPopupHost.CreatePopupHost` tenta a nativa primeiro e cai para o
  overlay quando a plataforma devolve null — que é como o headless funciona.
- **O popup nunca ativa.** `PopupImpl.Show` no Win32 é `ShowNoActivate`;
  `WM_MOUSEACTIVATE` responde `MA_NOACTIVATE`; `TakeFocus` devolve o foco do
  SO à janela dona. O teclado chega pela dona e o framework o entrega ao
  elemento focado, que pode estar dentro do `PopupRoot` — o foco do framework
  é uma coisa, o foco do SO é outra.
- **Descarte leve** é do framework, não do SO: assina `Deactivated`/`LostFocus`
  da janela dona, `PointerPressed` na dona fora do popup, e clique na área
  não-cliente (`NonClientLeftButtonDown`, ou seja, arrastar a barra de título
  fecha o menu).
- **Wayland: não chama `xdg_popup.grab()`**, de propósito. O descarte vem do
  framework, do `popup_done` do compositor e da perda de foco do toplevel. O
  `grab` exige um serial de input recente e falha em voz alta sem ele
  (`wayland_connection.dart:1761` já registra exatamente esse erro).
- **X11: override-redirect** para todo popup (`X11Window(platform, popupParent)`
  liga `_overrideRedirect = _popup`), `_NET_WM_WINDOW_TYPE` apropriado, e o
  posicionamento é do framework (`ManagedPopupPositioner`), como no Win32.
- **macOS:** `NSPanel` com `NSWindowStyleMaskBorderless` (`AvnPanel`),
  ordenado à frente sem virar *key window*.
- `WS_EX_TOOLWINDOW` (sem taskbar) e `CS_DROPSHADOW` (sombra do SO, sem janela
  em camadas) no Win32; hit-test transparente (`HTTRANSPARENT`) para o tooltip,
  que nunca deve engolir um clique.

### Flutter (Canonical) — a API pública certa

- Controladores por *arquétipo*: `WindowController` (regular),
  `DialogWindowController`, `TooltipWindowController`,
  `PopupWindowController`, `SatelliteWindowController`; um `WindowingOwner`
  por plataforma os fabrica (`WindowingOwnerWin32`, e as variantes Linux e
  macOS). O `dart_ui` já tem o equivalente do arquétipo em `WindowKind`.
- Widgets `Window`, `DialogWindow`, `TooltipWindow`, `PopupWindow`,
  `SatelliteWindow`: o **conteúdo do popup é um subtree na árvore de widgets
  da aplicação**, e `WindowScope` dá ao conteúdo acesso ao seu controlador.
  É o que o comentário do `ContextMenuPresentation.present` já descreve.
- `PopupWindowController(parent, anchorRect, positioner)`: o âncora é
  **no espaço da janela pai**, e a plataforma posiciona; no Win32 o próprio
  Dart converte para tela e monitor
  (`_window_win32.dart:1050-1075`). "Popups may receive input focus; when
  another window receives input focus, the popup is closed; if the parent is
  destroyed, the popup is destroyed" — as três regras que `Application` já
  implementa.
- A lição mais importante: **o mesmo widget Material funciona nos dois
  modos**; quem escolhe é a plataforma, e no celular o app "volta ao
  comportamento tradicional". O `dart_ui` tem os mesmos dois destinos
  (headless e web sempre em overlay).

### JavaFX — o que confirmar

- `glass.Window` tem estilos funcionais `NORMAL | POPUP | UTILITY` e uma
  janela é exatamente um deles ("não uma combinação"), com `isFocusable`
  separado. `PopupWindow.autoHide` é o descarte leve, no framework. Mesma
  forma do `WindowKind`.

### O que **não** copiar

- Electron: um processo por janela. Nada a ver com este projeto, que já tem
  um isolate e memória compartilhada por desenho.
- O `runMultiApp`/`onViewCreated` do pacote `multiview_desktop`: é uma
  fábrica por id de view, e o `dart_ui` já resolve isso com `openWindow(rootWidget:)`.

## 3. A solução proposta

### 3.1 Uma hospedagem de popup, duas implementações

Generalizar a costura que já existe no menu de contexto para **todo** popup:

```dart
/// Onde os pixels de um popup vão. Não sabe o que o popup mostra.
abstract interface class PopupHost {
  /// Falso para tudo que é composto na superfície da janela dona.
  bool get escapesOwnerWindow;

  /// Abre (ou reposiciona) o popup. [anchorRect] é no espaço lógico da
  /// janela dona - a única coordenada que existe no Wayland - e [request]
  /// é o PopupRequest de hoje. O conteúdo é construído por [builder] na
  /// árvore que o host escolher.
  PopupHandle open({
    required Rect anchorRect,
    required PopupRequest request,
    required WidgetBuilder builder,
    required PopupKind kind,            // menu | tooltip | dropdown
    PopupDismissPolicy dismissPolicy,
    PopupHandle? parent,                // submenu: popup dono de popup
    void Function()? onDismiss,
  });
}
```

- **`InTreePopupHost`**: o `Overlay` + `PopupPositioner` de hoje. É o que
  `InTreeContextMenuPresentation` e `ComboBoxOverlay` já fazem; passam a
  ser uma implementação só.
- **`WindowPopupHost`**: abre um `ApplicationWindow` de `WindowKind.popup`
  (ou `tooltip`) com `owner:` a janela atual, `rootWidget:` o conteúdo,
  posição calculada por `PopupPositioner` contra a **área útil do monitor**
  (Win32, X11, macOS) ou entregue como âncora ao `xdg_positioner`
  (Wayland, onde `PopupRequest` já é o formato certo). O `PopupHandle`
  fecha a janela, atualiza a posição e é dono do próximo nível (submenu).

A escolha é feita uma vez por janela, num `PopupPolicy` que vive no
`WindowScope`/`MediaQuery` da janela:

- `PopupPolicy.auto` (padrão): nativa se o backend reivindicar
  `Capability.nativePopups` **e** a janela dona for uma janela nativa com
  dono conhecido; senão, na árvore. Headless e web são sempre na árvore.
- `PopupPolicy.inTree` e `PopupPolicy.window`: forçados, para teste e para
  a aplicação que preferir um ou outro (o `OverlayPopups` do Avalonia).

Um widget que precisa de popup — menu de contexto, combo box, tooltip, botão
de menu — pede `PopupHost.of(context)` e **não sabe** qual dos dois recebeu.
É o que faz o mesmo `ContextMenuRegion` funcionar no Windows com janela e no
navegador sem ela.

### 3.2 O conteúdo do popup fica na árvore da aplicação

O conteúdo é um subtree construído pelo `builder` do widget que abriu o
popup, no `BuildOwner` da **janela do popup** — exatamente como
`gallery_multiwindow.dart` compartilha um `State` entre duas janelas. Isso dá
o que o Flutter da Canonical promete: `ValueNotifier`, controladores e
`Theme` compartilhados sem serialização; a janela do popup só tem o seu
`BuildOwner` porque o cabeçalho de `application.dart` prova que os owners
não podem ser compartilhados (dirty lists e foco são por janela).

O que **não** atravessa: `InheritedWidget`s da janela dona. O
`WindowPopupHost` reembrulha o conteúdo com o `Theme`, a `Directionality`, a
`MediaQuery` (do monitor do popup, ver 3.4) e o `ContextMenuScope` da dona,
que é a lista que `gallery_multiwindow.dart` já reembrulha à mão. Um
`PopupScope` expõe o `PopupHandle` ao conteúdo (o `WindowScope` do Flutter).

### 3.3 Teclado: o popup nunca ativa, e o framework redireciona

Regra: **o foco do SO fica na janela dona; o foco do framework pode estar no
popup.** É o modelo do Avalonia e o que preserva o caret piscando na janela
de trás enquanto o usuário lê o menu (o motivo escrito em `WindowKind`).

Em `Application`, o despacho de `KeyEvent`/`TextInputEvent` para a janela
que detém `_keyboardFocus` passa antes pelo **popup vivo mais interno
pertencente a ela** (a cadeia `_isSelfOrOwnerOf`, já escrita). Se o popup
não consumir, a dona recebe — que é o que faz Alt+F4 fechar a aplicação com
um menu aberto, e Escape fechar o menu. O `FocusManager` do `BuildOwner` do
popup é quem decide o que dentro dele tem foco (o `Menu` já implementa
setas, Home/End, mnemônicos e Escape).

O Flutter da Canonical permite que o popup *receba* foco de verdade. Não é
o caminho aqui: no Win32 ativar o popup manda `WM_ACTIVATE(WA_INACTIVE)` à
dona e todo anel de foco fica cinza — a falha que `WindowKind` foi escrito
para impedir.

### 3.4 Descarte leve, com as cinco entradas nomeadas

Hoje existe uma: foco mudando de janela (`focusWindow → dismissPopups`).
Faltam quatro, e todas ficam em `Application`, não no widget:

1. **`PointerDownEvent` na janela dona fora do popup** — o popup não vê o
   clique porque é outra janela. `Application` intercepta o *down* dirigido
   a uma janela que possui popups vivos, descarta-os e então **entrega ou
   engole** o evento conforme `PopupDismissPolicy` (o
   `OverlayDismissEventPassThrough` do Avalonia; o padrão de menu é engolir,
   o de combo box é entregar);
2. **clique na área não-cliente da dona** (`WM_NCLBUTTONDOWN`, arrastar a
   barra de título, botões do caption) — nova `WindowNonClientPressEvent`
   no Win32 e no X11 (onde é o próprio gerenciador de janelas, então vira
   `ConfigureNotify` da dona); no Wayland é o `popup_done`;
3. **a dona moveu ou redimensionou** — `WindowMovedEvent`/`WindowResizedEvent`
   já existem; um popup ancorado numa dona que se moveu ou é reposicionado
   (`PopupHandle.updatePosition`, o que o combo box faz) ou é descartado
   (menu). O `PopupKind` decide;
4. **`popup_done` do compositor** (Wayland) e **`WM_KILLFOCUS`/`Deactivated`**
   sem mudança de foco entre as nossas janelas (o usuário clicou em *outra
   aplicação*) — hoje `focusWindow` só roda para as nossas janelas;
5. **Escape** no conteúdo — já existe no `Menu`, no `ContextMenu` e no
   `ComboBox`; chega pelo redirecionamento de 3.3.

### 3.5 Geometria: monitor, área útil, DPI

Nova API em `platform/`:

```dart
// platform/screen_info.dart; WindowingBackend mora em platform/native_window.dart
final class ScreenInfo {
  final Rect bounds;        // físico ou lógico? lógico, na escala do monitor
  final Rect workArea;      // sem taskbar/dock/painel
  final double scale;       // DPI do monitor / 96
  final bool isPrimary;
}
abstract interface class WindowingBackend {
  List<ScreenInfo> get screens;                       // Win32, X11 (RandR), macOS
  ScreenInfo? screenAt(Offset screenPoint);
}
```

- **Win32:** `MonitorFromPoint`/`MonitorFromWindow` + `GetMonitorInfoW`
  (`rcWork`) + `GetDpiForMonitor`; o Avalonia usa `ScreenFromHwnd(...).WorkingArea`
  como `MaxAutoSizeHint` do popup. Reagir a `WM_DISPLAYCHANGE`.
- **X11:** RandR (`_hasRandr` já é sondado) ou `_NET_WORKAREA` como recuo.
- **macOS:** `NSScreen.screens`, `visibleFrame`, `backingScaleFactor`.
- **Wayland:** **não há coordenadas de tela** e não há como saber; o
  `xdg_positioner` faz o flip/slide no compositor. `ScreenInfo` fica vazia e
  o `WindowPopupHost` passa a âncora relativa à dona. O `PopupPositioner`
  local roda só onde há tela.

DPI misto: o popup que abre num monitor de escala diferente da dona tem a
sua própria `MediaQuery.devicePixelRatio` (é outra `ApplicationWindow`, já
tem o seu `renderScale`). O `anchorRect` é convertido lógico → tela pela
dona e tela → lógico pelo popup. É o que `_window_win32.dart` faz com
`scale` em `_positioner.copyWith(offset: scaledOffset)`.

### 3.6 Backends

- **Win32** (`win32_window.dart`): `CS_DROPSHADOW` na classe de janela de
  popup (outra classe registrada, porque é um estilo de classe);
  `WM_MOUSEACTIVATE → MA_NOACTIVATE`; `WM_NCHITTEST → HTTRANSPARENT` para
  `WindowKind.tooltip`; `WM_NCLBUTTONDOWN` da dona vira evento. Cantos
  arredondados e sombra fora do retângulo pedem `DwmSetWindowAttribute`
  (`DWMWA_WINDOW_CORNER_PREFERENCE`, Windows 11) — opcional, degradável.
- **X11** (`x11_backend.dart:382`, `x11_connection.dart`): honrar o kind:
  `override_redirect = true` para popup e tooltip, `_NET_WM_WINDOW_TYPE`
  em `POPUP_MENU`/`DROPDOWN_MENU`/`COMBO`/`TOOLTIP`, `WM_TRANSIENT_FOR` =
  dona, sem `XGrabPointer` (descarte é do framework, como no Avalonia; um
  grab é a segunda etapa se o teste com um WM real mostrar cliques que
  escapam). Visual ARGB para sombra só sob compositor; sem ele, retângulo
  opaco.
- **Wayland** (`wayland_window.dart`): já cria o `xdg_popup`. Decisões a
  registrar: (a) **parar de pedir `grab`** por padrão, pela razão do
  Avalonia e porque o `grab` sem serial recente já é o erro registrado em
  `wayland_connection.dart:1761`; (b) submenu = `xdg_popup` cujo pai é o
  `xdg_popup` anterior (a cadeia de donos já é a cadeia de pais); (c)
  `popup_done` → `closeWindow`.
- **macOS** (`macos_window.dart` e o host nativo): `NSPanel` com
  `borderless | nonactivatingPanel`, `orderFront:` sem `makeKeyAndOrderFront:`,
  `level = .popUpMenu`, filho da dona via `addChildWindow:ordered:` para
  mover junto. Só verificável no CI Apple Silicon.
- **Headless/web:** devolvem `nativePopups = false`; nada muda.

### 3.7 O popup é GPU, pela mesma razão que a janela é

**Um popup renderiza pelo mesmo caminho que a janela que o abriu.** Se a dona
está no Direct3D 11, o menu está no Direct3D 11; a CPU é o recuo de último
caso, o mesmo que o resto do framework já tem, e não uma escolha de desenho.

A razão de peso **não é** desempenho, é correção. Um menu rasterizado na CPU
sobre uma janela rasterizada na GPU exibe as divergências que a §68.4 lista
por nome — retângulo antialiasado divergindo um nível, `src` sobre máscara
divergindo até 255, e o texto vindo de outro rasterizador. O usuário vê um
menu cujo texto e cujas bordas não casam com o resto da aplicação, e essa é
uma diferença que nenhum número de milissegundos compra. Um framework
GPU-first que abre o menu na CPU não é GPU-first; é GPU-first no fundo e CPU
na frente, que é a metade que o olho encontra primeiro.

O que isso exige, e o que custa:

- **Um dispositivo, N swapchains.** O popup **não deve** criar um
  `GlRenderDevice`, um `D3d12Device` ou um `VkDevice` próprio: deve adotar o da
  janela dona e criar apenas a sua superfície de apresentação.

  > **Estado em 06/09/2026: metade feito, e a metade que falta está medida.**
  > O popup herda o **caminho** já escolhido pela aplicação — nenhuma exceção
  > de CPU foi criada, e um menu nunca diverge do rasterizador da dona, que é
  > a parte que importa para a correção visual. Mas ele **não** herda o
  > *dispositivo*: `Application.openWindow` chama `_presentationPath.attach`
  > por janela, e o `attach` abre um dispositivo para aquela janela. Então o
  > atlas de glifos e o cache de cobertura **não** são compartilhados hoje, e
  > o texto de um menu é rasterizado de novo em vez de ser reaproveitado.
  > Consertar isso é mover a costura para um dispositivo por *aplicação* com
  > swapchains por janela, em `window_host.dart` e
  > `default_platform_resolver.dart` — trabalho real, fora do escopo desta
  > entrega, e é ele que o número de reabertura da fase 2 vai justificar ou
  > não. É o que todo toolkit acelerado
  faz, e é o que faz o **atlas de glifos e o cache de cobertura serem
  compartilhados** — o texto de um menu já está rasterizado, porque a mesma
  fonte no mesmo tamanho já foi desenhada na janela de trás. Um dispositivo
  por popup jogaria esse cache fora a cada abertura, que é o custo real que
  se estava tentando evitar;
- a costura para isso já existe: `GlRenderDevice.adoptContext` adota um
  contexto em vez de criá-lo, e o seletor de apresentação
  (`default_platform_resolver.dart`) escolhe o caminho uma vez por
  aplicação. O popup pede o caminho **já escolhido**, não repete a escolha —
  repetir a sondagem por popup é como se paga o preço duas vezes;
- **o swapchain é o objeto caro, então é ele que se reaproveita.** Um popup
  oculto por janela dona, mantido vivo e apenas mostrado/escondido
  (`SW_SHOWNOACTIVATE`/`SW_HIDE`), preserva a superfície entre aberturas —
  que é o que o próprio Win32 faz com os menus do sistema. Isso deixa de ser
  o plano B da versão anterior desta seção e passa a ser o desenho: com GPU,
  criar e destruir por abertura é que seria caro;
- **a CPU entra nos três casos em que ela é a resposta certa, e em nenhum
  outro.** Este framework é acelerado por GPU com foco em GPU; o rasterizador
  de CPU existe com paridade medida, e ter paridade não o torna um caminho
  co-igual. Os três casos já são exatamente o que `RenderingPolicy`
  (`platform/backend_selection.dart`) enumera, e o popup herda a política da
  janela dona em vez de decidir de novo:
  1. **o hardware ou o sistema não suportam** — nenhum candidato de GPU
     passou na sondagem, e `RenderingPolicy.auto` cai para o último da lista;
  2. **renderização off-screen** — headless, captura, teste de conformidade,
     onde não há swapchain e não deveria haver;
  3. **o usuário da biblioteca forçou** — `RenderingPolicy.cpuOnly`, que é uma
     escolha declarada e não um acidente.

  Numa janela cuja dona está no `win32-dib` por um desses três motivos, o
  popup vai junto. O que não pode existir é a combinação cruzada — dona na
  GPU, menu na CPU — que é o que a versão anterior desta seção prescrevia.

### O que a fase 2 mediu — 06/09/2026, janela real

`tool/popup_window_smoke.dart`, Windows 11, Intel UHD Graphics, Direct3D 11,
`onError` e `onDiagnostic` instalados, JIT e AOT concordando:

| Medida | Resultado |
|---|---|
| o popup **sai** da janela dona | popup `676,494 220x190`; dona `140,120 560x380`. Passa **196 px** da borda direita e **184 px** da inferior |
| o mesmo posicionador contra a janela | `474,286 220x190`, virado para cima e **contido** — é o que o host in-tree produziria |
| tela real por trás da colocação | `DISPLAY1`, bounds 1920x1080, área útil 1920x1032, os 48 px são a taskbar; `synthetic=0` |
| a dona continua ativa | `ownerActive=true popupActive=false keyboardFocus=1`, lido da aplicação e não do que foi pedido |
| frames do popup | 121 em 2016 ms = **60,0 fps**, `errors=0`, `rejected=0` |
| cadeia | profundidade 2; a janela do submenu tem como dona a **janela do menu**, não a de topo |
| descarte | 3 janelas → 1, `popupsLeft=0`, nenhuma janela vazada |
| caminho de renderização | dona e popup em `direct3d11/gpu`, mesmo adaptador, mesma abordagem (`analyticCoverageAtlas`) |
| custo de abertura | fria 63 ms; reabertura melhor 35,4 ms, mediana **41,3 ms** |

**As duas primeiras linhas são a prova da funcionalidade inteira**, e valem
mais que qualquer teste headless: o mesmo `PopupPositioner`, o mesmo
`PopupRequest`, trocando só a área útil — e um retângulo sai da janela
enquanto o outro é virado para dentro dela. Um overlay não pode produzir o
primeiro.

**O que o smoke encontrou e não foi consertado**, com arquivo e linha:

- **o popup cria o seu próprio dispositivo** (`sharedDevice=false`). A criação
  é por *janela*, por *presenter*:
  `default_platform_resolver.dart:191` faz `backend.createDevice()` em todo
  attach. `application.dart:348` já enuncia a regra que o código segue — "um
  presenter por janela, porque um presenter é ligado a uma superfície" — e o
  presenter por superfície está certo; é o **dispositivo pegar carona** que a
  §3.7 proíbe;
- **pior que isso: o atlas é por *alvo*.**
  `d3d11_window_target.dart:131-134` constrói `GpuMaskAtlas`, `GpuGlyphAtlas`,
  `D3d11FontResolver` e `D3d11ImageCache` no construtor do alvo. Então o ganho
  que esta seção promete — "o texto de um menu já está rasterizado" — **não
  acontece**: todo menu rasteriza os glifos de novo, a partir do contorno;
- nada disso é visível hoje, porque os dois lados são o mesmo rasterizador no
  mesmo adaptador. A divergência que a §3.7 teme está ausente; o mecanismo que
  ela nomeia como a razão, também.

### Fechado em 06/09/2026: um dispositivo por adaptador

O achado acima virou trabalho, e o resultado está medido no mesmo smoke, na
mesma máquina, AOT:

**Um par medido na mesma sessão, com a mesma versão da ferramenta**, contra
uma cópia limpa do índice:

| | antes | depois |
|---|---|---|
| abertura do popup, mediana | 30,26 ms | **7,29 ms** |
| abertura, melhor de 20 | 22,33 ms | 5,43 ms |
| abertura fria | 45,67 ms | 10,93 ms |
| **anexar a superfície** | **22,62 ms** | **1,38 ms** |
| dispositivo | dois `D3d11RenderDevice` distintos | **o mesmo objeto** |
| frames do popup | 60,0 fps, `errors=0` | 60,0 fps, `errors=0` |

**Correção de um número que publiquei antes.** Eu escrevi "41,34 ms → 7,54 ms,
5,5 vezes" comparando o "antes" da primeira sessão de smoke com o "depois"
desta. Os dois são medições legítimas, e comparar entre sessões **exagera**: a
máquina varia e a ferramenta mudou entre elas. O par honesto é o da tabela
acima, **4,1 vezes**, e o número mais limpo de todos é a linha do attach, que
isola a mudança: 22,62 ms para 1,38 ms.

A separação, que era o dado que faltava:

| parte | mediana |
|---|---|
| criar a janela nativa | 1,38 ms |
| **criar o dispositivo** | **20,71 ms** |
| anexar o swapchain | 1,91 ms |

O dispositivo era **~70%** de uma abertura de 30 ms — não os "cerca de 90%" que
eu tinha inferido do controle de janela nua, porque aquele controle somava as
três partes. Compartilhá-lo era a correção certa, e agora isso é dado e não
inferência: na versão anterior desta seção eu dizia "por experiência, a criação
do device é a parte cara", e sinalizei que era palpite. Era, e estava certo
pelo motivo certo, com a magnitude errada.

**Verificado em janela real nos outros caminhos**, não só no Direct3D 11:

| caminho | reabertura | compartilha |
|---|---|---|
| `direct2d` | 6,46 ms | sim |
| `direct3d12` | 14,28 ms | sim |
| `opengl` | 38,56 ms | **não, como declarado** |

O OpenGL manter o número antigo é o resultado esperado e é a prova de que a
declaração `sharesDevice: false` está sendo respeitada em vez de ignorada.

**A questão do pool ficou pequena.** Com o dispositivo compartilhado, criar a
janela é 2,5 ms de 7,5 ms. Um popup oculto reaproveitado economizaria um terço
do que sobrou, contra os 90% que economizaria antes. Deixa de ser a próxima
coisa a fazer e passa a ser uma otimização comum.

**E o desenho ficou flexível de propósito.** `RenderDeviceRequest` carrega
`adapter` e `exclusive`: o adaptador está na chave desde o primeiro dia, então
uma janela na GPU discreta e outra na integrada é uma chamada e não uma
refatoração, e quem precisar de um dispositivo sem histórico — uma captura,
uma corrida de conformidade — pede `exclusive` e o recebe.

**O OpenGL é a exceção, e é a mesma do Avalonia.** Um `GlRenderDevice` equivale
a um `GlContext` e a uma janela, e **não há `wglShareLists` neste
repositório**, então nomes de textura não atravessam. A metade OpenGL da
camada 2 é mudança estrutural: põe os caches onde eles pertencem e deixa o dia
em que os contextos compartilharem a uma linha de distância. Ela não rende
desempenho hoje e não foi relatada como se rendesse. O Avalonia responde
`UsesSharedContext => false` nos backends GL dele, o GLX inclusive.

**E o número decide a questão do pool.** O smoke mediu um controle: uma janela
`WindowKind.popup` nua, sem medir, colocar nem mostrar — exatamente a metade
que um popup oculto reaproveitado já possui. Melhor 32,9 ms, mediana 37,1 ms,
contra 35,4 / 41,3 do `openPopup` completo. Ou seja, **cerca de 90% do custo de
abrir um menu é criar a janela, o dispositivo e o swapchain**; medir, colocar e
mostrar somam 3 a 4 ms. A 41 ms um menu perde duas ou três frames antes de
aparecer, e isso se vê. O pool resolve — e **adotar o dispositivo da dona
ataca o mesmo custo dominante**, então as duas são alternativas e não somas.

### 3.8 Acessibilidade

A ponte UIA do Win32 já registra um host por janela (`WindowsAccessibility`,
§68.1 do roteiro). Um popup nativo é uma janela com o seu HWND e a sua
árvore semântica; o que falta é o **`ControlType.Menu` como janela filha do
dono na *control view*** — `IRawElementProviderFragmentRoot` do popup com
`get_FragmentRoot` apontando para si e `Navigate(Parent)` para o dono — e o
evento `MenuOpened`/`MenuClosed` (`UIA_MenuOpenedEventId`). Fica na fase 5;
o `uia_app_test.dart` fora de processo é o lugar da prova.

## 4. Os widgets

| Widget | Hoje | Fica |
|---|---|---|
| `ContextMenuRegion`/`ContextMenu` | `InTreeContextMenuPresentation` | `ContextMenuPresentation` vira um `PopupHost`; a `InTree` continua existindo; entra `WindowContextMenuPresentation`. O `RenderContextMenuSurface` não muda — é o que a costura foi feita para garantir |
| `ComboBox` | `ComboBoxOverlay` na árvore, `PopupDismissPolicy.lightDismiss`, `onWorkAreaChanged` | `ComboBoxOverlay` implementa `PopupHost`, e `ComboBoxScope` recebe um `PopupHost` em vez de possuir a lista; `onWorkAreaChanged` passa a receber a área útil do monitor |
| `Tooltip` | `build` devolve o filho | passa a funcionar: hover com atraso, `PopupKind.tooltip`, `WindowKind.tooltip` (sem grab, sem hit-test), segue o ponteiro entre monitores |
| `Menu` | inline, sem submenus | ganha `MenuItem.submenu` e abre o submenu como popup filho (`parent:` handle); Direita/Esquerda entram e saem; hover com o *safe triangle* |
| `MenuBar` (novo) | só no `vector_editor_demo` | widget do framework: `MenuBar(menus:)`, Alt/mnemônicos, navegação Esquerda/Direita **entre dropdowns abertos** (o dropdown é um popup por menu; trocar de menu fecha um e abre outro sem fechar a barra), F10 |
| `MenuButton`/`DropdownButton` (novos) | — | botão que abre um `Menu` ancorado; o dropdown do combo box é o mesmo host com outro conteúdo |
| `Dialog` | overlay opaco (`Overlay.opaque`) | opção `presentation: window` que abre `WindowKind.dialog` modal com `owner:` — já funciona hoje pelo `openWindow(modal: true)`; falta só o widget |

Todos continuam funcionando sem janela nativa. O teste de cada um roda **nos
dois hosts** com o mesmo caso, que é a única prova de que a lógica do widget
não depende de onde os pixels vão.

## 4.1 Estado da execução — 06/09/2026

Este plano foi escrito e executado no mesmo dia. O que está feito, e como isso
foi provado, está aqui; o que sobrou está nomeado no fim da seção. A decisão
de desenho está no **ADR 0008**.

| Fase | Estado | Prova |
|---|---|---|
| 0 — geometria e Win32 | **feita** | `ScreenInfo`/`ScreenProvider` como interface opcional; Win32 por `EnumDisplayMonitors`/`GetMonitorInfoW`/`GetDpiForMonitor`. Medido nesta máquina: 1920x1080, área útil 1032, os 48 px de taskbar são reais. Classe de popup própria com `CS_DROPSHADOW` (`0x2000b`), `MA_NOACTIVATE`, `HTTRANSPARENT` para tooltip, `WindowNonClientPressEvent` |
| 1 — `Application` | **feita** | `openPopup` com auto-dimensionamento por medição em janela oculta, teclado redirecionado ao popup vivo mais interno, e as cinco rotas de descarte |
| 2 — `PopupHost` | **feita e provada em janela real** | `PopupHost`/`PopupHandle`/`PopupSpec`/`PopupKind`/`PopupPolicy`, `InTreePopupHost` e `WindowPopupHost`. `test/widgets/popup_host_test.dart` é o **contrato compartilhado**: as duas implementações têm de satisfazer os mesmos casos. `tool/popup_window_smoke.dart` mediu num HWND de verdade que o popup sai 196 px da janela dona (§3.7) |
| 3 — widgets | **feita** | `Tooltip` real, `MenuAnchor`, `MenuController`, `MenuItemButton`, `SubmenuButton`, `MenuBar`, `showMenu`, `PopupMenuButton`, `PopupMenuItem`, `PopupMenuDivider`, `RelativeRect` — nos nomes e assinaturas do Flutter (`doc/MIGRACAO_DO_FLUTTER.md`) |
| 4 — X11 e Wayland | **feita no código, não executada** | X11 honra `WindowKind` (override-redirect, `_NET_WM_WINDOW_TYPE`, `WM_TRANSIENT_FOR`); Wayland com grab desligado e o serial dentro do tipo. Provados por testes de bytes numa máquina Windows; os dois smokes **nunca rodaram** |
| 4 — macOS | **não feita** | sem host de popup nativo; cai no overlay. Escrever às cegas produz confiança falsa (§68.1) |
| 5 — acessibilidade | **não feita** | o popup ainda não é fragmento UIA filho da dona, nem emite `MenuOpened`/`MenuClosed` |

**A correção mais importante do plano original**, registrada porque errar em
público é o que torna o resto confiável: a §3.7 dizia "popups usam sempre o
apresentador de CPU". Estava errada, e não por desempenho — um menu na CPU
sobre uma janela na GPU exibe lado a lado as divergências que a §68.4 lista.
A §3.7 foi reescrita e a regra virou a §8.1.1 do roteiro.

**O que a auditoria de execução encontrou e vale registrar:**

- **o descarte não podia ser decidido depois da entrega.** O roteador entrega o
  caminho de hit do mais profundo para a raiz, então um botão deixado no
  caminho já foi pressionado quando o evento sobe até a camada de popup. A
  decisão foi para o *hit test* (ADR 0008, item 4);
- **`canOpenPopupWindows` não pode ser inferido de um handle nativo.** O
  Wayland cria um `xdg_popup` real e não tem handle a exibir, então o proxy
  responde "não" para ele. Virou `Capability.nativePopups`, declarada por cada
  backend;
- **uma barra de menus precisa de "modal, exceto aqui".** Um menu tira o
  conteúdo do caminho de hit para que o clique que o fecha não pressione o que
  está atrás — mas a barra **é** conteúdo, e precisa continuar recebendo o
  ponteiro para trocar de menu no hover e fechar no segundo clique. A primeira
  tentativa foi tornar a cadeia da barra inteira não-modal, o que devolve o
  clique que fecha *e* pressiona. `PopupSpec.passThrough` nomeia a região que
  continua sendo do conteúdo, e é um *callback* e não um `Rect` porque a barra
  se move: um retângulo capturado na abertura deixa o buraco no lugar errado
  depois de um redimensionamento;
- **um dispositivo por janela** (acima): o achado que a auditoria de execução
  não conseguiu fechar;
- **a colocação inicial de um popup é um move e um resize.** Sem excluir isso
  das rotas de descarte, todo submenu fecharia no instante em que abrisse;
- **o host tem de ser compartilhado por cadeia, a partir da janela de topo.**
  Um host por `ApplicationWindow` faria um submenu aberto de dentro de um popup
  não achar o pai — e no Wayland um `xdg_popup` com o pai errado é erro de
  protocolo, que mata a conexão e leva junto todas as janelas do processo;
- **"o tooltip já está quente"** precisou de uma variável própria com carência:
  o roteador reporta a *saída* do ponteiro antes da *entrada*, então limpar o
  calor ao esconder faria todo tooltip depois do primeiro pagar a espera cheia.

---

## 5. Fases, com o que prova cada uma

### Fase 0 — geometria e o resto do Win32 (1 semana)

- `ScreenInfo` + `WindowingBackend.screens/screenAt`; Win32 por
  `GetMonitorInfoW`/`GetDpiForMonitor`; headless com uma tela sintética.
- Win32: `CS_DROPSHADOW`, `MA_NOACTIVATE`, `HTTRANSPARENT` para tooltip,
  `WindowNonClientPressEvent`.
- **Prova:** `test/backends/win32/win32_screens_test.dart` contra o driver
  real (esta máquina tem um monitor; o teste afirma que a área útil é menor
  que os limites quando há taskbar); `test/platform/screen_info_test.dart`.

### Fase 1 — `Application`: teclado e descarte (1 semana)

- Redirecionamento de teclas para o popup vivo mais interno da janela
  focada (3.3).
- As quatro entradas de descarte que faltam (3.4), com `PopupDismissPolicy`
  decidindo entregar ou engolir o clique.
- `Application.openPopup(owner, anchorRect, request, kind, rootWidget)`:
  o `openWindow` de hoje mais a conversão de âncora e a escolha do
  apresentador de CPU.
- **Prova:** `multi_window_test.dart` ganha "typing with a menu open reaches
  the menu, not the owner", "Escape closes the innermost popup and the owner
  never sees it", "a click in the owner outside the menu dismisses it and is
  swallowed", "a click in the owner with a combo open dismisses it and is
  delivered", "the owner moving repositions a dropdown and dismisses a menu".
  Tudo headless, tudo por `windowId`.

### Fase 2 — `PopupHost` e o menu de contexto em janela (2 semanas)

- `PopupHost`, `PopupHandle`, `PopupPolicy`, `PopupScope`;
  `InTreePopupHost` absorve o overlay do menu de contexto.
- `WindowPopupHost` e `WindowContextMenuPresentation`; `ContextMenuScope`
  escolhe por `PopupPolicy`.
- `tool/popup_window_smoke.dart`: janela real no Win32, `onError` instalado
  (a regra de `headless-tests-miss-backend-bugs`), abre o menu perto da
  borda direita e afirma que o retângulo do popup **sai** da janela dona
  (`escapesOwnerWindow` medido, não declarado), confirma que o popup adotou
  **o dispositivo da dona** e não criou o seu, mede primeira abertura e
  reabertura, e compara o menu em janela com o mesmo menu em overlay (§3.7).
- **Prova:** os 32 casos de `context_menu_test.dart` rodam duas vezes, uma
  por host, sem mudar um `expect`; o smoke em janela real dá o
  número de 3.7.

### Fase 3 — combo box, tooltip, barra de menus, submenus (2 semanas)

- `ComboBoxOverlay` sobre `PopupHost`; `Tooltip` real; `Menu.submenu`;
  `MenuBar`, `MenuButton`, `DropdownButton`; o `vector_editor_demo` troca a
  sua barra pela do framework.
- **Prova:** `combo_box_test.dart` nos dois hosts; `menu_bar_test.dart`
  (Alt, mnemônicos, Esquerda/Direita entre dropdowns, F10, Escape em
  cascata); `tooltip_test.dart` (atraso, não rouba clique, some ao mover).

### Fase 4 — X11, Wayland, macOS (2 semanas, dependente de CI)

- X11: kind → override-redirect + tipo EWMH + transient; `tool/x11_backend_smoke.dart`
  ganha `X11_POPUP=` (abre um popup e lê de volta `override_redirect` e o
  tipo pelo `GetWindowAttributes`/`GetProperty`), sob Xvfb no CI.
- Wayland: `grab` desligado por padrão, submenu como popup de popup,
  `popup_done`; o smoke do Weston ganha `WAYLAND_POPUP=` (o compositor
  responde `configure` do popup, o que prova o positioner aceito).
- macOS: `NSPanel` sem ativação no host nativo; smoke no CI Apple Silicon.
- **Prova:** as três linhas de smoke no `ci.yml`, e a §68.5 do roteiro
  atualizada por plataforma com o que rodou e o que não rodou.

### Fase 5 — acessibilidade, documentação e gate (1 semana)

- UIA: popup como fragmento filho do dono, `MenuOpened`/`MenuClosed`;
  `uia_app_test.dart` abre um menu de contexto e o cliente fora de processo
  encontra `ControlType.Menu` sob a janela.
- `Capability.nativePopups` (em `foundation/diagnostics.dart`, ao lado de
  `accessibility` e `vsync`) na matriz da §55; ADR-0008 "popups em janela
  nativa: sem ativação, teclado redirecionado, descarte no framework";
  §68 com o que ficou de fora.

## 6. Riscos e decisões que precisam ficar registradas

1. **Grab ou não grab (X11 e Wayland).** Sem grab, um clique fora do popup
   numa *outra aplicação* chega a ela (comportamento do Avalonia; o GTK
   faz grab e engole). Decisão: **sem grab na primeira entrega**, porque o
   grab no Wayland exige serial e no X11 congela o desktop se o processo
   travar. Reavaliar com o WM real na fase 4.
2. **Popup ativado ou não.** Não ativado (3.3). O custo é o
   redirecionamento de teclado em `Application`; o ganho é o caret da dona
   e a ausência de `WM_ACTIVATE` espúrio. O Flutter da Canonical escolheu
   permitir foco; o Avalonia, não. Fica com o Avalonia, pelas razões que
   `WindowKind` já escreveu.
3. **Custo de criação.** Medido na fase 2, com o *pool* de um popup oculto
   por dona como plano B (3.7).
4. **DPI misto.** O popup que cruza para um monitor de outra escala muda de
   tamanho lógico; o `anchorRect` é o único dado que atravessa a fronteira
   e é convertido nas duas pontas. Um teste headless com duas `ScreenInfo`
   de escalas diferentes prova a conversão.
5. **Wayland não tem tela.** O `PopupPositioner` local não roda lá; o
   compositor decide, e o `PopupPlacement` de volta vem do `configure` do
   `xdg_popup`. O widget não pode depender de saber onde ficou antes do
   primeiro frame.
6. **Sombra e transparência.** Sem compositor (X11 sem `_NET_WM_CM_S0`),
   sem sombra. Não é bloqueante: um menu opaco com borda é um menu.
7. **Não penalizar uma plataforma por causa de outra** (§69 do roteiro): o
   headless e a web nunca sabem que existe janela nativa; o widget nunca
   sabe qual host recebeu. A regra do §8.2 vale: `widgets` não importa
   `backends`, e a decisão fica em `app/`.

## 7. Como fica para quem usa

```dart
// Nada muda para o menu de contexto: o mesmo ContextMenuRegion.
ContextMenuRegion(
  itemsBuilder: () => <MenuItem>[...],
  child: editor,
)

// A política, quando a aplicação quiser forçar:
Application.run(
  options: ApplicationOptions(popupPolicy: PopupPolicy.inTree),
  ...
)

// A barra de menus nova, com submenus:
MenuBar(menus: <MenuBarItem>[
  MenuBarItem(label: 'File', mnemonic: 'F', items: <MenuItem>[
    MenuItem(label: 'Open…', shortcut: 'Ctrl+O', onSelected: open),
    MenuItem(label: 'Recent', submenu: recentFiles),
    const MenuItem.separator(),
    MenuItem(label: 'Exit', onSelected: exit),
  ]),
])

// Um popup próprio, ancorado num widget:
final handle = PopupHost.of(context).open(
  anchorRect: anchorBox.globalRect,
  request: PopupRequest(anchorPoint: PopupAnchor.bottomLeft, ...),
  kind: PopupKind.menu,
  builder: (context) => ColorPalette(onPicked: (c) { pick(c); handle.close(); }),
);
```

## 8. O que este plano deliberadamente não faz

- Não transforma diálogos em janelas por padrão: `openWindow(modal: true)`
  já existe para quem quer, e o `Overlay.opaque` continua sendo o diálogo
  barato.
- Não muda o modelo de owners por janela: o cabeçalho de `application.dart`
  explica por que não pode, e `multi_window_test.dart` conta `performLayout`
  por janela para impedir.
- Não escreve o backend macOS às cegas: a regra da §68.1 (escrever sem poder
  rodar produz confiança falsa) vale aqui.
- Não abre exceção de renderização para popups: o popup vai pelo caminho da
  janela dona, GPU inclusive, e a CPU é o mesmo recuo de sempre (§3.7). A
  versão anterior desta seção dizia o contrário — "CPU por desenho" — e
  estava errada no ponto que decide: o custo de um menu na CPU sobre uma
  janela na GPU não é tempo, é a divergência visível que a §68.4 lista.
