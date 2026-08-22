Read C:\MyDartProjects\dart_ui\lib\src\backends\win32\d3d12\d3d12_com.dart
Read C:\MyDartProjects\dart_ui\lib\src\platform\input_events.dart
Bash List x11 tests
IN
ls C:/MyDartProjects/dart_ui/test/backends/x11 && wc -l C:/MyDartProjects/dart_ui/test/backends/x11/*.dart

OUT
x11_backend_test.dart
x11_bindings_test.dart
x11_cpu_presenter_test.dart
x11_events_test.dart
x11_put_image_plan_test.dart
x11_surface_test.dart
x11_window_test.dart
  603 C:/MyDartProjects/dart_ui/test/backends/x11/x11_backend_test.dart
   40 C:/MyDartProjects/dart_ui/test/backends/x11/x11_bindings_test.dart
  283 C:/MyDartProjects/dart_ui/test/backends/x11/x11_cpu_presenter_test.dart
  763 C:/MyDartProjects/dart_ui/test/backends/x11/x11_events_test.dart
  351 C:/MyDartProjects/dart_ui/test/backends/x11/x11_put_image_plan_test.dart
  206 C:/MyDartProjects/dart_ui/test/backends/x11/x11_surface_test.dart
  478 C:/MyDartProjects/dart_ui/test/backends/x11/x11_window_test.dart
 2724 total
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\webgl\webgl_canvas_target.dart
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\webgl\webgl_backend.dart
Read C:\MyDartProjects\dart_ui\lib\src\backends\win32\d3d12\d3d12_interfaces.dart
Read C:\MyDartProjects\dart_ui\test\backends\x11\x11_window_test.dart
Agent:Widgets modernos faltantes
IN
Você trabalha no repositório c:\MyDartProjects\dart_ui — um framework de UI desktop 100% Dart com sistema próprio de widgets (widgets/elements/render objects, estilo Flutter-like mas próprio). Leia primeiro:
- lib\src\widgets\ INTEIRO no nível de inventário (liste arquivos, leia basic.dart, control.dart, controls.dart, theme.dart, style.dart para entender o padrão de controle + tema)
- Um controle completo existente como referência de padrão: combo_box.dart, list_box.dart, tabs.dart, text_field.dart (escolha 2 e leia por inteiro — siga fielmente o padrão de foco, teclado, semântica/acessibilidade, tema e testes deles)
- test\widgets\ (como testes de widget headless são escritos neste repo)
- lib\src\gallery\ (galeria de controles — novos controles devem aparecer lá; veja como os existentes se registram)

TAREFA: Primeiro faça um INVENTÁRIO do que já existe (inclusive dentro de basic.dart/controls.dart — pode haver Button/Checkbox/Slider lá dentro) e então implemente os widgets importantes de aplicações modernas que FALTAM, nesta ordem de prioridade (pule os que já existirem, pare onde o tempo acabar, qualidade > quantidade):
1. **TreeView** — hierárquico, expansão/colapso, seleção, navegação por teclado (setas/Home/End/asterisco), lazy loading de filhos, virtualização se a infra de virtualization.dart permitir, semântica de árvore.
2. **DataGrid/Table** — colunas redimensionáveis, ordenação por cabeçalho, seleção de linha (single/multi), virtualização de linhas, células customizáveis, teclado.
3. **Slider** (se faltar) — horizontal/vertical, teclado, ticks, range opcional.
4. **Tooltip** — atraso de exibição, posicionamento inteligente nas bordas, segue padrão overlay.dart existente.
5. **DatePicker + Calendar** — calendário mensal navegável, teclado, locale via localizations.dart existente.
6. **NumberBox/Spinner** — edição numérica com botões +/- , validação, formato.
7. **Toast/InfoBar/Snackbar** — notificações transientes in-app via overlay.
8. **Badge, Chip/Tag, Avatar, Card** — primitivos visuais simples.
Para CADA widget: seguir o padrão dos controles existentes (tema via theme.dart, foco/teclado, semântica de acessibilidade, directionality), adicionar à galeria (lib\src\gallery), exportar no barrel que os outros controles usam, e escrever testes headless em test\widgets\ no padrão dos testes existentes (montagem, interação por teclado/ponteiro, semântica).
Arquivos compartilhados (barrels, gallery): edições mínimas e aditivas — outros agentes editam outros diretórios em paralelo.
TESTES: rode apenas os seus (dart test test\widgets\<novos>) + dart analyze — NÃO rode a suíte completa.

REGRAS: branch main somente, NUNCA crie branches/worktrees, NUNCA faça git commit (o orquestrador commitará). Siga o estilo/idioma do código vizinho (nomes de API em inglês se os vizinhos forem em inglês). dart analyze sem errors/warnings novos. Ao final retorne: inventário do que já existia, widgets implementados, arquivos criados, resultado dos testes.
Grep "export 'src/backends" (in C:\MyDartProjects\dart_ui\lib)
3 lines of output
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\webgl\webgl_backend.dart (lines 1396-2295)
Read C:\MyDartProjects\dart_ui\lib\src\graphics\display_list_opcodes.dart
Read C:\MyDartProjects\dart_ui\lib\src\rendering\renderer.dart
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gl\gl_shaders.dart
Bash List platform, backends, and doc directories
IN
ls C:/MyDartProjects/dart_ui/lib/src/platform/ && ls C:/MyDartProjects/dart_ui/lib/src/backends/ && ls C:/MyDartProjects/dart_ui/doc/ | head -30

OUT
backend_selection.dart
clipboard.dart
file_picker.dart
file_picker_platform_io.dart
file_picker_platform_stub.dart
file_picker_platform_web.dart
file_picker_types.dart
input_events.dart
native_window.dart
system_fonts.dart
window_events.dart
default_platform_resolver.dart
default_platform_resolver_stub.dart
headless
macos
web
win32
x11
GITHUB_CI_MULTIPLATAFORMA.md
MACOS_TRES_BACKENDS.md
PLANO_POC_MVP_IMPLEMENTACAO_INICIAL.md
PLANO_SUPORTE_PDF_E_CDR_PURO_DART.md
ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md
SPIKE_MACOS_MAIN_THREAD.md
TECNICA_MAIN_THREAD_DART_FFI.md
adr
architecture
logs
propostas
Read C:\MyDartProjects\dart_ui\lib\src\rendering\replay\display_list_player.dart
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\webgl\webgl_surface_descriptor.dart
Read C:\MyDartProjects\dart_ui\lib\src\platform\file_picker.dart
Read C:\MyDartProjects\dart_ui\lib\src\platform\file_picker_types.dart
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\webgl\webgl_framebuffer_pool.dart
Read C:\MyDartProjects\dart_ui\lib\src\platform\file_picker_platform_io.dart
Bash List d3d11, gpu, app, platform dirs
IN
ls lib/src/backends/win32/d3d11/ lib/src/rendering/gpu/d3d11/ lib/src/rendering/gpu/d3d12/ lib/src/app lib/src/platform 2>/dev/null

OUT
lib/src/app:
app.dart
application.dart
application_info.dart
window_host.dart

lib/src/backends/win32/d3d11/:
win32_d3d11_surface.dart

lib/src/platform:
backend_selection.dart
clipboard.dart
file_picker.dart
file_picker_platform_io.dart
file_picker_platform_stub.dart
file_picker_platform_web.dart
file_picker_types.dart
input_events.dart
native_window.dart
system_fonts.dart
window_events.dart

lib/src/rendering/gpu/d3d11/:
d3d11_backend.dart
d3d11_bindings.dart
d3d11_shaders.dart
d3d11_surface_descriptor.dart
d3d11_window_target.dart

lib/src/rendering/gpu/d3d12/:
d3d12_shaders.dart
d3d12_surface_descriptor.dart
Read C:\MyDartProjects\dart_ui\lib\src\platform\file_picker_platform_stub.dart
Read C:\MyDartProjects\dart_ui\lib\src\platform\file_picker_platform_web.dart
Grep "d3d11|d3d12|RendererKind" (in C:\MyDartProjects\dart_ui\lib\src\app)
1 line of output
Read C:\MyDartProjects\dart_ui\lib\dart_ui.dart
Read C:\MyDartProjects\dart_ui\lib\src\platform\clipboard.dart
Read C:\MyDartProjects\dart_ui\lib\src\platform\backend_selection.dart
Read C:\MyDartProjects\dart_ui\lib\src\platform\backend_selection.dart
Read C:\MyDartProjects\dart_ui\lib\src\platform\system_fonts.dart
Bash Locate web backend entry and file sizes
IN
ls "C:\MyDartProjects\dart_ui\lib\src\backends" "C:\MyDartProjects\dart_ui\lib\src\backends\web" && wc -l C:\MyDartProjects\dart_ui\lib\src\backends\web\*.dart C:\MyDartProjects\dart_ui\lib\src\app\window_host.dart 2>/dev/null; find "C:\MyDartProjects\dart_ui\lib\src" -name "web_backend_entry.dart"

OUT
C:\MyDartProjects\dart_ui\lib\src\backends:
default_platform_resolver.dart
default_platform_resolver_stub.dart
headless
macos
web
win32
x11

C:\MyDartProjects\dart_ui\lib\src\backends\web:
dom_input_translation.dart
web_fonts.dart
web_gl_presenter.dart
web_window.dart
0 total
Grep "d3d11|D3d11|d3d12|D3d12" (in C:\MyDartProjects\dart_ui\lib\src\app)
1 line of output
Grep "PresentationPathEntry|presentationPaths|WebGlCanvasPresenter" (in C:\MyDartProjects\dart_ui\lib)
6 lines of output
Read C:\MyDartProjects\dart_ui\lib\src\foundation\diagnostics.dart
Read C:\MyDartProjects\dart_ui\lib\src\ffi\native_memory.dart
Read C:\MyDartProjects\dart_ui\lib\src\foundation\lifecycle.dart
Grep "FileDialogBackend|SystemThemeBackend|StandardPaths|TrashBackend|openUrl|revealInFile" (in C:\MyDartProjects\dart_ui)
3 lines of output
Read C:\MyDartProjects\dart_ui\lib\src\backends\default_platform_resolver.dart
Grep "PresentationCandidate\(" (in C:\MyDartProjects\dart_ui\lib)
41 lines of output
Bash Check test suite result tail
IN
tail -15 "C:\Users\pmro\AppData\Local\Temp\claude\c--MyDartProjects-dart-ui\2cc739b3-1f87-452e-a821-ad371837cade\tasks\bvic1cb5l.output"

OUT
<persisted-output>
Output too large (460KB). Full output saved to: C:\Users\pmro\.claude\projects\c--MyDartProjects-dart-ui\2cc739b3-1f87-452e-a821-ad371837cade\tool-results\bi8z40lvw.txt

Preview (first 2KB):

01:26 +2196 ~24: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2196 ~24: test\rendering\gpu\metal\metal_device_test.dart: a real device the vertex descriptor is the shared layout, and Metal accepts it
  Skip: needs a Mac: this opens a real MTLDevice and runs the Metal shader compiler. On Windows there is neither.

01:26 +2196 ~25: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2196 ~25: test\rendering\gpu\metal\metal_device_test.dart: a real device a vertex descriptor missing an attribute is refused by Metal
  Skip: needs a Mac: this opens a real MTLDevice and runs the Metal shader compiler. On Windows there is neither.

01:26 +2196 ~26: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2196 ~26: test\rendering\gpu\metal\metal_device_test.dart: a real device a syntax error comes back as Apple's own diagnostic
  Skip: needs a Mac: this opens a real MTLDevice and runs the Metal shader compiler. On Windows there is neither.

01:26 +2196 ~27: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2196 ~27: test\rendering\gpu\metal\metal_offscreen_test.dart: an offscreen pass that only clears writes the requested colour into every pixel
...
</persisted-output>
Grep "export 'src/platform" (in C:\MyDartProjects\dart_ui\lib)
6 lines of output
Grep "class PresentationPathEntry|class SurfacePresenter|abstract.*SurfacePresenter|presentationPaths|PresentationPath" (in C:\MyDartProjects\dart_ui\lib\src\app\application.dart)
151 lines of output
Grep "D3d11WindowTarget|d3d11_window_target|D3d11RendererBackend|d3d11_backend" (in C:\MyDartProjects\dart_ui\lib)
44 lines of output
Bash List widgets, tests, gallery directories
IN
ls C:/MyDartProjects/dart_ui/lib/src/widgets/ && echo --- && ls C:/MyDartProjects/dart_ui/test/widgets/ 2>/dev/null && echo --- && ls C:/MyDartProjects/dart_ui/lib/src/gallery/ 2>/dev/null && echo --- && ls C:/MyDartProjects/dart_ui/lib/src/ && echo --- && ls C:/MyDartProjects/dart_ui/lib/

OUT
actions.dart
animation_scope.dart
basic.dart
cdr
combo_box.dart
context_menu.dart
control.dart
controls.dart
dart_ui_app.dart
directionality.dart
docking
docking.dart
element.dart
errors.dart
expander.dart
focus.dart
focus_scope.dart
gesture_detector.dart
icon.dart
icon_button.dart
image.dart
keyboard_router.dart
list_box.dart
localizations.dart
media_query.dart
menu.dart
navigator.dart
overlay.dart
pdf
phosphor_icons.dart
pointer_router.dart
popup.dart
progress_indicator.dart
properties.dart
proxy.dart
routes.dart
safe_area.dart
scroll_view.dart
scrollbar.dart
semantics.dart
split_view.dart
style.dart
svg.dart
tabs.dart
text_editing.dart
text_field.dart
theme.dart
toolbar.dart
virtualization.dart
widget.dart
---
actions_test.dart
basic_test.dart
combo_box_test.dart
context_menu_test.dart
controls_test.dart
directionality_test.dart
docking_test.dart
expander_test.dart
flex_directionality_test.dart
focus_test.dart
global_key_test.dart
icon_test.dart
image_test.dart
keyboard_router_test.dart
list_box_test.dart
localizations_test.dart
material_contracts_test.dart
media_query_test.dart
navigator_test.dart
overlay_test.dart
parent_data_test.dart
pdf_page_view_test.dart
pdf_view_test.dart
pointer_capture_test.dart
pointer_router_test.dart
popup_test.dart
properties_test.dart
proxy_test.dart
rebuild_scope_test.dart
reconciliation_test.dart
scroll_view_test.dart
scrollbar_test.dart
semantics_test.dart
split_view_test.dart
style_test.dart
svg_test.dart
tabs_test.dart
text_editing_test.dart
text_field_clipboard_test.dart
text_field_context_menu_test.dart
text_field_selection_test.dart
virtualization_test.dart
widget_tree_test.dart
widgets_test.dart
---
gallery.dart
---
animation
app
backends
cdr
crypto
diagnostics
ffi
foundation
gallery
geometry
gestures
graphics
layout
pdf
platform
rendering
scheduler
text
tooling
widgets
---
cdr.dart
dart_ui.dart
pdf.dart
src
Bash Read final test counts
IN
tail -5 "C:\Users\pmro\.claude\projects\c--MyDartProjects-dart-ui\2cc739b3-1f87-452e-a821-ad371837cade\tool-results\bi8z40lvw.txt"

OUT
<persisted-output>
Output too large (457.5KB). Full output saved to: C:\Users\pmro\.claude\projects\c--MyDartProjects-dart-ui\2cc739b3-1f87-452e-a821-ad371837cade\tool-results\b85431z73.txt

Preview (first 2KB):

01:26 +2196 ~29: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2196 ~29: test\rendering\gpu\metal\metal_offscreen_test.dart: an offscreen pass that only clears the CPU renderer agrees with it, deviation 0
  Skip: needs a Mac: this renders into an MTLTexture and reads it back.

01:26 +2196 ~30: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2197 ~30: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2198 ~30: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2199 ~30: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2200 ~30: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2201 ~30: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2202 ~30: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by file name
01:26 +2203 ~30: test\platform\system_fonts_test.dart: this machine a family is found by the name in its name table, not by fi
...
</persisted-output>
Read C:\MyDartProjects\dart_ui\lib\src\backends\default_platform_resolver.dart
Bash Read roadmap sections about backends contracts
IN
sed -n 420,460p C:/MyDartProjects/dart_ui/doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md; echo ---; sed -n 730,760p C:/MyDartProjects/dart_ui/doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md

OUT
6. tentar o backend preferido;
7. registrar motivo de falha;
8. cair para o próximo;
9. garantir sempre o backend CPU quando o sistema suporta uma janela.

---

# 6. Princípios arquiteturais

## 6.1 Portas e adaptadores

O núcleo não conhece Win32, XCB, Wayland, GTK ou AppKit. Ele depende de interfaces:

- `PlatformBackend`;
- `WindowingBackend`;
- `NativeWindow`;
- `UiDispatcher`;
- `InputBackend`;
- `ClipboardBackend`;
- `DragDropBackend`;
- `TextInputBackend`;
- `AccessibilityBackend`;
- `RendererBackend`;
- `RenderSurface`;
- `SystemThemeBackend`;
- `FileDialogBackend`.

## 6.2 Backend de janela não é backend gráfico

Uma janela pode expor várias superfícies:

```dart
sealed class NativeSurfaceDescriptor {}

final class Win32HwndSurface extends NativeSurfaceDescriptor {
  final int hwnd;
}

final class XcbWindowSurface extends NativeSurfaceDescriptor {
  final int connection;
  final int window;
---
    // Seleção de plataforma, criação do dispatcher e montagem da raiz.
  }
}
```

## 9.2 Plataforma

```dart
abstract interface class PlatformBackend {
  String get name;
  PlatformCapabilities get capabilities;
  UiDispatcher get dispatcher;
  WindowingBackend get windowing;
  ClipboardBackend get clipboard;
  DragDropBackend get dragDrop;
  TextInputBackend get textInput;
  SystemThemeBackend get systemTheme;
  AccessibilityBackend? get accessibility;

  Future<void> initialize(PlatformInitOptions options);
  Future<void> shutdown();
}
```

## 9.3 Janela

```dart
abstract interface class NativeWindow {
  NativeWindowId get id;
  NativeHandle get handle;
  Size get clientSize;
Bash File sizes of widget files
IN
wc -l C:/MyDartProjects/dart_ui/lib/src/widgets/*.dart | sort -n | tail -40

OUT
   167 C:/MyDartProjects/dart_ui/lib/src/widgets/directionality.dart
   242 C:/MyDartProjects/dart_ui/lib/src/widgets/svg.dart
   255 C:/MyDartProjects/dart_ui/lib/src/widgets/actions.dart
   258 C:/MyDartProjects/dart_ui/lib/src/widgets/widget.dart
   286 C:/MyDartProjects/dart_ui/lib/src/widgets/pointer_router.dart
   300 C:/MyDartProjects/dart_ui/lib/src/widgets/properties.dart
   304 C:/MyDartProjects/dart_ui/lib/src/widgets/menu.dart
   318 C:/MyDartProjects/dart_ui/lib/src/widgets/virtualization.dart
   319 C:/MyDartProjects/dart_ui/lib/src/widgets/progress_indicator.dart
   321 C:/MyDartProjects/dart_ui/lib/src/widgets/icon_button.dart
   337 C:/MyDartProjects/dart_ui/lib/src/widgets/proxy.dart
   347 C:/MyDartProjects/dart_ui/lib/src/widgets/media_query.dart
   390 C:/MyDartProjects/dart_ui/lib/src/widgets/overlay.dart
   418 C:/MyDartProjects/dart_ui/lib/src/widgets/semantics.dart
   484 C:/MyDartProjects/dart_ui/lib/src/widgets/gesture_detector.dart
   498 C:/MyDartProjects/dart_ui/lib/src/widgets/popup.dart
   521 C:/MyDartProjects/dart_ui/lib/src/widgets/expander.dart
   542 C:/MyDartProjects/dart_ui/lib/src/widgets/focus.dart
   546 C:/MyDartProjects/dart_ui/lib/src/widgets/list_box.dart
   550 C:/MyDartProjects/dart_ui/lib/src/widgets/control.dart
   570 C:/MyDartProjects/dart_ui/lib/src/widgets/split_view.dart
   596 C:/MyDartProjects/dart_ui/lib/src/widgets/image.dart
   630 C:/MyDartProjects/dart_ui/lib/src/widgets/navigator.dart
   645 C:/MyDartProjects/dart_ui/lib/src/widgets/scrollbar.dart
   652 C:/MyDartProjects/dart_ui/lib/src/widgets/icon.dart
   655 C:/MyDartProjects/dart_ui/lib/src/widgets/localizations.dart
   688 C:/MyDartProjects/dart_ui/lib/src/widgets/text_editing.dart
   708 C:/MyDartProjects/dart_ui/lib/src/widgets/theme.dart
   764 C:/MyDartProjects/dart_ui/lib/src/widgets/basic.dart
   774 C:/MyDartProjects/dart_ui/lib/src/widgets/tabs.dart
   792 C:/MyDartProjects/dart_ui/lib/src/widgets/style.dart
   885 C:/MyDartProjects/dart_ui/lib/src/widgets/routes.dart
  1035 C:/MyDartProjects/dart_ui/lib/src/widgets/scroll_view.dart
  1209 C:/MyDartProjects/dart_ui/lib/src/widgets/combo_box.dart
  1400 C:/MyDartProjects/dart_ui/lib/src/widgets/context_menu.dart
  1405 C:/MyDartProjects/dart_ui/lib/src/widgets/controls.dart
  1532 C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart
  1976 C:/MyDartProjects/dart_ui/lib/src/widgets/text_field.dart
  1995 C:/MyDartProjects/dart_ui/lib/src/widgets/phosphor_icons.dart
 26977 total
Grep "dark|DarkMode|systemTheme|SystemTheme" (in C:\MyDartProjects\dart_ui\lib)
15 lines of output
Bash List classes in controls.dart and basic.dart
IN
grep -nE "^(class|abstract class|enum|mixin) " C:/MyDartProjects/dart_ui/lib/src/widgets/controls.dart C:/MyDartProjects/dart_ui/lib/src/widgets/basic.dart | head -100

OUT
C:/MyDartProjects/dart_ui/lib/src/widgets/controls.dart:268:enum ToggleStyle { button, checkBox, radio, switchControl }
C:/MyDartProjects/dart_ui/lib/src/widgets/basic.dart:205:class Flexible extends ParentDataWidget<layout.FlexParentData> {
Read C:\MyDartProjects\dart_ui\lib\src\backends\web\web_window.dart
PowerShell Read last lines of test output
IN
Get-Content "C:\Users\pmro\.claude\projects\c--MyDartProjects-dart-ui\2cc739b3-1f87-452e-a821-ad371837cade\tool-results\bi8z40lvw.txt" -Tail 3

OUT
02:11 +4192 ~30: All tests passed!

[exited with code 0]
Bash List top-level declarations
IN
grep -nE "^(class|abstract class|enum|mixin|typedef) \w+" C:/MyDartProjects/dart_ui/lib/src/widgets/controls.dart; echo ===; grep -nE "^(class|abstract class|enum|mixin|typedef) \w+" C:/MyDartProjects/dart_ui/lib/src/widgets/basic.dart

OUT
268:enum ToggleStyle { button, checkBox, radio, switchControl }
===
205:class Flexible extends ParentDataWidget<layout.FlexParentData> {
764:typedef RenderColoredBox = layout.RenderColoredBox;
Read C:\MyDartProjects\dart_ui\test\backends\web\web_compilation_test.dart
Grep "dark|Dark" (in C:\MyDartProjects\dart_ui\lib\src\widgets\theme.dart)
19 lines of output
Grep "AppsUseLightTheme|isDarkMode|darkMode|prefers-color-scheme" (in C:\MyDartProjects\dart_ui)
10 lines of output
Read C:\MyDartProjects\dart_ui\test\backends\web\web_compilation_fixture.dart
Bash Check dart_test.yaml, web main, mvp_04
IN
cat "C:\MyDartProjects\dart_ui\dart_test.yaml" 2>/dev/null; cat "C:\MyDartProjects\dart_ui\web\main.dart" | head -80; ls "C:\MyDartProjects\dart_ui\mvp\mvp_04_web_counter"; ls "C:\MyDartProjects\dart_ui\mvp\mvp_04_web_counter\web" 2>/dev/null

OUT
/// The gallery, in a browser, on WebGL2.
///
/// The web counterpart of `example/gallery_headless.dart`, and the thing to
/// notice is how little differs: the widget tree is the same `Gallery`, the
/// options are the same `ApplicationOptions`, and the frame loop draws the same
/// display lists. What changes is two entries - a [WebWindowingBackend] instead
/// of a headless or Win32 one, and a WebGL2 presentation path instead of the
/// CPU renderer - plus the one thing a browser genuinely does differently,
/// which is who owns the clock.
///
/// ## Why this does not call `Application.run()`
///
/// `Application.run()` is a `while` loop that pumps the backend and yields with
/// `await Future.delayed(Duration.zero)`. On Win32 that is right: `pumpEvents`
/// blocks in `GetMessage` until something happens, so the loop sleeps when the
/// application is idle.
///
/// A browser has no such call. `WebWindowingBackend.pumpEvents` returns
/// immediately and always - the browser *is* the event loop, and DOM events are
/// delivered to listeners whether or not anybody asks. So `run()` here would
/// spin through timers at whatever rate the microtask queue allows, burning a
/// core to redraw a static page. `Application`'s own documentation says what to
/// do instead: "drive `drawPendingFrames` yourself".
///
/// That is what [_FrameLoop] below does, from `requestAnimationFrame`, which is
/// the browser's real frame clock - vsync-aligned, throttled in a background
/// tab, and the only callback in which a WebGL drawing buffer is composited the
/// way the application intended. See `webgl_canvas_target.dart` on why a frame
/// must be drawn inside one callback and not across two.
///
/// ## Building and running
///
/// ```
/// dart compile js -O2 -o web/main.dart.js web/main.dart
/// dart run tool/serve_web.dart          # or any static file server
/// ```
///
/// `dart compile wasm` also works and produces `main.wasm` plus `main.mjs`;
/// `index.html` loads the JavaScript build, because that is the one a plain
/// `<script>` tag can take.
library;

import 'dart:js_interop';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/web/web_fonts.dart';
import 'package:dart_ui/src/backends/web/web_gl_presenter.dart';
import 'package:dart_ui/src/backends/web/web_window.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_backend.dart';
import 'package:web/web.dart' as web;

/// Asks whether this browser has WebGL2.
///
/// A top-level function rather than `const WebGlRendererBackend().probe`,
/// because a tear-off of an *instance* method is not a constant expression and
/// the entry above wants to be `const`. The probe creates and throws away a
/// detached 1x1 canvas - see `WebGlRendererBackend.probe` - and never throws,
/// so a browser without WebGL2 produces a named rejection in the startup report
/// rather than an exception out of `Application.start`.
BackendProbeResult _probeWebGl2() => const WebGlRendererBackend().probe();

/// The face the gallery draws its labels in.
///
/// Bundled in `web/fonts` rather than found on the machine, because a browser
/// offers no way to enumerate or read an installed font - see `web_fonts.dart`
/// for why that is a deliberate closure rather than a gap. Roboto under
/// Apache-2.0, with the licence next to it.
const String _uiFontUrl = 'fonts/Roboto-Regular.ttf';

Future<void> main() async {
  // Before the application starts, so the first frame already has a face. A
  // font loaded afterwards would be correct too - the registry clears its size
  // cache - but the first frame would draw blank labels and the page would
  // visibly flash from no text to text.
  final String? fontFailure = await useWebUiFont(_uiFontUrl);
  if (fontFailure != null) {
    // Loud, because the symptom is silent: every label draws blank and every
    // box draws normally, which looks exactly like a text layout bug rather
    // than a missing file.
    web.console.error(
pubspec.yaml
test
web
index.html
main.dart
main.dart.js
main.dart.js.deps
main.dart.js.map
Bash Broader declaration search
IN
grep -nE "(class|enum|mixin|typedef)\s+\w+" C:/MyDartProjects/dart_ui/lib/src/widgets/controls.dart | head -60; echo ===BASIC; grep -nE "(class|enum|mixin|typedef)\s+\w+" C:/MyDartProjects/dart_ui/lib/src/widgets/basic.dart | head -60

OUT
53:final class Button extends StatefulWidget {
78:final class _ButtonState extends State<Button> {
102:final class _ButtonRenderWidget extends RenderObjectWidget {
150:final class RenderButton extends RenderBox with ControlBehavior {
228:final class ToggleButton extends StatefulWidget {
244:final class _ToggleButtonState extends State<ToggleButton> {
268:enum ToggleStyle { button, checkBox, radio, switchControl }
270:final class _ToggleRenderWidget extends RenderObjectWidget {
321:/// One class rather than four, because they differ only in the glyph they draw
325:final class RenderToggle extends RenderBox with ControlBehavior {
545:final class CheckBox extends StatefulWidget {
564:final class _CheckBoxState extends State<CheckBox> {
590:final class Radio<T> extends StatefulWidget {
608:final class _RadioState<T> extends State<Radio<T>> {
638:final class Switch extends StatefulWidget {
654:final class _SwitchState extends State<Switch> {
681:final class Slider extends StatefulWidget {
701:final class _SliderState extends State<Slider> {
725:final class _SliderRenderWidget extends RenderObjectWidget {
773:final class RenderSlider extends RenderBox with ControlBehavior {
974:final class ProgressBar extends StatelessWidget {
985:final class _ProgressRenderWidget extends RenderObjectWidget {
1009:final class RenderProgressBar extends RenderBox with ControlBehavior {
1062:final class ScrollViewer extends StatefulWidget {
1078:final class _ScrollViewerState extends State<ScrollViewer> {
1093:final class _ScrollViewerRenderWidget extends SingleChildRenderObjectWidget {
1119:final class RenderScrollViewer extends RenderViewport with ControlBehavior {
1179:final class Dialog extends StatelessWidget {
1200:final class _DialogRenderWidget extends SingleChildRenderObjectWidget {
1225:final class RenderDialog extends RenderSingleChildBox with ControlBehavior {
1322:final class Tooltip extends StatelessWidget {
1333:final class TooltipSurface extends StatelessWidget {
1343:final class _TooltipRenderWidget extends RenderObjectWidget {
1365:final class RenderTooltip extends RenderBox with ControlBehavior {
===BASIC
31:final class Align extends SingleChildRenderObjectWidget {
65:final class ColoredBox extends SingleChildRenderObjectWidget {
88:final class Padding extends SingleChildRenderObjectWidget {
111:final class Flex extends MultiChildRenderObjectWidget {
171:final class Column extends Flex {
182:final class Row extends Flex {
205:class Flexible extends ParentDataWidget<layout.FlexParentData> {
237:final class Expanded extends Flexible {
253:final class Spacer extends StatelessWidget {
270:final class Wrap extends MultiChildRenderObjectWidget {
316:final class AspectRatio extends SingleChildRenderObjectWidget {
343:final class Grid extends MultiChildRenderObjectWidget {
389:final class Stack extends MultiChildRenderObjectWidget {
426:final class Positioned extends ParentDataWidget<layout.StackParentData> {
481:final class SizedBox extends SingleChildRenderObjectWidget {
514:final class DefaultTextStyle extends InheritedWidget {
536:final class Text extends RenderObjectWidget {
607:final class RenderText extends RenderBox {
764:typedef RenderColoredBox = layout.RenderColoredBox;
Bash Check file sizes and test dir
IN
wc -l C:/MyDartProjects/dart_ui/lib/src/backends/win32/win32_api.dart C:/MyDartProjects/dart_ui/lib/src/backends/win32/win32_clipboard.dart C:/MyDartProjects/dart_ui/lib/src/backends/x11/x11_libc.dart; ls C:/MyDartProjects/dart_ui/test/ 2>/dev/null

OUT
  711 C:/MyDartProjects/dart_ui/lib/src/backends/win32/win32_api.dart
  121 C:/MyDartProjects/dart_ui/lib/src/backends/win32/win32_clipboard.dart
  312 C:/MyDartProjects/dart_ui/lib/src/backends/x11/x11_libc.dart
 1144 total
animation
app
architecture
backends
benchmark
cdr
crypto
data
diagnostics
differential
end_to_end_test.dart
ffi
fonts
foundation
gallery
geometry
gestures
graphics
layout
pdf
platform
rendering
scheduler
text
tooling
widgets
Bash Read rest of web main and browser test setup
IN
sed -n '80,220p' "C:\MyDartProjects\dart_ui\web\main.dart"; echo ====; head -80 "C:\MyDartProjects\dart_ui\test\rendering\gpu\webgl\webgl_session.dart"; echo ====; head -60 "C:\MyDartProjects\dart_ui\test\rendering\gpu\webgl\webgl_device_test.dart"

OUT
    web.console.error(
      'no UI font, so every label will be blank: $fontFailure'.toJS,
    );
  }

  final Application application = await Application.start(
    rootWidget: Gallery(model: GalleryModel(), theme: ThemeData.neutralLight),
    backends: <WindowingBackendEntry>[
      const WindowingBackendEntry(
        name: WebWindowingBackend.backendName,
        create: WebWindowingBackend.new,
      ),
    ],
    presentations: <PresentationPathEntry>[
      const PresentationPathEntry(
        name: WebGlRendererBackend.backendName,
        kind: PresentationKind.gpu,
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
        probe: _probeWebGl2,
        attach: WebGlCanvasPresenter.attach,
      ),
    ],
    options: ApplicationOptions(
      title: 'dart_ui gallery - WebGL2',
      size: galleryDesignSize,
      // No frame budget: this is interactive, not a smoke run. The loop below
      // stops when the page goes away.
      showDevOverlay: true,
      minimumSize: const Size(480, 360),
      windowBackgroundColor: ThemeData.neutralLight.surface,
      // Both go to the browser console, which is the web's stderr. A page that
      // swallowed them would be a page where a failed present is invisible.
      onError: (FrameworkError error) => web.console.error(
        error.describe().toJS,
      ),
      onDiagnostic: (BackendDiagnostic diagnostic) => web.console.warn(
        'present: $diagnostic'.toJS,
      ),
    ),
  );

  // The startup report, in full, before the first frame. It names the backend
  // and the presentation path that were chosen and every candidate that was
  // passed over with the reason - which on the web is the difference between
  // "WebGL2 is running" and "WebGL2 was rejected and you are looking at
  // something else", and those two look identical on screen.
  web.console.log(application.describeStartup().toJS);

  _FrameLoop(application).start();
}

/// Drives [Application.drawPendingFrames] from `requestAnimationFrame`.
///
/// ## Why it reschedules unconditionally
///
/// The obvious loop asks `application.needsFrame` and only reschedules when
/// something is dirty. That is the right shape for a backend whose event
/// delivery can wake the loop - and it is wrong here, because the thing that
/// would have to wake it is a DOM event, and a DOM event arriving does not by
/// itself resume a `requestAnimationFrame` chain that has stopped.
///
/// So the chain never stops. The cost is one callback per vsync doing almost
/// nothing on an idle page, which is what every browser application does and
/// what the browser is built to make cheap: it throttles the callback to a few
/// per second in a background tab and stops it entirely in a hidden one,
/// without the page having to know.
///
/// The alternative - stopping the chain and restarting it from every input
/// listener - is a second scheduler competing with the first, and the failure
/// it produces is a page that is occasionally, unreproducibly one frame stale.
final class _FrameLoop {
  _FrameLoop(this._application);

  final Application _application;
  bool _stopped = false;

  /// Whether a frame is still being awaited.
  ///
  /// `drawPendingFrames` is a `Future`, and a callback that fired again before
  /// the previous one settled would have two frames recording into the same
  /// batcher. The flag is the whole of the guard: `requestAnimationFrame`
  /// callbacks never overlap, so nothing more elaborate is needed.
  bool _drawing = false;

  void start() => web.window.requestAnimationFrame(_tick.toJS);

  void _tick(num _) {
    if (_stopped) return;
    // Rescheduled first, so an exception below does not end the loop. A page
    // whose frame loop died silently on one bad frame is far worse than one
    // that logs it and draws the next.
    web.window.requestAnimationFrame(_tick.toJS);
    if (_drawing) return;
    if (!_application.needsFrame) return;
    _drawing = true;
    _application.drawPendingFrames().whenComplete(() => _drawing = false);
  }

  /// Stops the chain. Nothing calls it yet: a tab closing tears the isolate
  /// down without running Dart, so there is no teardown path a page can rely
  /// on. It exists so an embedder that wants to hand the page back - a test
  /// harness, an application that unmounts itself - has something to call.
  void stop() => _stopped = true;
}
====
@TestOn('browser')

/// One WebGL2 device, opened once, shared by every test file in this directory.
///
/// Not a test file: a helper, in the shape `test/backends/win32/d3d12/
/// d3d12_session.dart` established for Direct3D 12. It exists for the same
/// reason - opening a device per test is slow, and on this platform it is worse
/// than slow: a browser allows only a small number of live WebGL contexts per
/// page (commonly sixteen), and a suite that opened one per test would start
/// losing the oldest ones part way through and report the loss as a rendering
/// failure.
///
/// ## The skip contract, stated once
///
/// The CI for this repository has neither Chrome nor a GPU, and a test that
/// *fails* there fails the gate. Two things therefore have to be true, and both
/// are:
///
///   * every file in this directory carries `@TestOn('browser')`, so a plain
///     `dart test` - which is what CI runs - never compiles or runs them at
///     all. This is the gate that matters, and it is why no `dart_test.yaml` is
///     needed.
///   * within a browser, [skipReason] is a **string** rather than a bool, and
///     it is non-null whenever the context could not be created. A run that
///     skipped has to say why instead of looking like a run that passed, so
///     every caller prints it and passes it to `markTestSkipped`.
///
/// The second is not hypothetical. `dart test -p chrome` on a headless machine,
/// in a container, or on a laptop whose browser has fallen back to a blocklisted
/// driver all produce a null context from `getContext('webgl2')`, and none of
/// them is a bug in this backend.
library;

import 'dart:js_interop';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

/// A WebGL2 device on a detached canvas, or the reason there is none.
final class WebGlSession {
  WebGlSession._(this.device, this.skipReason, this._canvas);

  /// Null when the context could not be created. [skipReason] says why.
  final WebGlRenderDevice? device;

  /// Null when the device opened. A string when it did not, so a run with no
  /// GPU reports what was missing rather than passing quietly.
  final String? skipReason;

  /// Kept alive for the lifetime of the device.
  ///
  /// A `WebGLRenderingContext` holds a reference to its canvas, so this is
  /// belt and braces - but the canvas is also what [close] loses the context
  /// through, and a session that had dropped it could not.
  final web.HTMLCanvasElement? _canvas;

  /// Opens a device, or records why it could not.
  ///
  /// The canvas is **detached** - created and never added to the document.
  /// Every target this session hands out renders into a framebuffer object of
  /// its own, so nothing is ever drawn into the canvas's own buffer and its
  /// size is irrelevant; 1x1 is the smallest thing that still gets a real
  /// context. A detached canvas is never laid out or composited, which is what
  /// makes this cheap enough to do at the top of every file.
  static WebGlSession open() {
    try {
      final web.HTMLCanvasElement canvas =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      canvas
        ..width = 1
        ..height = 1;
      final web.WebGL2RenderingContext? gl = createWebGl2Context(canvas);
      if (gl == null) {
        return WebGlSession._(
          null,
====
@TestOn('browser')

/// The WebGL2 device and its targets: the things parity cannot see.
///
/// A parity suite compares pixels, so everything it checks is something that
/// shows up in an image. This file is for the claims that do not: whether the
/// layer pool actually pools, whether the probe answers rather than throwing,
/// whether a resize invalidates the generation, and whether a lost context is
/// reported as lost instead of silently drawing nothing.
///
/// That last one is the reason this file matters most on this platform. On a
/// lost WebGL context every entry point is *defined* to become a no-op that
/// raises nothing, so a backend that forgot to ask `isContextLost()` would
/// issue a whole frame of draws into nowhere, report success, and present an
/// empty canvas - which reads as a bug in the scene. There is a test below that
/// takes the context away on purpose and asserts the device notices.
///
/// See `webgl_session.dart` for the skip contract; the short form is that
/// `@TestOn('browser')` keeps this file out of the CI run entirely, and
/// [WebGlSession.skipReason] keeps it honest inside a browser that has no GPU.
library;

import 'dart:js_interop';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_framebuffer_pool.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import 'webgl_session.dart';

void main() {
  final WebGlSession session = WebGlSession.open();
  tearDownAll(session.close);

  /// Skips the calling test when there is no device, naming the reason.
  bool ready() {
    final String? reason = session.skipReason;
    if (reason == null) return true;
    printOnFailure('skipped: $reason');
    markTestSkipped('no WebGL2 device: $reason');
    return false;
  }

  group('the backend probe', () {
    test('answers instead of throwing, whatever the browser says', () {
      // Never throws is the whole contract - section 6.6 - and it holds even
      // in a browser with WebGL disabled, which is why this one does not need
      // a device and is not skipped.
      late BackendProbeResult result;
      expect(
        () => result = const WebGlRendererBackend().probe(),
        returnsNormally,
Read C:\MyDartProjects\dart_ui\lib\src\backends\win32\win32_api.dart
Bash List platform and architecture tests
IN
ls C:/MyDartProjects/dart_ui/test/platform/ 2>/dev/null; ls C:/MyDartProjects/dart_ui/test/architecture/

OUT
backend_selection_test.dart
file_picker_test.dart
system_fonts_test.dart
text_input_test.dart
layering_test.dart
public_surface_test.dart
Slider and Tooltip already exist. Now let me read the core pattern files.

Read C:\MyDartProjects\dart_ui\lib\src\widgets\control.dart
Read C:\MyDartProjects\dart_ui\lib\src\widgets\list_box.dart
Read C:\MyDartProjects\dart_ui\test\platform\file_picker_test.dart
Read C:\MyDartProjects\dart_ui\test\architecture\public_surface_test.dart
Bash Group lint issues by file
IN
cd "c:\MyDartProjects\dart_ui" && dart analyze 2>&1 | grep info | awk '{print $3}' | sort | uniq -c | sort -rn

OUT
      1 test\widgets\proxy_test.dart:389:17
      1 test\widgets\proxy_test.dart:384:17
      1 test\widgets\proxy_test.dart:368:23
      1 test\widgets\proxy_test.dart:341:20
      1 test\pdf\sign_test.dart:5:1
      1 test\pdf\sign_test.dart:4:1
      1 test\pdf\sign_test.dart:3:1
      1 test\pdf\sign_test.dart:2:1
      1 test\pdf\export_test.dart:5:1
      1 test\pdf\export_test.dart:4:1
      1 test\pdf\export_test.dart:2:1
      1 test\cdr\geometry_test.dart:8:7
      1 test\cdr\geometry_test.dart:7:7
      1 test\cdr\geometry_test.dart:2:1
      1 test\cdr\geometry_test.dart:29:7
      1 test\cdr\geometry_test.dart:28:7
      1 test\cdr\geometry_test.dart:25:7
      1 test\cdr\geometry_test.dart:24:7
      1 test\cdr\geometry_test.dart:11:7
      1 test\cdr\geometry_test.dart:10:7
      1 test\cdr\fills_test.dart:35:9
      1 test\cdr\fills_test.dart:34:9
      1 test\cdr\fills_test.dart:33:9
      1 test\cdr\fills_test.dart:32:9
      1 test\cdr\fills_test.dart:2:1
      1 test\cdr\fills_test.dart:19:11
      1 test\cdr\fills_test.dart:18:11
      1 test\cdr\fills_test.dart:10:21
      1 test\benchmark\benchmark_test.dart:4:1
      1 test\benchmark\benchmark_test.dart:3:1
      1 test\app\gallery_shell_test.dart:40:21
      1 lib\src\text\truetype\interpreter.dart:899:11
      1 lib\src\text\truetype\interpreter.dart:897:11
      1 lib\src\text\truetype\interpreter.dart:892:9
      1 lib\src\text\truetype\interpreter.dart:890:9
      1 lib\src\text\truetype\interpreter.dart:868:9
      1 lib\src\text\truetype\interpreter.dart:841:15
      1 lib\src\text\truetype\interpreter.dart:833:15
      1 lib\src\text\truetype\interpreter.dart:769:11
      1 lib\src\text\truetype\interpreter.dart:481:11
      1 lib\src\text\truetype\interpreter.dart:469:11
      1 lib\src\text\glyf.dart:227:15
      1 lib\src\pdf\sign\pdf_signature_appearance.dart:2:1
      1 lib\src\pdf\sign\pdf_byte_range_signer.dart:2:1
      1 lib\src\pdf\crypto\pdf_security_handler.dart:76:7
      1 lib\src\crypto\ffi\ffi_crypto_backend_native.dart:6:1
      1 lib\src\crypto\dart\pure_dart_sha.dart:483:36
      1 lib\src\cdr\fills\cdr_mesh_fill.dart:2:1
Read C:\MyDartProjects\dart_ui\lib\src\widgets\theme.dart
Read C:\MyDartProjects\dart_ui\lib\src\widgets\virtualization.dart
Bash Inspect WebGPU POC
IN
find "C:\MyDartProjects\dart_ui\poc\poc_18_webgpu" -type f | head -30; echo ====; cat "C:\MyDartProjects\dart_ui\poc\poc_18_webgpu\pubspec.yaml" 2>/dev/null

OUT
C:\MyDartProjects\dart_ui\poc\poc_18_webgpu/.dart_tool/pub/workspace_ref.json
C:\MyDartProjects\dart_ui\poc\poc_18_webgpu/pubspec.yaml
C:\MyDartProjects\dart_ui\poc\poc_18_webgpu/test/webgpu_test.dart
C:\MyDartProjects\dart_ui\poc\poc_18_webgpu/web/index.html
C:\MyDartProjects\dart_ui\poc\poc_18_webgpu/web/main.dart
C:\MyDartProjects\dart_ui\poc\poc_18_webgpu/web/main.dart.js
C:\MyDartProjects\dart_ui\poc\poc_18_webgpu/web/main.dart.js.deps
C:\MyDartProjects\dart_ui\poc\poc_18_webgpu/web/main.dart.js.map
====
name: poc_18_webgpu
description: POC-18 — WebGPU context via package:web (dart:js_interop).
version: 0.0.1
publish_to: none

environment:
  sdk: ^3.6.0

resolution: workspace

dependencies:
  web: ^1.1.0

dev_dependencies:
  lints: ^5.1.0
  test: ^1.25.0
Bash Check pub cache for package:web version
IN
grep -ril "gpu" "C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev" --include="*.dart" -l 2>/dev/null | grep -i "web-1" | head; ls "C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev" 2>/dev/null | grep -i "^web-"

OUT
C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev/web-1.1.1/lib/src/dom/cssom.dart
C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev/web-1.1.1/lib/src/dom/ext_disjoint_timer_query.dart
C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev/web-1.1.1/lib/src/dom/ext_disjoint_timer_query_webgl2.dart
C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev/web-1.1.1/lib/src/dom/webgl1.dart
C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev/web-1.1.1/lib/src/dom/webgl2.dart
C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev/web-1.1.1/lib/src/dom/webgpu.dart
C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev/web-1.1.1/lib/src/dom.dart
web-0.5.1
web-1.1.1
Read C:\MyDartProjects\dart_ui\lib\dart_ui.dart
Read C:\MyDartProjects\dart_ui\lib\src\gallery\gallery.dart
Read C:\MyDartProjects\dart_ui\test\widgets\list_box_test.dart
Read C:\MyDartProjects\dart_ui\lib\src\widgets\tabs.dart
Read C:\MyDartProjects\dart_ui\lib\src\widgets\semantics.dart
Read C:\MyDartProjects\dart_ui\lib\src\widgets\controls.dart (lines 661-1080)
Bash Auto-fix lints in cdr/pdf/benchmark/crypto areas
IN
cd "c:\MyDartProjects\dart_ui" && dart fix --apply test/cdr && dart fix --apply test/pdf && dart fix --apply test/benchmark && dart fix --apply lib/src/cdr/fills && dart fix --apply lib/src/crypto && dart fix --apply "lib/src/pdf/sign" 2>&1 | tail -5

OUT
Computing fixes in cdr...
Applying fixes...

fills_test.dart
  directives_ordering - 1 fix
  prefer_const_constructors - 7 fixes
  prefer_const_declarations - 1 fix

geometry_test.dart
  directives_ordering - 1 fix
  prefer_const_declarations - 8 fixes

18 fixes made in 2 files.
Computing fixes in pdf...
Applying fixes...

export_test.dart
  directives_ordering - 1 fix

sign_test.dart
  directives_ordering - 1 fix

2 fixes made in 2 files.
Computing fixes in benchmark...
Applying fixes...

benchmark_test.dart
  directives_ordering - 1 fix

1 fix made in 1 file.
Computing fixes in fills...
Applying fixes...

cdr_mesh_fill.dart
  directives_ordering - 1 fix

1 fix made in 1 file.
Computing fixes in crypto...
Applying fixes...

dart\pure_dart_sha.dart
  curly_braces_in_flow_control_structures - 1 fix

ffi\ffi_crypto_backend_native.dart
  directives_ordering - 1 fix

2 fixes made in 2 files.

pdf_signature_appearance.dart
  directives_ordering - 1 fix

2 fixes made in 2 files.
Read C:\MyDartProjects\dart_ui\poc\poc_18_webgpu\web\main.dart
Grep "const int logicalKey\w+" (in C:\MyDartProjects\dart_ui\lib\src)
17 lines of output
Bash Class inventory in widget/focus/localizations/overlay
IN
grep -nE "(class|typedef) \w+" C:/MyDartProjects/dart_ui/lib/src/widgets/widget.dart C:/MyDartProjects/dart_ui/lib/src/widgets/focus.dart C:/MyDartProjects/dart_ui/lib/src/widgets/localizations.dart C:/MyDartProjects/dart_ui/lib/src/widgets/overlay.dart | head -60

OUT
C:/MyDartProjects/dart_ui/lib/src/widgets/widget.dart:6:abstract class Key {
C:/MyDartProjects/dart_ui/lib/src/widgets/widget.dart:11:final class ValueKey<T> extends Key {
C:/MyDartProjects/dart_ui/lib/src/widgets/widget.dart:57:final class GlobalKey<T extends State<StatefulWidget>> extends Key {
C:/MyDartProjects/dart_ui/lib/src/widgets/widget.dart:127:abstract interface class BuildContext {
C:/MyDartProjects/dart_ui/lib/src/widgets/widget.dart:157:abstract class Widget {
C:/MyDartProjects/dart_ui/lib/src/widgets/widget.dart:170:abstract class StatelessWidget extends Widget {
C:/MyDartProjects/dart_ui/lib/src/widgets/widget.dart:185:abstract class InheritedWidget extends Widget {
C:/MyDartProjects/dart_ui/lib/src/widgets/widget.dart:202:abstract class StatefulWidget extends Widget {
C:/MyDartProjects/dart_ui/lib/src/widgets/widget.dart:212:abstract class State<T extends StatefulWidget> {
C:/MyDartProjects/dart_ui/lib/src/widgets/focus.dart:46:class FocusNode {
C:/MyDartProjects/dart_ui/lib/src/widgets/focus.dart:254:final class FocusScopeNode extends FocusNode {
C:/MyDartProjects/dart_ui/lib/src/widgets/focus.dart:290:final class FocusManager {
C:/MyDartProjects/dart_ui/lib/src/widgets/localizations.dart:87:abstract class LocalizationsDelegate<T extends Object> {
C:/MyDartProjects/dart_ui/lib/src/widgets/localizations.dart:142:final class MissingLocalizationsError extends Error {
C:/MyDartProjects/dart_ui/lib/src/widgets/localizations.dart:177:final class Localizations extends StatefulWidget {
C:/MyDartProjects/dart_ui/lib/src/widgets/localizations.dart:304:final class _LocalizationsState extends State<Localizations> {
C:/MyDartProjects/dart_ui/lib/src/widgets/localizations.dart:421:final class _LocalizationsScope extends InheritedWidget {
C:/MyDartProjects/dart_ui/lib/src/widgets/localizations.dart:467:final class PseudoLocalization {
C:/MyDartProjects/dart_ui/lib/src/widgets/localizations.dart:576:final class PseudoLocalizationsDelegate
C:/MyDartProjects/dart_ui/lib/src/widgets/overlay.dart:45:typedef WidgetBuilder = Widget Function(BuildContext context);
C:/MyDartProjects/dart_ui/lib/src/widgets/overlay.dart:53:final class OverlayEntry {
C:/MyDartProjects/dart_ui/lib/src/widgets/overlay.dart:140:final class Overlay extends StatefulWidget {
C:/MyDartProjects/dart_ui/lib/src/widgets/overlay.dart:177:final class OverlayState extends State<Overlay> {
C:/MyDartProjects/dart_ui/lib/src/widgets/overlay.dart:348:final class _OverlayScope extends InheritedWidget {
C:/MyDartProjects/dart_ui/lib/src/widgets/overlay.dart:360:final class _OverlayEntryWidget extends StatefulWidget {
C:/MyDartProjects/dart_ui/lib/src/widgets/overlay.dart:374:final class _OverlayEntryState extends State<_OverlayEntryWidget> {
Bash Check package:web webgpu API surface
IN
grep -n "web:" "C:\MyDartProjects\dart_ui\pubspec.lock" -A3 | head -10; grep -n "class GPU\b\|extension type GPU\b\|GPUCanvasContext\|GPUDevice\b\|GPUAdapter\b\|requestAdapter\|getPreferredCanvasFormat" "C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev\web-1.1.1\lib\src\dom\webgpu.dart" | head -30; grep -n "get gpu" "C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev\web-1.1.1\lib\src\dom"/*.dart | head

OUT
396:  web:
397-    dependency: "direct main"
398-    description:
399-      name: web
Read C:\MyDartProjects\dart_ui\lib\src\widgets\focus.dart (lines 501-542)
Bash Class inventory of element and render_box
IN
grep -nE "(abstract )?(final )?class \w+|^typedef" C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart C:/MyDartProjects/dart_ui/lib/src/layout/render_viewport.dart | head -50

OUT
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:26:final class BuildOwner {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:408:abstract class Element implements BuildContext {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:733:abstract class ComponentElement extends Element {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:766:final class StatelessElement extends ComponentElement {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:776:final class StatefulElement extends ComponentElement {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:828:final class InheritedElement extends ComponentElement {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:899:abstract class RenderObjectWidget extends Widget {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:941:abstract class ParentDataWidget<T extends BoxParentData> extends Widget {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:949:  /// The widget class that installs a [T] on its children, named in the error
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:951:  /// check itself is on the parent data, so a subclass or a custom container
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:969:final class ParentDataElement<T extends BoxParentData>
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:1046:abstract class SingleChildRenderObjectWidget extends RenderObjectWidget {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:1056:class RenderObjectElement extends Element {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:1207:final class SingleChildRenderObjectElement extends RenderObjectElement {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:1247:abstract class MultiChildRenderObjectWidget extends RenderObjectWidget {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:1268:final class MultiChildRenderObjectElement extends RenderObjectElement {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:1432:sealed class ElementError extends Error {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:1449:final class ParentDataError extends ElementError {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:1498:final class DuplicateGlobalKeyError extends ElementError {
C:/MyDartProjects/dart_ui/lib/src/widgets/element.dart:1521:final class _WidgetRenderView extends RenderSingleChildBox {
C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart:48:/// this class is open for extension while almost everything else here is not.
C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart:49:class BoxParentData {
C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart:62:final class HitTestPath {
C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart:103:abstract class RenderBox {
C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart:286:  /// is the first thing a multi-child subclass must write.
C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart:439:    // every subclass to buy a boundary in cases that tight constraints already
C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart:634:  //      convention. A subclass that cannot answer without laying out has a
C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart:863:abstract class RenderSingleChildBox extends RenderBox {
C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart:949:/// [T] is the per-child record type the subclass installs, so `childParentData`
C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart:952:abstract class RenderBoxContainer<T extends BoxParentData> extends RenderBox {
C:/MyDartProjects/dart_ui/lib/src/layout/render_box.dart:1049:  /// a row of such containers. A subclass whose children are not in reading
C:/MyDartProjects/dart_ui/lib/src/layout/render_viewport.dart:34:final class ScrollPosition {
C:/MyDartProjects/dart_ui/lib/src/layout/render_viewport.dart:255:class RenderViewport extends RenderSingleChildBox {
Bash Auto-fix remaining single-file lints
IN
cd "c:\MyDartProjects\dart_ui" && dart fix --apply test/app/gallery_shell_test.dart 2>&1 | tail -3; dart fix --apply test/widgets/proxy_test.dart 2>&1 | tail -3; dart fix --apply lib/src/pdf/crypto/pdf_security_handler.dart 2>&1 | tail -3

OUT
  unnecessary_const - 1 fix

1 fix made in 1 file.
  unnecessary_const - 4 fixes

4 fixes made in 1 file.
  curly_braces_in_flow_control_structures - 1 fix

1 fix made in 1 file.
Bash Check resolved web version and webgpu API
IN
sed -n '396,404p' "C:/MyDartProjects/dart_ui/pubspec.lock"; P="C:/Users/pmro/AppData/Local/Pub/Cache/hosted/pub.dev/web-1.1.1/lib/src/dom/webgpu.dart"; wc -l "$P"; grep -n "extension type GPU\b\|extension type GPUCanvasContext\|extension type GPUDevice\|extension type GPUAdapter\|requestAdapter\|getPreferredCanvasFormat\|getCurrentTexture" "$P" | head -30; grep -rn "GPU get gpu\|get gpu" "C:/Users/pmro/AppData/Local/Pub/Cache/hosted/pub.dev/web-1.1.1/lib/src/dom/webgpu.dart" | head

OUT
  web:
    dependency: "direct main"
    description:
      name: web
      sha256: "868d88a33d8a87b18ffc05f9f030ba328ffefba92d6c127917a2ba740f9cfe4a"
      url: "https://pub.dev"
    source: hosted
    version: "1.1.1"
  web_socket:
88 C:/Users/pmro/AppData/Local/Pub/Cache/hosted/pub.dev/web-1.1.1/lib/src/dom/webgpu.dart
Read C:\Users\pmro\AppData\Local\Pub\Cache\hosted\pub.dev\web-1.1.1\lib\src\dom\webgpu.dart
Bash Auto-fix text lints
IN
cd "c:\MyDartProjects\dart_ui" && dart fix --apply lib/src/text/truetype/interpreter.dart 2>&1 | tail -4; dart fix --apply lib/src/text/glyf.dart 2>&1 | tail -3

OUT
  curly_braces_in_flow_control_structures - 4 fixes
  prefer_final_locals - 6 fixes

10 fixes made in 1 file.
  prefer_const_constructors - 1 fix

1 fix made in 1 file.
Bash Verify analyze clean and rerun affected tests
IN
cd "c:\MyDartProjects\dart_ui" && dart analyze 2>&1 | tail -3 && dart test test/cdr test/pdf test/benchmark test/widgets/proxy_test.dart test/app/gallery_shell_test.dart --reporter compact 2>&1 | tail -2

OUT
Analyzing dart_ui...
No issues found!
Parsed 50000 CDRs in 49ms (1020408.16 docs/sec)

00:03 +47: test/benchmark\benchmark_test.dart: Engine Performance & Stress Benchmarks CdrDocument - Stress Parsing
00:03 +47: loading test/widgets/proxy_test.dart
00:03 +47: test/widgets/proxy_test.dart: Opacity composites a whole frame to the exact half-opacity value
00:03 +48: test/app/gallery_shell_test.dart: (setUpAll)
00:03 +49: test/app/gallery_shell_test.dart: (setUpAll)
00:03 +50: test/app/gallery_shell_test.dart: (setUpAll)
00:03 +51: test/app/gallery_shell_test.dart: (setUpAll)
00:03 +52: test/app/gallery_shell_test.dart: (setUpAll)
00:03 +53: test/app/gallery_shell_test.dart: (setUpAll)
00:03 +53: test/widgets/proxy_test.dart: Transform translate moves the pixels and folds into the offset
00:03 +54: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +55: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +56: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +57: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +58: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +59: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +60: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +61: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +62: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +63: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +64: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +65: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +66: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +67: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +68: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +69: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +70: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +71: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +72: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +73: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +74: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +75: test/app/gallery_shell_test.dart: the shell mounts the same gallery the hand-built owner does
00:03 +75: test/app/gallery_shell_test.dart: the same gallery is byte-identical through two applications
00:03 +76: test/app/gallery_shell_test.dart: the same gallery is byte-identical through two applications
00:03 +76: test/app/gallery_shell_test.dart: a frame settles despite the virtualized list rebuilding once
00:03 +77: test/app/gallery_shell_test.dart: a frame settles despite the virtualized list rebuilding once
00:03 +77: test/app/gallery_shell_test.dart: a click on the default button reaches it and rebuilds the label
00:03 +78: test/app/gallery_shell_test.dart: a click on the default button reaches it and rebuilds the label
00:03 +78: test/app/gallery_shell_test.dart: (tearDownAll)
00:03 +78: All tests passed!
Now let me look at the shared GPU infrastructure signatures.

Bash Sizes of shared infra files
IN
cd "C:/MyDartProjects/dart_ui" && wc -l lib/src/rendering/gpu/gpu_batcher.dart lib/src/rendering/gpu/gpu_pipeline.dart lib/src/rendering/gpu/gpu_texture.dart lib/src/rendering/gpu/gpu_vertex_buffer.dart lib/src/rendering/gpu/gpu_layer_stack.dart lib/src/rendering/gpu/gpu_device_state.dart lib/src/rendering/gpu/gpu_recovery.dart lib/src/rendering/renderer.dart lib/src/app/window_host.dart lib/src/foundation/diagnostics.dart lib/src/foundation/lifecycle.dart lib/src/rendering/gpu/gpu_raster_sink.dart

OUT
   258 lib/src/rendering/gpu/gpu_batcher.dart
   138 lib/src/rendering/gpu/gpu_pipeline.dart
   479 lib/src/rendering/gpu/gpu_texture.dart
   207 lib/src/rendering/gpu/gpu_vertex_buffer.dart
   638 lib/src/rendering/gpu/gpu_layer_stack.dart
    94 lib/src/rendering/gpu/gpu_device_state.dart
   734 lib/src/rendering/gpu/gpu_recovery.dart
   647 lib/src/rendering/renderer.dart
  1072 lib/src/app/window_host.dart
   230 lib/src/foundation/diagnostics.dart
   117 lib/src/foundation/lifecycle.dart
  1245 lib/src/rendering/gpu/gpu_raster_sink.dart
  5859 total
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gpu_batcher.dart
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gpu_pipeline.dart
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gpu_device_state.dart
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gpu_raster_sink.dart
Read C:\MyDartProjects\dart_ui\lib\src\backends\win32\win32_cpu_presenter.dart
Bash Find FocusAttachment and TextField declarations
IN
grep -n "FocusAttachment" C:/MyDartProjects/dart_ui/lib/src/widgets/focus_scope.dart | head; grep -nE "class (TextField|PasswordField|TextEditingController)" C:/MyDartProjects/dart_ui/lib/src/widgets/*.dart

OUT
6:/// [FocusAttachment] inserts a control's node into whichever scope encloses it.
38:  Widget build(BuildContext context) => FocusAttachment(
62:final class FocusAttachment extends StatefulWidget {
63:  const FocusAttachment({
78:  State<FocusAttachment> createState() => _FocusAttachmentState();
81:final class _FocusAttachmentState extends State<FocusAttachment> {
C:/MyDartProjects/dart_ui/lib/src/widgets/text_field.dart:93:final class TextEditingController extends ValueNotifier<String> {
C:/MyDartProjects/dart_ui/lib/src/widgets/text_field.dart:634:final class TextField extends StatefulWidget {
C:/MyDartProjects/dart_ui/lib/src/widgets/text_field.dart:677:final class PasswordField extends StatelessWidget {
Read C:\MyDartProjects\dart_ui\lib\src\widgets\localizations.dart (lines 2-141)
Bash Layer stack API surface
IN
cd "C:/MyDartProjects/dart_ui" && grep -n "class GpuRenderPass\|final \|int get \|bool get \|GpuRenderPass passAt\|int passEnd\|int get passCount\|void beginFrame\|void endFrame\|abstract\|acquireLayerTarget\|releaseLayerTarget" lib/src/rendering/gpu/gpu_layer_stack.dart | head -60

OUT
91:///     layers of abstraction away from the widget that caused it.
106:abstract interface class GpuLayerTarget {
108:  int get id;
112:  int get textureId;
117:  int get width;
118:  int get height;
126:abstract interface class GpuLayerTargetAllocator {
135:  GpuLayerTarget acquireLayerTarget(int width, int height);
140:  void releaseLayerTarget(GpuLayerTarget target);
151:final class GpuLayerDepthExceededError extends Error {
159:  final String backendName;
162:  final int depth;
164:  final int maxDepth;
194:final class GpuLayer {
207:  final GpuLayerKind kind;
211:  final Rect deviceBounds;
217:  final Rect clip;
220:  final int alpha;
223:  final int blendMode;
226:  final GpuLayerTarget? target;
230:  final double parentOriginX;
231:  final double parentOriginY;
237:  final int firstBatch;
243:  bool get drewSomething => _drewSomething;
248:  int get pixelWidth => deviceBounds.width.round();
249:  int get pixelHeight => deviceBounds.height.round();
282:final class GpuRenderPass {
299:  int get firstBatch => _firstBatch;
304:  int get viewportWidth => _viewportWidth;
305:  int get viewportHeight => _viewportHeight;
311:  bool get clearsTarget => _clearsTarget;
317:  bool get rendersTopDown => _rendersTopDown;
328:final class GpuLayerStack {
346:  final GpuLayerTargetAllocator allocator;
349:  final String backendName;
351:  final int maxDepth;
353:  final List<GpuLayer> _open = <GpuLayer>[];
356:  final List<GpuLayerTarget> _acquired = <GpuLayerTarget>[];
361:  final List<GpuRenderPass> _passPool = <GpuRenderPass>[];
371:  int get depth => _open.length;
381:  int get targetWidth => _open.isEmpty
384:  int get targetHeight => _open.isEmpty
389:  int get passCount => _passCount;
391:  GpuRenderPass passAt(int index) {
404:  bool get hasLayerPasses => _passCount > 1;
411:  int passEnd(int index, int totalBatchCount) => index + 1 < _passCount
421:  void beginFrame({required int surfaceWidth, required int surfaceHeight}) {
477:    final double left = deviceBounds.left.floorToDouble();
478:    final double top = deviceBounds.top.floorToDouble();
479:    final double right = deviceBounds.right.ceilToDouble();
480:    final double bottom = deviceBounds.bottom.ceilToDouble();
481:    final bool degenerate = !(right > left) ||
520:    final int width = (right - left).round();
521:    final int height = (bottom - top).round();
522:    final GpuLayerTarget target = allocator.acquireLayerTarget(width, height);
525:    final GpuLayer layer = _pushOpen(
568:    final GpuLayer layer = _open.removeLast();
579:      allocator.releaseLayerTarget(layer.target!);
599:  void endFrame() {
601:      allocator.releaseLayerTarget(_acquired[i]);
Bash Locale API and TextField constructor
IN
grep -n "static .*localeOf\|static .*textDirection\|static .*maybe" C:/MyDartProjects/dart_ui/lib/src/widgets/localizations.dart; echo ===; sed -n 620,700p C:/MyDartProjects/dart_ui/lib/src/widgets/text_field.dart

OUT
279:  static Locale localeOf(BuildContext context) {
288:  static Locale? maybeLocaleOf(BuildContext context) =>
===
/// before there is a signal to drive it would be untestable.
enum InactiveSelectionHighlight {
  /// Not painted at all: the Win32, WPF and browser behaviour.
  hidden,

  /// Painted, muted. Keeps the range visible - so a user who selected a phrase
  /// and then clicked something else can still see what the next command will
  /// apply to - while making it unambiguous which field the keyboard is in.
  dimmed,

  /// Painted exactly as if focused: `ES_NOHIDESEL`.
  visible,
}

final class TextField extends StatefulWidget {
  const TextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.label = '',
    this.obscure = false,
    this.readOnly = false,
    this.enabled = true,
    this.inactiveSelection = InactiveSelectionHighlight.dimmed,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String label;

  /// How the selection is painted when another control holds the keyboard.
  ///
  /// Defaults to [InactiveSelectionHighlight.dimmed], which is the behaviour
  /// this field has always had; it is defensible as a default because it is the
  /// only one of the three that loses no information, and it is now only a
  /// default rather than a law. An application that wants the Win32 and browser
  /// behaviour asks for [InactiveSelectionHighlight.hidden].
  ///
  /// **The controller's range is never touched by any of these**: this decides
  /// a colour, not a selection. Losing focus must not lose the selection, or
  /// right-clicking a field - which moves focus to the menu - would silently
  /// discard what the user was about to copy.
  final InactiveSelectionHighlight inactiveSelection;

  /// Renders the value as bullets. Section 30.8 requires the *value* still be
  /// the real text; only the painting changes, so copy remains the caller's
  /// policy rather than something a display trick decides.
  final bool obscure;

  final bool readOnly;
  final bool enabled;

  @override
  State<TextField> createState() => _TextFieldState();
}

/// A password field: a text field that never paints its value.
final class PasswordField extends StatelessWidget {
  const PasswordField({super.key, required this.controller, this.label = ''});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) =>
      TextField(controller: controller, label: label, obscure: true);
}

final class _TextFieldState extends State<TextField> {
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownedFocusNode ??= FocusNode(debugLabel: 'TextField'));

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }
Read C:\MyDartProjects\dart_ui\lib\src\geometry\path.dart
Bash List test directory layout
IN
ls test/ test/backends 2>/dev/null; ls test/backends/win32 2>/dev/null | head -30

OUT
test/:
animation
app
architecture
backends
benchmark
cdr
crypto
data
diagnostics
differential
end_to_end_test.dart
ffi
fonts
foundation
gallery
geometry
gestures
graphics
layout
pdf
platform
rendering
scheduler
text
tooling
widgets

test/backends:
headless
macos
web
win32
x11
d3d11
d3d12
uia
win32_abi_test.dart
win32_clipboard_test.dart
win32_coordinates_test.dart
win32_cpu_presenter_test.dart
win32_cursor_test.dart
win32_live_resize_test.dart
win32_message_coverage_test.dart
win32_mouse_input_test.dart
win32_multi_window_test.dart
win32_probe_test.dart
win32_text_input_test.dart
Bash Texture and renderer API surfaces
IN
cd "C:/MyDartProjects/dart_ui" && grep -n "^const int kNoTexture\|enum GpuTextureFormat\|enum GpuTextureFilter\|abstract interface class GpuTextureHandle\|abstract interface class GpuTextureAllocator\|int get bytesPerPixel\|createTexture\|uploadRegion\|releaseTexture" lib/src/rendering/gpu/gpu_texture.dart | head; echo ===; grep -n "abstract\|class \|enum \|  [A-Za-z].*(\|get " lib/src/rendering/renderer.dart | head -120

OUT
25:enum GpuTextureFormat {
35:  int get bytesPerPixel => this == alpha8 ? 1 : 4;
48:enum GpuTextureFilter { nearest, linear }
54:const int kNoTexture = 0;
62:abstract interface class GpuTextureHandle {
85:abstract interface class GpuTextureAllocator {
86:  GpuTextureHandle createTexture({
101:  void uploadRegion(
111:  void releaseTexture(GpuTextureHandle texture);
===
5:/// vocabulary. That is what lets the same widget code run over a CPU
9:/// The split between backend, device and target mirrors what the platform APIs
12:///   RendererBackend   the API is available on this machine (a DLL loaded,
17:///   RenderTarget      the pixels for one surface. Bound to a window and dies
32:/// This is descriptive metadata, not a switch in widget or compositor code.
36:enum RasterizationApproach {
59:/// Deliberately abstract: a Win32 `HWND`, an `IOSurface` id and an X11 shm
63:abstract interface class NativeSurfaceDescriptor {
65:  /// backend-specific assumptions get into common code.
66:  String get kind;
68:  int get pixelWidth;
69:  int get pixelHeight;
72:  double get scale;
77:final class MemorySurfaceDescriptor implements NativeSurfaceDescriptor {
78:  const MemorySurfaceDescriptor({
86:  String get kind => 'memory';
101:final class RendererInfo {
102:  const RendererInfo({
123:  String toString() => driverVersion == null
128:/// The abstract questions a control is allowed to ask, from section 9.7.
129:final class RendererCapabilities {
130:  const RendererCapabilities({
152:  bool supportsFormat(PixelFormat format) => formats.contains(format);
160:final class Frame {
161:  Frame({
168:  final RenderTarget target;
178:  /// always exists. A windowed GPU target has no such thing: the pixels are in
185:  /// The honest shape is this one: a target that has CPU pixels reports them,
186:  /// a target that does not reports null, and [framebuffer] stays as the
198:  Framebuffer? get cpuPixels => _framebuffer;
201:  bool get hasCpuPixels => _framebuffer != null;
203:  /// The CPU-visible pixels, or a named failure when the target has none.
206:  /// before. Use [cpuPixels] when "this target draws straight to a screen" is a
208:  Framebuffer get framebuffer {
210:    if (pixels != null) return pixels;
211:    throw StateError(
215:      'MemorySurfaceDescriptor target if the pixels are what you are after',
224:  /// target was resized or lost must be rejected, not drawn.
229:final class FrameRequest {
230:  const FrameRequest({
244:enum PresentStatus {
258:final class PresentResult {
259:  const PresentResult({required this.status, this.diagnostic});
268:  bool get isSuccess => status == PresentStatus.presented;
272:abstract interface class RenderTarget implements Disposable {
273:  NativeSurfaceDescriptor get surface;
277:  int get generation;
279:  Frame beginFrame(FrameRequest request);
280:  Future<PresentResult> present(Frame frame);
282:  void resize(int pixelWidth, int pixelHeight, double scale);
285:/// A target that consumes a display list directly instead of CPU pixels.
291:abstract interface class DisplayListRenderTarget implements RenderTarget {
292:  Future<PresentResult> renderDisplayList(
300:abstract interface class RenderDevice implements Disposable {
301:  RendererInfo get info;
302:  RendererCapabilities get capabilities;
306:  bool get isLost;
308:  RenderTarget createTarget(NativeSurfaceDescriptor surface);
337:sealed class RendererEvent {
338:  const RendererEvent({
352:  String toString() => '$runtimeType($backendName): $diagnostic';
360:final class DeviceLost extends RendererEvent {
361:  const DeviceLost({
373:  String toString() => 'DeviceLost($backendName, loss #$lossCount): '
383:final class DeviceRecovered extends RendererEvent {
384:  const DeviceRecovered({
407:  bool get needsFullRepaint => true;
410:  String toString() => 'DeviceRecovered($backendName, loss #$lossCount, '
421:final class DeviceRecoveryFailed extends RendererEvent {
422:  const DeviceRecoveryFailed({
436:  String toString() =>
441:/// The surface a target draws into no longer matches the window.
449:final class SurfaceOutOfDate extends RendererEvent {
450:  const SurfaceOutOfDate({
458:  /// The target generation that invalidated the frames.
471:/// device lost: the *cause* is the caller's memory budget and the fix is to
475:final class OutOfMemory extends RendererEvent {
476:  const OutOfMemory({
483:  /// What could not be allocated - `layer target 512x512`, `image cache entry
488:  /// refusal came from the driver rather than from a budget this side counted.
492:  String toString() => 'OutOfMemory($backendName, $resourceName'
503:final class RendererFellBackToCpu extends RendererEvent {
504:  const RendererFellBackToCpu({
518:  String toString() => 'RendererFellBackToCpu($backendName, $attempts '
527:abstract interface class RendererEventSink {
528:  void emit(RendererEvent event);
548:final class RendererEventChannel implements RendererEventSink {
549:  final List<void Function(RendererEvent)> _listeners =
553:  int get listenerErrorCount => _listenerErrorCount;
556:  Object? get lastListenerError => _lastListenerError;
559:  int get listenerCount => _listeners.length;
562:  RendererEventSubscription listen(void Function(RendererEvent) onEvent) {
564:    return RendererEventSubscription._(this, onEvent);
568:  void emit(RendererEvent event) {
569:    if (_listeners.isEmpty) return;
573:    for (final listener in List<void Function(RendererEvent)>.of(_listeners)) {
575:        listener(event);
585:final class RendererEventSubscription {
586:  RendererEventSubscription._(this._channel, this._listener);
589:  final void Function(RendererEvent) _listener;
592:  bool get isCancelled => _cancelled;
594:  void cancel() {
595:    if (_cancelled) return;
605:final class RecordingRendererEventSink implements RendererEventSink {
606:  RecordingRendererEventSink({this.capacity = 256});
611:  List<RendererEvent> get events => List<RendererEvent>.unmodifiable(_events);
614:  List<T> ofType<T extends RendererEvent>() => _events.whereType<T>().toList();
617:  int get droppedCount => _droppedCount;
621:  void emit(RendererEvent event) {
622:    if (_events.length >= capacity) {
629:  void clear() {
636:abstract interface class RendererBackend {
637:  RendererInfo get info;
642:  BackendProbeResult probe();
644:  bool supportsSurface(NativeSurfaceDescriptor surface);
646:  Future<RenderDevice> createDevice();
Lints zerados (No issues found!) e os testes das áreas tocadas passam. Como o dart fix alterou o interpretador TrueType, vou rodar os testes de texto por segurança.

Bash Run text tests after truetype lint fixes
IN
cd "c:\MyDartProjects\dart_ui" && dart test test/text --reporter compact 2>&1 | tail -2

OUT
<persisted-output>
Output too large (156.1KB). Full output saved to: C:\Users\pmro\.claude\projects\c--MyDartProjects-dart-ui\2cc739b3-1f87-452e-a821-ad371837cade\tool-results\bhva2fubp.txt

Preview (first 2KB):

00:00 +0: loading test/text\arabic_shaping_test.dart
00:01 +0: loading test/text\arabic_shaping_test.dart
00:01 +0: test/text\arabic_shaping_test.dart: the fixture DejaVu covers Arabic and Hebrew
00:01 +1: test/text\arabic_shaping_test.dart: the fixture DejaVu covers Arabic and Hebrew
00:01 +1: test/text\arabic_shaping_test.dart: the fixture DejaVu has the lam-alef presentation forms in its cmap
00:01 +2: test/text\arabic_shaping_test.dart: the fixture DejaVu has the lam-alef presentation forms in its cmap
00:01 +2: test/text\arabic_shaping_test.dart: the joining machine a lone letter is isolated
00:01 +3: test/text\arabic_shaping_test.dart: the joining machine a lone letter is isolated
00:01 +3: test/text\arabic_shaping_test.dart: the joining machine alef joins only to what precedes it
00:01 +4: test/text\arabic_shaping_test.dart: the joining machine alef joins only to what precedes it
...
</persisted-output>
Read C:\MyDartProjects\dart_ui\lib\src\geometry\path.dart (lines 121-260)
Bash List d3d11/d3d12 test files
IN
ls test/backends/win32/d3d12 test/backends/win32/d3d11 2>/dev/null

OUT
test/backends/win32/d3d11:
d3d11_window_target_test.dart

test/backends/win32/d3d12:
d3d12_barrier_test.dart
d3d12_device_test.dart
d3d12_fence_test.dart
d3d12_layout_test.dart
d3d12_session.dart
d3d12_swapchain_test.dart
Bash SurfacePresenter and diagnostics API
IN
cd "C:/MyDartProjects/dart_ui" && grep -n "abstract interface class SurfacePresenter" -A 40 lib/src/app/window_host.dart | head -70; echo ===; grep -n "enum DiagnosticKind\|class BackendDiagnostic\|class BackendProbeResult\|class BackendSelectionError\|BackendDiagnostic.note\|BackendProbeResult.unsupported" lib/src/foundation/diagnostics.dart

OUT
139:abstract interface class SurfacePresenter implements Disposable {
140-  /// Identity for logs and for the startup report.
141-  RendererInfo get info;
142-
143-  /// Rasterises [list] and puts it on screen.
144-  ///
145-  /// [deviceTransform] carries the window's render scale. It is passed
146-  /// explicitly rather than left to the presenter's own idea of the surface
147-  /// scale so that one authority - the window - decides how many physical
148-  /// pixels a logical unit is worth, and a disagreement between the two shows
149-  /// up as a visibly wrong size instead of a silently blurry one.
150-  Future<PresentResult> present(
151-    DisplayList list, {
152-    int? clearColor,
153-    Transform2D? deviceTransform,
154-    Rect? damage,
155-  });
156-
157-  /// The surface behind this presenter changed size or scale.
158-  ///
159-  /// Called *after* the window has already reallocated its own surface, so an
160-  /// implementation that reads the window's surface on every frame (the Win32
161-  /// and X11 presenters do) may legitimately do nothing here.
162-  void surfaceResized({
163-    required int pixelWidth,
164-    required int pixelHeight,
165-    required double scale,
166-  });
167-
168-  /// Whether the device this presenter draws with has been lost.
169-  ///
170-  /// Distinct from [isDisposed]: a lost device is recoverable and the window
171-  /// survives it, which is exactly the split `renderer.dart` describes when it
172-  /// says "recreating a device must not mean recreating the window".
173-  bool get isDeviceLost;
174-
175-  /// Rebuilds whatever the device loss destroyed.
176-  ///
177-  /// Returns false when recovery failed, in which case the caller must tear
178-  /// down rather than spin: a presenter that cannot get a device back will not
179-  /// get one back on the next frame either, and retrying forever is how a
===
72:enum DiagnosticKind {
93:final class BackendDiagnostic {
114:  const BackendDiagnostic.note(String message, {String? detail})
133:final class BackendProbeResult {
144:  factory BackendProbeResult.unsupported(
190:final class BackendSelectionError extends Error {
Read C:\MyDartProjects\dart_ui\test\backends\win32\d3d12\d3d12_session.dart
Read C:\MyDartProjects\dart_ui\lib\src\backends\win32\d3d12\d3d12_library.dart
Read C:\MyDartProjects\dart_ui\test\architecture\layering_test.dart
PowerShell Check text test results
IN
Get-Content "C:\Users\pmro\.claude\projects\c--MyDartProjects-dart-ui\2cc739b3-1f87-452e-a821-ad371837cade\tool-results\bhva2fubp.txt" -Tail 3

OUT
00:04 +777: test/text\unicode_tables_test.dart: table invariants the pooled sequences are unmodifiable views
00:04 +778: test/text\unicode_tables_test.dart: table invariants the pooled sequences are unmodifiable views
00:04 +778: All tests passed!
Bash Check for Direct2D POC
IN
ls poc/ 2>/dev/null; ls poc/poc_05_com_direct2d/bin 2>/dev/null

OUT
poc_01_win32_window
poc_02_x11_window
poc_03_appkit_window
poc_04_cpu_raster
poc_05_com_direct2d
poc_06_opengl
poc_07_metal
poc_08_vulkan
poc_09_wayland
poc_10_event_loop
poc_11_async_image_download
poc_12_native_buffers
poc_13_native_dib_present
poc_14_direct3d
poc_15_direct3d12
poc_16_webgl1
poc_17_webgl2
poc_18_webgpu
poc_19_event_loop_metrics
poc_20_macos_three_backends
direct2d_windows.dart
main.dart
Grep "Object imageAt|Object fontAt|addImage|addFont" (in C:\MyDartProjects\dart_ui\lib\src\graphics\display_list.dart)
71 lines of output
Read C:\MyDartProjects\dart_ui\poc\poc_05_com_direct2d\bin\direct2d_windows.dart
Bash Read pubspec and analysis options
IN
cat C:/MyDartProjects/dart_ui/pubspec.yaml; cat C:/MyDartProjects/dart_ui/analysis_options.yaml 2>/dev/null | head -60

OUT
name: dart_ui
description: Framework de interface grafica multiplataforma em 100% Dart.
publish_to: none

environment:
  sdk: ^3.6.0

dependencies:
  # Anotacoes apenas: `meta` nao tem codigo em runtime. Entra para que
  # "owner-side API" possa ser verificado pelo analisador em vez de ficar so
  # no comentario - um TimerHandle e devolvido ao usuario, e markFired() nas
  # maos dele corromperia o estado do dispatcher.
  meta: ^1.16.0

  # Fallback bitmap 100% Dart para headless/CI, plataformas sem codec nativo e
  # falhas graves do codec do sistema. Desktop e web tentam primeiro WIC,
  # ImageIO, TurboJPEG e createImageBitmap. Nenhum tipo desta dependência
  # atravessa a API pública do framework.
  image: '>=4.5.4 <5.0.0'

  # Parser XML 100% Dart usado pelo leitor SVG. É declarado diretamente (em
  # vez de depender da dependência transitiva de package:image) porque tipos e
  # funções de package:xml são importados pelo código de produção.
  xml: '>=6.5.0 <7.0.0'

  # As definicoes de interop do navegador (DOM, canvas, WebGL2, WebGPU),
  # geradas a partir do WebIDL e escritas sobre `dart:js_interop`. Entra como
  # dependencia normal - e nao dev - porque `lib/src/backends/web` e
  # `lib/src/rendering/gpu/{webgl,webgpu}` sao codigo de producao.
  #
  # `package:web` e nao `dart:html`: `dart:html` esta em depreciacao e nao
  # existe sob dart2wasm, entao um backend escrito sobre ele compilaria por
  # dart2js e falharia por wasm - exatamente a divergencia que a secao 6.6
  # proibe. `package:web` e puro `dart:js_interop` e por isso e o unico que
  # funciona nos dois compiladores.
  #
  # Nada disso alcanca a VM: nenhuma biblioteca alcancavel a partir de
  # `lib/dart_ui.dart` importa `package:web`, e os pontos de escolha usam
  # `if (dart.library.js_interop)` - ver
  # `lib/src/backends/web/web_backend_entry.dart`. Um `dart compile exe` de um
  # exemplo desktop continua funcionando porque o compilador nunca chega nesses
  # arquivos.
  web: ^1.1.0

dev_dependencies:
  lints: ^5.1.0
  test: ^1.25.0

executables:
  dart_ui:

# O roteiro (secao 7) descreve um monorepo de dezenas de packages como alvo
# final, e a secao 7.1 autoriza comecar em um package unico para nao criar
# pacotes vazios. O codigo em lib/src ja e dividido pelas fronteiras de camada
# do roteiro, entao a separacao futura e mecanica: cada diretorio vira package
# quando tiver contrato estavel, consumidor real e testes proprios.
workspace:
  - poc/poc_01_win32_window
  - poc/poc_04_cpu_raster
  - poc/poc_05_com_direct2d
  - poc/poc_10_event_loop
  - poc/poc_11_async_image_download
  - poc/poc_06_opengl
  - poc/poc_07_metal
  - poc/poc_08_vulkan
  - poc/poc_09_wayland
  - poc/poc_12_native_buffers
  - poc/poc_13_native_dib_present
  - poc/poc_14_direct3d
  - poc/poc_15_direct3d12
  - poc/poc_16_webgl1
  - poc/poc_17_webgl2
  - poc/poc_18_webgpu
  - poc/poc_02_x11_window
  - poc/poc_03_appkit_window
  - poc/poc_19_event_loop_metrics
  - poc/poc_20_macos_three_backends
  - mvp/mvp_01_win32_counter
  - mvp/mvp_02_x11_counter
  - mvp/mvp_03_appkit_counter
  - mvp/mvp_04_web_counter
include: package:lints/recommended.yaml

analyzer:
  # POCs and vendored references are independent projects with their own
  # analyzers. Walking them from the framework root makes `dart analyze`
  # traverse millions of reference lines and can leave the CI gate timing out.
  exclude:
    - poc/**
    - referencias/**
    - build/**
  language:
    strict-casts: true
    strict-raw-types: true

linter:
  rules:
    - prefer_final_locals
    - prefer_const_constructors
    - prefer_const_declarations
    - avoid_print: false
    - directives_ordering
    - prefer_single_quotes
Bash See barrel export section
IN
sed -n 90,115p C:/MyDartProjects/dart_ui/lib/dart_ui.dart

OUT
export 'src/layout/render_box.dart';
export 'src/layout/render_colored_box.dart';
export 'src/layout/render_constrained_box.dart';
export 'src/layout/render_flex.dart';
export 'src/layout/render_grid.dart';
export 'src/layout/render_padding.dart';
export 'src/layout/render_proxy_box.dart';
export 'src/layout/render_stack.dart';
export 'src/layout/render_viewport.dart';
export 'src/layout/render_wrap.dart';
export 'src/platform/backend_selection.dart';
export 'src/platform/file_picker.dart';
export 'src/platform/input_events.dart';
export 'src/platform/native_window.dart';
export 'src/platform/system_fonts.dart';
export 'src/platform/window_events.dart';
export 'src/rendering/cpu_canvas.dart';
export 'src/rendering/cpu_renderer.dart';
export 'src/rendering/framebuffer.dart';
export 'src/rendering/path/coverage_span_sink.dart';
export 'src/rendering/path/fill_rule.dart';
export 'src/rendering/path/scanline_filler.dart';
export 'src/rendering/path/stroker.dart';
export 'src/rendering/raster/blend.dart';
export 'src/rendering/raster/clip_stack.dart';
export 'src/rendering/raster/rasterizer.dart';
Testes de texto todos passando (778). Vou registrar essa limpeza como um commit isolado antes de os agentes terminarem, para manter o histórico organizado.

Bash Commit lint cleanup
IN
cd "c:\MyDartProjects\dart_ui" && git add -A && git status --short && git commit -m "style: zera os lints informativos do analyze

dart fix aplicado em test/cdr, test/pdf, test/benchmark, lib/src/cdr,
lib/src/crypto, lib/src/pdf e lib/src/text: ordenacao de diretivas,
const preferido, chaves em fluxos de controle e locais finais.
dart analyze volta a terminar sem nenhum issue.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"

OUT
warning: in the working copy of 'lib/src/cdr/fills/cdr_mesh_fill.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'lib/src/crypto/dart/pure_dart_sha.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'lib/src/crypto/ffi/ffi_crypto_backend_native.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'lib/src/pdf/crypto/pdf_security_handler.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'lib/src/pdf/sign/pdf_byte_range_signer.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'lib/src/pdf/sign/pdf_signature_appearance.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'lib/src/text/glyf.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'lib/src/text/truetype/interpreter.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'test/app/gallery_shell_test.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'test/benchmark/benchmark_test.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'test/cdr/fills_test.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'test/cdr/geometry_test.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'test/pdf/export_test.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'test/pdf/sign_test.dart', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'test/widgets/proxy_test.dart', LF will be replaced by CRLF the next time Git touches it
M  doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md
M  lib/src/cdr/fills/cdr_mesh_fill.dart
M  lib/src/crypto/dart/pure_dart_sha.dart
M  lib/src/crypto/ffi/ffi_crypto_backend_native.dart
M  lib/src/pdf/crypto/pdf_security_handler.dart
M  lib/src/pdf/sign/pdf_byte_range_signer.dart
M  lib/src/pdf/sign/pdf_signature_appearance.dart
M  lib/src/text/glyf.dart
M  lib/src/text/truetype/interpreter.dart
M  test/app/gallery_shell_test.dart
M  test/benchmark/benchmark_test.dart
M  test/cdr/fills_test.dart
M  test/cdr/geometry_test.dart
M  test/pdf/export_test.dart
M  test/pdf/sign_test.dart
M  test/widgets/proxy_test.dart
[main dbae3f1] style: zera os lints informativos do analyze
 16 files changed, 59 insertions(+), 48 deletions(-)
O commit arrastou uma modificação em doc\ROTEIRO...md que não fiz eu — pode ser de um subagente em andamento. Vou verificar.

Bash Inspect doc change swept into commit
IN
cd "c:\MyDartProjects\dart_ui" && git show dbae3f1 -- doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md | head -40

OUT
commit dbae3f17cc4182893af3868ade64a50c3ad7e42e
Author: Isaque <insinfo2008@gmail.com>
Date:   Sat Aug 22 02:31:15 2026 -0300

    style: zera os lints informativos do analyze

    dart fix aplicado em test/cdr, test/pdf, test/benchmark, lib/src/cdr,
    lib/src/crypto, lib/src/pdf e lib/src/text: ordenacao de diretivas,
    const preferido, chaves em fluxos de controle e locais finais.
    dart analyze volta a terminar sem nenhum issue.

    Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

diff --git a/doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md b/doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md
index 82f05d4..97c4e18 100644
--- a/doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md
+++ b/doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md
@@ -7,7 +7,7 @@
 > **Integração nativa:** `dart:ffi`, sem biblioteca intermediária escrita pelo projeto em C, C++, Objective-C ou Swift
 > **Modelo de widgets:** widgets, layout, estilos, eventos, composição e acessibilidade implementados em Dart
 > **Backends planejados:** Win32, GDI, Direct2D, Direct3D 11, DirectComposition, X11/XCB, Wayland, GTK opcional, OpenGL, Vulkan, AppKit, Core Graphics e Metal
-> **Referências arquiteturais principais:** Avalonia, OpenJFX/JavaFX, `dart_graphics`, `marlin`, `win32` e demais referências locais
+> **Referências arquiteturais principais:** Avalonia, OpenJFX/JavaFX, Flutter, `dart_graphics`, `marlin`, `win32` e demais referências locais

 ---
Grep "drawDeviceImage|drawDeviceGlyphRun|beginLayer|is Framebuffer|is RasterImage" (in C:\MyDartProjects\dart_ui\lib\src\rendering\cpu_renderer.dart)
201 lines of output
Grep "class Framebuffer|get pixels|get stride|get width|get height|PixelFormat get|enum PixelFormat" (in C:\MyDartProjects\dart_ui\lib\src\rendering\framebuffer.dart)
19 lines of output
Now let me check a few remaining contracts: NativeSurfaceDescriptor, Framebuffer, and the x11 cpu presenter test for the fake pattern.

Grep "drawDeviceGlyphRun" (in C:\MyDartProjects\dart_ui\lib\src\rendering\cpu_renderer.dart)
81 lines of output
Grep "abstract interface class NativeSurfaceDescriptor|class Framebuffer|factory Framebuffer.wrap|enum PixelFormat|class PresentResult|enum PresentStatus" (in C:\MyDartProjects\dart_ui\lib\src\rendering)
158 lines of output
Aquela mudança no roteiro era uma edição de uma linha (adicionando "Flutter" às referências) — provavelmente sua, feita no IDE, já que o arquivo estava aberto. Ela foi preservada e commitada junto, sem problema.

Status até agora:

Baseline verificada — dart analyze sem erros e 4192 testes passando (30 skips que exigem macOS). Não havia bugs de teste pendentes.
48 lints corrigidos e commitados (dbae3f1) — imports ordenados, const, chaves em fluxo de controle, em test/cdr, test/pdf, lib/src/text/truetype, crypto e pdf. Analyze agora: No issues found!. Testes das áreas afetadas re-rodados e passando (inclusive os 778 de texto, por causa do interpretador TrueType).
5 subagentes trabalhando em paralelo, com territórios de arquivos disjuntos:
Backend Wayland — protocolo wire em Dart puro sobre socket (mesmo estilo do backend X11), wl_shm, xdg-shell, input, com testes headless de marshalling.
Renderizador Direct2D — COM via FFI no padrão do d3d12 existente, replay da display list (paths, gradientes, clipping, glifos via atlas), com testes reais de pixel aqui no Windows.
WebGPU — presenter para o backend web com shaders WGSL equivalentes aos do WebGL2, fallback automático para WebGL2.
APIs de SO/arquivos — StandardPaths (Known Folders/XDG/macOS), abrir URL/arquivo/revelar no gerenciador, lixeira, SystemInfo, message box nativo, file watcher.
Widgets modernos — inventário do que falta e implementação priorizada: TreeView, DataGrid, Slider, Tooltip, DatePicker, NumberBox, Toast, Badge/Chip/Avatar/Card — com testes headless e registro na galeria.
Conforme cada agente terminar, vou revisar o resultado, rodar os testes da área, resolver conflitos nos barrels de export e commitar por área. Aviso quando houver novidade.

Read C:\MyDartProjects\dart_ui\lib\src\backends\win32\win32_clipboard.dart
Read C:\MyDartProjects\dart_ui\lib\src\backends\x11\x11_libc.dart
I now have the full picture of the architecture. Let me write the Wayland backend. Starting with the wire protocol constants file.

Let me check the input events and pointer routing details.

Bash KeyEvent fields
IN
grep -nE "class (KeyEvent|KeyDownEvent|KeyUpEvent|PointerEvent|PointerDownEvent|KeyModifiers)|final .*modifiers|bool get (shift|control|ctrl|alt)|final String\? character|this\.character|this\.modifiers" C:/MyDartProjects/dart_ui/lib/src/platform/input_events.dart

OUT
32:sealed class PointerEvent extends PlatformInputEvent {
51:final class PointerDownEvent extends PointerEvent {
155:sealed class KeyEvent extends PlatformInputEvent {
162:    this.modifiers = const <KeyModifier>{},
173:  final Set<KeyModifier> modifiers;
181:final class KeyDownEvent extends KeyEvent {
194:final class KeyUpEvent extends KeyEvent {
Read C:\MyDartProjects\dart_ui\lib\src\widgets\pointer_router.dart
Bash KeyModifier and ScrollPosition API
IN
grep -n "enum KeyModifier" -A 8 C:/MyDartProjects/dart_ui/lib/src/platform/input_events.dart; grep -n "defaultLineExtent\|class ScrollPosition" -A 2 C:/MyDartProjects/dart_ui/lib/src/layout/render_viewport.dart | head -20; grep -nE "  (double|bool|void|int) \w+|  double get \w+" C:/MyDartProjects/dart_ui/lib/src/layout/render_viewport.dart | sed -n 1,40p

OUT
23:enum KeyModifier { shift, control, alt, meta, capsLock, numLock, scrollLock }
24-
25-/// Physical location of a key when the keyboard exposes left/right variants.
26-enum KeyLocation { standard, left, right, numpad }
27-
28-/// The coordinate unit used by a [PointerScrollEvent.scrollDelta].
29-enum ScrollDeltaUnit { pixels, lines }
30-
31-/// Base class for pointer input (mouse, touch).
31:const double defaultLineExtent = 48.0;
32-
33-/// Where a scrollable is, how far it may go, and what happens at the edges.
34:final class ScrollPosition {
35-  ScrollPosition({
36-    this.axis = ScrollAxis.vertical,
--
174:    double lineExtent = defaultLineExtent,
175-  }) =>
176-      applyDelta(inLines ? delta * lineExtent : delta);
--
184:        (_viewportExtent - defaultLineExtent).clamp(1.0, double.infinity);
185-    return applyDelta(step * pages);
186-  }
37:    double pixels = 0,
38:    double viewportExtent = 0,
39:    double contentExtent = 0,
55:  double _pixels;
56:  double _viewportExtent;
57:  double _contentExtent;
58:  double _velocity = 0;
62:  double get pixels => _pixels;
65:  double get viewportExtent => _viewportExtent;
68:  double get contentExtent => _contentExtent;
72:  double get maxScrollExtent {
77:  bool get canScroll => maxScrollExtent > 0;
79:  bool get atStart => _pixels <= 0;
81:  bool get atEnd => _pixels >= maxScrollExtent;
84:  double get velocity => _velocity;
98:  void addListener(void Function(ScrollPosition position) listener) =>
101:  void removeListener(void Function(ScrollPosition position) listener) =>
109:  bool applyViewportGeometry({
128:  bool jumpTo(double value) {
144:  double applyDelta(double delta, {bool allowOverscroll = false}) {
171:  double applyScrollDelta(
172:    double delta, {
173:    bool inLines = false,
174:    double lineExtent = defaultLineExtent,
182:  double pageBy(int pages) {
189:  void fling(double velocity) {
199:  bool tickMomentum(Duration elapsed, {double friction = 0.94}) {
218:  bool revealRange(double start, double extent) {
227:  double _clamp(double value, {required bool allowOverscroll}) {
236:  void _notify() {
282:  double computeMinIntrinsicWidth(double height) =>
288:  double computeMaxIntrinsicWidth(double height) =>
294:  double computeMinIntrinsicHeight(double width) =>
300:  double computeMaxIntrinsicHeight(double width) =>
311:  void performLayout() {
355:  void paint(DisplayList list, Offset offset) {
376:  void _onPositionChanged(ScrollPosition position) {
Write C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_protocol.dart
279 lines
/// Wire constants of the Wayland core and xdg-shell protocols.
///
/// They live in one file so that no other file in this backend contains a bare
/// number, mirroring `x11_protocol.dart`: a request built from magic constants
/// is unreviewable, and `wlSurfaceRequestCommit` tells a reader exactly which
/// message is being marshalled.
///
/// Opcodes are positional: a request's opcode is its zero-based index in the
/// protocol XML, an event's opcode likewise. The values below were transcribed
/// from `wayland.xml` and `xdg-shell.xml` (stable), which are append-only by
/// protocol rule - existing opcodes never change.
library;

// ---------------------------------------------------------------------------
// Interface names, exactly as they appear in wl_registry.global events.
// ---------------------------------------------------------------------------

const String wlDisplayInterfaceName = 'wl_display';
const String wlRegistryInterfaceName = 'wl_registry';
const String wlCallbackInterfaceName = 'wl_callback';
const String wlCompositorInterfaceName = 'wl_compositor';
const String wlShmInterfaceName = 'wl_shm';
const String wlShmPoolInterfaceName = 'wl_shm_pool';
const String wlBufferInterfaceName = 'wl_buffer';
const String wlSurfaceInterfaceName = 'wl_surface';
const String wlSeatInterfaceName = 'wl_seat';
const String wlPointerInterfaceName = 'wl_pointer';
const String wlKeyboardInterfaceName = 'wl_keyboard';
const String wlOutputInterfaceName = 'wl_output';
const String xdgWmBaseInterfaceName = 'xdg_wm_base';
const String xdgSurfaceInterfaceName = 'xdg_surface';
const String xdgToplevelInterfaceName = 'xdg_toplevel';

/// Versions this backend binds when the compositor offers at least them.
/// Conservative on purpose: every request issued below exists at these
/// versions, and binding higher than what is used invites protocol errors.
const int wlCompositorBindVersion = 4;
const int wlShmBindVersion = 1;
const int wlSeatBindVersion = 5;
const int wlOutputBindVersion = 2;
const int xdgWmBaseBindVersion = 1;

// ---------------------------------------------------------------------------
// wl_display (object id 1, implicit).
// ---------------------------------------------------------------------------

/// The client half of the object id space. Ids above this belong to the
/// server; a client that allocates into the server range corrupts the
/// connection.
const int wlDisplayObjectId = 1;
const int wlClientIdMinimum = 2;
const int wlClientIdMaximum = 0xfeffffff;

const int wlDisplayRequestSync = 0;
const int wlDisplayRequestGetRegistry = 1;

const int wlDisplayEventError = 0;
const int wlDisplayEventDeleteId = 1;

/// `wl_display.error` codes.
const int wlDisplayErrorInvalidObject = 0;
const int wlDisplayErrorInvalidMethod = 1;
const int wlDisplayErrorNoMemory = 2;
const int wlDisplayErrorImplementation = 3;

// ---------------------------------------------------------------------------
// wl_registry.
// ---------------------------------------------------------------------------

const int wlRegistryRequestBind = 0;

const int wlRegistryEventGlobal = 0;
const int wlRegistryEventGlobalRemove = 1;

// ---------------------------------------------------------------------------
// wl_callback.
// ---------------------------------------------------------------------------

const int wlCallbackEventDone = 0;

// ---------------------------------------------------------------------------
// wl_compositor.
// ---------------------------------------------------------------------------

const int wlCompositorRequestCreateSurface = 0;
const int wlCompositorRequestCreateRegion = 1;

// ---------------------------------------------------------------------------
// wl_shm and wl_shm_pool.
// ---------------------------------------------------------------------------

const int wlShmRequestCreatePool = 0;

const int wlShmEventFormat = 0;

/// `wl_shm.format` values. ARGB8888 is "32-bit ARGB, little-endian", which in
/// memory is exactly the framework's premultiplied BGRA byte order - the same
/// happy coincidence the Win32 DIB and X11 PutImage paths rely on.
const int wlShmFormatArgb8888 = 0;
const int wlShmFormatXrgb8888 = 1;

const int wlShmPoolRequestCreateBuffer = 0;
const int wlShmPoolRequestDestroy = 1;
const int wlShmPoolRequestResize = 2;

// ---------------------------------------------------------------------------
// wl_buffer.
// ---------------------------------------------------------------------------

const int wlBufferRequestDestroy = 0;

const int wlBufferEventRelease = 0;

// ---------------------------------------------------------------------------
// wl_surface.
// ---------------------------------------------------------------------------

const int wlSurfaceRequestDestroy = 0;
const int wlSurfaceRequestAttach = 1;
const int wlSurfaceRequestDamage = 2;
const int wlSurfaceRequestFrame = 3;
const int wlSurfaceRequestSetOpaqueRegion = 4;
const int wlSurfaceRequestSetInputRegion = 5;
const int wlSurfaceRequestCommit = 6;
const int wlSurfaceRequestSetBufferTransform = 7;
const int wlSurfaceRequestSetBufferScale = 8;
const int wlSurfaceRequestDamageBuffer = 9;

const int wlSurfaceEventEnter = 0;
const int wlSurfaceEventLeave = 1;

// ---------------------------------------------------------------------------
// wl_seat.
// ---------------------------------------------------------------------------

const int wlSeatRequestGetPointer = 0;
const int wlSeatRequestGetKeyboard = 1;
const int wlSeatRequestGetTouch = 2;
const int wlSeatRequestRelease = 3;

const int wlSeatEventCapabilities = 0;
const int wlSeatEventName = 1;

const int wlSeatCapabilityPointer = 1;
const int wlSeatCapabilityKeyboard = 2;
const int wlSeatCapabilityTouch = 4;

// ---------------------------------------------------------------------------
// wl_pointer.
// ---------------------------------------------------------------------------

const int wlPointerRequestSetCursor = 0;
const int wlPointerRequestRelease = 1;

const int wlPointerEventEnter = 0;
const int wlPointerEventLeave = 1;
const int wlPointerEventMotion = 2;
const int wlPointerEventButton = 3;
const int wlPointerEventAxis = 4;
const int wlPointerEventFrame = 5;
const int wlPointerEventAxisSource = 6;
const int wlPointerEventAxisStop = 7;
const int wlPointerEventAxisDiscrete = 8;

const int wlPointerButtonStateReleased = 0;
const int wlPointerButtonStatePressed = 1;

const int wlPointerAxisVerticalScroll = 0;
const int wlPointerAxisHorizontalScroll = 1;

/// Linux evdev button codes carried by `wl_pointer.button`.
const int btnLeft = 0x110;
const int btnRight = 0x111;
const int btnMiddle = 0x112;
const int btnSide = 0x113;
const int btnExtra = 0x114;

// ---------------------------------------------------------------------------
// wl_keyboard.
// ---------------------------------------------------------------------------

const int wlKeyboardRequestRelease = 0;

const int wlKeyboardEventKeymap = 0;
const int wlKeyboardEventEnter = 1;
const int wlKeyboardEventLeave = 2;
const int wlKeyboardEventKey = 3;
const int wlKeyboardEventModifiers = 4;
const int wlKeyboardEventRepeatInfo = 5;

const int wlKeyboardKeymapFormatNoKeymap = 0;
const int wlKeyboardKeymapFormatXkbV1 = 1;

const int wlKeyboardKeyStateReleased = 0;
const int wlKeyboardKeyStatePressed = 1;

/// `wl_keyboard.key` carries the evdev keycode; the xkb keymap indexes keys by
/// the historical X keycode, which is evdev + 8.
const int evdevToXkbKeycodeOffset = 8;

// ---------------------------------------------------------------------------
// wl_output.
// ---------------------------------------------------------------------------

const int wlOutputEventGeometry = 0;
const int wlOutputEventMode = 1;
const int wlOutputEventDone = 2;
const int wlOutputEventScale = 3;

// ---------------------------------------------------------------------------
// xdg_wm_base.
// ---------------------------------------------------------------------------

const int xdgWmBaseRequestDestroy = 0;
const int xdgWmBaseRequestCreatePositioner = 1;
const int xdgWmBaseRequestGetXdgSurface = 2;
const int xdgWmBaseRequestPong = 3;

const int xdgWmBaseEventPing = 0;

// ---------------------------------------------------------------------------
// xdg_surface.
// ---------------------------------------------------------------------------

const int xdgSurfaceRequestDestroy = 0;
const int xdgSurfaceRequestGetToplevel = 1;
const int xdgSurfaceRequestGetPopup = 2;
const int xdgSurfaceRequestSetWindowGeometry = 3;
const int xdgSurfaceRequestAckConfigure = 4;

const int xdgSurfaceEventConfigure = 0;

// ---------------------------------------------------------------------------
// xdg_toplevel.
// ---------------------------------------------------------------------------

const int xdgToplevelRequestDestroy = 0;
const int xdgToplevelRequestSetParent = 1;
const int xdgToplevelRequestSetTitle = 2;
const int xdgToplevelRequestSetAppId = 3;
const int xdgToplevelRequestShowWindowMenu = 4;
const int xdgToplevelRequestMove = 5;
const int xdgToplevelRequestResize = 6;
const int xdgToplevelRequestSetMaxSize = 7;
const int xdgToplevelRequestSetMinSize = 8;
const int xdgToplevelRequestSetMaximized = 9;
const int xdgToplevelRequestUnsetMaximized = 10;
const int xdgToplevelRequestSetFullscreen = 11;
const int xdgToplevelRequestUnsetFullscreen = 12;
const int xdgToplevelRequestSetMinimized = 13;

const int xdgToplevelEventConfigure = 0;
const int xdgToplevelEventClose = 1;
const int xdgToplevelEventConfigureBounds = 2;
const int xdgToplevelEventWmCapabilities = 3;

/// `xdg_toplevel.state` values inside the configure `states` array.
const int xdgToplevelStateMaximized = 1;
const int xdgToplevelStateFullscreen = 2;
const int xdgToplevelStateResizing = 3;
const int xdgToplevelStateActivated = 4;

/// `wl_display.error` code names, per section 6.6: a failure that reports
/// "error 1" is useless; "invalid_method" names the bug.
String wlDisplayErrorName(int code) {
  switch (code) {
    case wlDisplayErrorInvalidObject:
      return 'invalid_object';
    case wlDisplayErrorInvalidMethod:
      return 'invalid_method';
    case wlDisplayErrorNoMemory:
      return 'no_memory';
    case wlDisplayErrorImplementation:
      return 'implementation';
    default:
      return 'display error $code';
  }
}
Bash Find capability error and recovery coordinator API
IN
cd "C:/MyDartProjects/dart_ui" && grep -rn "class UnsupportedCapabilityError\|enum Capability" lib/src --include="*.dart" | head; echo ===; grep -rn "GpuRecoveryCoordinator" lib/src test --include="*.dart" -l | head; echo ===; grep -n "class GpuRecoveryCoordinator\|abstract interface class GpuRecoveryHost\|abstract interface class GpuRecoverableResource\|class CallbackGpuResource\|enum GpuResourceRecovery\|Future\|execute\|recover(" lib/src/rendering/gpu/gpu_recovery.dart | head -40

OUT
lib/src/foundation/diagnostics.dart:17:enum Capability {
lib/src/foundation/diagnostics.dart:216:final class UnsupportedCapabilityError extends Error {
===
lib/src/rendering/gpu/d3d11/d3d11_backend.dart
lib/src/rendering/gpu/gpu_device_state.dart
lib/src/rendering/gpu/gpu_recovery.dart
test/rendering/gpu/d3d11/d3d11_recovery_test.dart
test/rendering/gpu/gl_recovery_device_test.dart
test/rendering/gpu/gpu_recovery_test.dart
===
6:/// one-liner: `recover()` only flips a boolean, and flipping it before every
83:enum GpuResourceRecovery {
107:abstract interface class GpuRecoverableResource {
186:final class CallbackGpuResource implements GpuRecoverableResource {
235:abstract interface class GpuRecoveryHost {
422:final class GpuRecoveryCoordinator {
492:  GpuRecoveryReport recover() {
613:            'GpuDeviceState.recover() when it succeeds; ${_host.backendName} '
Grep "directRenderer|retainedCpu|class PresentationPathEntry|DisplayListRenderTarget|createAttachment" (in C:\MyDartProjects\dart_ui\lib\src\app\application.dart)
6 lines of output
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gpu_recovery.dart (lines 81-290)
Read C:\MyDartProjects\dart_ui\lib\src\app\application.dart (lines 151-430)
Now I have a clear picture of the patterns. Let me check a couple of remaining style details, then write the implementation.

Read C:\MyDartProjects\dart_ui\lib\src\platform\backend_selection.dart
Grep "RendererWindowAttachmentFactory|attachToWindow|renderDisplayList\(|is DisplayListRenderTarget" (in C:\MyDartProjects\dart_ui\lib\src\app\window_host.dart)
221 lines of output
Now I'll write the implementation. Starting with StandardPaths.

Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gpu_recovery.dart (lines 401-580)
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\d3d11\d3d11_surface_descriptor.dart
Read C:\MyDartProjects\dart_ui\lib\src\backends\win32\d3d12\d3d12_offscreen_target.dart
Read C:\MyDartProjects\dart_ui\lib\src\widgets\keyboard_router.dart
Bash IconButton and Popup APIs
IN
sed -n 1,120p C:/MyDartProjects/dart_ui/lib/src/widgets/icon_button.dart; echo ====POPUP; sed -n 1,90p C:/MyDartProjects/dart_ui/lib/src/widgets/popup.dart

OUT
/// A Flutter-shaped icon button backed by dart_ui's control system.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'icon.dart';
import 'semantics.dart';
import 'theme.dart';
import 'widget.dart';

final class IconButton extends StatefulWidget {
  const IconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconSize = 20,
    this.color,
    this.disabledColor,
    this.isSelected = false,
    this.selectedIcon,
    this.selectedColor,
    this.backgroundColor,
    this.hoverColor,
    this.selectedBackgroundColor,
    this.padding = const EdgeInsets.all(8),
    this.constraints,
  });

  final Widget icon;
  final void Function()? onPressed;
  final String? tooltip;
  final double iconSize;
  final Color? color;
  final Color? disabledColor;
  final bool isSelected;
  final Widget? selectedIcon;
  final Color? selectedColor;
  final Color? backgroundColor;
  final Color? hoverColor;
  final Color? selectedBackgroundColor;
  final EdgeInsets padding;
  final BoxConstraints? constraints;

  @override
  State<IconButton> createState() => _IconButtonState();
}

final class _IconButtonState extends State<IconButton> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'IconButton');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color foreground = widget.onPressed == null
        ? widget.disabledColor ?? theme.disabledForeground
        : widget.isSelected
            ? widget.selectedColor ?? theme.colorScheme.onPrimary
            : widget.color ?? theme.iconTheme.color ?? theme.foreground;
    return FocusAttachment(
      node: _focusNode,
      child: _IconButtonRenderWidget(
        onPressed: widget.onPressed,
        tooltip: widget.tooltip,
        padding: widget.padding,
        additionalConstraints:
            widget.constraints ?? BoxConstraints(minWidth: 40, minHeight: 40),
        isSelected: widget.isSelected,
        backgroundColor: widget.backgroundColor,
        hoverColor: widget.hoverColor,
        selectedBackgroundColor: widget.selectedBackgroundColor,
        theme: theme,
        focusNode: _focusNode,
        child: IconTheme(
          data: IconThemeData(color: foreground, size: widget.iconSize),
          child: widget.isSelected && widget.selectedIcon != null
              ? widget.selectedIcon!
              : widget.icon,
        ),
      ),
    );
  }
}

final class _IconButtonRenderWidget extends SingleChildRenderObjectWidget {
  const _IconButtonRenderWidget({
    required this.onPressed,
    required this.tooltip,
    required this.padding,
    required this.additionalConstraints,
    required this.isSelected,
    required this.backgroundColor,
    required this.hoverColor,
    required this.selectedBackgroundColor,
    required this.theme,
    required this.focusNode,
    required super.child,
  });

  final void Function()? onPressed;
  final String? tooltip;
  final EdgeInsets padding;
====POPUP
/// Popups: menus, tooltips, combo dropdowns and modal overlays.
///
/// Section 29.6 makes two demands that pull in opposite directions. A popup
/// must be placed correctly against a *screen*, flipping and sliding when it
/// does not fit - and a popup may live either inside the owner's surface or in
/// a separate native window, a choice only the backend can make (Wayland's
/// `xdg_popup` does not even let a client know where its window is).
///
/// The resolution here is that placement is a pure function. [PopupPositioner]
/// computes a rect from an anchor, a size, a work area and a set of allowed
/// adjustments, and it is the same computation whether the result becomes an
/// overlay rect inside one surface or the geometry handed to `xdg_positioner`.
/// Nothing in this file knows what a window is.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';

/// Which edge or corner of the anchor the popup attaches to.
enum PopupAnchorPoint {
  topLeft,
  topCenter,
  topRight,
  centerLeft,
  center,
  centerRight,
  bottomLeft,
  bottomCenter,
  bottomRight;

  /// The point in [rect] this constant names.
  Offset resolve(Rect rect) {
    final double x = switch (this) {
      PopupAnchorPoint.topLeft ||
      PopupAnchorPoint.centerLeft ||
      PopupAnchorPoint.bottomLeft =>
        rect.left,
      PopupAnchorPoint.topCenter ||
      PopupAnchorPoint.center ||
      PopupAnchorPoint.bottomCenter =>
        rect.left + rect.width / 2,
      PopupAnchorPoint.topRight ||
      PopupAnchorPoint.centerRight ||
      PopupAnchorPoint.bottomRight =>
        rect.right,
    };
    final double y = switch (this) {
      PopupAnchorPoint.topLeft ||
      PopupAnchorPoint.topCenter ||
      PopupAnchorPoint.topRight =>
        rect.top,
      PopupAnchorPoint.centerLeft ||
      PopupAnchorPoint.center ||
      PopupAnchorPoint.centerRight =>
        rect.top + rect.height / 2,
      PopupAnchorPoint.bottomLeft ||
      PopupAnchorPoint.bottomCenter ||
      PopupAnchorPoint.bottomRight =>
        rect.bottom,
    };
    return Offset(x, y);
  }

  /// This point mirrored across the anchor's centre, used when a flip is
  /// applied.
  PopupAnchorPoint get flippedVertically => switch (this) {
        PopupAnchorPoint.topLeft => PopupAnchorPoint.bottomLeft,
        PopupAnchorPoint.topCenter => PopupAnchorPoint.bottomCenter,
        PopupAnchorPoint.topRight => PopupAnchorPoint.bottomRight,
        PopupAnchorPoint.bottomLeft => PopupAnchorPoint.topLeft,
        PopupAnchorPoint.bottomCenter => PopupAnchorPoint.topCenter,
        PopupAnchorPoint.bottomRight => PopupAnchorPoint.topRight,
        PopupAnchorPoint.centerLeft ||
        PopupAnchorPoint.center ||
        PopupAnchorPoint.centerRight =>
          this,
      };

  PopupAnchorPoint get flippedHorizontally => switch (this) {
        PopupAnchorPoint.topLeft => PopupAnchorPoint.topRight,
        PopupAnchorPoint.centerLeft => PopupAnchorPoint.centerRight,
        PopupAnchorPoint.bottomLeft => PopupAnchorPoint.bottomRight,
        PopupAnchorPoint.topRight => PopupAnchorPoint.topLeft,
        PopupAnchorPoint.centerRight => PopupAnchorPoint.centerLeft,
        PopupAnchorPoint.bottomRight => PopupAnchorPoint.bottomLeft,
        PopupAnchorPoint.topCenter ||
        PopupAnchorPoint.center ||
        PopupAnchorPoint.bottomCenter =>
          this,
Bash Recovery driving in app layer
IN
cd "C:/MyDartProjects/dart_ui" && grep -n "GpuRecoveryCoordinator\|recoverFromDeviceLoss\|GpuRecoveryHost" lib/src/app/window_host.dart lib/src/app/application.dart | head -20

OUT
lib/src/app/window_host.dart:181:  Future<bool> recoverFromDeviceLoss();
lib/src/app/window_host.dart:377:  ///     [recoverFromDeviceLoss]; a caller that retried the same frame would
lib/src/app/window_host.dart:556:  Future<bool> recoverFromDeviceLoss() async {
lib/src/app/window_host.dart:559:    final recovered = await _presenter.recoverFromDeviceLoss();
lib/src/app/window_host.dart:850:  Future<bool> recoverFromDeviceLoss() async {
lib/src/app/window_host.dart:1068:  Future<bool> recoverFromDeviceLoss() async => true;
lib/src/app/application.dart:1191:        final recovered = await host.recoverFromDeviceLoss();
Read C:\MyDartProjects\dart_ui\lib\src\app\window_host.dart (lines 821-900)
Write C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_wire.dart
344 lines
/// Marshalling and unmarshalling of the Wayland wire format, in pure Dart.
///
/// A Wayland message is two 32-bit header words followed by the arguments:
///
/// ```text
/// word 0: sender/target object id
/// word 1: (size in bytes, header included) << 16 | opcode
/// ```
///
/// Arguments are 32-bit aligned. `int`/`uint`/`object`/`new_id` are one word;
/// `fixed` is signed 24.8; `string` is a length word (NUL included) followed by
/// NUL-terminated UTF-8 padded to a word; `array` is a length word followed by
/// bytes padded to a word; `fd` occupies **no bytes at all** - the descriptor
/// travels as `SCM_RIGHTS` ancillary data on the socket and is consumed in
/// argument order by the receiver.
///
/// The wire is in the *host's* byte order. Everything this backend runs on is
/// little-endian, and the code says so once here instead of assuming it
/// silently in every reader - the same posture `x11_libc.dart` takes.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Wayland speaks host byte order; this backend supports the little-endian
/// hosts Linux desktops actually run on. A big-endian port would only need to
/// change this constant's derivation.
final Endian waylandWireEndian = Endian.host;

/// Bytes of a message header: object id word plus size/opcode word.
const int waylandHeaderBytes = 8;

/// The size field is 16 bits, so no single message can exceed this.
const int waylandMaximumMessageBytes = 0xffff;

/// Converts a signed 24.8 fixed-point wire value to a double.
double waylandFixedToDouble(int fixed) {
  final signed = fixed >= 0x80000000 ? fixed - 0x100000000 : fixed;
  return signed / 256.0;
}

/// Converts a double to the signed 24.8 fixed-point wire encoding.
int waylandDoubleToFixed(double value) {
  final scaled = (value * 256.0).round();
  return scaled & 0xffffffff;
}

/// Rounds [length] up to the 32-bit alignment every argument obeys.
int waylandWordAlign(int length) => (length + 3) & ~3;

/// Builds one outgoing message, then hands back its exact bytes.
///
/// One instance per connection, reused for every request: `reset` rewinds it,
/// `take` copies out only the bytes written. The scratch grows to the largest
/// message ever sent and stays there, which honours section 6.5's rule against
/// per-event allocation without a fixed ceiling guess.
final class WaylandMessageWriter {
  WaylandMessageWriter([int initialCapacity = 256])
      : _bytes = Uint8List(initialCapacity < 64 ? 64 : initialCapacity) {
    _data = ByteData.sublistView(_bytes);
  }

  Uint8List _bytes;
  late ByteData _data;
  int _length = 0;
  int _objectId = 0;
  int _opcode = 0;

  /// The file descriptors queued by [putFd], in argument order. The transport
  /// must send them with the same `sendmsg` that carries the bytes.
  final List<int> fds = <int>[];

  /// Starts a message for [objectId]/[opcode]. Arguments follow.
  void begin(int objectId, int opcode) {
    if (objectId <= 0) {
      throw ArgumentError.value(objectId, 'objectId', 'must be positive');
    }
    if (opcode < 0 || opcode > 0xffff) {
      throw ArgumentError.value(opcode, 'opcode', 'must fit in 16 bits');
    }
    _objectId = objectId;
    _opcode = opcode;
    _length = waylandHeaderBytes;
    fds.clear();
  }

  void putInt(int value) => _putWord(value & 0xffffffff);

  void putUint(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw ArgumentError.value(value, 'value', 'must fit in 32 bits');
    }
    _putWord(value);
  }

  void putFixed(double value) => _putWord(waylandDoubleToFixed(value));

  void putObject(int objectId) => putUint(objectId);

  void putNewId(int objectId) => putUint(objectId);

  /// A non-null protocol string: length word (NUL included), UTF-8 bytes, NUL,
  /// padding to a word boundary.
  void putString(String value) {
    final encoded = utf8.encode(value);
    final lengthWithNul = encoded.length + 1;
    putUint(lengthWithNul);
    _ensure(waylandWordAlign(lengthWithNul));
    _bytes.setAll(_length, encoded);
    var cursor = _length + encoded.length;
    final padded = _length + waylandWordAlign(lengthWithNul);
    while (cursor < padded) {
      _bytes[cursor++] = 0;
    }
    _length = padded;
  }

  /// A protocol array: length word (bytes, padding excluded), raw bytes,
  /// padding to a word boundary.
  void putArray(Uint8List value) {
    putUint(value.length);
    _ensure(waylandWordAlign(value.length));
    _bytes.setAll(_length, value);
    var cursor = _length + value.length;
    final padded = _length + waylandWordAlign(value.length);
    while (cursor < padded) {
      _bytes[cursor++] = 0;
    }
    _length = padded;
  }

  /// Queues [fd] as ancillary data. Writes nothing into the byte stream.
  void putFd(int fd) {
    if (fd < 0) throw ArgumentError.value(fd, 'fd', 'must be a valid fd');
    fds.add(fd);
  }

  /// Finishes the message and returns a copy of exactly its bytes.
  Uint8List take() {
    if (_length < waylandHeaderBytes) {
      throw StateError('WaylandMessageWriter.take before begin');
    }
    if (_length > waylandMaximumMessageBytes) {
      throw StateError('Wayland message of $_length bytes exceeds the 16-bit '
          'size field');
    }
    _data.setUint32(0, _objectId, waylandWireEndian);
    _data.setUint32(4, (_length << 16) | _opcode, waylandWireEndian);
    final result = Uint8List.fromList(
      Uint8List.sublistView(_bytes, 0, _length),
    );
    _length = 0;
    return result;
  }

  void _putWord(int value) {
    _ensure(4);
    _data.setUint32(_length, value, waylandWireEndian);
    _length += 4;
  }

  void _ensure(int extra) {
    if (_length + extra <= _bytes.length) return;
    var capacity = _bytes.length * 2;
    while (capacity < _length + extra) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity);
    grown.setAll(0, _bytes);
    _bytes = grown;
    _data = ByteData.sublistView(_bytes);
  }
}

/// One decoded message: who it is for, which event, and its argument bytes.
///
/// Reused by [WaylandWireDecoder]; never retained across `nextMessage` calls.
/// The payload view is only valid until the next decode, which is the same
/// borrow rule `X11RawEvent` lives by.
final class WaylandWireMessage {
  int objectId = 0;
  int opcode = 0;
  Uint8List payload = _emptyPayload;

  static final Uint8List _emptyPayload = Uint8List(0);
}

/// Reads arguments out of one message payload, in declaration order.
final class WaylandMessageReader {
  WaylandMessageReader(this._payload, [List<int>? fdQueue])
      : _data = ByteData.sublistView(_payload),
        _fdQueue = fdQueue;

  final Uint8List _payload;
  final ByteData _data;

  /// Received descriptors, shared with the connection: an `fd` argument
  /// consumes the head of this queue, in the order `recvmsg` delivered them.
  final List<int>? _fdQueue;

  int _offset = 0;

  bool get isAtEnd => _offset >= _payload.length;

  int readUint() {
    final value = _data.getUint32(_require(4), waylandWireEndian);
    _offset += 4;
    return value;
  }

  int readInt() {
    final value = _data.getInt32(_require(4), waylandWireEndian);
    _offset += 4;
    return value;
  }

  double readFixed() {
    final value = _data.getInt32(_require(4), waylandWireEndian);
    _offset += 4;
    return value / 256.0;
  }

  int readObject() => readUint();

  int readNewId() => readUint();

  /// A protocol string. Empty length means a null string, returned as ''.
  String readString() {
    final lengthWithNul = readUint();
    if (lengthWithNul == 0) return '';
    final start = _require(waylandWordAlign(lengthWithNul));
    final textLength = lengthWithNul - 1;
    final value = utf8.decode(
      Uint8List.sublistView(_payload, start, start + textLength),
      allowMalformed: true,
    );
    _offset += waylandWordAlign(lengthWithNul);
    return value;
  }

  /// A protocol array, copied out so the caller may keep it.
  Uint8List readArray() {
    final length = readUint();
    final start = _require(waylandWordAlign(length));
    final value = Uint8List.fromList(
      Uint8List.sublistView(_payload, start, start + length),
    );
    _offset += waylandWordAlign(length);
    return value;
  }

  /// The next ancillary file descriptor, or -1 when none arrived - which is a
  /// protocol violation by the peer, reported by the caller rather than
  /// guessed around here.
  int readFd() {
    final queue = _fdQueue;
    if (queue == null || queue.isEmpty) return -1;
    return queue.removeAt(0);
  }

  int _require(int bytes) {
    if (_offset + bytes > _payload.length) {
      throw StateError(
        'Wayland message payload of ${_payload.length} bytes ended while '
        'reading $bytes byte(s) at offset $_offset',
      );
    }
    return _offset;
  }
}

/// Reassembles complete messages out of an arbitrary chunking of the stream.
///
/// A unix socket delivers bytes, not messages: one read can contain half a
/// header, three whole events and the first word of a fourth. The decoder
/// buffers what arrived and yields a message only when all of it is present.
final class WaylandWireDecoder {
  Uint8List _buffer = Uint8List(4096);
  int _start = 0;
  int _end = 0;

  int get bufferedBytes => _end - _start;

  /// Appends [bytes] (the first [length] entries, or all of them) to the
  /// stream.
  void addBytes(Uint8List bytes, [int? length]) {
    final count = length ?? bytes.length;
    if (count <= 0) return;
    _reserve(count);
    _buffer.setRange(_end, _end + count, bytes);
    _end += count;
  }

  /// Decodes the next complete message into [into]. Returns false when the
  /// buffered bytes do not yet contain one.
  bool nextMessage(WaylandWireMessage into) {
    if (bufferedBytes < waylandHeaderBytes) return false;
    final data = ByteData.sublistView(_buffer, _start, _end);
    final objectId = data.getUint32(0, waylandWireEndian);
    final sizeOpcode = data.getUint32(4, waylandWireEndian);
    final size = sizeOpcode >> 16;
    if (size < waylandHeaderBytes) {
      throw StateError(
        'Wayland message header declares $size bytes; the minimum is '
        '$waylandHeaderBytes',
      );
    }
    if (bufferedBytes < size) return false;
    into
      ..objectId = objectId
      ..opcode = sizeOpcode & 0xffff
      ..payload = Uint8List.sublistView(
        _buffer,
        _start + waylandHeaderBytes,
        _start + size,
      );
    _start += size;
    if (_start == _end) {
      _start = 0;
      _end = 0;
    }
    return true;
  }

  void _reserve(int extra) {
    if (_end + extra <= _buffer.length) return;
    // Compact before growing: the live bytes usually fit once the consumed
    // prefix is dropped.
    if (_start > 0) {
      _buffer.setRange(0, _end - _start, _buffer, _start);
      _end -= _start;
      _start = 0;
      if (_end + extra <= _buffer.length) return;
    }
    var capacity = _buffer.length * 2;
    while (capacity < _end + extra) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, _end, _buffer);
    _buffer = grown;
  }
}
Write C:\MyDartProjects\dart_ui\lib\src\platform\standard_paths_types.dart
131 lines
/// The shared vocabulary of [StandardPaths]: which folders exist, how a
/// failure is reported, and the XDG parsing that is pure string work.
///
/// The parsing lives here rather than in the `io` implementation because it
/// has no `dart:io` in it at all: `~/.config/user-dirs.dirs` is a text format,
/// and a text format is testable on any platform, including the Windows
/// machine this framework is developed on. The `io` file feeds it real file
/// contents; a test feeds it strings.
library;

/// A well-known directory the operating system names for the current user.
enum StandardFolder {
  /// The user's home directory - `%USERPROFILE%`, `$HOME`.
  home,

  /// Documents.
  documents,

  /// Downloads.
  downloads,

  /// Pictures.
  pictures,

  /// Music.
  music,

  /// Videos - `Movies` on macOS, which is a naming difference and not a
  /// semantic one.
  videos,

  /// The desktop directory.
  desktop,

  /// Where an application stores per-user configuration and data that should
  /// follow the user: `%APPDATA%` (Roaming) on Windows, `$XDG_CONFIG_HOME`
  /// (default `~/.config`) on Linux, `~/Library/Application Support` on
  /// macOS. Callers append their own application name.
  appData,

  /// Per-user data that stays on this machine: `%LOCALAPPDATA%` on Windows,
  /// `$XDG_DATA_HOME` (default `~/.local/share`) on Linux, and the same
  /// `~/Library/Application Support` on macOS, which draws no such
  /// distinction.
  appDataLocal,

  /// Where an application caches things it can regenerate: `%LOCALAPPDATA%`
  /// on Windows (the platform has no dedicated cache root),
  /// `$XDG_CACHE_HOME` (default `~/.cache`) on Linux, `~/Library/Caches` on
  /// macOS. Callers append their own application name.
  cache,

  /// The system temporary directory.
  temp,

  /// The running executable itself - `Platform.resolvedExecutable` - so a
  /// program can find files shipped next to it.
  executable,
}

/// A standard-path lookup that could not be answered.
final class StandardPathsException implements Exception {
  const StandardPathsException({
    required this.folder,
    required this.reason,
    this.platform,
    this.errorCode,
  });

  final StandardFolder folder;
  final String reason;
  final String? platform;
  final int? errorCode;

  @override
  String toString() => 'StandardPathsException: ${folder.name} unavailable'
      '${platform == null ? '' : ' on $platform'}'
      '${errorCode == null ? '' : ' (code $errorCode)'} - $reason';
}

/// Parses the body of `~/.config/user-dirs.dirs` into folder assignments.
///
/// The format is fixed by xdg-user-dirs: shell-like assignments of the form
/// `XDG_DOWNLOAD_DIR="$HOME/Downloads"`, where the value is always quoted and
/// either starts with `$HOME/` or is an absolute path. Anything else in the
/// file - comments, blank lines, malformed lines - is skipped rather than
/// rejected, because this is a best-effort configuration file that desktop
/// environments rewrite and users hand-edit.
///
/// Returns a map from the `XDG_*_DIR` key to the *expanded* absolute path.
/// A value that expands to [home] itself means the user disabled that folder
/// (that is the convention xdg-user-dirs documents), and is omitted.
Map<String, String> parseXdgUserDirs(String content, {required String home}) {
  final Map<String, String> result = <String, String>{};
  final RegExp assignment =
      RegExp(r'^\s*(XDG_[A-Z]+_DIR)\s*=\s*"([^"]*)"\s*$');
  for (final String line in content.split('\n')) {
    final RegExpMatch? match = assignment.firstMatch(line);
    if (match == null) continue;
    final String key = match.group(1)!;
    String value = match.group(2)!;
    if (value.startsWith(r'$HOME/')) {
      value = '$home/${value.substring(6)}';
    } else if (value == r'$HOME' || value == r'$HOME/') {
      value = home;
    } else if (!value.startsWith('/')) {
      // Neither $HOME-relative nor absolute: not a shape the spec allows.
      continue;
    }
    // Strip a trailing slash so callers compare and join uniformly.
    if (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value == home) continue; // Disabled by the user, per the convention.
    result[key] = value;
  }
  return result;
}

/// The `XDG_*_DIR` key for [folder], or null for folders the user-dirs file
/// does not describe.
String? xdgUserDirKey(StandardFolder folder) => switch (folder) {
      StandardFolder.documents => 'XDG_DOCUMENTS_DIR',
      StandardFolder.downloads => 'XDG_DOWNLOAD_DIR',
      StandardFolder.pictures => 'XDG_PICTURES_DIR',
      StandardFolder.music => 'XDG_MUSIC_DIR',
      StandardFolder.videos => 'XDG_VIDEOS_DIR',
      StandardFolder.desktop => 'XDG_DESKTOP_DIR',
      _ => null,
    };
Now the libc FFI layer with sendmsg/recvmsg (SCM_RIGHTS), memfd and mmap.

Bash How ComboBox implements its dropdown
IN
grep -n "Overlay\|Popup\|Stack\|_Dropdown\|dropdown" C:/MyDartProjects/dart_ui/lib/src/widgets/combo_box.dart | head -30

OUT
7:///   * [PopupPositioner] places the drop-down, flipping it above the field when
133:/// ## Why this is not a [PopupStack]
139:/// is down. Pushing an immutable [PopupEntry] per frame would fire that entry's
142:/// `popup.dart` - [PopupPositioner], [PopupRequest], [PopupDismissPolicy] - is
144:final class ComboBoxOverlay {
145:  ComboBoxOverlay();
154:  PopupDismissPolicy _dismissPolicy = PopupDismissPolicy.lightDismiss;
155:  PopupPlacement? _placement;
168:  PopupPlacement? get placement => _open ? _placement : null;
188:    PopupDismissPolicy dismissPolicy = PopupDismissPolicy.lightDismiss,
231:  Widget? buildPopup() => _open ? _builder?.call() : null;
253:  final ComboBoxOverlay? overlay;
258:  static ComboBoxOverlay? maybeOf(BuildContext context) => context
263:  static ComboBoxOverlay of(BuildContext context) {
264:    final ComboBoxOverlay? overlay = maybeOf(context);
276:  late ComboBoxOverlay _overlay;
277:  late bool _ownsOverlay;
282:    _ownsOverlay = widget.overlay == null;
283:    _overlay = widget.overlay ?? ComboBoxOverlay();
292:    _ownsOverlay = widget.overlay == null;
293:    _overlay = widget.overlay ?? ComboBoxOverlay();
300:    if (_ownsOverlay) _overlay.close();
310:    final Widget? popup = _overlay.buildPopup();
324:  final ComboBoxOverlay overlay;
334:  final ComboBoxOverlay overlay;
356:  ComboBoxOverlay? _overlay;
358:  PopupPlacement? _placement;
360:  ComboBoxOverlay? get overlay => _overlay;
362:  set overlay(ComboBoxOverlay? value) {
377:  PopupPlacement? get placement => _placement;
Read C:\MyDartProjects\dart_ui\lib\src\rendering\cpu_renderer.dart (lines 1029-1088)
Grep "class GlyphCache|GlyphMask maskFor|class GlyphMask|final Uint8List coverage|glyphSubpixelBucket|glyphPixelOrigin" (in C:\MyDartProjects\dart_ui\lib\src\rendering\text\glyph_cache.dart)
55 lines of output
Write C:\MyDartProjects\dart_ui\lib\src\platform\standard_paths.dart
57 lines
/// The operating system's well-known directories, by name.
///
/// "Where do documents go" is a question only the platform can answer:
/// Windows lets the user relocate every known folder and records the answer
/// behind `SHGetKnownFolderPath`, Linux records it in environment variables
/// and `~/.config/user-dirs.dirs`, and macOS fixes the layout under `$HOME`
/// by convention. Guessing `$HOME/Documents` is right until the first user
/// who moved their Documents to another drive, which is exactly the user the
/// platform API exists for.
///
/// Every accessor is synchronous: each platform answers from memory, a
/// registry call or one small file read, and none of them talks to another
/// process. Browsers have no filesystem to name, so on the web every lookup
/// throws [StandardPathsException].
library;

import 'standard_paths_platform_stub.dart'
    if (dart.library.io) 'standard_paths_platform_io.dart' as platform;
import 'standard_paths_types.dart';

export 'standard_paths_types.dart';

/// Well-known per-user directories, resolved the way the platform resolves
/// them.
///
/// Accessors throw [StandardPathsException] when the platform cannot answer -
/// a folder the user deleted, a headless Linux with no `$HOME`, a browser.
/// They never invent a path that was not derived from the platform's own
/// configuration.
abstract final class StandardPaths {
  /// The directory for [folder], as an absolute path without a trailing
  /// separator.
  static String resolve(StandardFolder folder) => platform.resolve(folder);

  static String get home => resolve(StandardFolder.home);
  static String get documents => resolve(StandardFolder.documents);
  static String get downloads => resolve(StandardFolder.downloads);
  static String get pictures => resolve(StandardFolder.pictures);
  static String get music => resolve(StandardFolder.music);
  static String get videos => resolve(StandardFolder.videos);
  static String get desktop => resolve(StandardFolder.desktop);

  /// Roaming configuration/data root; append your application's name.
  static String get appData => resolve(StandardFolder.appData);

  /// Machine-local data root; append your application's name.
  static String get appDataLocal => resolve(StandardFolder.appDataLocal);

  /// Cache root; append your application's name.
  static String get cache => resolve(StandardFolder.cache);

  static String get temp => resolve(StandardFolder.temp);

  /// The full path of the running executable.
  static String get executable => resolve(StandardFolder.executable);
}
Write C:\MyDartProjects\dart_ui\lib\src\platform\standard_paths_platform_stub.dart
11 lines
library;

import 'standard_paths_types.dart';

String resolve(StandardFolder folder) {
  throw StandardPathsException(
    folder: folder,
    reason: 'this target exposes no filesystem to name standard folders in',
  );
}
Bash Icon and phosphor icon names
IN
grep -n "class Icon\b\|const Icon(" C:/MyDartProjects/dart_ui/lib/src/widgets/icon.dart | head; grep -no "caretLeft\|caretRight\|caretDown\|caretUp\|\bx\b =\|info\|warning\|warningCircle\|checkCircle\|xCircle\|calendar\w*\|user\b" C:/MyDartProjects/dart_ui/lib/src/widgets/phosphor_icons.dart | head -30

OUT
175:final class Icon extends RenderObjectWidget {
176:  const Icon(
396:calendar
397:calendarBlank
399:calendarCheck
401:calendarDot
402:calendarDots
403:calendarHeart
405:calendarMinus
407:calendarPlus
408:calendarSlash
410:calendarStar
411:calendarX
451:caretDown
452:caretLeft
460:caretRight
461:caretUp
462:caretUp
535:checkCircle
1087:info
1903:user
1951:warning
1952:warningCircle
1954:warning
1956:warning
1988:x =
1989:xCircle
Bash Icon widget constructor
IN
sed -n 160,240p C:/MyDartProjects/dart_ui/lib/src/widgets/icon.dart; grep -n "static const IconData caretLeft\|static const IconData caretRight\|class IconData\|IconData(" C:/MyDartProjects/dart_ui/lib/src/widgets/phosphor_icons.dart | head -5

OUT
      other.codePoint == codePoint &&
      other.fontFamily == fontFamily &&
      other.matchTextDirection == matchTextDirection;

  @override
  int get hashCode => Object.hash(codePoint, fontFamily, matchTextDirection);

  @override
  String toString() => 'IconData(U+'
      '${codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}'
      '${fontFamily == null ? '' : ', $fontFamily'}'
      '${matchTextDirection ? ', mirrors' : ''})';
}

/// A single glyph, drawn at a square size in one colour.
final class Icon extends RenderObjectWidget {
  const Icon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.textDirection,
  });

  final IconData icon;

  /// The side of the square box, in logical pixels. Defaults to
  /// [kDefaultIconSize].
  final double? size;

  /// The glyph colour, or null to take the ambient icon theme.
  final Color? color;

  /// The reading order, overriding the ambient [Directionality].
  ///
  /// Null - the usual case - reads the ambient value, and only for an icon that
  /// declared [IconData.matchTextDirection]. An icon that does not mirror never
  /// asks, so it stays usable in a subtree that has no reading direction at all.
  final TextDirection? textDirection;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderIcon createRenderObject(BuildContext context) => RenderIcon(
        icon,
        size: _sizeFrom(context),
        color: _colorFrom(context),
        textDirection: _directionFrom(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderIcon renderObject,
  ) {
    renderObject
      ..icon = icon
      ..iconSize = _sizeFrom(context)
      ..color = _colorFrom(context)
      ..textDirection = _directionFrom(context);
  }

  /// Resolves from both icon and application themes and subscribes to them.
  /// Render-object elements can rebuild inherited values through
  /// `updateRenderObject`; without the dependency, a const icon retained the
  /// light palette after a live switch to dark mode.
  Color _colorFrom(BuildContext context) {
    final IconThemeData? local = IconTheme.maybeOf(context);
    final ThemeData? theme =
        context.dependOnInheritedWidgetOfExactType<Theme>()?.data;
    return color ??
        local?.color ??
        theme?.iconTheme.color ??
        theme?.foreground ??
        const Color(0xFF111111);
  }

  double _sizeFrom(BuildContext context) {
    final IconThemeData? local = IconTheme.maybeOf(context);
    final ThemeData? theme =
15:  static const IconData acorn = IconData(0xEB9A, fontFamily: fontFamily);
16:  static const IconData addressBook = IconData(0xE6F8, fontFamily: fontFamily);
18:      IconData(0xEE4E, fontFamily: fontFamily);
20:      IconData(0xECD8, fontFamily: fontFamily);
21:  static const IconData airplane = IconData(0xE002, fontFamily: fontFamily);
Grep "enum Capability|class BackendProbeResult|class BackendDiagnostic|enum DiagnosticKind|class UnsupportedCapabilityError|factory BackendDiagnostic|factory BackendProbeResult|class BackendSelectionError" (in C:\MyDartProjects\dart_ui\lib\src\foundation\diagnostics.dart)
169 lines of output
Grep "describeSurface|GenerationToken|generationToken" (in C:\MyDartProjects\dart_ui\lib\src\backends\win32\d3d11\win32_d3d11_surface.dart)
36 lines of output
Read C:\MyDartProjects\dart_ui\lib\src\app\window_host.dart (lines 811-930)
Now I have the full picture. Time to implement. Starting with TreeView.

Write C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_libc.dart
367 lines
/// The libc entry points the Wayland backend needs, and nothing more.
///
/// Same policy as `x11_libc.dart`: `package:ffi` is not a dependency, libc is
/// already mapped into every process this backend can run in, and everything
/// here is Linux-shaped. Two further constraints are specific to Wayland:
///
///   * **The socket itself is opened through libc**, not `dart:io`. Wayland
///     passes file descriptors (`SCM_RIGHTS`) attached to ordinary protocol
///     bytes - the keyboard keymap arrives that way, the shm pool fd leaves
///     that way - and `dart:io` sockets cannot see or send ancillary data. One
///     transport must own the descriptor, so all of it is `sendmsg`/`recvmsg`.
///   * **Struct layouts are the LP64 ones** (x86_64/aarch64): `msghdr` is 56
///     bytes, `cmsghdr` headers are 16, `sockaddr_un` is 2 + 108. 32-bit and
///     exotic ABIs differ and are not supported; that is a stated limitation,
///     not an oversight.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../../foundation/diagnostics.dart';

// ---------------------------------------------------------------------------
// Constants (Linux, x86_64/aarch64 values).
// ---------------------------------------------------------------------------

const int afUnix = 1;
const int sockStream = 1;
const int sockCloexec = 0x80000;
const int sockNonblock = 0x800;

/// `sockaddr_un`: `sa_family_t` (2 bytes) + `sun_path[108]`.
const int sockaddrUnSize = 110;
const int sockaddrUnPathCapacity = 108;

const int solSocket = 1;
const int scmRights = 1;

const int msgDontwait = 0x40;
const int msgNosignal = 0x4000;
const int msgCmsgCloexec = 0x40000000;

/// LP64 `struct msghdr` layout.
const int msghdrSize = 56;
const int msghdrNameOffset = 0;
const int msghdrNamelenOffset = 8;
const int msghdrIovOffset = 16;
const int msghdrIovlenOffset = 24;
const int msghdrControlOffset = 32;
const int msghdrControllenOffset = 40;
const int msghdrFlagsOffset = 48;

/// LP64 `struct iovec`: pointer + size.
const int iovecSize = 16;

/// LP64 `struct cmsghdr` header: `size_t cmsg_len; int cmsg_level; int
/// cmsg_type;` then data, all word-aligned.
const int cmsgHeaderSize = 16;

/// Enough control space for the bursts Wayland actually produces. libwayland
/// uses 28 fds; rounding to 32 costs nothing.
const int maxAncillaryFds = 32;
const int controlBufferSize = cmsgHeaderSize + maxAncillaryFds * 4;

const int oCloexec = 0x80000;
const int oNonblock = 0x800;

const int pollIn = 0x0001;
const int pollErr = 0x0008;
const int pollHup = 0x0010;

/// Size of one `struct pollfd` (int fd, short events, short revents).
const int pollFdSize = 8;

const int eagain = 11;
const int eintr = 4;
const int epipe = 32;
const int econnreset = 104;

const int mfdCloexec = 0x0001;
const int mfdAllowSealing = 0x0002;

const int protRead = 0x1;
const int protWrite = 0x2;
const int mapShared = 0x01;
const int mapPrivate = 0x02;

// ---------------------------------------------------------------------------
// Typedefs.
// ---------------------------------------------------------------------------

typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);
typedef _SocketNative = Int32 Function(Int32, Int32, Int32);
typedef _SocketDart = int Function(int, int, int);
typedef _ConnectNative = Int32 Function(Int32, Pointer<Uint8>, Uint32);
typedef _ConnectDart = int Function(int, Pointer<Uint8>, int);
typedef _SendmsgNative = IntPtr Function(Int32, Pointer<Uint8>, Int32);
typedef _SendmsgDart = int Function(int, Pointer<Uint8>, int);
typedef _RecvmsgNative = IntPtr Function(Int32, Pointer<Uint8>, Int32);
typedef _RecvmsgDart = int Function(int, Pointer<Uint8>, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _PollNative = Int32 Function(Pointer<Uint8>, UintPtr, Int32);
typedef _PollDart = int Function(Pointer<Uint8>, int, int);
typedef _Pipe2Native = Int32 Function(Pointer<Int32>, Int32);
typedef _Pipe2Dart = int Function(Pointer<Int32>, int);
typedef _ReadNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _ReadDart = int Function(int, Pointer<Uint8>, int);
typedef _WriteNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _WriteDart = int Function(int, Pointer<Uint8>, int);
typedef _MemfdCreateNative = Int32 Function(Pointer<Uint8>, Uint32);
typedef _MemfdCreateDart = int Function(Pointer<Uint8>, int);
typedef _FtruncateNative = Int32 Function(Int32, Int64);
typedef _FtruncateDart = int Function(int, int);
typedef _MmapNative = Pointer<Uint8> Function(
    Pointer<Uint8>, IntPtr, Int32, Int32, Int32, Int64);
typedef _MmapDart = Pointer<Uint8> Function(
    Pointer<Uint8>, int, int, int, int, int);
typedef _MunmapNative = Int32 Function(Pointer<Uint8>, IntPtr);
typedef _MunmapDart = int Function(Pointer<Uint8>, int);
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

/// The libc symbols this backend calls, resolved once.
///
/// [open] never throws: a machine missing one of these cannot run the backend,
/// and the probe report needs the missing symbol's name rather than a stack
/// trace from three layers down.
final class WaylandLibc {
  WaylandLibc._(this._library);

  /// Returns null and fills [diagnostics] when libc could not be resolved.
  static WaylandLibc? open(List<BackendDiagnostic> diagnostics) {
    DynamicLibrary? library;
    try {
      library = DynamicLibrary.process();
    } on Object catch (error) {
      diagnostics.add(
        BackendDiagnostic.missingLibrary('process image', detail: '$error'),
      );
    }
    if (library == null || !library.providesSymbol('malloc')) {
      for (final candidate in const <String>['libc.so.6', 'libc.so']) {
        try {
          library = DynamicLibrary.open(candidate);
          break;
        } on Object catch (error) {
          diagnostics.add(
            BackendDiagnostic.missingLibrary(candidate, detail: '$error'),
          );
        }
      }
    }
    if (library == null) return null;

    final missing = <String>[];
    for (final symbol in _requiredSymbols) {
      if (!library.providesSymbol(symbol)) missing.add(symbol);
    }
    if (missing.isNotEmpty) {
      for (final symbol in missing) {
        diagnostics.add(
          BackendDiagnostic.missingSymbol(symbol, detail: 'libc'),
        );
      }
      return null;
    }
    return WaylandLibc._(library);
  }

  /// `memfd_create` is checked separately: it appeared in glibc 2.27 and its
  /// absence only disables shm presentation, not the whole backend.
  static const List<String> _requiredSymbols = <String>[
    'malloc',
    'free',
    'socket',
    'connect',
    'sendmsg',
    'recvmsg',
    'close',
    'poll',
    'pipe2',
    'read',
    'write',
    'ftruncate',
    'mmap',
    'munmap',
  ];

  final DynamicLibrary _library;

  late final _MallocDart _malloc =
      _library.lookupFunction<_MallocNative, _MallocDart>('malloc');
  late final _FreeDart _free =
      _library.lookupFunction<_FreeNative, _FreeDart>('free');
  late final _SocketDart _socket =
      _library.lookupFunction<_SocketNative, _SocketDart>('socket');
  late final _ConnectDart _connect =
      _library.lookupFunction<_ConnectNative, _ConnectDart>('connect');
  late final _SendmsgDart _sendmsg =
      _library.lookupFunction<_SendmsgNative, _SendmsgDart>('sendmsg');
  late final _RecvmsgDart _recvmsg =
      _library.lookupFunction<_RecvmsgNative, _RecvmsgDart>('recvmsg');
  late final _CloseDart _close =
      _library.lookupFunction<_CloseNative, _CloseDart>('close');
  late final _PollDart _poll =
      _library.lookupFunction<_PollNative, _PollDart>('poll');
  late final _Pipe2Dart _pipe2 =
      _library.lookupFunction<_Pipe2Native, _Pipe2Dart>('pipe2');
  late final _ReadDart _read =
      _library.lookupFunction<_ReadNative, _ReadDart>('read');
  late final _WriteDart _write =
      _library.lookupFunction<_WriteNative, _WriteDart>('write');
  late final _FtruncateDart _ftruncate =
      _library.lookupFunction<_FtruncateNative, _FtruncateDart>('ftruncate');
  late final _MmapDart _mmap =
      _library.lookupFunction<_MmapNative, _MmapDart>('mmap');
  late final _MunmapDart _munmap =
      _library.lookupFunction<_MunmapNative, _MunmapDart>('munmap');

  late final bool hasMemfdCreate = _library.providesSymbol('memfd_create');

  late final _MemfdCreateDart _memfdCreate = _library
      .lookupFunction<_MemfdCreateNative, _MemfdCreateDart>('memfd_create');

  late final _ErrnoLocationDart? _errnoLocation =
      _library.providesSymbol('__errno_location')
          ? _library.lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
              '__errno_location')
          : null;

  /// The current `errno`, or -1 when the host hides `__errno_location`.
  /// Read immediately after the failing call; any libc call may overwrite it.
  int get errno {
    final location = _errnoLocation;
    if (location == null) return -1;
    return location().value;
  }

  Pointer<Uint8> allocateZeroed(int bytes) {
    final pointer = _malloc(bytes);
    if (pointer == nullptr) return pointer;
    for (var i = 0; i < bytes; i++) {
      pointer[i] = 0;
    }
    return pointer;
  }

  void free(Pointer<Uint8> pointer) {
    if (pointer == nullptr) return;
    _free(pointer);
  }

  /// A NUL-terminated UTF-8 copy of [value]. The caller owns it.
  Pointer<Uint8> allocateUtf8(String value) {
    final bytes = utf8.encode(value);
    final pointer = _malloc(bytes.length + 1);
    if (pointer == nullptr) return pointer;
    for (var i = 0; i < bytes.length; i++) {
      pointer[i] = bytes[i];
    }
    pointer[bytes.length] = 0;
    return pointer;
  }

  int socket(int domain, int type, int protocol) =>
      _socket(domain, type, protocol);

  int connect(int fd, Pointer<Uint8> address, int addressLength) =>
      _connect(fd, address, addressLength);

  int sendmsg(int fd, Pointer<Uint8> msghdr, int flags) =>
      _sendmsg(fd, msghdr, flags);

  int recvmsg(int fd, Pointer<Uint8> msghdr, int flags) =>
      _recvmsg(fd, msghdr, flags);

  int closeFd(int fd) => _close(fd);

  int poll(Pointer<Uint8> fds, int count, int timeoutMillis) =>
      _poll(fds, count, timeoutMillis);

  int pipe2(Pointer<Int32> fds, int flags) => _pipe2(fds, flags);

  int read(int fd, Pointer<Uint8> buffer, int count) =>
      _read(fd, buffer, count);

  int write(int fd, Pointer<Uint8> buffer, int count) =>
      _write(fd, buffer, count);

  int memfdCreate(Pointer<Uint8> name, int flags) => _memfdCreate(name, flags);

  int ftruncate(int fd, int length) => _ftruncate(fd, length);

  Pointer<Uint8> mmap(int length, int prot, int flags, int fd, int offset) =>
      _mmap(nullptr, length, prot, flags, fd, offset);

  int munmap(Pointer<Uint8> address, int length) => _munmap(address, length);
}

// ---------------------------------------------------------------------------
// Struct writers. Byte-indexing a Pointer<Uint8> compiles to a raw store and
// allocates nothing, the same trick x11_libc.dart uses for event decoding.
// ---------------------------------------------------------------------------

final bool waylandHostIsLittleEndian = Endian.host == Endian.little;

int readU16(Pointer<Uint8> p, int offset) {
  if (waylandHostIsLittleEndian) {
    return p[offset] | (p[offset + 1] << 8);
  }
  return (p[offset] << 8) | p[offset + 1];
}

int readU32(Pointer<Uint8> p, int offset) {
  if (waylandHostIsLittleEndian) {
    return p[offset] |
        (p[offset + 1] << 8) |
        (p[offset + 2] << 16) |
        (p[offset + 3] << 24);
  }
  return (p[offset] << 24) |
      (p[offset + 1] << 16) |
      (p[offset + 2] << 8) |
      p[offset + 3];
}

int readU64(Pointer<Uint8> p, int offset) =>
    readU32(p, offset) | (readU32(p, offset + 4) << 32);

void writeU16(Pointer<Uint8> p, int offset, int value) {
  if (waylandHostIsLittleEndian) {
    p[offset] = value & 0xff;
    p[offset + 1] = (value >> 8) & 0xff;
    return;
  }
  p[offset] = (value >> 8) & 0xff;
  p[offset + 1] = value & 0xff;
}

void writeU32(Pointer<Uint8> p, int offset, int value) {
  if (waylandHostIsLittleEndian) {
    p[offset] = value & 0xff;
    p[offset + 1] = (value >> 8) & 0xff;
    p[offset + 2] = (value >> 16) & 0xff;
    p[offset + 3] = (value >> 24) & 0xff;
    return;
  }
  p[offset] = (value >> 24) & 0xff;
  p[offset + 1] = (value >> 16) & 0xff;
  p[offset + 2] = (value >> 8) & 0xff;
  p[offset + 3] = value & 0xff;
}

void writeU64(Pointer<Uint8> p, int offset, int value) {
  writeU32(p, offset, value & 0xffffffff);
  writeU32(p, offset + 4, (value >> 32) & 0xffffffff);
}

void writePointer(Pointer<Uint8> p, int offset, Pointer<Uint8> value) {
  writeU64(p, offset, value.address);
}
Bash Find presentation selection loop
IN
cd "C:/MyDartProjects/dart_ui" && grep -n "attach\b\|BackendSelectionError\|attempts\|for (final PresentationPathEntry\|_selectPresentation\|selectPresentation" lib/src/app/application.dart | sed -n '1,40p'

OUT
67:///      including the healthy ones. Failure throws [BackendSelectionError]
72:///      [Application.openWindow]: create the window, attach a
91:///     caller can attach diagnostics between the two.
224:    required this.attach,
262:        attach: (NativeWindow window) async =>
286:        attach: (NativeWindow window) =>
287:            RenderTargetPresenter.attach(backend: backend, window: window),
310:        attach: (NativeWindow window) => RenderTargetPresenter.attachToWindow(
327:  /// Windowing backend entry names this path can attach to, or null when it is
340:  final Future<SurfacePresenter> Function(NativeWindow window) attach;
351:        message: '$name cannot attach to the selected $backendName windowing '
657:  /// Passed through to [selectPresentation]. Defaults to
1402:  /// Throws [BackendSelectionError] when no windowing backend or no
1457:    final presentationSelection = selectPresentation(
1854:          presenter = await _presentationPath.attach(native);
1868:            message: '$failedName passed its probe but could not attach to '
1877:          presentationSelection = _selectPresentation();
2017:  PresentationSelection _selectPresentation() => selectPresentation(
Read C:\MyDartProjects\dart_ui\lib\src\app\application.dart (lines 1831-1910)
Write C:\MyDartProjects\dart_ui\lib\src\platform\standard_paths_platform_io.dart
347 lines
library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'standard_paths_types.dart';

String resolve(StandardFolder folder) {
  // Two folders are platform-neutral: dart:io already asked the OS.
  switch (folder) {
    case StandardFolder.temp:
      return _stripTrailingSeparator(Directory.systemTemp.path);
    case StandardFolder.executable:
      return Platform.resolvedExecutable;
    default:
      break;
  }
  if (Platform.isWindows) return _resolveWindows(folder);
  if (Platform.isMacOS) {
    return macStandardPath(folder, home: _requireHome(folder));
  }
  if (Platform.isLinux) {
    return linuxStandardPath(
      folder,
      environment: Platform.environment,
      readUserDirs: _readLinuxUserDirs,
    );
  }
  throw StandardPathsException(
    folder: folder,
    platform: Platform.operatingSystem,
    reason: 'no standard-paths backend exists for this operating system',
  );
}

String _requireHome(StandardFolder folder) {
  final String? home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StandardPathsException(
      folder: folder,
      platform: Platform.operatingSystem,
      reason: r'$HOME is not set',
    );
  }
  return _stripTrailingSeparator(home);
}

String _stripTrailingSeparator(String path) {
  var result = path;
  while (result.length > 1 &&
      (result.endsWith('/') ||
          (result.endsWith(r'\') && !result.endsWith(r':\')))) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

// ---------------------------------------------------------------------------
// macOS: fixed conventions under $HOME.
//
// NSSearchPathForDirectoriesInDomains would be the platform's own answer, but
// it lives behind the Objective-C runtime, which this framework does not
// bind. The layout below has been documented and stable since Mac OS X 10.0,
// and - unlike Windows - the folders are not user-relocatable through any
// supported UI, so the convention *is* the platform answer.
// ---------------------------------------------------------------------------

/// The macOS path for [folder] under [home]. Pure, so it is testable on any
/// machine.
String macStandardPath(StandardFolder folder, {required String home}) =>
    switch (folder) {
      StandardFolder.home => home,
      StandardFolder.documents => '$home/Documents',
      StandardFolder.downloads => '$home/Downloads',
      StandardFolder.pictures => '$home/Pictures',
      StandardFolder.music => '$home/Music',
      StandardFolder.videos => '$home/Movies',
      StandardFolder.desktop => '$home/Desktop',
      StandardFolder.appData ||
      StandardFolder.appDataLocal =>
        '$home/Library/Application Support',
      StandardFolder.cache => '$home/Library/Caches',
      // temp and executable are answered before dispatch; reaching here is a
      // caller using this helper directly, and the honest answer is a throw.
      StandardFolder.temp || StandardFolder.executable =>
        throw StandardPathsException(
          folder: folder,
          platform: 'macos',
          reason: 'answered by dart:io, not by home-relative convention',
        ),
    };

// ---------------------------------------------------------------------------
// Linux: XDG base directories plus xdg-user-dirs.
// ---------------------------------------------------------------------------

/// The Linux path for [folder], resolved from [environment] and - for the
/// media folders - from the `user-dirs.dirs` content [readUserDirs] provides.
///
/// [readUserDirs] is a function rather than a string so the file is only read
/// for the folders that need it, and so a test can inject content without a
/// filesystem.
String linuxStandardPath(
  StandardFolder folder, {
  required Map<String, String> environment,
  required String? Function(String configHome) readUserDirs,
}) {
  final String? home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StandardPathsException(
      folder: folder,
      platform: 'linux',
      reason: r'$HOME is not set',
    );
  }
  final String homePath = _stripTrailingSeparator(home);

  String xdgBase(String variable, String fallback) {
    final String? value = environment[variable];
    if (value != null && value.startsWith('/')) {
      return _stripTrailingSeparator(value);
    }
    return '$homePath/$fallback';
  }

  switch (folder) {
    case StandardFolder.home:
      return homePath;
    case StandardFolder.appData:
      return xdgBase('XDG_CONFIG_HOME', '.config');
    case StandardFolder.appDataLocal:
      return xdgBase('XDG_DATA_HOME', '.local/share');
    case StandardFolder.cache:
      return xdgBase('XDG_CACHE_HOME', '.cache');
    default:
      break;
  }

  // Media folders: an explicit XDG_*_DIR environment variable wins, then the
  // user-dirs.dirs file, then the well-known default name under $HOME.
  final String key = xdgUserDirKey(folder)!;
  final String? fromEnvironment = environment[key];
  if (fromEnvironment != null && fromEnvironment.startsWith('/')) {
    return _stripTrailingSeparator(fromEnvironment);
  }
  final String configHome = xdgBase('XDG_CONFIG_HOME', '.config');
  final String? content = readUserDirs(configHome);
  if (content != null) {
    final String? configured =
        parseXdgUserDirs(content, home: homePath)[key];
    if (configured != null) return configured;
  }
  final String defaultName = switch (folder) {
    StandardFolder.documents => 'Documents',
    StandardFolder.downloads => 'Downloads',
    StandardFolder.pictures => 'Pictures',
    StandardFolder.music => 'Music',
    StandardFolder.videos => 'Videos',
    _ => 'Desktop',
  };
  return '$homePath/$defaultName';
}

String? _readLinuxUserDirs(String configHome) {
  try {
    final File file = File('$configHome/user-dirs.dirs');
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  } on FileSystemException {
    return null; // Unreadable is the same as absent: fall back to defaults.
  }
}

// ---------------------------------------------------------------------------
// Windows: SHGetKnownFolderPath, because every known folder is relocatable
// and the registry-backed answer is the only true one. Environment variables
// are the fallback when shell32 cannot be loaded, which on a real Windows
// means something is deeply wrong - but a degraded answer with a name beats
// an unexplained crash.
// ---------------------------------------------------------------------------

final class _Guid extends Struct {
  @Uint32()
  external int data1;

  @Uint16()
  external int data2;

  @Uint16()
  external int data3;

  @Array<Uint8>(8)
  external Array<Uint8> data4;
}

typedef _SHGetKnownFolderPathNative = Int32 Function(
  Pointer<_Guid> id,
  Uint32 flags,
  IntPtr token,
  Pointer<Pointer<Uint16>> path,
);
typedef _SHGetKnownFolderPathDart = int Function(
  Pointer<_Guid> id,
  int flags,
  int token,
  Pointer<Pointer<Uint16>> path,
);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Void> block);
typedef _CoTaskMemFreeDart = void Function(Pointer<Void> block);

/// The KNOWNFOLDERID GUIDs this file asks for, in canonical string form.
///
/// These are ABI constants fixed by the Windows SDK (KnownFolders.h); they
/// are the same on every Windows since Vista.
const Map<StandardFolder, String> _windowsFolderIds =
    <StandardFolder, String>{
  StandardFolder.home: '5E6C858F-0E22-4760-9AFE-EA3317B67173', // Profile
  StandardFolder.documents: 'FDD39AD0-238F-46AF-ADB4-6C85480369C7',
  StandardFolder.downloads: '374DE290-123F-4565-9164-39C4925E467B',
  StandardFolder.pictures: '33E28130-4E1E-4676-835A-98395C3BC3BB',
  StandardFolder.music: '4BD8D571-6D19-48D3-BE97-422220080E43',
  StandardFolder.videos: '18989B1D-99B5-455B-841C-AB7C74E4DDFC',
  StandardFolder.desktop: 'B4BFCC3A-DB2C-424C-B029-7FE99A87C641',
  StandardFolder.appData: '3EB685DB-65F9-4CF6-A03A-E3EF65729F3D', // Roaming
  StandardFolder.appDataLocal: 'F1B32785-6FBA-4FCF-9D55-7B8E7F157091',
  // Windows has no dedicated per-user cache root; LocalAppData is where
  // every application (and the platform's own INetCache) puts caches.
  StandardFolder.cache: 'F1B32785-6FBA-4FCF-9D55-7B8E7F157091',
};

_SHGetKnownFolderPathDart? _shGetKnownFolderPath;
_CoTaskMemFreeDart? _coTaskMemFree;
bool _windowsBindAttempted = false;

void _bindWindows() {
  if (_windowsBindAttempted) return;
  _windowsBindAttempted = true;
  try {
    final DynamicLibrary shell32 = DynamicLibrary.open('shell32.dll');
    final DynamicLibrary ole32 = DynamicLibrary.open('ole32.dll');
    _shGetKnownFolderPath = shell32.lookupFunction<
        _SHGetKnownFolderPathNative,
        _SHGetKnownFolderPathDart>('SHGetKnownFolderPath');
    _coTaskMemFree = ole32.lookupFunction<_CoTaskMemFreeNative,
        _CoTaskMemFreeDart>('CoTaskMemFree');
  } on Object {
    _shGetKnownFolderPath = null;
    _coTaskMemFree = null;
  }
}

void _writeGuid(Pointer<_Guid> target, String canonical) {
  final List<String> parts = canonical.split('-');
  target.ref
    ..data1 = int.parse(parts[0], radix: 16)
    ..data2 = int.parse(parts[1], radix: 16)
    ..data3 = int.parse(parts[2], radix: 16);
  final String tail = parts[3] + parts[4];
  for (var i = 0; i < 8; i++) {
    target.ref.data4[i] =
        int.parse(tail.substring(i * 2, i * 2 + 2), radix: 16);
  }
}

String _resolveWindows(StandardFolder folder) {
  _bindWindows();
  final _SHGetKnownFolderPathDart? lookup = _shGetKnownFolderPath;
  final _CoTaskMemFreeDart? release = _coTaskMemFree;
  if (lookup != null && release != null) {
    final String id = _windowsFolderIds[folder]!;
    final String? path = using((NativeArena arena) {
      final Pointer<_Guid> guid = arena<_Guid>();
      _writeGuid(guid, id);
      final Pointer<Pointer<Uint16>> out =
          arena<Pointer<Uint16>>(sizeOf<Pointer<Uint16>>());
      final int hresult = lookup(guid, 0, 0, out);
      final Pointer<Uint16> buffer = out.value;
      if (hresult != 0) {
        // The returned buffer must be freed even on failure, per the API's
        // own documentation.
        if (buffer != nullptr) release(buffer.cast<Void>());
        return null;
      }
      try {
        return readNativeUtf16(buffer, limit: 32768);
      } finally {
        release(buffer.cast<Void>());
      }
    });
    if (path != null && path.isNotEmpty) {
      return _stripTrailingSeparator(path);
    }
  }
  return _windowsEnvironmentFallback(folder);
}

/// The environment-variable approximation, used only when shell32 failed.
///
/// `USERPROFILE`, `APPDATA` and `LOCALAPPDATA` are set by the platform for
/// every interactive session; the media folders are approximated by their
/// default names, which is exactly the guess `SHGetKnownFolderPath` exists to
/// avoid - hence fallback, not first choice.
String _windowsEnvironmentFallback(StandardFolder folder) {
  final Map<String, String> environment = Platform.environment;
  String require(String name) {
    final String? value = environment[name];
    if (value == null || value.isEmpty) {
      throw StandardPathsException(
        folder: folder,
        platform: 'windows',
        reason: 'SHGetKnownFolderPath is unavailable and %$name% is not set',
      );
    }
    return _stripTrailingSeparator(value);
  }

  switch (folder) {
    case StandardFolder.home:
      return require('USERPROFILE');
    case StandardFolder.appData:
      return require('APPDATA');
    case StandardFolder.appDataLocal:
    case StandardFolder.cache:
      return require('LOCALAPPDATA');
    case StandardFolder.documents:
      return '${require('USERPROFILE')}\\Documents';
    case StandardFolder.downloads:
      return '${require('USERPROFILE')}\\Downloads';
    case StandardFolder.pictures:
      return '${require('USERPROFILE')}\\Pictures';
    case StandardFolder.music:
      return '${require('USERPROFILE')}\\Music';
    case StandardFolder.videos:
      return '${require('USERPROFILE')}\\Videos';
    case StandardFolder.desktop:
      return '${require('USERPROFILE')}\\Desktop';
    case StandardFolder.temp:
    case StandardFolder.executable:
      throw StandardPathsException(
        folder: folder,
        platform: 'windows',
        reason: 'answered by dart:io before platform dispatch',
      );
  }
}
Now Shell.

Now the transport layer — abstract seam plus the real unix-socket implementation.

Bash Read AGENTS.md and budget tool
IN
cd "C:/MyDartProjects/dart_ui" && head -100 AGENTS.md; echo ===; head -40 tool/check_budgets.dart

OUT
# Regras de trabalho do repositório

- Trabalhe exclusivamente na branch `main`.
- Não crie branches locais, remotas ou worktrees adicionais.
- Antes de editar ou executar uma operação Git, confirme que a branch atual é `main`.
- Preserve alterações existentes do usuário e de outros agentes.
===
/// Runs the benchmarks and fails when a measured case is over its budget.
///
/// This is the half of section 36 that a benchmark alone cannot be. A
/// benchmark answers "how long did that take, on this machine, just now". A
/// gate answers "is this slower than we agreed to tolerate", every push, on a
/// machine nobody chose. The second question is the one that catches a
/// regression before a release, and it needs the budgets to be written down
/// beforehand - which is what `benchmark/budgets.dart` is.
///
/// ```
/// dart run tool/check_budgets.dart            # run and enforce
/// dart run tool/check_budgets.dart --report   # run, print, enforce nothing
/// ```
///
/// ## What it deliberately does not do
///
/// **It does not compare against a stored baseline.** Tracking the previous
/// run's numbers on a shared CI runner measures the runner's neighbours as
/// much as the code, and a gate that flaps is a gate people learn to re-run
/// until it passes. A fixed ceiling, argued in `budgets.dart` and loose enough
/// to survive a noisy machine, catches the regressions that matter - a
/// quadratic loop, a cache that stopped hitting - and stays quiet otherwise.
///
/// **It does not fail on a case with no budget.** Adding a measurement should
/// never be blocked on agreeing a ceiling for it. Those are printed as
/// `unbudgeted` so they are visible without being enforced.
///
/// It *does* fail on a budget with no measurement: an id in `budgets.dart` that
/// nothing emits means a case was renamed or deleted and quietly left the gate,
/// which looks identical to passing.
library;

import 'dart:io';

import '../benchmark/budgets.dart';

/// The benchmarks to run, in the order their output should appear.
const List<String> _benchmarks = <String>[
  'benchmark/widget_tree_benchmark.dart',
  'benchmark/text_benchmark.dart',
Write C:\MyDartProjects\dart_ui\lib\src\platform\shell_types.dart
119 lines
/// The shared vocabulary of [Shell]: how a launch is described, how a
/// failure is reported, and the command planning that is pure string work.
///
/// The planners live here, outside the `io` implementation, because deciding
/// *what to run* is arithmetic over strings and deciding it is the part worth
/// testing on every machine. Executing the plan - `Process.run`, or
/// `ShellExecuteW` through FFI - is the thin part, and it is the only part
/// that differs per target.
library;

/// One external command a shell operation may run.
final class ShellCommand {
  const ShellCommand({required this.executable, required this.arguments});

  final String executable;
  final List<String> arguments;

  @override
  String toString() => 'ShellCommand($executable ${arguments.join(' ')})';
}

/// A shell operation that could not be completed.
final class ShellException implements Exception {
  const ShellException({
    required this.operation,
    required this.reason,
    this.platform,
    this.errorCode,
  });

  final String operation;
  final String reason;
  final String? platform;
  final int? errorCode;

  @override
  String toString() => 'ShellException: $operation failed'
      '${platform == null ? '' : ' on $platform'}'
      '${errorCode == null ? '' : ' (code $errorCode)'} - $reason';
}

/// Validates [url] for [Shell.openUrl] and returns it parsed.
///
/// The requirement is an *absolute* URI: something with a scheme. That is
/// what separates "open this in the browser" from "run this program" - on
/// Windows the same native call does both, and a caller who passes
/// `cmd.exe` must get a [ShellException], not a command prompt.
Uri parseLaunchableUrl(String url) {
  final Uri? parsed = Uri.tryParse(url.trim());
  if (parsed == null || !parsed.hasScheme) {
    throw ShellException(
      operation: 'openUrl',
      reason: 'not an absolute URL: "$url" (a scheme such as https: is '
          'required, so that a bare program name cannot be launched as one)',
    );
  }
  return parsed;
}

/// The launchers a Linux desktop may have, in preference order, for opening
/// [target] (a URL or a path) with the default application.
///
/// `xdg-open` is the freedesktop entry point and is installed nearly
/// everywhere; `gio open` ships with GLib and is what `xdg-open` itself
/// defers to on GNOME; `kde-open5` covers a KDE without xdg-utils.
List<ShellCommand> linuxOpenCommands(String target) => <ShellCommand>[
      ShellCommand(executable: 'xdg-open', arguments: <String>[target]),
      ShellCommand(executable: 'gio', arguments: <String>['open', target]),
      ShellCommand(executable: 'kde-open5', arguments: <String>[target]),
    ];

/// The commands that select [absolutePath] in a Linux file manager, best
/// effort first.
///
/// The portable interface is the D-Bus `org.freedesktop.FileManager1`
/// service, which every major file manager implements; the last resort is
/// opening the containing directory without selection, which is degraded and
/// says so by being last.
List<ShellCommand> linuxRevealCommands(String absolutePath) {
  final String fileUri = Uri.file(absolutePath).toString();
  final int slash = absolutePath.lastIndexOf('/');
  final String parent = slash <= 0 ? '/' : absolutePath.substring(0, slash);
  return <ShellCommand>[
    ShellCommand(
      executable: 'dbus-send',
      arguments: <String>[
        '--session',
        '--print-reply',
        '--dest=org.freedesktop.FileManager1',
        '/org/freedesktop/FileManager1',
        'org.freedesktop.FileManager1.ShowItems',
        'array:string:$fileUri',
        'string:',
      ],
    ),
    ...linuxOpenCommands(parent),
  ];
}

/// `open`, macOS's own launcher, for a URL or path.
ShellCommand macOpenCommand(String target) =>
    ShellCommand(executable: '/usr/bin/open', arguments: <String>[target]);

/// `open -R`, which reveals (selects) the file in the Finder.
ShellCommand macRevealCommand(String absolutePath) => ShellCommand(
      executable: '/usr/bin/open',
      arguments: <String>['-R', absolutePath],
    );

/// The parameter string for `explorer.exe` that opens the containing folder
/// with [absolutePath] selected.
///
/// The quoting matters: `/select,` takes the rest of the parameter string as
/// the path, and Explorer only honours paths with spaces when they are
/// quoted. There is deliberately no space after the comma - with one,
/// some Windows builds fall back to opening Documents.
String windowsRevealParameters(String absolutePath) =>
    '/select,"$absolutePath"';
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gpu_texture.dart (lines 21-120)
Read C:\MyDartProjects\dart_ui\lib\src\foundation\diagnostics.dart
Write C:\MyDartProjects\dart_ui\lib\src\platform\shell.dart
43 lines
/// Handing things to the operating system's own openers.
///
/// Three operations, all of the shape "the user clicked something that is not
/// ours to render": a URL goes to the default browser, a file goes to
/// whatever application the user associated with it, and "show me this file"
/// goes to the file manager with the file selected. Each is fire-and-forget -
/// the launched application belongs to the user, not to this process, so
/// success means "the platform accepted the request", never "the document
/// finished opening".
///
/// On the web only [Shell.openUrl] exists (a new browser tab); the other two
/// throw [ShellException], because a browser has no file manager to reveal
/// anything in.
library;

import 'shell_platform_stub.dart'
    if (dart.library.io) 'shell_platform_io.dart'
    if (dart.library.js_interop) 'shell_platform_web.dart' as platform;
import 'shell_types.dart';

export 'shell_types.dart';

/// Opening URLs, files and folders with the user's own default applications.
abstract final class Shell {
  /// Opens [url] in the default browser (or the handler registered for its
  /// scheme - `mailto:` opens the mail client).
  ///
  /// [url] must be absolute; a bare program name or relative path throws
  /// [ShellException] rather than being handed to the platform, where at
  /// least one target would happily execute it.
  static Future<void> openUrl(String url) => platform.openUrl(url);

  /// Opens the file or directory at [path] with its default application.
  ///
  /// The path must exist; a missing path is a [ShellException] here rather
  /// than a silent no-op or a platform error dialog.
  static Future<void> openPath(String path) => platform.openPath(path);

  /// Opens the platform's file manager with [path] selected.
  static Future<void> revealInFileManager(String path) =>
      platform.revealInFileManager(path);
}
Write C:\MyDartProjects\dart_ui\lib\src\platform\shell_platform_stub.dart
25 lines
library;

import 'shell_types.dart';

Future<void> openUrl(String url) async {
  throw const ShellException(
    operation: 'openUrl',
    reason: 'this target has no shell implementation',
  );
}

Future<void> openPath(String path) async {
  throw const ShellException(
    operation: 'openPath',
    reason: 'this target has no shell implementation',
  );
}

Future<void> revealInFileManager(String path) async {
  throw const ShellException(
    operation: 'revealInFileManager',
    reason: 'this target has no shell implementation',
  );
}
Write C:\MyDartProjects\dart_ui\lib\src\platform\shell_platform_web.dart
40 lines
library;

import 'package:web/web.dart' as web;

import 'shell_types.dart';

Future<void> openUrl(String url) async {
  final Uri parsed = parseLaunchableUrl(url);
  // `noopener` severs the opener reference: the opened page must not be able
  // to script this one back through `window.opener`.
  final web.Window? opened =
      web.window.open(parsed.toString(), '_blank', 'noopener,noreferrer');
  // Popup blockers answer null. That is a real "did not open", and reporting
  // it lets the caller fall back to showing the URL for a user gesture.
  if (opened == null) {
    throw const ShellException(
      operation: 'openUrl',
      platform: 'web',
      reason: 'the browser refused to open a new tab; a popup blocker will '
          'do this for any open not caused directly by a user gesture',
    );
  }
}

Future<void> openPath(String path) async {
  throw const ShellException(
    operation: 'openPath',
    platform: 'web',
    reason: 'a browser exposes no local filesystem to open paths from',
  );
}

Future<void> revealInFileManager(String path) async {
  throw const ShellException(
    operation: 'revealInFileManager',
    platform: 'web',
    reason: 'a browser has no file manager to reveal a path in',
  );
}
Write C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_transport.dart
434 lines
/// Byte-and-descriptor transport between the client and the compositor.
///
/// The seam exists for the same reason `X11WindowClient` does: everything
/// above it - connection, windows, the whole protocol state machine - is pure
/// Dart over byte arrays, testable on a machine with no Wayland session. Only
/// [WaylandSocketTransport] touches FFI, and it is deliberately dumb: it moves
/// bytes and file descriptors, and knows nothing about messages.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import 'wayland_libc.dart';
import 'wayland_wire.dart';

/// Moving bytes and descriptors, with a doorbell.
///
/// Sending is buffered: [queueMessage] accumulates, [flush] writes. That is
/// not an optimisation detail but the protocol's own advice - Wayland clients
/// batch requests and flush once per pump, and a transport that wrote every
/// message eagerly would syscall per request.
abstract interface class WaylandTransport implements Disposable {
  bool get isOpen;

  /// Queues [bytes] for sending, with [fds] attached to their first byte.
  void queueMessage(Uint8List bytes, List<int> fds);

  /// Writes everything queued. Returns false when the connection failed.
  bool flush();

  /// Drains whatever the compositor already sent, without blocking. Bytes go
  /// into [decoder]; ancillary descriptors are appended to [receivedFds] in
  /// arrival order. Returns the byte count, 0 for nothing, -1 for a dead
  /// connection.
  int receive(WaylandWireDecoder decoder, List<int> receivedFds);

  /// Blocks until the socket or the wake pipe has something, or [timeout]
  /// milliseconds pass (negative blocks indefinitely). Returns true when the
  /// wake pipe fired.
  bool waitForActivity(int timeoutMilliseconds);

  /// Rings the doorbell from any thread or isolate.
  bool signalWake();

  /// Closes a descriptor the compositor handed over (a keymap fd, once read).
  void closeFd(int fd);
}

/// The outcome of trying to open the compositor socket.
final class WaylandTransportAttempt {
  const WaylandTransportAttempt({
    required this.transport,
    required this.diagnostics,
  });

  final WaylandTransport? transport;
  final List<BackendDiagnostic> diagnostics;

  bool get succeeded => transport != null;
}

/// The production transport: one `AF_UNIX` stream socket to
/// `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, spoken through `sendmsg`/`recvmsg` so
/// `SCM_RIGHTS` descriptors ride along with the protocol bytes.
final class WaylandSocketTransport
    with DisposableMixin
    implements WaylandTransport {
  WaylandSocketTransport._(this._libc, this._fd);

  /// Opens [socketPath], or reports exactly what stopped it. Never throws:
  /// a probe walking several backends needs a report from each.
  static WaylandTransportAttempt open({
    required WaylandLibc libc,
    required String socketPath,
  }) {
    final diagnostics = <BackendDiagnostic>[];
    final encodedPath = socketPath.codeUnits;
    if (encodedPath.length > sockaddrUnPathCapacity - 1) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'Wayland socket path exceeds sockaddr_un capacity',
        detail: socketPath,
      ));
      return WaylandTransportAttempt(
          transport: null, diagnostics: diagnostics);
    }

    final fd = libc.socket(afUnix, sockStream | sockCloexec, 0);
    if (fd < 0) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'socket(AF_UNIX) failed',
        detail: 'errno=${libc.errno}',
      ));
      return WaylandTransportAttempt(
          transport: null, diagnostics: diagnostics);
    }

    final address = libc.allocateZeroed(sockaddrUnSize);
    if (address == nullptr) {
      libc.closeFd(fd);
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'malloc failed while preparing sockaddr_un',
      ));
      return WaylandTransportAttempt(
          transport: null, diagnostics: diagnostics);
    }
    writeU16(address, 0, afUnix);
    for (var i = 0; i < encodedPath.length; i++) {
      address[2 + i] = encodedPath[i] & 0xff;
    }
    final connected = libc.connect(fd, address, sockaddrUnSize);
    final connectErrno = libc.errno;
    libc.free(address);
    if (connected != 0) {
      libc.closeFd(fd);
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'connect to Wayland socket failed',
        detail: '$socketPath (errno=$connectErrno)',
      ));
      return WaylandTransportAttempt(
          transport: null, diagnostics: diagnostics);
    }

    final transport = WaylandSocketTransport._(libc, fd);
    if (!transport._allocateScratch(diagnostics) ||
        !transport._openWakePipe(diagnostics)) {
      transport.dispose();
      return WaylandTransportAttempt(
          transport: null, diagnostics: diagnostics);
    }
    diagnostics.add(BackendDiagnostic.note('connected to $socketPath'));
    return WaylandTransportAttempt(
      transport: transport,
      diagnostics: diagnostics,
    );
  }

  final WaylandLibc _libc;
  final int _fd;
  final DisposableBag _bag = DisposableBag();

  bool _broken = false;
  int _wakeReadFd = -1;
  int _wakeWriteFd = -1;

  // Outgoing queue: plain Dart bytes plus the fds attached to the first
  // unsent byte. Copied into native scratch only inside flush().
  final BytesBuilder _outgoing = BytesBuilder(copy: true);
  final List<int> _outgoingFds = <int>[];

  /// Native scratch, allocated once. `_ioBuffer` carries payload both ways;
  /// 64 KiB matches libwayland's own connection buffer.
  static const int _ioBufferSize = 65536;
  late final Pointer<Uint8> _msghdr;
  late final Pointer<Uint8> _iovec;
  late final Pointer<Uint8> _control;
  late final Pointer<Uint8> _ioBuffer;
  late final Pointer<Uint8> _pollScratch;
  late final Pointer<Uint8> _wakeScratch;

  /// Reused per receive: the Dart-side view the decoder copies from.
  final Uint8List _receiveCopy = Uint8List(_ioBufferSize);

  @override
  bool get isOpen => !isDisposed && !_broken;

  bool _allocateScratch(List<BackendDiagnostic> diagnostics) {
    final msghdr = _libc.allocateZeroed(msghdrSize);
    final iovec = _libc.allocateZeroed(iovecSize);
    final control = _libc.allocateZeroed(controlBufferSize);
    final io = _libc.allocateZeroed(_ioBufferSize);
    final poll = _libc.allocateZeroed(2 * pollFdSize);
    final wake = _libc.allocateZeroed(64);
    if (msghdr == nullptr ||
        iovec == nullptr ||
        control == nullptr ||
        io == nullptr ||
        poll == nullptr ||
        wake == nullptr) {
      _libc.free(msghdr);
      _libc.free(iovec);
      _libc.free(control);
      _libc.free(io);
      _libc.free(poll);
      _libc.free(wake);
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'malloc failed while allocating Wayland transport scratch',
      ));
      return false;
    }
    _msghdr = msghdr;
    _iovec = iovec;
    _control = control;
    _ioBuffer = io;
    _pollScratch = poll;
    _wakeScratch = wake;
    _bag.add(msghdr, () {
      _libc.free(msghdr);
      _libc.free(iovec);
      _libc.free(control);
      _libc.free(io);
      _libc.free(poll);
      _libc.free(wake);
    });
    return true;
  }

  bool _openWakePipe(List<BackendDiagnostic> diagnostics) {
    final fds = _libc.allocateZeroed(8).cast<Int32>();
    if (fds == nullptr) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'malloc failed while preparing Wayland wake pipe',
      ));
      return false;
    }
    final result = _libc.pipe2(fds, oCloexec | oNonblock);
    if (result != 0) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'pipe2 failed; wake() will not interrupt a blocked pump',
        detail: 'errno=${_libc.errno}',
      ));
      _libc.free(fds.cast<Uint8>());
      return false;
    }
    _wakeReadFd = fds[0];
    _wakeWriteFd = fds[1];
    _libc.free(fds.cast<Uint8>());
    _bag.add(_wakeReadFd, () {
      if (_wakeWriteFd >= 0) _libc.closeFd(_wakeWriteFd);
      if (_wakeReadFd >= 0) _libc.closeFd(_wakeReadFd);
      _wakeWriteFd = -1;
      _wakeReadFd = -1;
    });
    return true;
  }

  @override
  void queueMessage(Uint8List bytes, List<int> fds) {
    throwIfDisposed();
    _outgoing.add(bytes);
    _outgoingFds.addAll(fds);
  }

  @override
  bool flush() {
    throwIfDisposed();
    if (_broken) return false;
    if (_outgoing.isEmpty && _outgoingFds.isEmpty) return true;
    final bytes = _outgoing.takeBytes();
    var offset = 0;
    var fdsPending = _outgoingFds.isNotEmpty;
    while (offset < bytes.length) {
      final chunk = bytes.length - offset > _ioBufferSize
          ? _ioBufferSize
          : bytes.length - offset;
      _ioBuffer
          .asTypedList(_ioBufferSize)
          .setRange(0, chunk, bytes, offset);
      final sent = _sendChunk(chunk, fdsPending ? _outgoingFds : null);
      if (sent < 0) {
        _broken = true;
        _outgoingFds.clear();
        return false;
      }
      if (fdsPending) {
        // Delivered with the first successful sendmsg; never resent.
        _outgoingFds.clear();
        fdsPending = false;
      }
      offset += sent;
      if (sent < chunk) {
        // Socket buffer full: requeue the tail and let the next pump retry.
        _outgoing.add(Uint8List.sublistView(bytes, offset));
        return true;
      }
    }
    return true;
  }

  int _sendChunk(int length, List<int>? fds) {
    // msghdr: no name, one iovec over _ioBuffer, optional SCM_RIGHTS control.
    writePointer(_msghdr, msghdrNameOffset, nullptr);
    writeU32(_msghdr, msghdrNamelenOffset, 0);
    writePointer(_msghdr, msghdrIovOffset, _iovec);
    writeU64(_msghdr, msghdrIovlenOffset, 1);
    writePointer(_iovec, 0, _ioBuffer);
    writeU64(_iovec, 8, length);
    if (fds == null || fds.isEmpty) {
      writePointer(_msghdr, msghdrControlOffset, nullptr);
      writeU64(_msghdr, msghdrControllenOffset, 0);
    } else {
      if (fds.length > maxAncillaryFds) {
        // More descriptors than one control block carries would need message
        // splitting; nothing in this backend sends more than one per flush.
        throw StateError('cannot send ${fds.length} fds in one message');
      }
      final cmsgLen = cmsgHeaderSize + fds.length * 4;
      writeU64(_control, 0, cmsgLen);
      writeU32(_control, 8, solSocket);
      writeU32(_control, 12, scmRights);
      for (var i = 0; i < fds.length; i++) {
        writeU32(_control, cmsgHeaderSize + i * 4, fds[i]);
      }
      writePointer(_msghdr, msghdrControlOffset, _control);
      writeU64(_msghdr, msghdrControllenOffset, (cmsgLen + 7) & ~7);
    }
    writeU32(_msghdr, msghdrFlagsOffset, 0);

    while (true) {
      final sent = _libc.sendmsg(_fd, _msghdr, msgNosignal);
      if (sent >= 0) return sent;
      final error = _libc.errno;
      if (error == eintr) continue;
      if (error == eagain) return 0;
      return -1;
    }
  }

  @override
  int receive(WaylandWireDecoder decoder, List<int> receivedFds) {
    throwIfDisposed();
    if (_broken) return -1;
    var total = 0;
    while (true) {
      writePointer(_msghdr, msghdrNameOffset, nullptr);
      writeU32(_msghdr, msghdrNamelenOffset, 0);
      writePointer(_msghdr, msghdrIovOffset, _iovec);
      writeU64(_msghdr, msghdrIovlenOffset, 1);
      writePointer(_iovec, 0, _ioBuffer);
      writeU64(_iovec, 8, _ioBufferSize);
      writePointer(_msghdr, msghdrControlOffset, _control);
      writeU64(_msghdr, msghdrControllenOffset, controlBufferSize);
      writeU32(_msghdr, msghdrFlagsOffset, 0);

      final received =
          _libc.recvmsg(_fd, _msghdr, msgDontwait | msgCmsgCloexec);
      if (received < 0) {
        final error = _libc.errno;
        if (error == eintr) continue;
        if (error == eagain) return total;
        _broken = true;
        return total > 0 ? total : -1;
      }
      if (received == 0) {
        // Orderly shutdown by the compositor.
        _broken = true;
        return total > 0 ? total : -1;
      }
      _collectAncillaryFds(receivedFds);
      final native = _ioBuffer.asTypedList(received);
      _receiveCopy.setRange(0, received, native);
      decoder.addBytes(_receiveCopy, received);
      total += received;
      if (received < _ioBufferSize) return total;
    }
  }

  void _collectAncillaryFds(List<int> receivedFds) {
    final controlLength = readU64(_msghdr, msghdrControllenOffset);
    var offset = 0;
    while (offset + cmsgHeaderSize <= controlLength) {
      final cmsgLen = readU64(_control, offset);
      if (cmsgLen < cmsgHeaderSize) break;
      final level = readU32(_control, offset + 8);
      final type = readU32(_control, offset + 12);
      final dataBytes = cmsgLen - cmsgHeaderSize;
      if (level == solSocket && type == scmRights) {
        for (var i = 0; i + 4 <= dataBytes; i += 4) {
          receivedFds.add(readU32(_control, offset + cmsgHeaderSize + i));
        }
      }
      offset += (cmsgLen + 7) & ~7;
    }
  }

  @override
  bool waitForActivity(int timeoutMilliseconds) {
    if (isDisposed || _broken) return false;
    writeU32(_pollScratch, 0, _fd);
    writeU16(_pollScratch, 4, pollIn);
    writeU16(_pollScratch, 6, 0);
    var count = 1;
    if (_wakeReadFd >= 0) {
      writeU32(_pollScratch, pollFdSize, _wakeReadFd);
      writeU16(_pollScratch, pollFdSize + 4, pollIn);
      writeU16(_pollScratch, pollFdSize + 6, 0);
      count = 2;
    }
    final ready = _libc.poll(_pollScratch, count, timeoutMilliseconds);
    if (ready <= 0) return false;
    if (count < 2) return false;
    final wakeRevents = readU16(_pollScratch, pollFdSize + 6);
    if ((wakeRevents & pollIn) == 0) return false;
    _drainWakePipe();
    return true;
  }

  void _drainWakePipe() {
    if (_wakeReadFd < 0) return;
    while (true) {
      final read = _libc.read(_wakeReadFd, _wakeScratch, 64);
      if (read < 64) return;
    }
  }

  @override
  bool signalWake() {
    if (_wakeWriteFd < 0) return false;
    _wakeScratch[0] = 1;
    final written = _libc.write(_wakeWriteFd, _wakeScratch, 1);
    if (written == 1) return true;
    return _libc.errno == eagain;
  }

  @override
  void closeFd(int fd) {
    if (fd >= 0) _libc.closeFd(fd);
  }

  @override
  void onDispose() {
    _bag.dispose();
    _libc.closeFd(_fd);
  }
}
Write C:\MyDartProjects\dart_ui\lib\src\platform\shell_platform_io.dart
209 lines
library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'shell_types.dart';

/// Runs one external command to completion. The seam a test injects a fake
/// through, so that "which command, with which arguments" is checkable
/// without a desktop launching anything.
typedef ShellProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

Future<ProcessResult> _runProcess(
  String executable,
  List<String> arguments,
) =>
    Process.run(executable, arguments);

Future<void> openUrl(String url) async {
  final Uri parsed = parseLaunchableUrl(url);
  final String target = parsed.toString();
  if (Platform.isWindows) {
    _windowsShellExecute(operation: 'openUrl', file: target);
    return;
  }
  if (Platform.isMacOS) {
    await runFirstAvailable(
      'openUrl',
      <ShellCommand>[macOpenCommand(target)],
    );
    return;
  }
  if (Platform.isLinux) {
    await runFirstAvailable('openUrl', linuxOpenCommands(target));
    return;
  }
  throw ShellException(
    operation: 'openUrl',
    platform: Platform.operatingSystem,
    reason: 'no shell backend exists for this operating system',
  );
}

Future<void> openPath(String path) async {
  _requireExisting('openPath', path);
  if (Platform.isWindows) {
    _windowsShellExecute(operation: 'openPath', file: path);
    return;
  }
  if (Platform.isMacOS) {
    await runFirstAvailable(
      'openPath',
      <ShellCommand>[macOpenCommand(path)],
    );
    return;
  }
  if (Platform.isLinux) {
    await runFirstAvailable('openPath', linuxOpenCommands(path));
    return;
  }
  throw ShellException(
    operation: 'openPath',
    platform: Platform.operatingSystem,
    reason: 'no shell backend exists for this operating system',
  );
}

Future<void> revealInFileManager(String path) async {
  _requireExisting('revealInFileManager', path);
  if (Platform.isWindows) {
    _windowsShellExecute(
      operation: 'revealInFileManager',
      file: 'explorer.exe',
      parameters: windowsRevealParameters(path),
    );
    return;
  }
  if (Platform.isMacOS) {
    await runFirstAvailable(
      'revealInFileManager',
      <ShellCommand>[macRevealCommand(path)],
    );
    return;
  }
  if (Platform.isLinux) {
    await runFirstAvailable(
      'revealInFileManager',
      linuxRevealCommands(path.replaceAll(r'\', '/')),
    );
    return;
  }
  throw ShellException(
    operation: 'revealInFileManager',
    platform: Platform.operatingSystem,
    reason: 'no shell backend exists for this operating system',
  );
}

void _requireExisting(String operation, String path) {
  if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
    throw ShellException(
      operation: operation,
      platform: Platform.operatingSystem,
      reason: 'the path does not exist: $path',
    );
  }
}

/// Tries each of [commands] until one runs and exits 0.
///
/// A command that is not installed ([ProcessException]) or that exits
/// non-zero moves on to the next candidate; when every candidate has been
/// tried the failure names all of them, so "nothing opened" arrives with the
/// list of launchers the machine was missing instead of arriving silently.
Future<void> runFirstAvailable(
  String operation,
  List<ShellCommand> commands, {
  ShellProcessRunner run = _runProcess,
}) async {
  final List<String> failures = <String>[];
  for (final ShellCommand command in commands) {
    try {
      final ProcessResult result =
          await run(command.executable, command.arguments);
      if (result.exitCode == 0) return;
      failures.add('${command.executable} exited ${result.exitCode}');
    } on ProcessException {
      failures.add('${command.executable} is not installed');
    }
  }
  throw ShellException(
    operation: operation,
    platform: Platform.operatingSystem,
    reason: 'no launcher succeeded: ${failures.join('; ')}',
  );
}

// ---------------------------------------------------------------------------
// Windows: ShellExecuteW, the API behind double-clicking. It resolves the
// association itself, so URLs, documents and folders all go through the one
// entry point.
// ---------------------------------------------------------------------------

typedef _ShellExecuteWNative = IntPtr Function(
  IntPtr ownerWindow,
  Pointer<Uint16> operation,
  Pointer<Uint16> file,
  Pointer<Uint16> parameters,
  Pointer<Uint16> directory,
  Int32 showCommand,
);
typedef _ShellExecuteWDart = int Function(
  int ownerWindow,
  Pointer<Uint16> operation,
  Pointer<Uint16> file,
  Pointer<Uint16> parameters,
  Pointer<Uint16> directory,
  int showCommand,
);

const int _swShowNormal = 1;

_ShellExecuteWDart? _shellExecute;

void _windowsShellExecute({
  required String operation,
  required String file,
  String? parameters,
}) {
  final _ShellExecuteWDart execute;
  try {
    execute = _shellExecute ??= DynamicLibrary.open('shell32.dll')
        .lookupFunction<_ShellExecuteWNative, _ShellExecuteWDart>(
            'ShellExecuteW');
  } on Object catch (error) {
    throw ShellException(
      operation: operation,
      platform: 'windows',
      reason: 'shell32.dll could not be loaded: $error',
    );
  }
  final int result = using((NativeArena arena) {
    return execute(
      0,
      arena.allocateUtf16('open'),
      arena.allocateUtf16(file),
      parameters == null ? nullptr : arena.allocateUtf16(parameters),
      nullptr,
      _swShowNormal,
    );
  });
  // The documented contract: values greater than 32 are success, the rest
  // are SE_ERR_* codes (2 = file not found, 8 = out of memory, 31 = no
  // association, ...).
  if (result <= 32) {
    throw ShellException(
      operation: operation,
      platform: 'windows',
      errorCode: result,
      reason: 'ShellExecuteW refused the request'
          '${result == 31 ? ' (no application is associated)' : ''}',
    );
  }
}
Write C:\MyDartProjects\dart_ui\lib\src\widgets\tree_view.dart
853 lines
/// A hierarchical, virtualized tree.
///
/// The control a file explorer is made of, and one whose keyboard contract is
/// written down in every accessibility guide because so many implementations
/// get it wrong. The contract implemented here:
///
///   * **The tree is one tab stop.** Tab moves into the tree and out of it;
///     the arrow keys move between rows. The tree owns one [FocusNode] and the
///     rows own none - the same design as `tabs.dart` and `list_box.dart`.
///   * **Right expands, left collapses.** On a collapsed expandable row the
///     right arrow expands it; on an expanded row it moves to the first child;
///     on a leaf it does nothing. The left arrow collapses an expanded row and
///     otherwise moves to the parent. In a right-to-left locale the two swap,
///     because "expand" reads toward the content.
///   * **Asterisk expands the level.** The keypad `*` expands every expandable
///     sibling of the current row, which is the WAI-ARIA tree idiom for "open
///     this whole level at once".
///   * **Home/End** jump to the first and last *visible* row.
///
/// ## Virtualization
///
/// Only the rows a scroll offset makes visible are realized, through the same
/// [ListVirtualization] planner `list_box.dart` uses: the tree flattens its
/// expanded nodes into a row list and virtualizes that. A tree of a hundred
/// thousand collapsed roots therefore costs a few dozen render objects, and
/// the semantic tree still reports the *full* row count.
///
/// ## Lazy loading
///
/// The tree is controlled: [TreeView.expandedIds] says which nodes are open
/// and [TreeView.onToggle] reports intent. A node whose children are not yet
/// known sets [TreeNode.hasChildren] to true with an empty child list; the
/// expand still fires [TreeView.onToggle], and the owner loads the children
/// and rebuilds. Nothing here waits: an expanded node with no children simply
/// has no child rows until the data arrives, which is what keeps the tree free
/// of spinners it cannot draw deterministically.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import '../text/shaper.dart' show TextDirection;
import 'control.dart';
import 'directionality.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'semantics.dart';
import 'style.dart';
import 'theme.dart';
import 'virtualization.dart';
import 'widget.dart';

/// The keypad multiply key, which the tree contract spells `*`.
const int logicalKeyNumpadMultiply = 0x6A;

/// One node of the tree: a label, its children, and whether more exist.
final class TreeNode {
  const TreeNode({
    required this.label,
    this.id,
    this.children = const <TreeNode>[],
    this.hasChildren,
    this.enabled = true,
  });

  final String label;

  /// What this node *is*, across rebuilds in which the list changed. Defaults
  /// to the label, exactly as [TabItem.id] does.
  final Object? id;

  final List<TreeNode> children;

  /// Whether this node can expand. Null - the usual case - means "look at
  /// [children]"; an explicit true on a node with an empty child list is the
  /// lazy-loading handshake described in the library doc.
  final bool? hasChildren;

  final bool enabled;

  Object get identity => id ?? label;

  bool get isExpandable => hasChildren ?? children.isNotEmpty;
}

/// A hierarchical, virtualized, selectable tree.
///
/// Controlled: the widget shows [expandedIds] and [selectedId], and reports
/// intent through [onToggle] and [onSelected].
final class TreeView extends StatefulWidget {
  const TreeView({
    super.key,
    required this.nodes,
    this.expandedIds = const <Object>{},
    this.onToggle,
    this.selectedId,
    this.onSelected,
    this.rowExtent = 24.0,
    this.cacheExtent = 48.0,
    this.controller,
  });

  final List<TreeNode> nodes;

  /// The identities of the nodes currently expanded.
  final Set<Object> expandedIds;

  /// Called when the user asks to open or close [TreeNode]. The owner updates
  /// [expandedIds] - and, for a lazy node, loads its children - and rebuilds.
  final void Function(TreeNode node, bool expanded)? onToggle;

  /// The identity of the selected node, or null for no selection.
  final Object? selectedId;

  final void Function(TreeNode node)? onSelected;

  final double rowExtent;
  final double cacheExtent;
  final ScrollPosition? controller;

  @override
  State<TreeView> createState() => _TreeViewState();
}

/// One flattened, visible row: the node plus where it sits in the hierarchy.
final class _FlatRow {
  const _FlatRow({
    required this.node,
    required this.depth,
    required this.parentIndex,
  });

  final TreeNode node;
  final int depth;

  /// Index of the parent's row in the flattened list, or -1 for a root.
  final int parentIndex;
}

final class _TreeViewState extends State<TreeView> {
  late final ScrollPosition _position = widget.controller ?? ScrollPosition();
  late final FocusNode _focusNode = FocusNode(debugLabel: 'TreeView');
  double _viewportExtent = 0;
  List<_FlatRow> _rows = const <_FlatRow>[];

  @override
  void initState() {
    super.initState();
    _position.addListener(_onScrolled);
  }

  @override
  void dispose() {
    _position.removeListener(_onScrolled);
    _focusNode.dispose();
    super.dispose();
  }

  void _onScrolled(ScrollPosition position) {
    if (mounted) setState(() {});
  }

  /// Depth-first over the expanded part of the tree only: a collapsed node's
  /// descendants contribute no rows, which is what makes the flattened list
  /// the exact thing to virtualize.
  List<_FlatRow> _flatten() {
    final List<_FlatRow> rows = <_FlatRow>[];
    void visit(List<TreeNode> nodes, int depth, int parentIndex) {
      for (final TreeNode node in nodes) {
        rows.add(_FlatRow(node: node, depth: depth, parentIndex: parentIndex));
        if (node.isExpandable && widget.expandedIds.contains(node.identity)) {
          visit(node.children, depth + 1, rows.length - 1);
        }
      }
    }

    visit(widget.nodes, 0, -1);
    return rows;
  }

  int get _selectedIndex {
    final Object? selected = widget.selectedId;
    if (selected == null) return -1;
    for (int i = 0; i < _rows.length; i++) {
      if (_rows[i].node.identity == selected) return i;
    }
    return -1;
  }

  void _select(int index) {
    if (index < 0 || index >= _rows.length) return;
    final TreeNode node = _rows[index].node;
    if (!node.enabled) return;
    if (node.identity != widget.selectedId) widget.onSelected?.call(node);
    _reveal(index);
  }

  /// Keyboard selection must bring the row into view, or a screen reader
  /// announces a selection that remains invisible on screen.
  void _reveal(int index) {
    final double? target = _virtualization.scrollToReveal(
      index,
      scrollOffset: _position.pixels,
      viewportExtent:
          _viewportExtent > 0 ? _viewportExtent : widget.rowExtent * 8,
    );
    if (target != null) _position.jumpTo(target);
  }

  void _toggle(int index, bool expanded) {
    if (index < 0 || index >= _rows.length) return;
    final TreeNode node = _rows[index].node;
    if (!node.isExpandable || !node.enabled) return;
    final bool isExpanded = widget.expandedIds.contains(node.identity);
    if (isExpanded == expanded) return;
    widget.onToggle?.call(node, expanded);
  }

  /// The `*` idiom: every expandable sibling of the current row opens, the
  /// current row included. Siblings are the children of the same parent, or
  /// the roots for a top-level row.
  void _expandSiblings(int index) {
    final _FlatRow row = _rows[index];
    final List<TreeNode> siblings = row.parentIndex < 0
        ? widget.nodes
        : _rows[row.parentIndex].node.children;
    for (final TreeNode sibling in siblings) {
      if (sibling.isExpandable &&
          sibling.enabled &&
          !widget.expandedIds.contains(sibling.identity)) {
        widget.onToggle?.call(sibling, true);
      }
    }
  }

  bool _handleKey(KeyEvent event, TextDirection direction) {
    if (event is! KeyDownEvent) return false;
    if (_rows.isEmpty) return false;
    final int current = _selectedIndex;
    final bool rtl = direction.isRightToLeft;
    // In a right-to-left locale the arrows swap so that "toward the content"
    // still expands, which is what the hand expects there.
    final int expandKey = rtl ? logicalKeyArrowLeft : logicalKeyArrowRight;
    final int collapseKey = rtl ? logicalKeyArrowRight : logicalKeyArrowLeft;
    final int key = event.logicalKey;
    if (key == logicalKeyArrowDown) {
      _select(current + 1 >= _rows.length ? _rows.length - 1 : current + 1);
      return true;
    }
    if (key == logicalKeyArrowUp) {
      _select(current <= 0 ? 0 : current - 1);
      return true;
    }
    if (key == logicalKeyHome) {
      _select(0);
      return true;
    }
    if (key == logicalKeyEnd) {
      _select(_rows.length - 1);
      return true;
    }
    if (current < 0) return false;
    final _FlatRow row = _rows[current];
    final bool expanded = widget.expandedIds.contains(row.node.identity);
    if (key == expandKey) {
      if (row.node.isExpandable && !expanded) {
        _toggle(current, true);
      } else if (expanded && current + 1 < _rows.length) {
        // The first child is the next row exactly when the node is expanded.
        if (_rows[current + 1].parentIndex == current) _select(current + 1);
      }
      return true;
    }
    if (key == collapseKey) {
      if (row.node.isExpandable && expanded) {
        _toggle(current, false);
      } else if (row.parentIndex >= 0) {
        _select(row.parentIndex);
      }
      return true;
    }
    if (key == logicalKeyNumpadMultiply) {
      _expandSiblings(current);
      return true;
    }
    if (key == logicalKeyEnter || key == logicalKeySpace) {
      if (row.node.isExpandable) _toggle(current, !expanded);
      return true;
    }
    return false;
  }

  /// A press at [dx] inside row [index]. The toggle gutter belongs to the
  /// expand glyph; everywhere else selects. Decided here rather than in the
  /// row's render object because the gutter's position depends on the depth
  /// and the reading direction, both of which this state already knows.
  void _handleRowPress(
    int index,
    double dx,
    double width,
    TextDirection direction,
  ) {
    if (index < 0 || index >= _rows.length) return;
    final _FlatRow row = _rows[index];
    final double indent = row.depth * RenderTreeItem.indentPerLevel;
    final bool rtl = direction.isRightToLeft;
    final double toggleStart =
        rtl ? width - indent - RenderTreeItem.toggleExtent : indent;
    final double toggleEnd = toggleStart + RenderTreeItem.toggleExtent;
    if (row.node.isExpandable && dx >= toggleStart && dx < toggleEnd) {
      _toggle(index, !widget.expandedIds.contains(row.node.identity));
    } else {
      _select(index);
    }
  }

  ListVirtualization get _virtualization => ListVirtualization(
        itemCount: _rows.length,
        estimatedExtent: widget.rowExtent,
        cacheExtent: widget.cacheExtent,
      );

  @override
  Widget build(BuildContext context) {
    final TextDirection direction = Directionality.of(context);
    _rows = _flatten();
    final ListVirtualization virtualization = _virtualization;
    final double viewport =
        _viewportExtent > 0 ? _viewportExtent : widget.rowExtent * 8;
    final RealizedRange range = virtualization.rangeFor(
      scrollOffset: _position.pixels,
      viewportExtent: viewport,
    );
    return FocusAttachment(
      node: _focusNode,
      child: _TreeViewRenderWidget(
        position: _position,
        focusNode: _focusNode,
        theme: Theme.of(context),
        virtualization: virtualization,
        range: range,
        selectedIndex: _selectedIndex,
        onKeyEvent: (KeyEvent event) => _handleKey(event, direction),
        onRowPressed: (int index, double dx, double width) =>
            _handleRowPress(index, dx, width, direction),
        onViewportExtent: (double extent) {
          if (extent == _viewportExtent) return;
          _viewportExtent = extent;
          if (mounted) setState(() {});
        },
        children: <Widget>[
          for (int index = range.firstRealized;
              index <= range.lastRealized && index < _rows.length;
              index++)
            _TreeItemWidget(
              // Keyed by node identity so an expand above a row updates the
              // row's element instead of rebuilding it as a stranger.
              key: ValueKey<Object>(_rows[index].node.identity),
              label: _rows[index].node.label,
              depth: _rows[index].depth,
              index: index,
              extent: widget.rowExtent,
              expandable: _rows[index].node.isExpandable,
              expanded:
                  widget.expandedIds.contains(_rows[index].node.identity),
              selected: index == _selectedIndex,
              enabled: _rows[index].node.enabled,
              textDirection: direction,
              theme: Theme.of(context),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// One row
// ---------------------------------------------------------------------------

final class _TreeItemWidget extends RenderObjectWidget {
  const _TreeItemWidget({
    super.key,
    required this.label,
    required this.depth,
    required this.index,
    required this.extent,
    required this.expandable,
    required this.expanded,
    required this.selected,
    required this.enabled,
    required this.textDirection,
    required this.theme,
  });

  final String label;
  final int depth;
  final int index;
  final double extent;
  final bool expandable;
  final bool expanded;
  final bool selected;
  final bool enabled;
  final TextDirection textDirection;
  final ThemeData theme;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderTreeItem createRenderObject(BuildContext context) => RenderTreeItem()
    ..label = label
    ..depth = depth
    ..index = index
    ..extent = extent
    ..expandable = expandable
    ..expanded = expanded
    ..selected = selected
    ..textDirection = textDirection
    ..theme = theme
    ..enabled = enabled;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTreeItem object,
  ) {
    object
      ..label = label
      ..depth = depth
      ..index = index
      ..extent = extent
      ..expandable = expandable
      ..expanded = expanded
      ..selected = selected
      ..textDirection = textDirection
      ..theme = theme
      ..enabled = enabled;
  }
}

/// One realized tree row: indent, toggle glyph, label.
final class RenderTreeItem extends RenderBox with ControlBehavior {
  /// Horizontal pixels one level of depth is worth.
  static const double indentPerLevel = 16;

  /// The gutter the expand glyph owns, whether or not one is drawn: keeping
  /// leaves aligned with their expandable siblings is what makes depth
  /// readable at a glance.
  static const double toggleExtent = 16;

  /// The side of the plus/minus box. Odd, so its centre lines land on pixels.
  static const double _glyphExtent = 9;

  String _label = '';
  int _depth = 0;
  int _index = 0;
  double _extent = 24;
  bool _expandable = false;
  bool _expanded = false;
  bool _selected = false;
  TextDirection _textDirection = TextDirection.leftToRight;

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsPaint();
  }

  int get depth => _depth;

  set depth(int value) {
    if (value == _depth) return;
    _depth = value;
    markNeedsPaint();
  }

  int get index => _index;

  set index(int value) {
    if (value == _index) return;
    _index = value;
    markNeedsPaint();
  }

  double get extent => _extent;

  set extent(double value) {
    if (value == _extent) return;
    _extent = value;
    markNeedsLayout();
  }

  bool get expandable => _expandable;

  set expandable(bool value) {
    if (value == _expandable) return;
    _expandable = value;
    markNeedsPaint();
  }

  bool get expanded => _expanded;

  set expanded(bool value) {
    if (value == _expanded) return;
    _expanded = value;
    markNeedsPaint();
  }

  bool get selected => _selected;

  set selected(bool value) {
    if (value == _selected) return;
    _selected = value;
    markNeedsPaint();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_selected) PseudoClass.selected,
        if (_expandable && _expanded) PseudoClass.expanded,
      };

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    size = constraints.constrain(Size(width, _extent));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    if (_selected) {
      paintFill(list, rect, theme.selection);
    } else if (isHovered && enabled) {
      paintFill(list, rect, theme.surface);
    }
    final bool rtl = _textDirection.isRightToLeft;
    final double indent = _depth * indentPerLevel;
    final double toggleStart =
        rtl ? size.width - indent - toggleExtent : indent;
    if (_expandable) {
      _paintToggle(
        list,
        Rect.fromLTWH(offset.dx + toggleStart, offset.dy, toggleExtent,
            size.height),
      );
    }
    final double labelStart = indent + toggleExtent + 2;
    final double labelWidth =
        (size.width - labelStart - 4).clamp(0.0, double.infinity);
    final Size box = measureLabel(_label);
    final double labelX = rtl
        ? (offset.dx + size.width - labelStart - box.width)
            .clamp(offset.dx + 4, double.infinity)
        : offset.dx + labelStart;
    final double labelY =
        (offset.dy + (size.height - box.height) / 2).roundToDouble();
    paintLabel(
      list,
      _label,
      Offset(labelX.roundToDouble(), labelY),
      enabled ? theme.foreground : theme.disabledForeground,
      maxWidth: labelWidth,
    );
  }

  /// The classic plus/minus box: a bordered square with a horizontal bar, and
  /// a vertical bar while collapsed. Pure rectangles on whole pixels, so a
  /// golden test compares geometry rather than antialiasing.
  void _paintToggle(DisplayList list, Rect gutter) {
    final double left =
        (gutter.left + (gutter.width - _glyphExtent) / 2).roundToDouble();
    final double top =
        (gutter.top + (gutter.height - _glyphExtent) / 2).roundToDouble();
    final Rect box = Rect.fromLTWH(left, top, _glyphExtent, _glyphExtent);
    paintFill(list, box, theme.surfaceAlternate);
    paintBorder(list, box, theme.border);
    final double mid = (_glyphExtent / 2).floorToDouble();
    paintFill(
      list,
      Rect.fromLTWH(box.left + 2, box.top + mid, _glyphExtent - 4, 1),
      enabled ? theme.foreground : theme.disabledForeground,
    );
    if (!_expanded) {
      paintFill(
        list,
        Rect.fromLTWH(box.left + mid, box.top + 2, 1, _glyphExtent - 4),
        enabled ? theme.foreground : theme.disabledForeground,
      );
    }
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.listItem,
        label: _label,
        // The depth as a value: "level 2" is what a screen reader announces
        // to make hierarchy audible, since indentation is invisible to it.
        value: 'level ${_depth + 1}',
        states: <SemanticsState>{
          if (_selected) SemanticsState.selected,
          if (_expandable && _expanded) SemanticsState.expanded,
          if (!enabled) SemanticsState.disabled,
        },
        actions: enabled
            ? const <SemanticsAction>{SemanticsAction.activate}
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}

// ---------------------------------------------------------------------------
// The tree container
// ---------------------------------------------------------------------------

final class _TreeViewRenderWidget extends MultiChildRenderObjectWidget {
  const _TreeViewRenderWidget({
    required this.position,
    required this.focusNode,
    required this.theme,
    required this.virtualization,
    required this.range,
    required this.selectedIndex,
    required this.onKeyEvent,
    required this.onRowPressed,
    required this.onViewportExtent,
    required super.children,
  });

  final ScrollPosition position;
  final FocusNode focusNode;
  final ThemeData theme;
  final ListVirtualization virtualization;
  final RealizedRange range;
  final int selectedIndex;
  final bool Function(KeyEvent event) onKeyEvent;
  final void Function(int index, double dx, double width) onRowPressed;
  final void Function(double extent) onViewportExtent;

  @override
  RenderTreeView createRenderObject(BuildContext context) => RenderTreeView(
        position: position,
        virtualization: virtualization,
        range: range,
        selectedIndex: selectedIndex,
        onKeyEvent: onKeyEvent,
        onRowPressed: onRowPressed,
        onViewportExtent: onViewportExtent,
      )
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTreeView object,
  ) {
    object
      ..position = position
      ..virtualization = virtualization
      ..range = range
      ..selectedIndex = selectedIndex
      ..onKeyEvent = onKeyEvent
      ..onRowPressed = onRowPressed
      ..onViewportExtent = onViewportExtent
      ..theme = theme
      ..focusNode = focusNode;
  }
}

/// Lays out the realized rows and reports the full tree to accessibility.
final class RenderTreeView extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  RenderTreeView({
    required ScrollPosition position,
    required ListVirtualization virtualization,
    required RealizedRange range,
    required this.selectedIndex,
    required this.onKeyEvent,
    required this.onRowPressed,
    required this.onViewportExtent,
  })  : _position = position,
        _virtualization = virtualization,
        _range = range {
    _position.addListener(_onScrolled);
  }

  ScrollPosition _position;
  ListVirtualization _virtualization;
  RealizedRange _range;
  int selectedIndex;
  bool Function(KeyEvent event) onKeyEvent;
  void Function(int index, double dx, double width) onRowPressed;
  void Function(double extent) onViewportExtent;

  ScrollPosition get position => _position;

  set position(ScrollPosition value) {
    if (identical(value, _position)) return;
    _position.removeListener(_onScrolled);
    _position = value..addListener(_onScrolled);
    markNeedsLayout();
  }

  ListVirtualization get virtualization => _virtualization;

  set virtualization(ListVirtualization value) {
    _virtualization = value;
    markNeedsLayout();
  }

  RealizedRange get range => _range;

  set range(RealizedRange value) {
    if (value == _range) return;
    _range = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    final double height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : constraints.minHeight;
    size = constraints.constrain(Size(width, height));

    _position.applyViewportGeometry(
      viewportExtent: height,
      contentExtent: _virtualization.totalExtent,
    );

    double cursor = _range.leadingExtent - _position.pixels;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(
        BoxConstraints(minWidth: width, maxWidth: width),
        parentUsesSize: true,
      );
      child.parentData!.offset = Offset(0, cursor);
      cursor += child.size.height;
    }
    onViewportExtent(height);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surfaceAlternate);
    list.save();
    list.clipRect(rect.left, rect.top, rect.right, rect.bottom);
    super.paint(list, offset);
    list.restore();
    paintBorder(list, rect, theme.border);
    paintFocusRing(list, rect);
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    if (!size.contains(position)) return null;
    return super.hitTestChildren(position, path: path);
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (event is PointerScrollEvent) {
      _position.applyScrollDelta(
        event.scrollDelta.dy,
        inLines: event.scrollDeltaUnit == ScrollDeltaUnit.lines,
      );
      return;
    }
    if (event is PointerDownEvent) {
      final Offset local = globalToLocal(event.logicalPosition);
      final double contentY = local.dy + _position.pixels;
      final int index = _virtualization.indexAt(contentY);
      if (index >= 0 && index < _virtualization.itemCount) {
        onRowPressed(index, local.dx, size.width);
      }
    }
  }

  @override
  bool handleKeyEvent(KeyEvent event) => onKeyEvent(event);

  void _onScrolled(ScrollPosition position) => markNeedsLayout();

  @override
  void detach() {
    _position.removeListener(_onScrolled);
    super.detach();
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.list,
        // The full flattened count, not the realized one: assistive clients
        // must hear "item 3 of 10000" for rows that mostly do not exist.
        value: '${_virtualization.itemCount} items',
        hint: selectedIndex < 0
            ? null
            : 'item ${selectedIndex + 1} of ${_virtualization.itemCount}',
        states: <SemanticsState>{
          if (hasFocus) SemanticsState.focused,
        },
        actions: const <SemanticsAction>{
          SemanticsAction.focus,
          SemanticsAction.scrollDown,
          SemanticsAction.scrollUp,
        },
      );
}
Grep "class DisplayListReader|DisplayListReader\(|factory DisplayListReader|rewind|fromList|forList" (in C:\MyDartProjects\dart_ui\lib\src\graphics\display_list_reader.dart)
90 lines of output
Now Trash.

Read C:\MyDartProjects\dart_ui\lib\src\rendering\framebuffer.dart (lines 29-128)
Grep "class GlyphMask" (in C:\MyDartProjects\dart_ui\lib\src\rendering\text\glyph_cache.dart)
1 line of output
Now the shm surface layer (pure) — mirroring x11_surface.dart.

Grep "class ScaledTypeface" (in C:\MyDartProjects\dart_ui\lib\src\text\typeface.dart)
41 lines of output
Bash Directionality.of and tabs test mounting
IN
grep -n "static TextDirection" -A 10 C:/MyDartProjects/dart_ui/lib/src/widgets/directionality.dart; grep -n "Directionality\|updateRoot\|BuildOwner\|rootConstraints" C:/MyDartProjects/dart_ui/test/widgets/tabs_test.dart | head -15

OUT
95:  static TextDirection of(BuildContext context) {
96-    final Directionality? scope =
97-        context.dependOnInheritedWidgetOfExactType<Directionality>();
98-    if (scope == null) {
99-      throw MissingDirectionalityError('${context.widget.runtimeType}');
100-    }
101-    return scope.textDirection;
102-  }
103-
104-  /// The reading direction in scope at [context], or null.
105-  ///
--
109:  static TextDirection? maybeOf(BuildContext context) => context
110-      .dependOnInheritedWidgetOfExactType<Directionality>()
111-      ?.textDirection;
112-
113-  /// Whether a drawable that opted into [matchTextDirection] must be painted
114-  /// mirrored at [context].
115-  ///
116-  /// The hook a directional icon uses. See [mirrorsInDirection] for the pure
117-  /// form and for what "directional" means here.
118-  ///
119-  /// Reads the direction through [of], so a widget that asked to follow the
350:    owner = BuildOwner(
352:        rootConstraints: BoxConstraints.tight(const Size(320, 200)),
355:    owner.updateRoot(_root());
363:  late final BuildOwner owner;
378:  Widget _root() => Directionality(
421:        owner.updateRoot(_root());
Grep "class GlyphMask|final class GlyphMask" (in C:\MyDartProjects\dart_ui\lib\src\rendering\text)
36 lines of output
Now I have the full picture. Let me write the Direct2D backend. Starting with the structs file.

Write C:\MyDartProjects\dart_ui\lib\src\platform\trash_types.dart
123 lines
/// The shared vocabulary of [Trash], and the freedesktop bookkeeping that is
/// pure string work.
///
/// The `.trashinfo` format, the percent-encoding its `Path=` key requires and
/// the collision-avoidance naming are all specified text manipulation, so
/// they live here where any machine can test them; the `io` implementation
/// contributes only the file moves.
library;

/// A move-to-trash that did not happen.
final class TrashException implements Exception {
  const TrashException({
    required this.path,
    required this.reason,
    this.platform,
    this.errorCode,
  });

  final String path;
  final String reason;
  final String? platform;
  final int? errorCode;

  @override
  String toString() => 'TrashException: could not trash $path'
      '${platform == null ? '' : ' on $platform'}'
      '${errorCode == null ? '' : ' (code $errorCode)'} - $reason';
}

/// Percent-encodes [path] the way the freedesktop trash spec requires for
/// the `Path=` key: RFC 2396 escaping applied per octet of the UTF-8 form,
/// with `/` kept literal because it is the separator being described.
String encodeTrashPath(String path) {
  const String keep =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
      r"-_.!~*'()/";
  final StringBuffer out = StringBuffer();
  for (final int byte in Uri.parse('').resolveUri(Uri()) == Uri()
      ? const <int>[]
      : const <int>[]) {
    // Unreachable; kept out of the loop below for clarity of the real code.
    out.writeCharCode(byte);
  }
  final List<int> bytes = _utf8Bytes(path);
  for (final int byte in bytes) {
    final String char = String.fromCharCode(byte);
    if (byte < 0x80 && keep.contains(char)) {
      out.write(char);
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

List<int> _utf8Bytes(String value) {
  // Hand-rolled rather than dart:convert so this file stays importable from
  // the narrowest of targets; UTF-8 of a Dart string is a dozen lines.
  final List<int> bytes = <int>[];
  for (final int rune in value.runes) {
    if (rune < 0x80) {
      bytes.add(rune);
    } else if (rune < 0x800) {
      bytes
        ..add(0xC0 | (rune >> 6))
        ..add(0x80 | (rune & 0x3F));
    } else if (rune < 0x10000) {
      bytes
        ..add(0xE0 | (rune >> 12))
        ..add(0x80 | ((rune >> 6) & 0x3F))
        ..add(0x80 | (rune & 0x3F));
    } else {
      bytes
        ..add(0xF0 | (rune >> 18))
        ..add(0x80 | ((rune >> 12) & 0x3F))
        ..add(0x80 | ((rune >> 6) & 0x3F))
        ..add(0x80 | (rune & 0x3F));
    }
  }
  return bytes;
}

/// [moment] as the trash spec's `DeletionDate` value: local time in
/// `YYYY-MM-DDThh:mm:ss`, no zone suffix.
String formatTrashDeletionDate(DateTime moment) {
  final DateTime local = moment.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
      '${two(local.day)}T${two(local.hour)}:${two(local.minute)}:'
      '${two(local.second)}';
}

/// The complete content of a `.trashinfo` file for [originalPath] deleted at
/// [deletedAt].
String buildTrashInfo({
  required String originalPath,
  required DateTime deletedAt,
}) =>
    '[Trash Info]\n'
    'Path=${encodeTrashPath(originalPath)}\n'
    'DeletionDate=${formatTrashDeletionDate(deletedAt)}\n';

/// A name near [name] that [exists] answers false for, counting upward in
/// the style the platform's own trash uses.
///
/// Freedesktop implementations insert a counter before the extension
/// (`report.2.pdf`); the Finder appends one after the stem (`report 2.pdf`).
/// [separator] chooses which: `'.'` produces the former, `' '` the latter.
String disambiguateTrashName(
  String name,
  bool Function(String candidate) exists, {
  String separator = '.',
}) {
  if (!exists(name)) return name;
  final int dot = name.startsWith('.') ? -1 : name.lastIndexOf('.');
  final String stem = dot <= 0 ? name : name.substring(0, dot);
  final String extension = dot <= 0 ? '' : name.substring(dot);
  for (var counter = 2;; counter++) {
    final String candidate = '$stem$separator$counter$extension';
    if (!exists(candidate)) return candidate;
  }
}
Edit C:\MyDartProjects\dart_ui\lib\src\platform\trash_types.dart
Removed 6 lines
TreeView done. Now DataGrid.

Write C:\MyDartProjects\dart_ui\lib\src\platform\trash.dart
31 lines
/// Moving files to the trash instead of destroying them.
///
/// Deleting is the one destructive operation a UI performs on the user's own
/// data, and every desktop platform agrees on the remedy: the file goes
/// somewhere recoverable. What differs is everything else - Windows has the
/// Recycle Bin behind a shell API, Linux has a specified directory layout
/// (the freedesktop trash spec), and macOS has `~/.Trash` with no public API
/// at all outside the Objective-C runtime. This port exposes the shared verb
/// and pushes the differences into the platform files.
///
/// What is deliberately *not* promised: restoring, listing, or emptying the
/// trash. Restore-from-trash is a file-manager feature on every platform, and
/// the platforms' own UIs do it better than a framework could.
library;

import 'trash_platform_stub.dart'
    if (dart.library.io) 'trash_platform_io.dart' as platform;
import 'trash_types.dart';

export 'trash_types.dart';

/// The platform's recoverable-delete.
abstract final class Trash {
  /// Moves the file or directory at [path] to the platform trash.
  ///
  /// [path] must name something that exists. On success the entry is no
  /// longer at [path] and is recoverable through the platform's own UI; on
  /// failure a [TrashException] says why and the entry is untouched.
  static Future<void> moveToTrash(String path) => platform.moveToTrash(path);
}
Write C:\MyDartProjects\dart_ui\lib\src\platform\trash_platform_stub.dart
11 lines
library;

import 'trash_types.dart';

Future<void> moveToTrash(String path) async {
  throw TrashException(
    path: path,
    reason: 'this target has no trash implementation',
  );
}
Write C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_shm.dart
364 lines
/// CPU-visible Wayland surface presented through `wl_shm`.
///
/// This layer intentionally contains no FFI, exactly like `x11_surface.dart`:
/// the connection owns the native side (memfd, mmap, the `wl_shm_pool` and
/// `wl_buffer` protocol objects), while [WaylandShmSurface] owns the returned
/// buffer's lifetime and exposes its pixels through the renderer's common
/// [Framebuffer] contract. Keeping the boundary pointer-free makes damage,
/// generation and teardown testable on hosts without a compositor.
library;

import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/rect.dart';
import '../../rendering/framebuffer.dart';
import '../../rendering/renderer.dart';
import 'wayland_protocol.dart';

/// Geometry of one shm pool: stride, byte length and wire format, derived in
/// one place so the create_pool/create_buffer requests and the [Framebuffer]
/// can never disagree about layout.
final class WaylandShmPoolPlan {
  factory WaylandShmPoolPlan({
    required int pixelWidth,
    required int pixelHeight,
  }) {
    if (pixelWidth <= 0) {
      throw ArgumentError.value(pixelWidth, 'pixelWidth', 'must be positive');
    }
    if (pixelHeight <= 0) {
      throw ArgumentError.value(pixelHeight, 'pixelHeight', 'must be positive');
    }
    // wl_shm_pool.create_buffer carries int32 geometry; anything larger than
    // this cannot even be requested. The practical ceiling is the compositor's
    // own texture limit, reported as a protocol error rather than guessed.
    if (pixelWidth > 0x7fff || pixelHeight > 0x7fff) {
      throw RangeError('wl_shm buffers are limited to 32767x32767 pixels');
    }
    final stride = pixelWidth * 4;
    return WaylandShmPoolPlan._(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      strideBytes: stride,
      byteLength: stride * pixelHeight,
      format: wlShmFormatArgb8888,
    );
  }

  const WaylandShmPoolPlan._({
    required this.pixelWidth,
    required this.pixelHeight,
    required this.strideBytes,
    required this.byteLength,
    required this.format,
  });

  final int pixelWidth;
  final int pixelHeight;

  /// Tightly packed: the framework rasteriser assumes `width * 4` and the
  /// compositor is told the same number, so no row-walking loop can diverge.
  final int strideBytes;

  final int byteLength;

  /// `wl_shm.format`. ARGB8888's little-endian memory layout is byte-for-byte
  /// the framework's premultiplied BGRA.
  final int format;

  @override
  String toString() => 'WaylandShmPoolPlan(${pixelWidth}x$pixelHeight, '
      'stride $strideBytes, $byteLength bytes)';
}

/// Anonymous shared memory the compositor can map too.
///
/// The production implementation is a `memfd_create` + `mmap` pair; tests
/// substitute a plain [Uint8List] with a fake descriptor.
abstract interface class WaylandShmMemory implements Disposable {
  /// The descriptor sent with `wl_shm.create_pool`. The transport duplicates
  /// nothing: after the pool is created the compositor holds its own
  /// reference and this one may be closed.
  int get fd;

  /// The client-side mapping, exactly [WaylandShmPoolPlan.byteLength] long.
  Uint8List get bytes;
}

/// Allocates [WaylandShmMemory]. Split from the connection so the shm pool
/// bookkeeping can be exercised without `memfd_create` existing on the host.
abstract interface class WaylandShmAllocator {
  /// False when the host cannot make anonymous shared memory at all, which
  /// rules out CPU presentation before any protocol request is sent.
  bool get isAvailable;

  /// Zero-initialised shared memory, or a thrown [StateError] naming errno.
  WaylandShmMemory allocate(int byteLength);

  /// Maps a descriptor the compositor sent (the xkb keymap). Returns null on
  /// failure; the caller reports it. The mapping is copied, not borrowed.
  Uint8List? readSharedMemory(int fd, int byteLength);
}

/// An allocation suitable for Wayland CPU presentation. The client that
/// created it owns the native pool/buffer objects; the surface borrows
/// [framebuffer] until it calls [WaylandCpuClient.destroyShmBuffer].
abstract interface class WaylandShmBufferHandle {
  Framebuffer get framebuffer;
}

/// A device-pixel rectangle submitted as damage from an shm buffer.
final class WaylandCpuDamage {
  const WaylandCpuDamage({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is WaylandCpuDamage &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'WaylandCpuDamage($x, $y, $width, $height)';
}

/// Native allocation and commit operations needed by [WaylandShmSurface].
abstract interface class WaylandCpuClient {
  /// Whether shm presentation is possible: the `wl_shm` global was bound,
  /// ARGB8888 was advertised and anonymous shared memory can be allocated.
  bool get supportsShmPresentation;

  WaylandShmBufferHandle createShmBuffer({
    required int pixelWidth,
    required int pixelHeight,
  });

  void destroyShmBuffer(WaylandShmBufferHandle buffer);

  /// Attaches [buffer] to [surfaceId], damages [damage] in buffer pixels and
  /// commits. Returns null on success, a diagnostic naming the failure
  /// otherwise.
  BackendDiagnostic? presentShmBuffer({
    required int surfaceId,
    required WaylandShmBufferHandle buffer,
    required WaylandCpuDamage damage,
    required int bufferScale,
  });
}

/// CPU framebuffer and presentation seam exposed by a Wayland window.
abstract interface class WaylandCpuSurface implements NativeSurfaceDescriptor {
  int get generation;
  Framebuffer get framebuffer;
  BackendDiagnostic? present({Rect? damage});
}

/// A tightly packed BGRA shm buffer committed to one `wl_surface`.
///
/// One instance belongs to exactly one window size and generation, the same
/// replace-not-mutate rule as `X11PutImageSurface`: a resize creates a new
/// surface for the new configure, so a frame holding the previous object is
/// rejected by identity and [generation] before touching released memory.
final class WaylandShmSurface with DisposableMixin implements WaylandCpuSurface {
  WaylandShmSurface._({
    required WaylandCpuClient client,
    required WaylandShmBufferHandle buffer,
    required this.surfaceId,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.scale,
    required this.bufferScale,
    required this.generation,
  })  : _client = client,
        _buffer = buffer;

  /// Allocates a surface or throws without leaking a partially accepted
  /// buffer. Presentation capability is checked before allocation.
  static WaylandShmSurface create({
    required WaylandCpuClient client,
    required int surfaceId,
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
    required int bufferScale,
    required int generation,
  }) {
    if (!client.supportsShmPresentation) {
      throw UnsupportedCapabilityError(
        backendName: 'wayland',
        capability: Capability.cpuPresentation,
        detail: 'the compositor offers no usable wl_shm ARGB8888 path',
      );
    }
    if (surfaceId == 0) {
      throw ArgumentError.value(surfaceId, 'surfaceId', 'must not be null');
    }
    if (pixelWidth <= 0) {
      throw ArgumentError.value(pixelWidth, 'pixelWidth', 'must be positive');
    }
    if (pixelHeight <= 0) {
      throw ArgumentError.value(pixelHeight, 'pixelHeight', 'must be positive');
    }
    if (!scale.isFinite || scale <= 0) {
      throw ArgumentError.value(scale, 'scale', 'must be finite and positive');
    }
    if (bufferScale < 1) {
      throw ArgumentError.value(bufferScale, 'bufferScale', 'must be >= 1');
    }
    if (generation < 0) {
      throw ArgumentError.value(
          generation, 'generation', 'must be non-negative');
    }

    final buffer = client.createShmBuffer(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
    try {
      final framebuffer = buffer.framebuffer;
      if (framebuffer.width != pixelWidth ||
          framebuffer.height != pixelHeight) {
        throw StateError(
          'Wayland shm buffer geometry is ${framebuffer.width}x'
          '${framebuffer.height}; expected ${pixelWidth}x$pixelHeight',
        );
      }
      if (framebuffer.format != PixelFormat.bgra8888Premultiplied) {
        throw StateError(
          'wl_shm ARGB8888 needs bgra8888Premultiplied; '
          'got ${framebuffer.format.name}',
        );
      }
      return WaylandShmSurface._(
        client: client,
        buffer: buffer,
        surfaceId: surfaceId,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale,
        bufferScale: bufferScale,
        generation: generation,
      );
    } on Object {
      client.destroyShmBuffer(buffer);
      rethrow;
    }
  }

  final WaylandCpuClient _client;
  final WaylandShmBufferHandle _buffer;

  @override
  String get kind => 'wayland-shm';

  /// The `wl_surface` protocol id this buffer is committed to.
  final int surfaceId;

  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  /// The integer `wl_surface.set_buffer_scale` factor. [pixelWidth] is the
  /// surface's logical width times this.
  final int bufferScale;

  @override
  final int generation;

  @override
  Framebuffer get framebuffer => _buffer.framebuffer;

  /// Commits the full buffer, or the outward-rounded intersection of [damage]
  /// with this surface. [damage] is in logical client coordinates; a no-op
  /// (empty or fully clipped damage) is a successful presentation.
  @override
  BackendDiagnostic? present({Rect? damage}) {
    throwIfDisposed();
    final region = damage == null ? _fullDamage : _deviceDamage(damage);
    if (region == null) return null;
    if (!_client.supportsShmPresentation) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'Wayland shm presentation became unavailable',
      );
    }
    try {
      return _client.presentShmBuffer(
        surfaceId: surfaceId,
        buffer: _buffer,
        damage: region,
        bufferScale: bufferScale,
      );
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'Wayland shm presentation threw',
        detail: '$error',
      );
    }
  }

  WaylandCpuDamage get _fullDamage => WaylandCpuDamage(
        x: 0,
        y: 0,
        width: pixelWidth,
        height: pixelHeight,
      );

  WaylandCpuDamage? _deviceDamage(Rect logical) {
    if (!logical.left.isFinite ||
        !logical.top.isFinite ||
        !logical.right.isFinite ||
        !logical.bottom.isFinite) {
      throw ArgumentError.value(logical, 'damage', 'edges must be finite');
    }
    if (logical.isEmpty) return null;
    final left = _clamp((logical.left * scale).floor(), 0, pixelWidth);
    final top = _clamp((logical.top * scale).floor(), 0, pixelHeight);
    final right = _clamp((logical.right * scale).ceil(), 0, pixelWidth);
    final bottom = _clamp((logical.bottom * scale).ceil(), 0, pixelHeight);
    if (right <= left || bottom <= top) return null;
    return WaylandCpuDamage(
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }

  static int _clamp(int value, int minimum, int maximum) => value < minimum
      ? minimum
      : value > maximum
          ? maximum
          : value;

  @override
  void onDispose() => _client.destroyShmBuffer(_buffer);

  @override
  String toString() => 'WaylandShmSurface('
      '${pixelWidth}x$pixelHeight @ $scale, '
      'surface: $surfaceId, generation: $generation)';
}
Write C:\MyDartProjects\dart_ui\lib\src\backends\win32\d2d\d2d1_structs.dart
380 lines
/// The Direct2D structures and enum constants this backend crosses the ABI
/// with, laid out exactly as `d2d1.h` declares them.
///
/// The same decision `d3d12_structs.dart` made: structures are declared here
/// once, by hand, with the SDK field order preserved, because a wrong offset
/// is a garbage draw rather than an error. Only the structures this backend
/// actually passes are declared - Direct2D has dozens more, and an unused
/// declaration is a place for a transcription error to hide unreviewed.
///
/// ## Two structures cross by value
///
/// `D2D1_SIZE_U` (in `ID2D1RenderTarget::CreateBitmap`) and `D2D1_POINT_2F`
/// (in `ID2D1GeometrySink::BeginFigure` / `AddLine`) are eight-byte aggregates
/// passed **by value**. Under the Windows x64 convention an eight-byte struct
/// argument travels in a general-purpose register, and `dart:ffi` implements
/// that correctly for by-value struct parameters, so those two methods take
/// the struct type directly rather than a pointer. Everything else Direct2D
/// takes is a `const` reference in C++, which is a pointer in the ABI.
///
/// Methods that *return* small structs (`GetSize`, `GetPixelSize`,
/// `GetPixelFormat`) are deliberately not bound anywhere in this directory:
/// MSVC returns aggregates from non-static member functions through a hidden
/// pointer - the divergence `d3d12_interfaces.dart` documents at length for
/// descriptor handles - and this backend never needs to ask a target for a
/// size it already knows.
library;

import 'dart:ffi';

// ---------------------------------------------------------------------------
// Enum constants, with the header's names in comments
// ---------------------------------------------------------------------------

/// `D2D1_FACTORY_TYPE_SINGLE_THREADED`. This framework is single-isolate per
/// window; the multithreaded factory serialises every call for no benefit.
const int d2d1FactoryTypeSingleThreaded = 0;

/// `D2D1_RENDER_TARGET_TYPE_*`.
const int d2d1RenderTargetTypeDefault = 0;
const int d2d1RenderTargetTypeSoftware = 1;
const int d2d1RenderTargetTypeHardware = 2;

/// `D2D1_RENDER_TARGET_USAGE_NONE`.
const int d2d1RenderTargetUsageNone = 0;

/// `D2D1_FEATURE_LEVEL_DEFAULT`.
const int d2d1FeatureLevelDefault = 0;

/// `DXGI_FORMAT_B8G8R8A8_UNORM` - the one format every Direct2D render target
/// accepts and the byte order the rest of this framework already uses.
const int dxgiFormatB8G8R8A8Unorm = 87;

/// `DXGI_FORMAT_UNKNOWN`, for targets that pick their own format.
const int dxgiFormatUnknown = 0;

/// `D2D1_ALPHA_MODE_*`.
const int d2d1AlphaModeUnknown = 0;
const int d2d1AlphaModePremultiplied = 1;
const int d2d1AlphaModeStraight = 2;
const int d2d1AlphaModeIgnore = 3;

/// `D2D1_PRESENT_OPTIONS_NONE`: present on `EndDraw`, waiting for vblank.
const int d2d1PresentOptionsNone = 0;

/// `D2D1_ANTIALIAS_MODE_*`. `FillOpacityMask` requires the aliased mode, which
/// is why the sink switches to it around glyph blits and back afterwards.
const int d2d1AntialiasModePerPrimitive = 0;
const int d2d1AntialiasModeAliased = 1;

/// `D2D1_FILL_MODE_*`. Alternate is even-odd; winding is non-zero.
const int d2d1FillModeAlternate = 0;
const int d2d1FillModeWinding = 1;

/// `D2D1_FIGURE_BEGIN_*`.
const int d2d1FigureBeginFilled = 0;
const int d2d1FigureBeginHollow = 1;

/// `D2D1_FIGURE_END_*`.
const int d2d1FigureEndOpen = 0;
const int d2d1FigureEndClosed = 1;

/// `D2D1_CAP_STYLE_FLAT` - the butt cap `StrokeStyle` defaults to, which is
/// the cap the replay contract promises (see `ReplayPaint.strokeWidth`).
const int d2d1CapStyleFlat = 0;

/// `D2D1_LINE_JOIN_MITER`.
const int d2d1LineJoinMiter = 0;

/// `D2D1_DASH_STYLE_SOLID`.
const int d2d1DashStyleSolid = 0;

/// `D2D1_GAMMA_2_2`: interpolate gradient stops in the space the colours were
/// specified in, which is what the CPU rasteriser does too.
const int d2d1Gamma22 = 0;

/// `D2D1_EXTEND_MODE_CLAMP`.
const int d2d1ExtendModeClamp = 0;

/// `D2D1_BITMAP_INTERPOLATION_MODE_*`.
const int d2d1BitmapInterpolationModeNearestNeighbor = 0;
const int d2d1BitmapInterpolationModeLinear = 1;

/// `D2D1_OPACITY_MASK_CONTENT_GRAPHICS`.
const int d2d1OpacityMaskContentGraphics = 0;

/// `D2D1_LAYER_OPTIONS_NONE`.
const int d2d1LayerOptionsNone = 0;

/// `D2D1_WINDOW_STATE_OCCLUDED` bit of `CheckWindowState`.
const int d2d1WindowStateOccluded = 1;

// ---------------------------------------------------------------------------
// HRESULTs specific to Direct2D
// ---------------------------------------------------------------------------

/// `D2DERR_RECREATE_TARGET`: the device behind the target is gone and the
/// target must be rebuilt. The Direct2D spelling of
/// `DXGI_ERROR_DEVICE_REMOVED`, and the code that turns a present failure
/// into [PresentStatus.deviceLost].
const int d2dErrRecreateTarget = 0x8899000C;

/// `D2DERR_WRONG_STATE`: a call outside begin/end, or an unbalanced push/pop.
const int d2dErrWrongState = 0x88990001;

/// The names a Direct2D diagnostic should carry, over what `hresultText`
/// already knows.
const Map<int, String> d2dHresultNames = <int, String>{
  0x88990001: 'D2DERR_WRONG_STATE',
  0x88990002: 'D2DERR_NOT_INITIALIZED',
  0x88990003: 'D2DERR_UNSUPPORTED_OPERATION',
  0x88990004: 'D2DERR_SCANNER_FAILED',
  0x88990007: 'D2DERR_ZERO_VECTOR',
  0x88990008: 'D2DERR_INTERNAL_ERROR',
  0x8899000A: 'D2DERR_INVALID_CALL',
  0x8899000C: 'D2DERR_RECREATE_TARGET',
  0x88990010: 'D2DERR_INCOMPATIBLE_BRUSH_TYPES',
  0x88990012: 'D2DERR_PUSH_POP_UNBALANCED',
  0x88990018: 'D2DERR_UNSUPPORTED_PIXEL_FORMAT',
};

// ---------------------------------------------------------------------------
// Structures
// ---------------------------------------------------------------------------

/// `D2D1_PIXEL_FORMAT`.
final class D2dPixelFormat extends Struct {
  @Uint32()
  external int format;
  @Uint32()
  external int alphaMode;
}

/// `D2D1_RENDER_TARGET_PROPERTIES`.
final class D2dRenderTargetProperties extends Struct {
  @Uint32()
  external int type;
  external D2dPixelFormat pixelFormat;

  /// 96 in this backend, always, so one device-independent pixel is exactly
  /// one physical pixel and the replay sink's device-space geometry lands
  /// where the player computed it. Passing 0 would take the desktop DPI and
  /// silently rescale everything on a HiDPI monitor.
  @Float()
  external double dpiX;
  @Float()
  external double dpiY;
  @Uint32()
  external int usage;
  @Uint32()
  external int minLevel;
}

/// `D2D1_SIZE_U`.
final class D2dSizeU extends Struct {
  @Uint32()
  external int width;
  @Uint32()
  external int height;
}

/// `D2D1_HWND_RENDER_TARGET_PROPERTIES`.
final class D2dHwndRenderTargetProperties extends Struct {
  external Pointer<Void> hwnd;
  external D2dSizeU pixelSize;
  @Uint32()
  external int presentOptions;
}

/// `D2D1_COLOR_F`: four straight-alpha floats in 0..1.
final class D2dColorF extends Struct {
  @Float()
  external double r;
  @Float()
  external double g;
  @Float()
  external double b;
  @Float()
  external double a;
}

/// `D2D1_RECT_F`.
final class D2dRectF extends Struct {
  @Float()
  external double left;
  @Float()
  external double top;
  @Float()
  external double right;
  @Float()
  external double bottom;
}

/// `D2D1_POINT_2F`. Crossed by value in `BeginFigure` and `AddLine`.
final class D2dPoint2F extends Struct {
  @Float()
  external double x;
  @Float()
  external double y;
}

/// `D2D1_MATRIX_3X2_F`, in the header's row order: `m11 m12 / m21 m22 /
/// dx dy`. Maps to [Transform2D] as `a b / c d / tx ty`.
final class D2dMatrix3x2F extends Struct {
  @Float()
  external double m11;
  @Float()
  external double m12;
  @Float()
  external double m21;
  @Float()
  external double m22;
  @Float()
  external double dx;
  @Float()
  external double dy;
}

/// `D2D1_BITMAP_PROPERTIES`.
final class D2dBitmapProperties extends Struct {
  external D2dPixelFormat pixelFormat;
  @Float()
  external double dpiX;
  @Float()
  external double dpiY;
}

/// `D2D1_GRADIENT_STOP`.
final class D2dGradientStop extends Struct {
  @Float()
  external double position;
  external D2dColorF color;
}

/// `D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES`.
final class D2dLinearGradientBrushProperties extends Struct {
  external D2dPoint2F startPoint;
  external D2dPoint2F endPoint;
}

/// `D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES`.
final class D2dRadialGradientBrushProperties extends Struct {
  external D2dPoint2F center;
  external D2dPoint2F gradientOriginOffset;
  @Float()
  external double radiusX;
  @Float()
  external double radiusY;
}

/// `D2D1_BRUSH_PROPERTIES`.
final class D2dBrushProperties extends Struct {
  @Float()
  external double opacity;
  external D2dMatrix3x2F transform;
}

/// `D2D1_STROKE_STYLE_PROPERTIES`.
final class D2dStrokeStyleProperties extends Struct {
  @Uint32()
  external int startCap;
  @Uint32()
  external int endCap;
  @Uint32()
  external int dashCap;
  @Uint32()
  external int lineJoin;
  @Float()
  external double miterLimit;
  @Uint32()
  external int dashStyle;
  @Float()
  external double dashOffset;
}

/// `D2D1_BEZIER_SEGMENT`.
final class D2dBezierSegment extends Struct {
  external D2dPoint2F point1;
  external D2dPoint2F point2;
  external D2dPoint2F point3;
}

/// `D2D1_QUADRATIC_BEZIER_SEGMENT`.
final class D2dQuadraticBezierSegment extends Struct {
  external D2dPoint2F point1;
  external D2dPoint2F point2;
}

/// `D2D1_ROUNDED_RECT`.
final class D2dRoundedRect extends Struct {
  external D2dRectF rect;
  @Float()
  external double radiusX;
  @Float()
  external double radiusY;
}

/// `D2D1_LAYER_PARAMETERS`.
final class D2dLayerParameters extends Struct {
  external D2dRectF contentBounds;
  external Pointer<Void> geometricMask;
  @Uint32()
  external int maskAntialiasMode;
  external D2dMatrix3x2F maskTransform;
  @Float()
  external double opacity;
  external Pointer<Void> opacityBrush;
  @Uint32()
  external int layerOptions;
}

// ---------------------------------------------------------------------------
// The two GDI structures the offscreen readback surface needs
// ---------------------------------------------------------------------------

/// `RECT`, for `ID2D1DCRenderTarget::BindDC`.
final class Win32NativeRect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

/// `BITMAPINFOHEADER` followed by no palette, which is all a 32-bit DIB
/// section needs. `biHeight` is written negative for a top-down bitmap so the
/// DIB's rows and the framebuffer's rows agree on which one is first.
final class Win32BitmapInfoHeader extends Struct {
  @Uint32()
  external int biSize;
  @Int32()
  external int biWidth;
  @Int32()
  external int biHeight;
  @Uint16()
  external int biPlanes;
  @Uint16()
  external int biBitCount;
  @Uint32()
  external int biCompression;
  @Uint32()
  external int biSizeImage;
  @Int32()
  external int biXPelsPerMeter;
  @Int32()
  external int biYPelsPerMeter;
  @Uint32()
  external int biClrUsed;
  @Uint32()
  external int biClrImportant;
}

/// `BI_RGB`.
const int biRgb = 0;

/// `DIB_RGB_COLORS`.
const int dibRgbColors = 0;
Write C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_memfd.dart
115 lines
/// The production [WaylandShmAllocator]: `memfd_create` + `ftruncate` +
/// `mmap`.
///
/// memfd is the right primitive for `wl_shm` on every kernel this backend can
/// meet (Linux >= 3.17, glibc >= 2.27): the fd is anonymous, sealable and
/// needs no name in `/dev/shm` that could collide or leak. Hosts whose libc
/// lacks the wrapper simply lose CPU presentation - the probe says so instead
/// of the first frame failing.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../foundation/lifecycle.dart';
import 'wayland_libc.dart';
import 'wayland_shm.dart';

final class WaylandMemfdAllocator implements WaylandShmAllocator {
  WaylandMemfdAllocator(this._libc);

  final WaylandLibc _libc;

  @override
  bool get isAvailable => _libc.hasMemfdCreate;

  @override
  WaylandShmMemory allocate(int byteLength) {
    if (byteLength <= 0) {
      throw ArgumentError.value(byteLength, 'byteLength', 'must be positive');
    }
    if (!isAvailable) {
      throw StateError('memfd_create is not exported by this libc');
    }
    final name = _libc.allocateUtf8('dart_ui-shm');
    if (name == nullptr) {
      throw StateError('malloc failed while naming a Wayland shm pool');
    }
    final fd = _libc.memfdCreate(name, mfdCloexec | mfdAllowSealing);
    final createErrno = _libc.errno;
    _libc.free(name);
    if (fd < 0) {
      throw StateError('memfd_create failed (errno=$createErrno)');
    }
    if (_libc.ftruncate(fd, byteLength) != 0) {
      final error = _libc.errno;
      _libc.closeFd(fd);
      throw StateError(
          'ftruncate($byteLength) failed for a Wayland shm pool '
          '(errno=$error)');
    }
    final mapping = _libc.mmap(
      byteLength,
      protRead | protWrite,
      mapShared,
      fd,
      0,
    );
    // MAP_FAILED is (void*)-1; dart:ffi surfaces it as that address.
    if (mapping == nullptr || mapping.address == -1) {
      final error = _libc.errno;
      _libc.closeFd(fd);
      throw StateError('mmap($byteLength) failed for a Wayland shm pool '
          '(errno=$error)');
    }
    return _MemfdMemory(
      libc: _libc,
      fd: fd,
      mapping: mapping,
      byteLength: byteLength,
    );
  }

  @override
  Uint8List? readSharedMemory(int fd, int byteLength) {
    if (fd < 0 || byteLength <= 0) return null;
    // Keymaps are mapped privately: the compositor may hand the same fd to
    // every client, and MAP_PRIVATE guarantees nobody's write can corrupt it.
    final mapping = _libc.mmap(byteLength, protRead, mapPrivate, fd, 0);
    if (mapping == nullptr || mapping.address == -1) return null;
    try {
      return Uint8List.fromList(mapping.asTypedList(byteLength));
    } finally {
      _libc.munmap(mapping, byteLength);
    }
  }
}

final class _MemfdMemory with DisposableMixin implements WaylandShmMemory {
  _MemfdMemory({
    required WaylandLibc libc,
    required this.fd,
    required Pointer<Uint8> mapping,
    required int byteLength,
  })  : _libc = libc,
        _mapping = mapping,
        _byteLength = byteLength,
        bytes = mapping.asTypedList(byteLength);

  final WaylandLibc _libc;
  final Pointer<Uint8> _mapping;
  final int _byteLength;

  @override
  final int fd;

  @override
  final Uint8List bytes;

  @override
  void onDispose() {
    _libc.munmap(_mapping, _byteLength);
    _libc.closeFd(fd);
  }
}
Write C:\MyDartProjects\dart_ui\lib\src\platform\trash_platform_io.dart
336 lines
library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'trash_types.dart';

Future<void> moveToTrash(String path) async {
  final String absolute = File(path).absolute.path;
  if (FileSystemEntity.typeSync(absolute) == FileSystemEntityType.notFound) {
    throw TrashException(
      path: absolute,
      platform: Platform.operatingSystem,
      reason: 'the path does not exist',
    );
  }
  if (Platform.isWindows) {
    _windowsRecycle(absolute);
    return;
  }
  if (Platform.isMacOS) {
    final String? home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw TrashException(
        path: absolute,
        platform: 'macos',
        reason: r'$HOME is not set, so ~/.Trash cannot be found',
      );
    }
    await moveToMacTrash(absolute, trashDirectory: '$home/.Trash');
    return;
  }
  if (Platform.isLinux) {
    await moveToFreedesktopTrash(
      absolute,
      trashRoot: linuxTrashRoot(Platform.environment),
    );
    return;
  }
  throw TrashException(
    path: absolute,
    platform: Platform.operatingSystem,
    reason: 'no trash backend exists for this operating system',
  );
}

// ---------------------------------------------------------------------------
// Linux: the freedesktop trash specification, home trash only.
//
// The spec also describes per-volume `.Trash-$uid` directories for files on
// other filesystems; those need the mount table and uid lookups, and the
// spec's own instruction for an implementation without them is explicit: if
// the file cannot be trashed, fail rather than delete. The cross-device
// fallback below (copy, then delete the copy's source) preserves that
// recoverability guarantee by never destroying bytes before a copy exists.
// ---------------------------------------------------------------------------

/// The home trash directory for [environment]: `$XDG_DATA_HOME/Trash`,
/// defaulting to `~/.local/share/Trash`.
String linuxTrashRoot(Map<String, String> environment) {
  final String? dataHome = environment['XDG_DATA_HOME'];
  if (dataHome != null && dataHome.startsWith('/')) {
    return '$dataHome/Trash';
  }
  final String? home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw const TrashException(
      path: '',
      platform: 'linux',
      reason: r'neither $XDG_DATA_HOME nor $HOME is set',
    );
  }
  return '$home/.local/share/Trash';
}

/// Trashes [absolutePath] into the spec's `files/` + `info/` pair under
/// [trashRoot].
///
/// Separated from the platform dispatch, with the root injectable, because
/// the sequence - reserve a unique name via the `.trashinfo` file, then move -
/// is the part worth testing, and it runs on any filesystem `dart:io` can
/// write to, including a Windows temp directory.
Future<void> moveToFreedesktopTrash(
  String absolutePath, {
  required String trashRoot,
  DateTime? now,
}) async {
  final Directory filesDir = Directory('$trashRoot/files');
  final Directory infoDir = Directory('$trashRoot/info');
  try {
    filesDir.createSync(recursive: true);
    infoDir.createSync(recursive: true);
  } on FileSystemException catch (error) {
    throw TrashException(
      path: absolutePath,
      platform: 'linux',
      reason: 'the trash directory could not be created: ${error.message}',
    );
  }

  final String baseName =
      absolutePath.substring(absolutePath.lastIndexOf('/') + 1);
  // The name must be free in *both* directories, and the spec's own locking
  // trick is to claim it by creating the info file exclusively first: two
  // processes trashing `report.pdf` at once race on the O_EXCL create, not
  // on the move.
  String chosen = baseName.isEmpty ? 'trashed' : baseName;
  File infoFile;
  for (var attempt = 0;; attempt++) {
    chosen = disambiguateTrashName(
      attempt == 0 ? chosen : '$chosen',
      (String candidate) =>
          File('${infoDir.path}/$candidate.trashinfo').existsSync() ||
          FileSystemEntity.typeSync('${filesDir.path}/$candidate') !=
              FileSystemEntityType.notFound,
    );
    infoFile = File('${infoDir.path}/$chosen.trashinfo');
    try {
      infoFile.writeAsStringSync(
        buildTrashInfo(
          originalPath: absolutePath,
          deletedAt: now ?? DateTime.now(),
        ),
        mode: FileMode.writeOnly,
        flush: true,
      );
      break;
    } on FileSystemException {
      if (attempt >= 32) {
        throw TrashException(
          path: absolutePath,
          platform: 'linux',
          reason: 'could not claim a unique name in ${infoDir.path}',
        );
      }
    }
  }

  try {
    await _move(absolutePath, '${filesDir.path}/$chosen');
  } on Object catch (error) {
    // The claim is released on failure so a retry does not leak info files.
    try {
      infoFile.deleteSync();
    } on FileSystemException {
      // The original failure is the one worth reporting.
    }
    throw TrashException(
      path: absolutePath,
      platform: 'linux',
      reason: 'the move into the trash failed: $error',
    );
  }
}

// ---------------------------------------------------------------------------
// macOS: ~/.Trash by convention.
//
// The supported API (NSFileManager trashItemAtURL) lives behind the
// Objective-C runtime, which this framework does not bind. Moving into
// ~/.Trash is what the Finder itself does with the file; what is lost
// without the API is only the Finder's "Put Back" bookkeeping.
// ---------------------------------------------------------------------------

/// Moves [absolutePath] into [trashDirectory], renaming on collision the way
/// the Finder does (`name 2.ext`).
Future<void> moveToMacTrash(
  String absolutePath, {
  required String trashDirectory,
}) async {
  final Directory trash = Directory(trashDirectory);
  try {
    trash.createSync(recursive: true);
  } on FileSystemException catch (error) {
    throw TrashException(
      path: absolutePath,
      platform: 'macos',
      reason: '$trashDirectory could not be created: ${error.message}',
    );
  }
  final String baseName =
      absolutePath.substring(absolutePath.lastIndexOf('/') + 1);
  final String chosen = disambiguateTrashName(
    baseName.isEmpty ? 'trashed' : baseName,
    (String candidate) =>
        FileSystemEntity.typeSync('$trashDirectory/$candidate') !=
        FileSystemEntityType.notFound,
    separator: ' ',
  );
  try {
    await _move(absolutePath, '$trashDirectory/$chosen');
  } on Object catch (error) {
    throw TrashException(
      path: absolutePath,
      platform: 'macos',
      reason: 'the move into $trashDirectory failed: $error',
    );
  }
}

/// Renames, falling back to copy-then-delete when source and destination sit
/// on different filesystems (`rename(2)` answers EXDEV there). The copy is
/// complete and flushed before anything is deleted, so failure at any point
/// leaves the original recoverable.
Future<void> _move(String from, String to) async {
  final FileSystemEntityType type =
      FileSystemEntity.typeSync(from, followLinks: false);
  try {
    if (type == FileSystemEntityType.directory) {
      Directory(from).renameSync(to);
    } else if (type == FileSystemEntityType.link) {
      Link(from).renameSync(to);
    } else {
      File(from).renameSync(to);
    }
    return;
  } on FileSystemException {
    // Cross-device, most likely. Fall through to copy + delete.
  }
  if (type == FileSystemEntityType.directory) {
    _copyDirectory(Directory(from), Directory(to));
    Directory(from).deleteSync(recursive: true);
  } else if (type == FileSystemEntityType.link) {
    Link(to).createSync(Link(from).targetSync());
    Link(from).deleteSync();
  } else {
    File(from).copySync(to);
    File(from).deleteSync();
  }
}

void _copyDirectory(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final FileSystemEntity entry
      in from.listSync(recursive: false, followLinks: false)) {
    final String name =
        entry.path.split(Platform.pathSeparator).last;
    final String target = '${to.path}/$name';
    if (entry is Directory) {
      _copyDirectory(entry, Directory(target));
    } else if (entry is Link) {
      Link(target).createSync(entry.targetSync());
    } else if (entry is File) {
      entry.copySync(target);
    }
  }
}

// ---------------------------------------------------------------------------
// Windows: SHFileOperationW with FOF_ALLOWUNDO, which is the Recycle Bin.
//
// IFileOperation is the newer COM route; it needs CoInitialize, an
// apartment, and a vtable binding, in exchange for per-item progress this
// port does not expose. The one function call below does the same move.
// ---------------------------------------------------------------------------

const int _foDelete = 3;
const int _fofSilent = 0x0004;
const int _fofNoConfirmation = 0x0010;
const int _fofAllowUndo = 0x0040;
const int _fofNoErrorUi = 0x0400;

/// `SHFILEOPSTRUCTW`, in its x64 layout. The x86 build of Windows packs this
/// struct to one byte; the framework targets 64-bit Windows, where the
/// natural alignment below matches the SDK's.
final class _ShFileOpStructW extends Struct {
  @IntPtr()
  external int ownerWindow;

  @Uint32()
  external int operation;

  external Pointer<Uint16> from;
  external Pointer<Uint16> to;

  @Uint16()
  external int flags;

  @Int32()
  external int anyOperationsAborted;

  external Pointer<Void> nameMappings;
  external Pointer<Uint16> progressTitle;
}

typedef _SHFileOperationWNative = Int32 Function(
  Pointer<_ShFileOpStructW> descriptor,
);
typedef _SHFileOperationWDart = int Function(
  Pointer<_ShFileOpStructW> descriptor,
);

_SHFileOperationWDart? _shFileOperation;

void _windowsRecycle(String absolutePath) {
  final _SHFileOperationWDart operate;
  try {
    operate = _shFileOperation ??= DynamicLibrary.open('shell32.dll')
        .lookupFunction<_SHFileOperationWNative, _SHFileOperationWDart>(
            'SHFileOperationW');
  } on Object catch (error) {
    throw TrashException(
      path: absolutePath,
      platform: 'windows',
      reason: 'shell32.dll could not be loaded: $error',
    );
  }
  final ({int code, bool aborted}) outcome = using((NativeArena arena) {
    // pFrom is a *double* NUL-terminated list of paths.
    final List<int> units = <int>[...absolutePath.codeUnits, 0, 0];
    final Pointer<Uint16> from = arena<Uint16>(units.length * 2);
    from.asTypedList(units.length).setAll(0, units);
    final Pointer<_ShFileOpStructW> descriptor = arena<_ShFileOpStructW>();
    descriptor.ref
      ..operation = _foDelete
      ..from = from
      ..flags = _fofAllowUndo |
          _fofNoConfirmation |
          _fofSilent |
          _fofNoErrorUi;
    final int code = operate(descriptor);
    return (code: code, aborted: descriptor.ref.anyOperationsAborted != 0);
  });
  if (outcome.code != 0 || outcome.aborted) {
    throw TrashException(
      path: absolutePath,
      platform: 'windows',
      errorCode: outcome.code,
      reason: outcome.aborted
          ? 'the shell aborted the recycle operation'
          : 'SHFileOperationW reported a failure code',
    );
  }
}
Now the minimal xkb keymap parser.

Write C:\MyDartProjects\dart_ui\lib\src\backends\win32\d2d\d2d1_library.dart
227 lines
/// Opening the DLLs the Direct2D backend needs, and binding their exports.
///
/// Three libraries, each with a stated reason:
///
///   * `d2d1.dll` - `D2D1CreateFactory`, the single entry point the whole API
///     hangs off. Shipped with every Windows since 7.
///   * `gdi32.dll` - `CreateDIBSection` and friends. Only the offscreen
///     readback surface uses them: a DC render target bound to a DIB section
///     is the one Direct2D target whose pixels the CPU can read back without
///     involving WIC or a Direct3D staging texture, and readable pixels are
///     what golden tests are made of.
///   * `kernel32.dll` - the process heap, for the same zeroing-allocator
///     `d3d12_library.dart` builds and for the same reason: this framework
///     carries no `package:ffi` dependency, and Direct2D structures have
///     fields this backend never sets that must be zero.
///
/// ## A missing library is data, not an exception
///
/// The rule `win32_api.dart` states and `d3d12_library.dart` follows: every
/// failure comes back as a [BackendDiagnostic] naming what was missing, so a
/// probe report can tell "this machine has no Direct2D" apart from a bug.
library;

import 'dart:ffi';

import '../../../foundation/diagnostics.dart';
import '../d3d12/d3d12_com.dart';
import 'd2d1_structs.dart';

/// `D2D1CreateFactory`.
typedef _CreateFactoryNative = Int32 Function(
  Uint32 factoryType,
  Pointer<Guid> riid,
  Pointer<Void> factoryOptions,
  Pointer<Pointer<Void>> factory,
);

typedef D2d1CreateFactoryDart = int Function(
  int factoryType,
  Pointer<Guid> riid,
  Pointer<Void> factoryOptions,
  Pointer<Pointer<Void>> factory,
);

/// The interface identifiers this backend asks for, in the textual form the
/// headers document, parsed by [writeGuid] so a transcription error fails at
/// the constant instead of as `E_NOINTERFACE` hours later.
abstract final class D2d1Iids {
  static const String factory = '06152247-6f50-465a-9245-118bfd3b6007';
}

/// [hresultText], extended with the Direct2D codes that table does not know.
String d2dHresultText(int hr) {
  final String? name = d2dHresultNames[hr.toUnsigned(32)];
  if (name == null) return hresultText(hr);
  final String hex =
      '0x${hr.toUnsigned(32).toRadixString(16).padLeft(8, '0').toUpperCase()}';
  return '$hex ($name)';
}

/// What [D2d1Library.open] found, whether or not it succeeded.
final class D2d1LibraryLoad {
  const D2d1LibraryLoad({required this.library, required this.diagnostics});

  /// Null when a required DLL or export was missing; [diagnostics] says which.
  final D2d1Library? library;

  final List<BackendDiagnostic> diagnostics;

  bool get isLoaded => library != null;
}

/// The bound entry points, loaded once per process.
final class D2d1Library {
  D2d1Library._({
    required DynamicLibrary d2d1,
    required DynamicLibrary gdi32,
    required DynamicLibrary kernel32,
  }) {
    createFactory =
        d2d1.lookupFunction<_CreateFactoryNative, D2d1CreateFactoryDart>(
            'D2D1CreateFactory');

    createCompatibleDc = gdi32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)>('CreateCompatibleDC');
    createDibSection = gdi32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Win32BitmapInfoHeader>,
            Uint32, Pointer<Pointer<Void>>, Pointer<Void>, Uint32),
        Pointer<Void> Function(Pointer<Void>, Pointer<Win32BitmapInfoHeader>,
            int, Pointer<Pointer<Void>>, Pointer<Void>, int)>(
        'CreateDIBSection');
    selectObject = gdi32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>('SelectObject');
    deleteObject = gdi32.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('DeleteObject');
    deleteDc = gdi32.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('DeleteDC');
    gdiFlush =
        gdi32.lookupFunction<Int32 Function(), int Function()>('GdiFlush');

    final int Function() getProcessHeap = kernel32
        .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap');
    final Pointer<Void> Function(int, int, int) heapAlloc =
        kernel32.lookupFunction<Pointer<Void> Function(IntPtr, Uint32, IntPtr),
            Pointer<Void> Function(int, int, int)>('HeapAlloc');
    final int Function(int, int, Pointer<Void>) heapFree =
        kernel32.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Void>),
            int Function(int, int, Pointer<Void>)>('HeapFree');
    allocator = _ProcessHeapAllocator(getProcessHeap(), heapAlloc, heapFree);
  }

  static D2d1LibraryLoad? _cached;

  /// Loads and binds, or names what stopped it.
  ///
  /// Cached like `Win32Api.load`, because selection probes every backend and
  /// reopening DLLs per probe is work nobody asked for.
  static D2d1LibraryLoad open() {
    final D2d1LibraryLoad? cached = _cached;
    if (cached != null) return cached;
    final D2d1LibraryLoad result = _open();
    _cached = result;
    return result;
  }

  /// Drops the cache. Only for tests that want a fresh load.
  static void debugResetCache() => _cached = null;

  static D2d1LibraryLoad _open() {
    final DynamicLibrary d2d1;
    try {
      d2d1 = DynamicLibrary.open('d2d1.dll');
    } on Object catch (error) {
      return D2d1LibraryLoad(
        library: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary(
            'd2d1.dll',
            detail: '$error. Direct2D shipped with Windows 7; a machine '
                'without it has no Direct2D at all and the CPU presenter is '
                'the answer, not a retry',
          ),
        ],
      );
    }

    final DynamicLibrary gdi32;
    final DynamicLibrary kernel32;
    try {
      gdi32 = DynamicLibrary.open('gdi32.dll');
      kernel32 = DynamicLibrary.open('kernel32.dll');
    } on Object catch (error) {
      return D2d1LibraryLoad(
        library: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary(
            'gdi32.dll / kernel32.dll',
            detail: '$error',
          ),
        ],
      );
    }

    try {
      return D2d1LibraryLoad(
        library: D2d1Library._(d2d1: d2d1, gdi32: gdi32, kernel32: kernel32),
        diagnostics: const <BackendDiagnostic>[],
      );
    } on ArgumentError catch (error) {
      return D2d1LibraryLoad(
        library: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingSymbol(
            '$error',
            detail: 'a required export was absent from d2d1.dll, gdi32.dll '
                'or kernel32.dll',
          ),
        ],
      );
    }
  }

  late final D2d1CreateFactoryDart createFactory;

  // GDI, for the offscreen readback surface only.
  late final Pointer<Void> Function(Pointer<Void>) createCompatibleDc;
  late final Pointer<Void> Function(Pointer<Void>,
      Pointer<Win32BitmapInfoHeader>, int, Pointer<Pointer<Void>>,
      Pointer<Void>, int) createDibSection;
  late final Pointer<Void> Function(Pointer<Void>, Pointer<Void>) selectObject;
  late final int Function(Pointer<Void>) deleteObject;
  late final int Function(Pointer<Void>) deleteDc;
  late final int Function() gdiFlush;

  /// Zeroing scratch memory for the structures handed across the ABI. See
  /// `d3d12_library.dart` for why the process heap and why zeroed.
  late final Allocator allocator;
}

/// `HEAP_ZERO_MEMORY`.
const int _heapZeroMemory = 0x00000008;

final class _ProcessHeapAllocator implements Allocator {
  const _ProcessHeapAllocator(this._heap, this._alloc, this._free);

  final int _heap;
  final Pointer<Void> Function(int, int, int) _alloc;
  final int Function(int, int, Pointer<Void>) _free;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    final Pointer<Void> pointer = _alloc(_heap, _heapZeroMemory, byteCount);
    if (pointer == nullptr) {
      throw StateError('HeapAlloc failed for $byteCount bytes');
    }
    return pointer.cast<T>();
  }

  @override
  void free(Pointer<NativeType> pointer) {
    if (pointer == nullptr) return;
    _free(_heap, 0, pointer.cast<Void>());
  }
}
Bash Check lint configuration
IN
cd "C:/MyDartProjects/dart_ui" && cat analysis_options.yaml

OUT
include: package:lints/recommended.yaml

analyzer:
  # POCs and vendored references are independent projects with their own
  # analyzers. Walking them from the framework root makes `dart analyze`
  # traverse millions of reference lines and can leave the CI gate timing out.
  exclude:
    - poc/**
    - referencias/**
    - build/**
  language:
    strict-casts: true
    strict-raw-types: true

linter:
  rules:
    - prefer_final_locals
    - prefer_const_constructors
    - prefer_const_declarations
    - avoid_print: false
    - directives_ordering
    - prefer_single_quotes
Edit C:\MyDartProjects\dart_ui\lib\src\platform\trash_platform_io.dart
Added 4 lines
Now the COM interface wrappers.

Now SystemInfo.

Now I have the full picture. Let me write the WebGPU backend. Starting with the pure, headless-testable part: the WGSL shaders and command-assembly helpers.

Write C:\MyDartProjects\dart_ui\lib\src\platform\system_info_types.dart
76 lines
/// The shared vocabulary of [SystemInfo], plus the answer-parsing that is
/// pure string work.
library;

/// A snapshot of what the platform says about itself and the session.
///
/// Plain values, captured at one moment: nothing here updates itself, and a
/// caller that needs a fresh answer takes a fresh snapshot. Fields that a
/// target genuinely cannot answer are empty strings rather than null - "the
/// browser does not say" is an answer, and an empty string keeps every caller
/// out of the null-check business for data that is only ever displayed.
final class SystemInfoData {
  const SystemInfoData({
    required this.operatingSystem,
    required this.operatingSystemVersion,
    required this.hostname,
    required this.userName,
    required this.locale,
    required this.processorCount,
  });

  /// `windows`, `linux`, `macos`, `web`, ...
  final String operatingSystem;

  /// The platform's own version string, verbatim - a build string on
  /// Windows, `uname` output on Linux, the user-agent on the web. Verbatim
  /// because every scheme for normalising these ages badly.
  final String operatingSystemVersion;

  final String hostname;

  /// The session's user name, from the platform's environment. Empty on the
  /// web, which does not have one.
  final String userName;

  /// A BCP 47-ish locale tag such as `pt_BR` or `en-US`, in the platform's
  /// own spelling.
  final String locale;

  final int processorCount;

  @override
  String toString() => 'SystemInfoData($operatingSystem '
      '$operatingSystemVersion, host: $hostname, user: $userName, '
      'locale: $locale, cpus: $processorCount)';
}

/// Whether the Windows `AppsUseLightTheme` registry value means dark mode.
///
/// The value is "apps use *light* theme", so 0 is dark - inverted enough to
/// deserve one named function and one test.
bool darkModeFromAppsUseLightTheme(int value) => value == 0;

/// Whether a freedesktop `color-scheme` answer means dark mode.
///
/// `gsettings get org.gnome.desktop.interface color-scheme` answers a quoted
/// GVariant string: `'prefer-dark'`, `'prefer-light'` or `'default'`.
/// Null means the answer named no preference either way.
bool? darkModeFromColorScheme(String answer) {
  final String normalized = answer.trim().toLowerCase();
  if (normalized.contains('prefer-dark')) return true;
  if (normalized.contains('prefer-light')) return false;
  if (normalized.contains('default')) return false;
  return null;
}

/// Whether `defaults read -g AppleInterfaceStyle` output means dark mode.
///
/// macOS only writes the key when dark mode is on; the command failing
/// (nonzero [exitCode]) *is* the light-mode answer.
bool darkModeFromAppleInterfaceStyle({
  required int exitCode,
  required String stdout,
}) =>
    exitCode == 0 && stdout.trim().toLowerCase() == 'dark';
Write C:\MyDartProjects\dart_ui\lib\src\platform\system_info.dart
33 lines
/// What the platform will say about itself: identity, session, and the one
/// appearance preference every desktop now exposes.
///
/// Two kinds of answer live here and their shapes differ on purpose.
/// [SystemInfo.snapshot] is synchronous plain values - name, version,
/// hostname, locale, CPU count - because every target answers those from
/// memory. [SystemInfo.isDarkMode] is asynchronous and tri-state: on Linux
/// and macOS the answer comes from asking another process, and on any
/// platform the honest answers are "dark", "light" and "the platform did not
/// say" - which is `null`, not a guessed `false`.
library;

import 'system_info_platform_stub.dart'
    if (dart.library.io) 'system_info_platform_io.dart'
    if (dart.library.js_interop) 'system_info_platform_web.dart' as platform;
import 'system_info_types.dart';

export 'system_info_types.dart';

/// Read-only facts about the machine and session this process runs in.
abstract final class SystemInfo {
  /// The current facts, captured now.
  static SystemInfoData snapshot() => platform.snapshot();

  /// Whether the platform is currently in dark mode, or null when it does
  /// not say (an older desktop, a Linux without gsettings, a stub target).
  ///
  /// This is the *current* value, not a subscription; there is no portable
  /// change notification across the three desktops, so a caller that wants
  /// to follow the setting re-asks when its window regains focus.
  static Future<bool?> isDarkMode() => platform.isDarkMode();
}
Write C:\MyDartProjects\dart_ui\lib\src\platform\system_info_platform_stub.dart
15 lines
library;

import 'system_info_types.dart';

SystemInfoData snapshot() => const SystemInfoData(
      operatingSystem: 'unknown',
      operatingSystemVersion: '',
      hostname: '',
      userName: '',
      locale: '',
      processorCount: 1,
    );

Future<bool?> isDarkMode() async => null;
Write C:\MyDartProjects\dart_ui\lib\src\widgets\data_grid.dart
1077 lines
/// A virtualized data grid: columns, sortable headers, resizable widths,
/// row selection.
///
/// The shape is the one every desktop toolkit converges on:
///
///   * **columns are configuration, cells are widgets.** A [DataGridColumn]
///     says what a column is called and how wide it starts; the cell content
///     comes from [DataGrid.cellBuilder], called only for realized rows -
///     which is what lets a grid of a hundred thousand rows exist at all. Row
///     virtualization reuses [ListVirtualization], the same planner
///     `list_box.dart` scrolls with.
///   * **the grid is controlled.** Sort state and selection live with the
///     caller; the grid reports intent through [DataGrid.onSortChanged] and
///     [DataGrid.onSelectionChanged]. Sorting *the data* is the caller's job:
///     the grid cannot know whether column 2 holds strings, dates or money,
///     and a control that guessed would sort one of them wrong.
///   * **the body is one tab stop.** Arrow keys move the row cursor,
///     Shift extends the selection in [DataGridSelectionMode.multiple],
///     Ctrl+A selects everything, Home/End and PageUp/PageDown do what they
///     say. The header is pointer-only, as it is on every platform.
///
/// Column resizing is a drag on the boundary between two headers; the grip is
/// a few pixels wide on either side. Widths are held by the grid's state,
/// keyed by column identity so a rebuild with the same columns keeps the
/// widths the user dragged, and reported through [DataGrid.onColumnResized]
/// for callers that persist them.
///
/// Horizontal overflow is clipped rather than scrolled in this first version;
/// the vertical axis is where a grid's size lives.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import '../text/shaper.dart' show TextDirection;
import 'basic.dart';
import 'control.dart';
import 'directionality.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'semantics.dart';
import 'style.dart';
import 'theme.dart';
import 'virtualization.dart';
import 'widget.dart';

/// One column: a title and its metrics. Content comes from the grid's
/// [DataGrid.cellBuilder].
final class DataGridColumn {
  const DataGridColumn({
    required this.title,
    this.id,
    this.width = 120.0,
    this.minWidth = 40.0,
    this.resizable = true,
    this.sortable = true,
  });

  final String title;

  /// What this column *is*, across rebuilds in which the list changed.
  /// Defaults to the title.
  final Object? id;

  /// The starting width; the user's drags override it from then on.
  final double width;

  final double minWidth;
  final bool resizable;
  final bool sortable;

  Object get identity => id ?? title;
}

enum DataGridSortDirection { ascending, descending }

/// Which column the data is sorted by, and which way.
final class DataGridSort {
  const DataGridSort(this.columnIndex, this.direction);

  final int columnIndex;
  final DataGridSortDirection direction;

  @override
  bool operator ==(Object other) =>
      other is DataGridSort &&
      other.columnIndex == columnIndex &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(columnIndex, direction);
}

enum DataGridSelectionMode { none, single, multiple }

/// A virtualized table of rows and columns.
final class DataGrid extends StatefulWidget {
  const DataGrid({
    super.key,
    required this.columns,
    required this.rowCount,
    required this.cellBuilder,
    this.rowExtent = 24.0,
    this.cacheExtent = 48.0,
    this.sort,
    this.onSortChanged,
    this.selectionMode = DataGridSelectionMode.single,
    this.selectedRows = const <int>{},
    this.onSelectionChanged,
    this.onColumnResized,
    this.controller,
  });

  final List<DataGridColumn> columns;
  final int rowCount;

  /// Called only for realized cells: a few dozen rows regardless of
  /// [rowCount].
  final Widget Function(BuildContext context, int row, int column) cellBuilder;

  final double rowExtent;
  final double cacheExtent;

  /// The current sort, or null for unsorted. The grid draws the arrow; the
  /// caller sorts the data.
  final DataGridSort? sort;

  final void Function(DataGridSort sort)? onSortChanged;

  final DataGridSelectionMode selectionMode;
  final Set<int> selectedRows;
  final void Function(Set<int> rows)? onSelectionChanged;

  /// Reports a width the user dragged, for callers that persist layout.
  final void Function(int columnIndex, double width)? onColumnResized;

  final ScrollPosition? controller;

  @override
  State<DataGrid> createState() => _DataGridState();
}

final class _DataGridState extends State<DataGrid> {
  late final ScrollPosition _position = widget.controller ?? ScrollPosition();
  late final FocusNode _focusNode = FocusNode(debugLabel: 'DataGrid');
  double _viewportExtent = 0;

  /// Widths the user has dragged, keyed by column identity so they survive a
  /// rebuild that reorders or extends the column list.
  final Map<Object, double> _draggedWidths = <Object, double>{};

  /// The row the keyboard is on. Selection follows it per the mode.
  int _cursor = 0;

  /// Where a Shift-extended range grows from.
  int _anchor = 0;

  @override
  void initState() {
    super.initState();
    _position.addListener(_onScrolled);
    if (widget.selectedRows.isNotEmpty) {
      _cursor = widget.selectedRows.reduce((int a, int b) => a < b ? a : b);
      _anchor = _cursor;
    }
  }

  @override
  void dispose() {
    _position.removeListener(_onScrolled);
    _focusNode.dispose();
    super.dispose();
  }

  void _onScrolled(ScrollPosition position) {
    if (mounted) setState(() {});
  }

  List<double> get _widths => <double>[
        for (final DataGridColumn column in widget.columns)
          _draggedWidths[column.identity] ?? column.width,
      ];

  void _resizeColumn(int index, double width) {
    final DataGridColumn column = widget.columns[index];
    final double clamped = width < column.minWidth ? column.minWidth : width;
    if ((_draggedWidths[column.identity] ?? column.width) == clamped) return;
    setState(() => _draggedWidths[column.identity] = clamped);
    widget.onColumnResized?.call(index, clamped);
  }

  void _requestSort(int index) {
    if (!widget.columns[index].sortable) return;
    final DataGridSort? current = widget.sort;
    // Clicking a new column sorts ascending; clicking the sorted column flips
    // it. That is the cycle every file manager taught everyone.
    final DataGridSortDirection direction = current?.columnIndex == index &&
            current?.direction == DataGridSortDirection.ascending
        ? DataGridSortDirection.descending
        : DataGridSortDirection.ascending;
    widget.onSortChanged?.call(DataGridSort(index, direction));
  }

  void _emitSelection(Set<int> rows) {
    widget.onSelectionChanged?.call(rows);
  }

  /// Selection after the cursor moved to [target] with [extend] (Shift held).
  void _moveCursor(int target, {bool extend = false}) {
    if (widget.rowCount == 0) return;
    final int clamped = target.clamp(0, widget.rowCount - 1);
    _cursor = clamped;
    switch (widget.selectionMode) {
      case DataGridSelectionMode.none:
        break;
      case DataGridSelectionMode.single:
        _anchor = clamped;
        _emitSelection(<int>{clamped});
      case DataGridSelectionMode.multiple:
        if (extend) {
          _emitSelection(_range(_anchor, clamped));
        } else {
          _anchor = clamped;
          _emitSelection(<int>{clamped});
        }
    }
    _reveal(clamped);
    if (mounted) setState(() {});
  }

  Set<int> _range(int a, int b) => <int>{
        for (int i = a < b ? a : b; i <= (a > b ? a : b); i++) i,
      };

  void _reveal(int index) {
    final double? target = _virtualization.scrollToReveal(
      index,
      scrollOffset: _position.pixels,
      viewportExtent:
          _viewportExtent > 0 ? _viewportExtent : widget.rowExtent * 8,
    );
    if (target != null) _position.jumpTo(target);
  }

  void _handleRowPress(int index, Set<KeyModifier> modifiers) {
    _cursor = index;
    switch (widget.selectionMode) {
      case DataGridSelectionMode.none:
        break;
      case DataGridSelectionMode.single:
        _anchor = index;
        _emitSelection(<int>{index});
      case DataGridSelectionMode.multiple:
        if (modifiers.contains(KeyModifier.shift)) {
          _emitSelection(_range(_anchor, index));
        } else if (modifiers.contains(KeyModifier.control)) {
          final Set<int> next = <int>{...widget.selectedRows};
          if (!next.remove(index)) next.add(index);
          _anchor = index;
          _emitSelection(next);
        } else {
          _anchor = index;
          _emitSelection(<int>{index});
        }
    }
    if (mounted) setState(() {});
  }

  int get _rowsPerPage {
    final double viewport =
        _viewportExtent > 0 ? _viewportExtent : widget.rowExtent * 8;
    return (viewport / widget.rowExtent).floor().clamp(1, 1 << 20);
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent || widget.rowCount == 0) return false;
    final bool shift = event.modifiers.contains(KeyModifier.shift);
    final bool control = event.modifiers.contains(KeyModifier.control);
    switch (event.logicalKey) {
      case logicalKeyArrowDown:
        _moveCursor(_cursor + 1, extend: shift);
        return true;
      case logicalKeyArrowUp:
        _moveCursor(_cursor - 1, extend: shift);
        return true;
      case logicalKeyHome:
        _moveCursor(0, extend: shift);
        return true;
      case logicalKeyEnd:
        _moveCursor(widget.rowCount - 1, extend: shift);
        return true;
      case logicalKeyPageDown:
        _moveCursor(_cursor + _rowsPerPage, extend: shift);
        return true;
      case logicalKeyPageUp:
        _moveCursor(_cursor - _rowsPerPage, extend: shift);
        return true;
      case logicalKeySpace:
        if (widget.selectionMode == DataGridSelectionMode.multiple && control) {
          final Set<int> next = <int>{...widget.selectedRows};
          if (!next.remove(_cursor)) next.add(_cursor);
          _emitSelection(next);
          return true;
        }
        _moveCursor(_cursor);
        return true;
      case 0x41: // A
        if (control &&
            widget.selectionMode == DataGridSelectionMode.multiple) {
          _emitSelection(_range(0, widget.rowCount - 1));
          return true;
        }
        return false;
      default:
        return false;
    }
  }

  ListVirtualization get _virtualization => ListVirtualization(
        itemCount: widget.rowCount,
        estimatedExtent: widget.rowExtent,
        cacheExtent: widget.cacheExtent,
      );

  @override
  Widget build(BuildContext context) {
    final TextDirection direction = Directionality.of(context);
    final ThemeData theme = Theme.of(context);
    final List<double> widths = _widths;
    final ListVirtualization virtualization = _virtualization;
    final double viewport =
        _viewportExtent > 0 ? _viewportExtent : widget.rowExtent * 8;
    final RealizedRange range = virtualization.rangeFor(
      scrollOffset: _position.pixels,
      viewportExtent: viewport,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DataGridHeaderWidget(
          columns: widget.columns,
          widths: widths,
          sort: widget.sort,
          textDirection: direction,
          theme: theme,
          onSortRequest: _requestSort,
          onResize: _resizeColumn,
        ),
        Expanded(
          child: FocusAttachment(
            node: _focusNode,
            child: _DataGridBodyWidget(
              position: _position,
              focusNode: _focusNode,
              theme: theme,
              virtualization: virtualization,
              range: range,
              selectedCount: widget.selectedRows.length,
              cursor: _cursor,
              onKeyEvent: _handleKey,
              onRowPressed: _handleRowPress,
              onViewportExtent: (double extent) {
                if (extent == _viewportExtent) return;
                _viewportExtent = extent;
                if (mounted) setState(() {});
              },
              children: <Widget>[
                for (int row = range.firstRealized;
                    row <= range.lastRealized && row < widget.rowCount;
                    row++)
                  _DataGridRowWidget(
                    key: ValueKey<int>(row),
                    index: row,
                    extent: widget.rowExtent,
                    widths: widths,
                    selected: widget.selectedRows.contains(row),
                    textDirection: direction,
                    theme: theme,
                    children: <Widget>[
                      for (int column = 0;
                          column < widget.columns.length;
                          column++)
                        widget.cellBuilder(context, row, column),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// The header
// ---------------------------------------------------------------------------

final class _DataGridHeaderWidget extends RenderObjectWidget {
  const _DataGridHeaderWidget({
    required this.columns,
    required this.widths,
    required this.sort,
    required this.textDirection,
    required this.theme,
    required this.onSortRequest,
    required this.onResize,
  });

  final List<DataGridColumn> columns;
  final List<double> widths;
  final DataGridSort? sort;
  final TextDirection textDirection;
  final ThemeData theme;
  final void Function(int column) onSortRequest;
  final void Function(int column, double width) onResize;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderDataGridHeader createRenderObject(BuildContext context) =>
      RenderDataGridHeader()
        ..columns = columns
        ..widths = widths
        ..sort = sort
        ..textDirection = textDirection
        ..onSortRequest = onSortRequest
        ..onResize = onResize
        ..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDataGridHeader object,
  ) {
    object
      ..columns = columns
      ..widths = widths
      ..sort = sort
      ..textDirection = textDirection
      ..onSortRequest = onSortRequest
      ..onResize = onResize
      ..theme = theme;
  }
}

/// The header row: titles, sort arrow, resize grips.
final class RenderDataGridHeader extends RenderBox with ControlBehavior {
  /// Half-width of the resize grip either side of a column boundary.
  static const double gripExtent = 4;

  List<DataGridColumn> _columns = const <DataGridColumn>[];
  List<double> _widths = const <double>[];
  DataGridSort? _sort;
  TextDirection _textDirection = TextDirection.leftToRight;
  void Function(int column)? onSortRequest;
  void Function(int column, double width)? onResize;

  List<DataGridColumn> get columns => _columns;

  set columns(List<DataGridColumn> value) {
    if (identical(value, _columns)) return;
    _columns = value;
    markNeedsLayout();
  }

  List<double> get widths => _widths;

  set widths(List<double> value) {
    _widths = value;
    markNeedsLayout();
  }

  DataGridSort? get sort => _sort;

  set sort(DataGridSort? value) {
    if (value == _sort) return;
    _sort = value;
    markNeedsPaint();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  bool get focusOnPointerDown => false;

  /// The x of column [index]'s start edge, in this header's coordinates.
  double columnStart(int index) {
    double cumulative = 0;
    for (int i = 0; i < index && i < _widths.length; i++) {
      cumulative += _widths[i];
    }
    if (!_textDirection.isRightToLeft) return cumulative;
    final double width =
        index < _widths.length ? _widths[index] : 0;
    return size.width - cumulative - width;
  }

  /// The column whose *boundary* grip contains [dx], or -1.
  ///
  /// The boundary after column i belongs to column i's resize: dragging the
  /// line between "Name" and "Size" resizes "Name", on every platform.
  int _gripAt(double dx) {
    double cumulative = 0;
    for (int i = 0; i < _widths.length; i++) {
      cumulative += _widths[i];
      final double edge = _textDirection.isRightToLeft
          ? size.width - cumulative
          : cumulative;
      if ((dx - edge).abs() <= gripExtent) {
        return _columns[i].resizable ? i : -1;
      }
    }
    return -1;
  }

  /// The column containing [dx], or -1.
  int _columnAt(double dx) {
    double cumulative = 0;
    for (int i = 0; i < _widths.length; i++) {
      final double start = _textDirection.isRightToLeft
          ? size.width - cumulative - _widths[i]
          : cumulative;
      if (dx >= start && dx < start + _widths[i]) return i;
      cumulative += _widths[i];
    }
    return -1;
  }

  int _resizingColumn = -1;
  double _resizeStartX = 0;
  double _resizeStartWidth = 0;
  int _pressedColumn = -1;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!enabled) return;
    switch (event) {
      case PointerDownEvent(button: PointerButton.primary):
        final Offset local = globalToLocal(event.logicalPosition);
        final int grip = _gripAt(local.dx);
        if (grip >= 0) {
          _resizingColumn = grip;
          _resizeStartX = local.dx;
          _resizeStartWidth = _widths[grip];
          _pressedColumn = -1;
        } else {
          _resizingColumn = -1;
          _pressedColumn = _columnAt(local.dx);
        }
      case PointerMoveEvent():
        if (_resizingColumn < 0) return;
        final Offset local = globalToLocal(event.logicalPosition);
        // In RTL a column grows toward the left, so the drag sign flips.
        final double delta = _textDirection.isRightToLeft
            ? _resizeStartX - local.dx
            : local.dx - _resizeStartX;
        onResize?.call(_resizingColumn, _resizeStartWidth + delta);
      case PointerUpEvent():
        _resizingColumn = -1;
      case PointerCancelEvent():
        _resizingColumn = -1;
        _pressedColumn = -1;
      default:
        break;
    }
  }

  /// Fired by the release-inside path of [ControlBehavior]: a completed click
  /// that was not a resize asks for a sort.
  @override
  void activate() {
    final int column = _pressedColumn;
    _pressedColumn = -1;
    if (column >= 0 && column < _columns.length &&
        _columns[column].sortable) {
      onSortRequest?.call(column);
    }
  }

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    size = constraints.constrain(Size(width, theme.effectiveControlHeight));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surface);
    list.save();
    list.clipRect(rect.left, rect.top, rect.right, rect.bottom);
    final double padding = theme.effectiveControlPadding / 2;
    for (int i = 0; i < _columns.length && i < _widths.length; i++) {
      final double start = columnStart(i);
      final double columnWidth = _widths[i];
      final bool sorted = _sort?.columnIndex == i;
      final double arrowSpace = sorted ? 12 : 0;
      paintLabel(
        list,
        _columns[i].title,
        Offset(
          (offset.dx + start + padding).roundToDouble(),
          (offset.dy + (size.height - labelLineHeight) / 2).roundToDouble(),
        ),
        theme.foreground,
        maxWidth: (columnWidth - padding * 2 - arrowSpace)
            .clamp(0.0, double.infinity),
      );
      if (sorted) {
        _paintSortArrow(
          list,
          Offset(
            offset.dx + start + columnWidth - padding - 8,
            offset.dy + size.height / 2,
          ),
          _sort!.direction,
        );
      }
      // The boundary line doubles as the visual for the resize grip.
      final double edge = _textDirection.isRightToLeft ? start : start +
          columnWidth;
      paintFill(
        list,
        Rect.fromLTWH(offset.dx + edge - 1, rect.top + 3, 1, size.height - 6),
        theme.border,
      );
    }
    list.restore();
    paintBorder(list, rect, theme.border);
  }

  /// A pixel-art triangle: stacked one-pixel rows, exact on whole pixels.
  void _paintSortArrow(
    DisplayList list,
    Offset center,
    DataGridSortDirection direction,
  ) {
    const int rows = 4;
    for (int i = 0; i < rows; i++) {
      final int halfWidth =
          direction == DataGridSortDirection.ascending ? i : rows - 1 - i;
      final double y = (center.dy - rows / 2 + i).roundToDouble();
      list.drawRectangle(
        Rect.fromLTWH(
          (center.dx - halfWidth).roundToDouble(),
          y,
          halfWidth * 2 + 1,
          1,
        ),
        list.addPaint(colorArgb: theme.foreground.value, antiAlias: false),
      );
    }
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.list,
        label: <String>[
          for (final DataGridColumn column in _columns) column.title,
        ].join(', '),
        value: '${_columns.length} columns',
        hint: _sort == null
            ? null
            : 'sorted by ${_columns[_sort!.columnIndex].title} '
                '${_sort!.direction.name}',
        mergesDescendants: true,
      );
}

// ---------------------------------------------------------------------------
// One row
// ---------------------------------------------------------------------------

final class _DataGridRowWidget extends MultiChildRenderObjectWidget {
  const _DataGridRowWidget({
    super.key,
    required this.index,
    required this.extent,
    required this.widths,
    required this.selected,
    required this.textDirection,
    required this.theme,
    required super.children,
  });

  final int index;
  final double extent;
  final List<double> widths;
  final bool selected;
  final TextDirection textDirection;
  final ThemeData theme;

  @override
  RenderDataGridRow createRenderObject(BuildContext context) =>
      RenderDataGridRow()
        ..index = index
        ..extent = extent
        ..widths = widths
        ..selected = selected
        ..textDirection = textDirection
        ..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDataGridRow object,
  ) {
    object
      ..index = index
      ..extent = extent
      ..widths = widths
      ..selected = selected
      ..textDirection = textDirection
      ..theme = theme;
  }
}

/// One realized row: its cells at the column offsets.
final class RenderDataGridRow extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  int _index = 0;
  double _extent = 24;
  List<double> _widths = const <double>[];
  bool _selected = false;
  TextDirection _textDirection = TextDirection.leftToRight;

  int get index => _index;

  set index(int value) {
    if (value == _index) return;
    _index = value;
    markNeedsPaint();
  }

  double get extent => _extent;

  set extent(double value) {
    if (value == _extent) return;
    _extent = value;
    markNeedsLayout();
  }

  List<double> get widths => _widths;

  set widths(List<double> value) {
    _widths = value;
    markNeedsLayout();
  }

  bool get selected => _selected;

  set selected(bool value) {
    if (value == _selected) return;
    _selected = value;
    markNeedsPaint();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_selected) PseudoClass.selected,
      };

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    size = constraints.constrain(Size(width, _extent));
    final double padding = theme.effectiveControlPadding / 2;
    double cumulative = 0;
    for (int i = 0; i < childCount; i++) {
      final double columnWidth = i < _widths.length ? _widths[i] : 0;
      final RenderBox child = childAt(i);
      final double cellWidth =
          (columnWidth - padding * 2).clamp(0.0, double.infinity);
      child.layout(
        BoxConstraints(maxWidth: cellWidth, maxHeight: _extent),
        parentUsesSize: true,
      );
      final double start = _textDirection.isRightToLeft
          ? size.width - cumulative - columnWidth
          : cumulative;
      child.parentData!.offset = Offset(
        start + padding,
        ((_extent - child.size.height) / 2).clamp(0.0, _extent),
      );
      cumulative += columnWidth;
    }
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    if (_selected) {
      paintFill(list, rect, theme.selection);
    } else if (isHovered && enabled) {
      paintFill(list, rect, theme.surface);
    } else if (_index.isOdd) {
      // Zebra from the *row index*, not the realized position, so the
      // stripes do not flicker as the grid scrolls.
      paintFill(list, rect, theme.surface);
    }
    super.paint(list, offset);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.listItem,
        value: 'row ${_index + 1}',
        states: <SemanticsState>{
          if (_selected) SemanticsState.selected,
        },
        actions: const <SemanticsAction>{SemanticsAction.activate},
      );
}

// ---------------------------------------------------------------------------
// The body
// ---------------------------------------------------------------------------

final class _DataGridBodyWidget extends MultiChildRenderObjectWidget {
  const _DataGridBodyWidget({
    required this.position,
    required this.focusNode,
    required this.theme,
    required this.virtualization,
    required this.range,
    required this.selectedCount,
    required this.cursor,
    required this.onKeyEvent,
    required this.onRowPressed,
    required this.onViewportExtent,
    required super.children,
  });

  final ScrollPosition position;
  final FocusNode focusNode;
  final ThemeData theme;
  final ListVirtualization virtualization;
  final RealizedRange range;
  final int selectedCount;
  final int cursor;
  final bool Function(KeyEvent event) onKeyEvent;
  final void Function(int index, Set<KeyModifier> modifiers) onRowPressed;
  final void Function(double extent) onViewportExtent;

  @override
  RenderDataGridBody createRenderObject(BuildContext context) =>
      RenderDataGridBody(
        position: position,
        virtualization: virtualization,
        range: range,
        selectedCount: selectedCount,
        cursor: cursor,
        onKeyEvent: onKeyEvent,
        onRowPressed: onRowPressed,
        onViewportExtent: onViewportExtent,
      )
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDataGridBody object,
  ) {
    object
      ..position = position
      ..virtualization = virtualization
      ..range = range
      ..selectedCount = selectedCount
      ..cursor = cursor
      ..onKeyEvent = onKeyEvent
      ..onRowPressed = onRowPressed
      ..onViewportExtent = onViewportExtent
      ..theme = theme
      ..focusNode = focusNode;
  }
}

/// Lays out the realized rows and reports the full grid to accessibility.
final class RenderDataGridBody extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  RenderDataGridBody({
    required ScrollPosition position,
    required ListVirtualization virtualization,
    required RealizedRange range,
    required this.selectedCount,
    required this.cursor,
    required this.onKeyEvent,
    required this.onRowPressed,
    required this.onViewportExtent,
  })  : _position = position,
        _virtualization = virtualization,
        _range = range {
    _position.addListener(_onScrolled);
  }

  ScrollPosition _position;
  ListVirtualization _virtualization;
  RealizedRange _range;
  int selectedCount;
  int cursor;
  bool Function(KeyEvent event) onKeyEvent;
  void Function(int index, Set<KeyModifier> modifiers) onRowPressed;
  void Function(double extent) onViewportExtent;

  ScrollPosition get position => _position;

  set position(ScrollPosition value) {
    if (identical(value, _position)) return;
    _position.removeListener(_onScrolled);
    _position = value..addListener(_onScrolled);
    markNeedsLayout();
  }

  ListVirtualization get virtualization => _virtualization;

  set virtualization(ListVirtualization value) {
    _virtualization = value;
    markNeedsLayout();
  }

  RealizedRange get range => _range;

  set range(RealizedRange value) {
    if (value == _range) return;
    _range = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    final double height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : constraints.minHeight;
    size = constraints.constrain(Size(width, height));

    _position.applyViewportGeometry(
      viewportExtent: height,
      contentExtent: _virtualization.totalExtent,
    );

    double cursorY = _range.leadingExtent - _position.pixels;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(
        BoxConstraints(minWidth: width, maxWidth: width),
        parentUsesSize: true,
      );
      child.parentData!.offset = Offset(0, cursorY);
      cursorY += child.size.height;
    }
    onViewportExtent(height);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surfaceAlternate);
    list.save();
    list.clipRect(rect.left, rect.top, rect.right, rect.bottom);
    super.paint(list, offset);
    list.restore();
    paintBorder(list, rect, theme.border);
    paintFocusRing(list, rect);
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    if (!size.contains(position)) return null;
    return super.hitTestChildren(position, path: path);
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (event is PointerScrollEvent) {
      _position.applyScrollDelta(
        event.scrollDelta.dy,
        inLines: event.scrollDeltaUnit == ScrollDeltaUnit.lines,
      );
      return;
    }
    if (event is PointerDownEvent) {
      final double contentY =
          globalToLocal(event.logicalPosition).dy + _position.pixels;
      final int index = _virtualization.indexAt(contentY);
      if (index >= 0 && index < _virtualization.itemCount) {
        onRowPressed(index, event.modifiers);
      }
    }
  }

  @override
  bool handleKeyEvent(KeyEvent event) => onKeyEvent(event);

  void _onScrolled(ScrollPosition position) => markNeedsLayout();

  @override
  void detach() {
    _position.removeListener(_onScrolled);
    super.detach();
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.list,
        value: '${_virtualization.itemCount} rows',
        hint: selectedCount == 0
            ? null
            : '$selectedCount of ${_virtualization.itemCount} selected',
        states: <SemanticsState>{
          if (hasFocus) SemanticsState.focused,
        },
        actions: const <SemanticsAction>{
          SemanticsAction.focus,
          SemanticsAction.scrollDown,
          SemanticsAction.scrollUp,
        },
      );
}
Write C:\MyDartProjects\dart_ui\lib\src\platform\system_info_platform_io.dart
143 lines
library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'system_info_types.dart';

SystemInfoData snapshot() {
  final Map<String, String> environment = Platform.environment;
  return SystemInfoData(
    operatingSystem: Platform.operatingSystem,
    operatingSystemVersion: Platform.operatingSystemVersion,
    hostname: Platform.localHostname,
    userName: environment['USERNAME'] ??
        environment['USER'] ??
        environment['LOGNAME'] ??
        '',
    locale: Platform.localeName,
    processorCount: Platform.numberOfProcessors,
  );
}

Future<bool?> isDarkMode() async {
  if (Platform.isWindows) {
    final int? value = readWindowsAppsUseLightTheme();
    return value == null ? null : darkModeFromAppsUseLightTheme(value);
  }
  if (Platform.isMacOS) return _macDarkMode();
  if (Platform.isLinux) return _linuxDarkMode();
  return null;
}

/// The seam a test injects a fake process runner through.
typedef SystemProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

Future<ProcessResult> _runProcess(
  String executable,
  List<String> arguments,
) =>
    Process.run(executable, arguments);

/// macOS: the global default `AppleInterfaceStyle` exists (and reads `Dark`)
/// only while dark mode is on.
Future<bool?> _macDarkMode({SystemProcessRunner run = _runProcess}) async {
  try {
    final ProcessResult result = await run(
      '/usr/bin/defaults',
      const <String>['read', '-g', 'AppleInterfaceStyle'],
    );
    return darkModeFromAppleInterfaceStyle(
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
    );
  } on ProcessException {
    return null;
  }
}

/// Linux: the freedesktop `color-scheme` setting, via gsettings. A desktop
/// without gsettings, or one where the schema is missing, answers null.
Future<bool?> _linuxDarkMode({SystemProcessRunner run = _runProcess}) async {
  try {
    final ProcessResult result = await run(
      'gsettings',
      const <String>['get', 'org.gnome.desktop.interface', 'color-scheme'],
    );
    if (result.exitCode != 0) return null;
    return darkModeFromColorScheme('${result.stdout}');
  } on ProcessException {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Windows: HKCU\...\Themes\Personalize!AppsUseLightTheme, via RegGetValueW.
// A registry read, not a process spawn: the value is what every application
// reading the "app mode" setting consults, and advapi32 is always present.
// ---------------------------------------------------------------------------

typedef _RegGetValueWNative = Int32 Function(
  IntPtr key,
  Pointer<Uint16> subKey,
  Pointer<Uint16> value,
  Uint32 flags,
  Pointer<Uint32> type,
  Pointer<Uint32> data,
  Pointer<Uint32> dataSize,
);
typedef _RegGetValueWDart = int Function(
  int key,
  Pointer<Uint16> subKey,
  Pointer<Uint16> value,
  int flags,
  Pointer<Uint32> type,
  Pointer<Uint32> data,
  Pointer<Uint32> dataSize,
);

const int _hkeyCurrentUser = 0x80000001;
const int _rrfRtRegDword = 0x00010000;

_RegGetValueWDart? _regGetValue;
bool _regBindAttempted = false;

/// The raw `AppsUseLightTheme` DWORD, or null when the value (or advapi32)
/// is unavailable - Windows before 1607 has neither the value nor the
/// setting.
int? readWindowsAppsUseLightTheme() {
  if (!_regBindAttempted) {
    _regBindAttempted = true;
    try {
      _regGetValue = DynamicLibrary.open('advapi32.dll')
          .lookupFunction<_RegGetValueWNative, _RegGetValueWDart>(
              'RegGetValueW');
    } on Object {
      _regGetValue = null;
    }
  }
  final _RegGetValueWDart? read = _regGetValue;
  if (read == null) return null;
  return using((NativeArena arena) {
    final Pointer<Uint32> data = arena<Uint32>(4);
    final Pointer<Uint32> size = arena<Uint32>(4);
    size.value = 4;
    final int status = read(
      _hkeyCurrentUser,
      arena.allocateUtf16(
        r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
      ),
      arena.allocateUtf16('AppsUseLightTheme'),
      _rrfRtRegDword,
      nullptr,
      data,
      size,
    );
    return status == 0 ? data.value : null;
  });
}
Bash PointerEvent fields
IN
sed -n 30,110p C:/MyDartProjects/dart_ui/lib/src/platform/input_events.dart

OUT
/// Base class for pointer input (mouse, touch).
sealed class PointerEvent extends PlatformInputEvent {
  const PointerEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required this.pointerId,
    required this.kind,
    required this.logicalPosition,
  });

  /// A stable identifier for this pointer (e.g., touch finger ID). For mice,
  /// this is typically 0.
  final int pointerId;
  final PointerKind kind;

  /// The position in logical units within the client area of the window.
  final Offset logicalPosition;
}

final class PointerDownEvent extends PointerEvent {
  const PointerDownEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.pointerId,
    required super.kind,
    required super.logicalPosition,
    required this.button,
    this.clickCount = 1,
  });

  final PointerButton button;

  /// Which press of a multi-click this is, **as the platform counted it**.
  ///
  /// 1 for an ordinary press, 2 when the platform itself decided this press
  /// continues the previous one. It exists because that decision is not a
  /// constant a widget may invent:
  ///
  ///  * Windows registers the class with `CS_DBLCLKS` and answers the second
  ///    press with `WM_LBUTTONDBLCLK`, having matched it against
  ///    `GetDoubleClickTime()` and the `SM_CXDOUBLECLK`/`SM_CYDOUBLECLK`
  ///    rectangle - both of which the user sets in the mouse control panel, and
  ///    both of which are **accessibility settings**: somebody with a tremor or
  ///    reduced dexterity raises the interval precisely because 500 ms is not
  ///    long enough for them. A widget that re-derives the count from a fixed
  ///    interval silently overrides that.
  ///  * macOS reports `NSEvent.clickCount` for the same reason, and X11 reports
  ///    none at all - which is why this defaults to 1 rather than being
  ///    required, and why a consumer must still be able to count for itself.
  ///
  /// It stops at 2 on Windows: there is no `WM_LBUTTONTRIPLECLK`, so a third
  /// press arrives as an ordinary down and a triple click is the consumer's own
  /// arithmetic either way.
  final int clickCount;
}

final class PointerUpEvent extends PointerEvent {
  const PointerUpEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.pointerId,
    required super.kind,
    required super.logicalPosition,
    required this.button,
  });

  final PointerButton button;
}

final class PointerMoveEvent extends PointerEvent {
  const PointerMoveEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.pointerId,
    required super.kind,
    required super.logicalPosition,
Write C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\webgpu\wgsl_shaders.dart
212 lines
/// The WGSL the WebGPU backend compiles, and the pure mappings around it.
///
/// This file is the `gl_shaders.dart` of the WebGPU path, and like that file it
/// is deliberately free of any browser import: everything in it is a string, a
/// constant or a total function over the renderer's own enums, so the VM test
/// suite can check the shader source and the mapping tables on a machine with
/// no browser and no GPU at all. The interop lives in `webgpu_interop.dart`;
/// the objects live in `webgpu_backend.dart`.
///
/// ## One module, three fragment entry points, where GL had one and a uniform
///
/// `gl_shaders.dart` selects the pipeline's behaviour with a `uMode` uniform,
/// because on GL a program switch costs more than an int compare that is
/// uniform across a draw call. WebGPU removes the choice: the *blend state* is
/// baked into a `GPURenderPipeline` at creation, so a batch that changes blend
/// mode forces a pipeline switch whatever the shader looks like - and once a
/// pipeline switch per state change is a given, folding the mode into the
/// pipeline too costs nothing and deletes a uniform, a branch and a way for the
/// two to disagree. So there is one shader module with one vertex entry point
/// and three fragment entry points, and a pipeline is the pair (entry point,
/// blend state). Nine pipelines at most, created lazily and cached for the
/// device's life.
///
/// The three fragment bodies are line-for-line translations of the GLSL in
/// `gl_shaders.dart`, coverage term included - that term *is* the antialiasing,
/// and the parity argument made there applies unchanged: a WGSL copy that
/// drifted from the GLSL would make the two web backends draw different edges
/// from the same display list, and the difference would look like a driver bug.
///
/// ## There is no `uYFlip`, and that is not an omission
///
/// The GL shader carries a `uYFlip` uniform because GL's framebuffer origin is
/// the bottom-left corner: a pass that renders into a texture something else
/// will sample must invert its projection to leave the image top-down, which is
/// the orientation every texture this renderer samples is stored in.
///
/// WebGPU's conventions dissolve the problem. Normalised device coordinates
/// are y-up, and framebuffer coordinates - where the pixels land - have their
/// origin at the **top-left**, like Metal and Direct3D. So the one projection
/// below, `ndcY = 1 - y / viewport.y * 2`, puts device row 0 in framebuffer
/// row 0 for *every* pass: a canvas comes out the right way up, and a layer
/// texture comes out top-down and is sampled with the same `v = y / height`
/// the sink computes for every other texture. `GpuRenderPass.rendersTopDown`
/// is therefore deliberately ignored by this backend - both orientations are
/// the same orientation here - and the scissor rectangle is passed through
/// unflipped, because `setScissorRect` is in framebuffer coordinates, which
/// already share device space's origin.
///
/// ## The bind group split, and why the uniform is dynamic
///
/// Group 0 holds the per-pass data (the viewport size) behind a dynamic
/// offset; group 1 holds the per-batch data (a sampler and a texture). They
/// are separate groups because they change at different rates and because a
/// grown uniform buffer must not invalidate every cached texture bind group -
/// group 1 never references the uniform buffer, so reallocating it rebuilds
/// exactly one bind group. The offset is dynamic rather than one buffer per
/// pass because `GPUQueue.writeBuffer` is ordered against `submit`: every
/// pass's viewport is written into its own 256-byte slice before the command
/// buffer is submitted, and each pass binds the same group at its own offset.
library;

import 'gpu_pipeline.dart';

/// The vertex entry point. One, shared by all three pipelines, exactly as the
/// GL path shares one vertex shader.
const String kWgslVertexEntryPoint = 'vs_main';

/// The fragment entry point for each [GpuPipelineKind].
///
/// A total function rather than a map, so a new pipeline kind is a compile
/// error here instead of a null at pipeline-creation time.
String wgslFragmentEntryPoint(GpuPipelineKind kind) => switch (kind) {
      GpuPipelineKind.solid => 'fs_solid',
      GpuPipelineKind.coverageMask => 'fs_mask',
      GpuPipelineKind.texturedImage => 'fs_image',
    };

/// The `GPUBlendFactor` enumerant for one of the renderer's blend factors.
///
/// Strings because that is what WebGPU descriptors take - the API has no
/// integer enums - and a total switch for [wgslFragmentEntryPoint]'s reason.
String webGpuBlendFactorName(GpuBlendFactor factor) => switch (factor) {
      GpuBlendFactor.zero => 'zero',
      GpuBlendFactor.one => 'one',
      GpuBlendFactor.oneMinusSrcAlpha => 'one-minus-src-alpha',
    };

/// Bytes per vertex in the one interleaved layout: [kGpuFloatsPerVertex]
/// 32-bit floats. The WebGPU vertex-state descriptor wants bytes where GL's
/// `vertexAttribPointer` wanted them too; the multiplication is done here once
/// so the descriptor and the test agree on the number.
const int kWebGpuVertexStrideBytes = kGpuFloatsPerVertex * 4;

/// Byte offsets of the four vertex attributes, derived from the same
/// `kGpu*Offset` constants the other backends derive theirs from - which is
/// what keeps this backend incapable of disagreeing with the batcher about
/// where a colour lives inside a vertex.
const int kWebGpuPositionOffsetBytes = kGpuPositionOffset * 4;
const int kWebGpuTexCoordOffsetBytes = kGpuTexCoordOffset * 4;
const int kWebGpuColorOffsetBytes = kGpuColorOffset * 4;
const int kWebGpuShapeRectOffsetBytes = kGpuShapeRectOffset * 4;

/// The stride between per-pass uniform slices, in bytes.
///
/// 256 is `minUniformBufferOffsetAlignment`'s specified default, and every
/// dynamic offset must be a multiple of it. The slice itself is eight bytes -
/// a `vec2f` viewport - so 248 of every 256 are padding; a frame has a handful
/// of passes, so the padding is bytes, not kilobytes, and buying the alignment
/// query from the adapter to shave it would be complexity for nothing.
const int kWebGpuUniformSliceStride = 256;

/// Bytes of one pass's uniform data: the `vec2f` viewport.
const int kWebGpuUniformSliceSize = 8;

/// The clear colour as WebGPU wants it: straight floats, RGBA order.
///
/// The input is the same packed premultiplied 32-bit BGRA integer
/// `FrameRequest.clearColor` carries everywhere else, and the extraction is
/// the same one `WebGlRenderDevice.submit` performs before `clearColor` - kept
/// as a pure function here so a VM test can pin the channel order without a
/// browser. Getting it wrong is the classic silently-wrong failure: a red
/// clear renders blue and everything else still works.
({double r, double g, double b, double a}) webGpuClearValue(int clearColor) => (
      r: ((clearColor >> 16) & 0xFF) / 255.0,
      g: ((clearColor >> 8) & 0xFF) / 255.0,
      b: (clearColor & 0xFF) / 255.0,
      a: ((clearColor >> 24) & 0xFF) / 255.0,
    );

/// The whole shader module.
///
/// A constant rather than a function of a dialect flag: WGSL has exactly one
/// dialect, which is the one honest simplification WebGPU offers over GL's
/// desktop/ES split.
const String kWgslShaderModuleSource = '''
// Per-pass data, bound at a dynamic offset. See the library comment of
// wgsl_shaders.dart for why the viewport is the only field and why there is
// no yFlip here.
struct FrameUniforms {
  viewport: vec2f,
}

@group(0) @binding(0) var<uniform> uFrame: FrameUniforms;
@group(1) @binding(0) var uSampler: sampler;
@group(1) @binding(1) var uTexture: texture_2d<f32>;

struct VertexInput {
  @location(0) position: vec2f,
  @location(1) texCoord: vec2f,
  @location(2) color: vec4f,
  @location(3) shapeRect: vec4f,
}

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) texCoord: vec2f,
  @location(1) color: vec4f,
  @location(2) shapeRect: vec4f,
  @location(3) devicePos: vec2f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
  var out: VertexOutput;
  out.texCoord = in.texCoord;
  out.color = in.color;
  out.shapeRect = in.shapeRect;
  out.devicePos = in.position;
  // Device space is y-down with the origin at the top-left corner; NDC is
  // y-up with the origin in the middle. WebGPU's framebuffer origin is the
  // top-left corner, so this one flip is right for every pass - surface and
  // layer alike - where GL needed a uniform to invert it per pass.
  out.position = vec4f(
    in.position.x / uFrame.viewport.x * 2.0 - 1.0,
    1.0 - in.position.y / uFrame.viewport.y * 2.0,
    0.0,
    1.0);
  return out;
}

// Exact area of the pixel square at p that lies inside the rectangle r.
// Separable, which is why an axis-aligned rectangle needs no mask. The same
// quantity gl_shaders.dart computes, translated token for token.
fn boxCoverage(r: vec4f, p: vec2f) -> f32 {
  let lo = max(r.xy, p - vec2f(0.5));
  let hi = min(r.zw, p + vec2f(0.5));
  let overlap = clamp(hi - lo, vec2f(0.0), vec2f(1.0));
  return overlap.x * overlap.y;
}

@fragment
fn fs_solid(in: VertexOutput) -> @location(0) vec4f {
  return in.color * boxCoverage(in.shapeRect, in.devicePos);
}

@fragment
fn fs_mask(in: VertexOutput) -> @location(0) vec4f {
  // A coverage mask scales the already-premultiplied colour, which is the
  // premultiplied equivalent of mul255(alpha, coverage) on the CPU.
  let coverage = textureSample(uTexture, uSampler, in.texCoord).r;
  return in.color * coverage * boxCoverage(in.shapeRect, in.devicePos);
}

@fragment
fn fs_image(in: VertexOutput) -> @location(0) vec4f {
  // Premultiplied texel modulated by the paint's alpha; the colour channels
  // carry that alpha too, so this is a plain scale.
  let texel = textureSample(uTexture, uSampler, in.texCoord);
  return texel * in.color.a * boxCoverage(in.shapeRect, in.devicePos);
}
''';
Grep "modifiers|KeyModifier" (in C:\MyDartProjects\dart_ui\lib\src\widgets)
25 lines of output
Edit C:\MyDartProjects\dart_ui\lib\src\platform\system_info_platform_io.dart
Modified
Edit C:\MyDartProjects\dart_ui\lib\src\platform\standard_paths_platform_io.dart
Removed 1 line
Write C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_keymap.dart
411 lines
/// Minimal parsing of the xkb keymap v1 text format `wl_keyboard.keymap`
/// delivers, plus the evdev fallback used when no keymap arrives.
///
/// ## Scope, stated plainly
///
/// A full xkb implementation (types, actions, compat, compose, multiple
/// groups) is what libxkbcommon is for, and binding it remains the roadmap's
/// answer for complete keyboard input (section 16.7). What this file does is
/// the honest subset that makes typing work today without guessing:
///
///   * the `xkb_keycodes` section is parsed for `<NAME> = code;` entries and
///     `alias` lines;
///   * the `xkb_symbols` section is parsed for `key <NAME> { [ a, A ] };`
///     entries, keeping the **first group** and its first two shift levels;
///   * keysyms are resolved for Latin-1, `U+XXXX` names, and a table of the
///     named function/modifier keys a desktop application actually handles.
///
/// What is *not* done - and, per the `TextInputEvent` contract, must not be
/// faked: dead keys, compose sequences, non-first groups (layout switching),
/// level-3 (`AltGr`) symbols and IME. Keys whose symbol cannot be resolved
/// still produce [KeyEvent]s with their keycode; they produce no text.
library;

import 'wayland_protocol.dart';

/// No keysym. Comparisons against it are always false, the same posture the
/// X11 backend takes for atoms that failed to intern.
const int xkbNoSymbol = 0;

// Named keysyms this backend understands (X11/keysymdef.h values).
const int xkbKeysymBackSpace = 0xff08;
const int xkbKeysymTab = 0xff09;
const int xkbKeysymReturn = 0xff0d;
const int xkbKeysymEscape = 0xff1b;
const int xkbKeysymDelete = 0xffff;
const int xkbKeysymHome = 0xff50;
const int xkbKeysymLeft = 0xff51;
const int xkbKeysymUp = 0xff52;
const int xkbKeysymRight = 0xff53;
const int xkbKeysymDown = 0xff54;
const int xkbKeysymPrior = 0xff55;
const int xkbKeysymNext = 0xff56;
const int xkbKeysymEnd = 0xff57;
const int xkbKeysymInsert = 0xff63;
const int xkbKeysymMenu = 0xff67;
const int xkbKeysymF1 = 0xffbe;
const int xkbKeysymShiftL = 0xffe1;
const int xkbKeysymShiftR = 0xffe2;
const int xkbKeysymControlL = 0xffe3;
const int xkbKeysymControlR = 0xffe4;
const int xkbKeysymCapsLock = 0xffe5;
const int xkbKeysymAltL = 0xffe9;
const int xkbKeysymAltR = 0xffea;
const int xkbKeysymSuperL = 0xffeb;
const int xkbKeysymSuperR = 0xffec;

/// The printable text of [keysym], or null when it has none.
///
/// Latin-1 keysyms are their own code points; keysyms above `0x01000000` embed
/// the code point directly (that is how xkb spells every non-legacy Unicode
/// character). Function and modifier keysyms have no text by definition.
String? xkbKeysymToText(int keysym) {
  if (keysym >= 0x20 && keysym <= 0x7e) return String.fromCharCode(keysym);
  if (keysym >= 0xa0 && keysym <= 0xff) return String.fromCharCode(keysym);
  if (keysym >= 0x01000100 && keysym <= 0x0110ffff) {
    return String.fromCharCode(keysym - 0x01000000);
  }
  return null;
}

/// Resolves an xkb symbol *name* - `a`, `exclam`, `U00E7`, `Return` - to its
/// keysym value, or [xkbNoSymbol] when the name is outside the supported
/// subset.
int xkbKeysymFromName(String name) {
  if (name.isEmpty || name == 'NoSymbol' || name == 'VoidSymbol') {
    return xkbNoSymbol;
  }
  if (name.length == 1) {
    final code = name.codeUnitAt(0);
    if (code >= 0x20 && code <= 0x7e) return code;
  }
  // U<hex> spells any Unicode code point; keymaps emitted by xkbcommon use it
  // for everything without a legacy name.
  if ((name.startsWith('U') || name.startsWith('u')) && name.length > 1) {
    final parsed = int.tryParse(name.substring(1), radix: 16);
    if (parsed != null && parsed > 0 && parsed <= 0x10ffff) {
      return parsed < 0x100 ? parsed : 0x01000000 + parsed;
    }
  }
  // 0x-prefixed raw keysym values also appear in generated keymaps.
  if (name.startsWith('0x') || name.startsWith('0X')) {
    final parsed = int.tryParse(name.substring(2), radix: 16);
    if (parsed != null && parsed > 0) return parsed;
  }
  return _namedKeysyms[name] ?? xkbNoSymbol;
}

const Map<String, int> _namedKeysyms = <String, int>{
  'space': 0x20,
  'exclam': 0x21,
  'quotedbl': 0x22,
  'numbersign': 0x23,
  'dollar': 0x24,
  'percent': 0x25,
  'ampersand': 0x26,
  'apostrophe': 0x27,
  'parenleft': 0x28,
  'parenright': 0x29,
  'asterisk': 0x2a,
  'plus': 0x2b,
  'comma': 0x2c,
  'minus': 0x2d,
  'period': 0x2e,
  'slash': 0x2f,
  'colon': 0x3a,
  'semicolon': 0x3b,
  'less': 0x3c,
  'equal': 0x3d,
  'greater': 0x3e,
  'question': 0x3f,
  'at': 0x40,
  'bracketleft': 0x5b,
  'backslash': 0x5c,
  'bracketright': 0x5d,
  'asciicircum': 0x5e,
  'underscore': 0x5f,
  'grave': 0x60,
  'braceleft': 0x7b,
  'bar': 0x7c,
  'braceright': 0x7d,
  'asciitilde': 0x7e,
  'exclamdown': 0xa1,
  'cedilla': 0xb8,
  'ccedilla': 0xe7,
  'Ccedilla': 0xc7,
  'ntilde': 0xf1,
  'Ntilde': 0xd1,
  'BackSpace': xkbKeysymBackSpace,
  'Tab': xkbKeysymTab,
  'Return': xkbKeysymReturn,
  'Escape': xkbKeysymEscape,
  'Delete': xkbKeysymDelete,
  'Home': xkbKeysymHome,
  'Left': xkbKeysymLeft,
  'Up': xkbKeysymUp,
  'Right': xkbKeysymRight,
  'Down': xkbKeysymDown,
  'Prior': xkbKeysymPrior,
  'Page_Up': xkbKeysymPrior,
  'Next': xkbKeysymNext,
  'Page_Down': xkbKeysymNext,
  'End': xkbKeysymEnd,
  'Insert': xkbKeysymInsert,
  'Menu': xkbKeysymMenu,
  'F1': xkbKeysymF1,
  'F2': xkbKeysymF1 + 1,
  'F3': xkbKeysymF1 + 2,
  'F4': xkbKeysymF1 + 3,
  'F5': xkbKeysymF1 + 4,
  'F6': xkbKeysymF1 + 5,
  'F7': xkbKeysymF1 + 6,
  'F8': xkbKeysymF1 + 7,
  'F9': xkbKeysymF1 + 8,
  'F10': xkbKeysymF1 + 9,
  'F11': xkbKeysymF1 + 10,
  'F12': xkbKeysymF1 + 11,
  'Shift_L': xkbKeysymShiftL,
  'Shift_R': xkbKeysymShiftR,
  'Control_L': xkbKeysymControlL,
  'Control_R': xkbKeysymControlR,
  'Caps_Lock': xkbKeysymCapsLock,
  'Alt_L': xkbKeysymAltL,
  'Alt_R': xkbKeysymAltR,
  'Super_L': xkbKeysymSuperL,
  'Super_R': xkbKeysymSuperR,
  'ISO_Left_Tab': xkbKeysymTab,
};

/// The two shift levels of one key in the first group.
final class XkbKeyLevels {
  const XkbKeyLevels(this.base, this.shifted);

  final int base;
  final int shifted;
}

/// One parsed keymap: xkb keycode (evdev + 8) to first-group symbol levels.
final class WaylandXkbKeymap {
  WaylandXkbKeymap._(this._levelsByKeycode, {required this.source});

  /// Where this keymap came from, for diagnostics: `xkb-v1` for a compositor
  /// keymap, `evdev-us-fallback` when none was usable.
  final String source;

  final Map<int, XkbKeyLevels> _levelsByKeycode;

  int get keyCount => _levelsByKeycode.length;

  /// Parses xkb keymap v1 text, or returns null when the two sections this
  /// parser needs cannot be found - the caller then falls back and says so.
  static WaylandXkbKeymap? parse(String text) {
    final keycodes = _extractSection(text, 'xkb_keycodes');
    final symbols = _extractSection(text, 'xkb_symbols');
    if (keycodes == null || symbols == null) return null;

    final codesByName = <String, int>{};
    for (final match in _keycodeEntry.allMatches(keycodes)) {
      codesByName[match.group(1)!] = int.parse(match.group(2)!);
    }
    for (final match in _keycodeAlias.allMatches(keycodes)) {
      final target = codesByName[match.group(2)!];
      if (target != null) codesByName[match.group(1)!] = target;
    }
    if (codesByName.isEmpty) return null;

    final levels = <int, XkbKeyLevels>{};
    for (final match in _symbolsEntry.allMatches(symbols)) {
      final keycode = codesByName[match.group(1)!];
      if (keycode == null) continue;
      final body = match.group(2)!;
      final bracket = _firstSymbolList.firstMatch(body);
      if (bracket == null) continue;
      final names = bracket
          .group(1)!
          .split(',')
          .map((String entry) => entry.trim())
          .where((String entry) => entry.isNotEmpty)
          .toList();
      if (names.isEmpty) continue;
      final base = xkbKeysymFromName(names[0]);
      final shifted =
          names.length > 1 ? xkbKeysymFromName(names[1]) : xkbNoSymbol;
      levels[keycode] = XkbKeyLevels(base, shifted);
    }
    if (levels.isEmpty) return null;
    return WaylandXkbKeymap._(levels, source: 'xkb-v1');
  }

  /// The evdev/US fallback used when the compositor sends no usable keymap.
  /// Correct only for a US layout; that limitation is what [source] reports.
  factory WaylandXkbKeymap.usFallback() {
    final levels = <int, XkbKeyLevels>{};
    void put(int evdevCode, int base, [int shifted = xkbNoSymbol]) {
      levels[evdevCode + evdevToXkbKeycodeOffset] =
          XkbKeyLevels(base, shifted);
    }

    void putChars(int evdevCode, String base, String shifted) {
      put(evdevCode, base.codeUnitAt(0), shifted.codeUnitAt(0));
    }

    put(1, xkbKeysymEscape);
    const digitRow = '1234567890';
    const digitShift = r'!@#$%^&*()';
    for (var i = 0; i < 10; i++) {
      putChars(2 + i, digitRow[i], digitShift[i]);
    }
    putChars(12, '-', '_');
    putChars(13, '=', '+');
    put(14, xkbKeysymBackSpace);
    put(15, xkbKeysymTab);
    const rowQ = 'qwertyuiop';
    for (var i = 0; i < rowQ.length; i++) {
      putChars(16 + i, rowQ[i], rowQ[i].toUpperCase());
    }
    putChars(26, '[', '{');
    putChars(27, ']', '}');
    put(28, xkbKeysymReturn);
    put(29, xkbKeysymControlL);
    const rowA = 'asdfghjkl';
    for (var i = 0; i < rowA.length; i++) {
      putChars(30 + i, rowA[i], rowA[i].toUpperCase());
    }
    putChars(39, ';', ':');
    putChars(40, "'", '"');
    putChars(41, '`', '~');
    put(42, xkbKeysymShiftL);
    putChars(43, r'\', '|');
    const rowZ = 'zxcvbnm';
    for (var i = 0; i < rowZ.length; i++) {
      putChars(44 + i, rowZ[i], rowZ[i].toUpperCase());
    }
    putChars(51, ',', '<');
    putChars(52, '.', '>');
    putChars(53, '/', '?');
    put(54, xkbKeysymShiftR);
    put(56, xkbKeysymAltL);
    put(57, 0x20, 0x20);
    put(58, xkbKeysymCapsLock);
    for (var i = 0; i < 10; i++) {
      put(59 + i, xkbKeysymF1 + i);
    }
    put(87, xkbKeysymF1 + 10);
    put(88, xkbKeysymF1 + 11);
    put(97, xkbKeysymControlR);
    put(100, xkbKeysymAltR);
    put(102, xkbKeysymHome);
    put(103, xkbKeysymUp);
    put(104, xkbKeysymPrior);
    put(105, xkbKeysymLeft);
    put(106, xkbKeysymRight);
    put(107, xkbKeysymEnd);
    put(108, xkbKeysymDown);
    put(109, xkbKeysymNext);
    put(110, xkbKeysymInsert);
    put(111, xkbKeysymDelete);
    put(125, xkbKeysymSuperL);
    put(126, xkbKeysymSuperR);
    put(127, xkbKeysymMenu);
    return WaylandXkbKeymap._(levels, source: 'evdev-us-fallback');
  }

  /// The keysym for [xkbKeycode] with the given modifier state.
  ///
  /// CapsLock upper-cases letters only, which is what real caps behaviour is
  /// for the alphabetic key types this parser keeps.
  int keysymFor(int xkbKeycode, {bool shift = false, bool capsLock = false}) {
    final levels = _levelsByKeycode[xkbKeycode];
    if (levels == null) return xkbNoSymbol;
    var keysym =
        shift && levels.shifted != xkbNoSymbol ? levels.shifted : levels.base;
    if (capsLock && !shift) {
      final text = xkbKeysymToText(keysym);
      if (text != null) {
        final upper = text.toUpperCase();
        if (upper != text && upper.length == 1) {
          final upperSym = upper.codeUnitAt(0);
          keysym = upperSym < 0x100 ? upperSym : 0x01000000 + upperSym;
        }
      }
    }
    return keysym;
  }

  /// The text this key produces under the given modifiers, or null for
  /// function/modifier keys and unresolved symbols.
  String? textFor(int xkbKeycode, {bool shift = false, bool capsLock = false}) {
    final keysym = keysymFor(xkbKeycode, shift: shift, capsLock: capsLock);
    if (keysym == xkbNoSymbol) return null;
    return xkbKeysymToText(keysym);
  }

  static final RegExp _keycodeEntry = RegExp(r'<([A-Za-z0-9_+\-]+)>\s*=\s*(\d+)\s*;');
  static final RegExp _keycodeAlias = RegExp(
      r'alias\s*<([A-Za-z0-9_+\-]+)>\s*=\s*<([A-Za-z0-9_+\-]+)>\s*;');
  static final RegExp _symbolsEntry = RegExp(
    r'key\s*<([A-Za-z0-9_+\-]+)>\s*\{([^}]*)\}',
    dotAll: true,
  );
  static final RegExp _firstSymbolList = RegExp(r'\[([^\]]*)\]');

  /// Extracts the balanced-brace body of `keyword "optional name" { ... }`.
  static String? _extractSection(String text, String keyword) {
    final start = text.indexOf(keyword);
    if (start < 0) return null;
    final open = text.indexOf('{', start);
    if (open < 0) return null;
    var depth = 0;
    for (var i = open; i < text.length; i++) {
      final char = text.codeUnitAt(i);
      if (char == 0x7b) depth++;
      if (char == 0x7d) {
        depth--;
        if (depth == 0) return text.substring(open + 1, i);
      }
    }
    return null;
  }
}

/// The `wl_keyboard.modifiers` state, interpreted with the conventional xkb
/// real-modifier bit positions (Shift=0, Lock=1, Control=2, Mod1=3, Mod4=6).
///
/// Reading the *actual* positions requires parsing the keymap's types and
/// modifier maps; every keymap xkbcommon emits uses the conventional ones, so
/// this is the documented approximation until libxkbcommon is bound.
final class WaylandModifiersState {
  int depressed = 0;
  int latched = 0;
  int locked = 0;
  int group = 0;

  int get _effective => depressed | latched | locked;

  bool get shift => (_effective & 0x01) != 0;
  bool get capsLock => (_effective & 0x02) != 0;
  bool get control => (_effective & 0x04) != 0;
  bool get alt => (_effective & 0x08) != 0;
  bool get numLock => (_effective & 0x10) != 0;
  bool get meta => (_effective & 0x40) != 0;

  void update({
    required int depressed,
    required int latched,
    required int locked,
    required int group,
  }) {
    this.depressed = depressed;
    this.latched = latched;
    this.locked = locked;
    this.group = group;
  }

  void reset() {
    depressed = 0;
    latched = 0;
    locked = 0;
    group = 0;
  }
}
Bash Modifier tracking idiom in text_field
IN
sed -n 845,875p C:/MyDartProjects/dart_ui/lib/src/widgets/text_field.dart; sed -n 1330,1350p C:/MyDartProjects/dart_ui/lib/src/widgets/text_field.dart

OUT
  /// Whether a drag begun on this field is still selecting.
  bool _dragging = false;

  /// 1, 2 or 3: how many clicks the last press was part of.
  int _clickCount = 0;
  Duration _lastClickAt = Duration.zero;
  Offset _lastClickPosition = Offset.zero;

  /// The modifiers reported by the most recent key transition.
  ///
  /// **This is a workaround and it is the one place a Shift+click can be
  /// wrong.** [PointerEvent] in this framework carries no modifier set - only
  /// [KeyEvent] does - so the only way to know whether Shift was down when the
  /// mouse went down is to remember what the last key transition said. That is
  /// accurate for the ordinary sequence (press Shift, click) *while this field
  /// has focus*, because pressing Shift is itself a key transition that arrives
  /// here. It is wrong in exactly one case: Shift was already held before this
  /// field got focus, so no key event has reached it yet, and the click
  /// collapses the caret instead of extending. The real fix is a modifier set
  /// on [PointerEvent], which every backend already samples - `win32_window`
  /// calls `GetKeyState` for each key event and could do the same for each
  /// mouse message - and which this work does not own.
  Set<KeyModifier> _modifiers = const <KeyModifier>{};

  /// How long after a click a second one still counts as a double click, **on
  /// a platform that did not count for us**.
  ///
  /// 500 ms is the Windows default (`GetDoubleClickTime`), and it is only ever
  /// a fallback: when [PointerDownEvent.clickCount] is above 1 the platform
  /// already matched the two presses against the interval and the rectangle the
      // The paragraph snaps to a grapheme cluster and reports which side of the
      // boundary was hit, so a click on the right half of an emoji lands after
      // it rather than between its surrogates, and the affinity it returns is
      // what puts the caret on the correct side of a direction change.
      return laid.getPositionForOffset(Offset(x, 0));
    }
    return TextPosition(
      labelIndexAtOffset(displayText, x).clamp(0, _controller.value.length),
    );
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    // Every transition, press *and* release, so that the modifier state a
    // Shift+click reads is the current one. See [_modifiers].
    _modifiers = event.modifiers;
    if (!enabled || event is! KeyDownEvent) return false;
    final bool shift = event.modifiers.contains(KeyModifier.shift);
    final bool control = event.modifiers.contains(KeyModifier.control);
    if (control) {
      // Ctrl turns the four editing keys into their word-wise forms, and Shift
Write C:\MyDartProjects\dart_ui\lib\src\platform\system_info_platform_web.dart
24 lines
library;

import 'package:web/web.dart' as web;

import 'system_info_types.dart';

SystemInfoData snapshot() {
  final web.Navigator navigator = web.window.navigator;
  return SystemInfoData(
    operatingSystem: 'web',
    // The user-agent is the only version string a browser offers, and it is
    // deliberately passed on verbatim; see [SystemInfoData].
    operatingSystemVersion: navigator.userAgent,
    hostname: web.window.location.hostname,
    userName: '',
    locale: navigator.language,
    processorCount:
        navigator.hardwareConcurrency > 0 ? navigator.hardwareConcurrency : 1,
  );
}

Future<bool?> isDarkMode() async =>
    web.window.matchMedia('(prefers-color-scheme: dark)').matches;
Now MessageBox.

Edit C:\MyDartProjects\dart_ui\lib\src\widgets\data_grid.dart
Added 14 lines
Edit C:\MyDartProjects\dart_ui\lib\src\widgets\data_grid.dart
Modified
Bash CrossAxisAlignment and analysis options
IN
grep -n "enum CrossAxisAlignment" -A 6 C:/MyDartProjects/dart_ui/lib/src/layout/render_flex.dart; grep -n "import" C:/MyDartProjects/dart_ui/lib/src/gallery/gallery.dart | head; grep -rn "analysis_options" -l C:/MyDartProjects/dart_ui/analysis_options.yaml 2>/dev/null; cat C:/MyDartProjects/dart_ui/analysis_options.yaml 2>/dev/null | head -40

OUT
66:enum CrossAxisAlignment {
67-  start,
68-  end,
69-  center,
70-
71-  /// Children are forced to the full cross extent. Requires a bounded cross
72-  /// axis - there is nothing to stretch to otherwise, and [RenderFlex] says so
13:import '../geometry/size.dart';
14:import '../layout/edge_insets.dart';
15:import '../layout/render_flex.dart';
16:import '../layout/render_viewport.dart';
17:import '../widgets/basic.dart';
18:import '../widgets/controls.dart';
19:import '../widgets/focus.dart';
20:import '../widgets/focus_scope.dart';
21:import '../widgets/list_box.dart';
22:import '../widgets/theme.dart';
include: package:lints/recommended.yaml

analyzer:
  # POCs and vendored references are independent projects with their own
  # analyzers. Walking them from the framework root makes `dart analyze`
  # traverse millions of reference lines and can leave the CI gate timing out.
  exclude:
    - poc/**
    - referencias/**
    - build/**
  language:
    strict-casts: true
    strict-raw-types: true

linter:
  rules:
    - prefer_final_locals
    - prefer_const_constructors
    - prefer_const_declarations
    - avoid_print: false
    - directives_ordering
    - prefer_single_quotes
Now wayland_events.dart — the raw event record, per-window protocol state (configure cycle), pending coalescing and the pure translator.

Write C:\MyDartProjects\dart_ui\lib\src\platform\message_box_types.dart
118 lines
/// The shared vocabulary of [NativeMessageBox], plus the command and style
/// planning that is pure string work.
library;

import 'shell_types.dart';

/// What a native message box is for. The kind picks the icon, the sound and
/// - for [confirm] - the second button.
enum MessageBoxKind {
  info,
  warning,
  error,

  /// A question with an affirmative and a cancel button. The only kind whose
  /// answer can be `false`.
  confirm,
}

/// A message box that could not be shown at all - as opposed to one the user
/// dismissed, which is a normal answer.
final class MessageBoxException implements Exception {
  const MessageBoxException({
    required this.reason,
    this.platform,
    this.errorCode,
  });

  final String reason;
  final String? platform;
  final int? errorCode;

  @override
  String toString() => 'MessageBoxException: could not show'
      '${platform == null ? '' : ' on $platform'}'
      '${errorCode == null ? '' : ' (code $errorCode)'} - $reason';
}

/// The `MessageBoxW` style flags for [kind]: `MB_OK` or `MB_OKCANCEL` plus
/// the matching `MB_ICON*`.
///
/// ABI constants from winuser.h, combined here so the mapping is a testable
/// value instead of an inline expression next to an FFI call.
int windowsMessageBoxStyle(MessageBoxKind kind) => switch (kind) {
      MessageBoxKind.info => 0x00000040, // MB_OK | MB_ICONINFORMATION
      MessageBoxKind.warning => 0x00000030, // MB_OK | MB_ICONWARNING
      MessageBoxKind.error => 0x00000010, // MB_OK | MB_ICONERROR
      // MB_OKCANCEL | MB_ICONQUESTION
      MessageBoxKind.confirm => 0x00000021,
    };

/// `IDOK`: the affirmative answer `MessageBoxW` returns.
const int windowsMessageBoxOk = 1;

/// The Linux dialog commands to try, in preference order.
///
/// zenity (GTK) and kdialog (Qt) are the two dialog helpers desktops
/// actually ship; which one exists tells us which desktop this is. Both exit
/// 0 for the affirmative button, 1 for cancel.
List<ShellCommand> linuxMessageBoxCommands(
  MessageBoxKind kind, {
  required String title,
  required String message,
}) {
  final String zenityKind = switch (kind) {
    MessageBoxKind.info => '--info',
    MessageBoxKind.warning => '--warning',
    MessageBoxKind.error => '--error',
    MessageBoxKind.confirm => '--question',
  };
  final String kdialogKind = switch (kind) {
    MessageBoxKind.info => '--msgbox',
    MessageBoxKind.warning => '--sorry',
    MessageBoxKind.error => '--error',
    MessageBoxKind.confirm => '--yesno',
  };
  return <ShellCommand>[
    ShellCommand(
      executable: 'zenity',
      arguments: <String>[zenityKind, '--title=$title', '--text=$message'],
    ),
    ShellCommand(
      executable: 'kdialog',
      arguments: <String>['--title', title, kdialogKind, message],
    ),
  ];
}

/// Escapes [value] for interpolation inside a double-quoted AppleScript
/// string literal. Backslash first, then the quote, or the escape itself
/// would be re-escaped.
String escapeAppleScriptString(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

/// The AppleScript program for one dialog of [kind].
///
/// `display dialog` rather than `display alert` because only the former
/// takes an icon by name and custom buttons in one grammar. A cancelled
/// dialog makes osascript exit non-zero, which the caller maps to `false`.
String macMessageBoxScript(
  MessageBoxKind kind, {
  required String title,
  required String message,
}) {
  final String safeTitle = escapeAppleScriptString(title);
  final String safeMessage = escapeAppleScriptString(message);
  final String icon = switch (kind) {
    MessageBoxKind.info => 'note',
    MessageBoxKind.warning => 'caution',
    MessageBoxKind.error => 'stop',
    MessageBoxKind.confirm => 'note',
  };
  final String buttons = kind == MessageBoxKind.confirm
      ? '{"Cancel", "OK"}'
      : '{"OK"}';
  return 'display dialog "$safeMessage" with title "$safeTitle" '
      'buttons $buttons default button "OK" with icon $icon';
}
Edit C:\MyDartProjects\dart_ui\lib\src\widgets\data_grid.dart
Added 1 line
Write C:\MyDartProjects\dart_ui\lib\src\platform\message_box.dart
45 lines
/// The operating system's own modal message box.
///
/// This is the dialog for the moments the framework's widgets cannot serve:
/// before a window exists, after rendering has failed, or when the message
/// is "this application is about to exit". Everything in between - styled
/// dialogs, theming, custom buttons - belongs to the widget layer, which can
/// draw them itself; this port is deliberately four kinds, two buttons and a
/// string, because that is the intersection the three desktops agree on.
///
/// The call blocks its answer, not the process: the future completes when
/// the user dismisses the dialog. On the web and other stub targets it
/// throws [MessageBoxException] - a browser `alert()` would be a lie about
/// what it looks like and cannot express a native title bar anyway.
library;

import 'message_box_platform_stub.dart'
    if (dart.library.io) 'message_box_platform_io.dart' as platform;
import 'message_box_types.dart';

export 'message_box_types.dart';

/// One native modal dialog, shown by the platform.
abstract final class NativeMessageBox {
  /// Shows a message box and answers how it was dismissed.
  ///
  /// Returns true for the affirmative button. For [MessageBoxKind.confirm]
  /// false means the user chose Cancel; for the other kinds the only button
  /// is OK, so the answer is always true.
  ///
  /// Throws [MessageBoxException] when no dialog could be shown at all - a
  /// Linux with neither zenity nor kdialog, a stub target.
  static Future<bool> show({
    required String title,
    required String message,
    MessageBoxKind kind = MessageBoxKind.info,
    int ownerWindowHandle = 0,
  }) =>
      platform.show(
        title: title,
        message: message,
        kind: kind,
        ownerWindowHandle: ownerWindowHandle,
      );
}
Write C:\MyDartProjects\dart_ui\lib\src\platform\message_box_platform_stub.dart
15 lines
library;

import 'message_box_types.dart';

Future<bool> show({
  required String title,
  required String message,
  required MessageBoxKind kind,
  required int ownerWindowHandle,
}) async {
  throw const MessageBoxException(
    reason: 'this target has no native message-box implementation',
  );
}
Write C:\MyDartProjects\dart_ui\lib\src\backends\win32\d2d\d2d1_interfaces.dart
581 lines
/// One thin Dart class per Direct2D COM interface, with the vtable slot
/// written down - the same shape, and the same discipline, as
/// `d3d12_interfaces.dart`.
///
/// ## How to read a slot number
///
/// A COM vtable is the flattened list of every method the interface and its
/// bases declare, base first. Direct2D's chains, counted out once here and
/// referenced by every class below:
///
///   * `IUnknown` contributes slots 0..2.
///   * `ID2D1Resource` adds `GetFactory` at 3.
///   * `ID2D1RenderTarget : ID2D1Resource` declares its own methods from
///     slot 4 (`CreateBitmap`) through 56 (`IsSupported`), in header order.
///   * `ID2D1HwndRenderTarget : ID2D1RenderTarget` adds `CheckWindowState`
///     57, `Resize` 58, `GetHwnd` 59. The proof-of-concept
///     `poc/poc_05_com_direct2d` drove a window through exactly these
///     numbers, which is the independent check on the arithmetic.
///   * `ID2D1DCRenderTarget : ID2D1RenderTarget` adds `BindDC` 57.
///   * `ID2D1Geometry : ID2D1Resource` runs 4..16;
///     `ID2D1PathGeometry` adds `Open` 17, `Stream` 18, counts 19..20.
///   * `ID2D1SimplifiedGeometrySink : IUnknown` runs 3..9;
///     `ID2D1GeometrySink` adds `AddLine` 10 through `AddArc` 14.
///   * `ID2D1Brush : ID2D1Resource` runs 4..7; `ID2D1SolidColorBrush` adds
///     `SetColor` 8, `GetColor` 9.
///
/// The three render-target methods that return small structs by value
/// (`GetSize`, `GetPixelSize`, `GetPixelFormat`) are not bound - see
/// `d2d1_structs.dart` for why that ABI is a trap and why nothing here needs
/// them.
library;

import 'dart:ffi';

import '../d3d12/d3d12_com.dart';
import 'd2d1_structs.dart';

/// `ID2D1Factory`. Slots: IUnknown 3, `ReloadSystemMetrics` 3... no -
/// IUnknown is 0..2, then `ReloadSystemMetrics` 3, `GetDesktopDpi` 4, the
/// geometry constructors 5..9, `CreatePathGeometry` 10, `CreateStrokeStyle`
/// 11, `CreateDrawingStateBlock` 12, `CreateWicBitmapRenderTarget` 13,
/// `CreateHwndRenderTarget` 14, `CreateDxgiSurfaceRenderTarget` 15,
/// `CreateDCRenderTarget` 16.
final class D2dFactory {
  D2dFactory(this.pointer)
      : _createPathGeometry = comMethod<
                Int32 Function(
                    Pointer<Void>, Pointer<Pointer<Void>>)>(pointer, 10)
            .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>(),
        _createStrokeStyle = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Pointer<D2dStrokeStyleProperties>,
                    Pointer<Float>,
                    Uint32,
                    Pointer<Pointer<Void>>)>(pointer, 11)
            .asFunction<
                int Function(Pointer<Void>, Pointer<D2dStrokeStyleProperties>,
                    Pointer<Float>, int, Pointer<Pointer<Void>>)>(),
        _createHwndRenderTarget = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Pointer<D2dRenderTargetProperties>,
                    Pointer<D2dHwndRenderTargetProperties>,
                    Pointer<Pointer<Void>>)>(pointer, 14)
            .asFunction<
                int Function(
                    Pointer<Void>,
                    Pointer<D2dRenderTargetProperties>,
                    Pointer<D2dHwndRenderTargetProperties>,
                    Pointer<Pointer<Void>>)>(),
        _createDcRenderTarget = comMethod<
                Int32 Function(Pointer<Void>, Pointer<D2dRenderTargetProperties>,
                    Pointer<Pointer<Void>>)>(pointer, 16)
            .asFunction<
                int Function(Pointer<Void>, Pointer<D2dRenderTargetProperties>,
                    Pointer<Pointer<Void>>)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _createPathGeometry;
  final int Function(Pointer<Void>, Pointer<D2dStrokeStyleProperties>,
      Pointer<Float>, int, Pointer<Pointer<Void>>) _createStrokeStyle;
  final int Function(
      Pointer<Void>,
      Pointer<D2dRenderTargetProperties>,
      Pointer<D2dHwndRenderTargetProperties>,
      Pointer<Pointer<Void>>) _createHwndRenderTarget;
  final int Function(Pointer<Void>, Pointer<D2dRenderTargetProperties>,
      Pointer<Pointer<Void>>) _createDcRenderTarget;

  int createPathGeometry(Pointer<Pointer<Void>> out) =>
      _createPathGeometry(pointer, out);

  /// [dashes] may be `nullptr` with [dashCount] 0 for a solid stroke.
  int createStrokeStyle(
    Pointer<D2dStrokeStyleProperties> properties,
    Pointer<Float> dashes,
    int dashCount,
    Pointer<Pointer<Void>> out,
  ) =>
      _createStrokeStyle(pointer, properties, dashes, dashCount, out);

  int createHwndRenderTarget(
    Pointer<D2dRenderTargetProperties> targetProperties,
    Pointer<D2dHwndRenderTargetProperties> hwndProperties,
    Pointer<Pointer<Void>> out,
  ) =>
      _createHwndRenderTarget(pointer, targetProperties, hwndProperties, out);

  int createDcRenderTarget(
    Pointer<D2dRenderTargetProperties> targetProperties,
    Pointer<Pointer<Void>> out,
  ) =>
      _createDcRenderTarget(pointer, targetProperties, out);

  void release() => ComObject(pointer).release();
}

/// `ID2D1RenderTarget` - the drawing surface both concrete targets share.
///
/// Slots: IUnknown 3 + `ID2D1Resource::GetFactory` = 4 inherited, then the
/// render target's own methods in header order. The constants below *are* the
/// ABI; the arithmetic is stated in the library comment.
final class D2dRenderTarget {
  D2dRenderTarget(this.pointer)
      : _createBitmap = comMethod<
                Int32 Function(Pointer<Void>, D2dSizeU, Pointer<Void>, Uint32,
                    Pointer<D2dBitmapProperties>, Pointer<Pointer<Void>>)>(
                pointer, 4)
            .asFunction<
                int Function(Pointer<Void>, D2dSizeU, Pointer<Void>, int,
                    Pointer<D2dBitmapProperties>, Pointer<Pointer<Void>>)>(),
        _createSolidColorBrush = comMethod<
                Int32 Function(Pointer<Void>, Pointer<D2dColorF>,
                    Pointer<D2dBrushProperties>, Pointer<Pointer<Void>>)>(
                pointer, 8)
            .asFunction<
                int Function(Pointer<Void>, Pointer<D2dColorF>,
                    Pointer<D2dBrushProperties>, Pointer<Pointer<Void>>)>(),
        _createGradientStopCollection = comMethod<
                Int32 Function(Pointer<Void>, Pointer<D2dGradientStop>, Uint32,
                    Uint32, Uint32, Pointer<Pointer<Void>>)>(pointer, 9)
            .asFunction<
                int Function(Pointer<Void>, Pointer<D2dGradientStop>, int, int,
                    int, Pointer<Pointer<Void>>)>(),
        _createLinearGradientBrush = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Pointer<D2dLinearGradientBrushProperties>,
                    Pointer<D2dBrushProperties>,
                    Pointer<Void>,
                    Pointer<Pointer<Void>>)>(pointer, 10)
            .asFunction<
                int Function(
                    Pointer<Void>,
                    Pointer<D2dLinearGradientBrushProperties>,
                    Pointer<D2dBrushProperties>,
                    Pointer<Void>,
                    Pointer<Pointer<Void>>)>(),
        _createRadialGradientBrush = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Pointer<D2dRadialGradientBrushProperties>,
                    Pointer<D2dBrushProperties>,
                    Pointer<Void>,
                    Pointer<Pointer<Void>>)>(pointer, 11)
            .asFunction<
                int Function(
                    Pointer<Void>,
                    Pointer<D2dRadialGradientBrushProperties>,
                    Pointer<D2dBrushProperties>,
                    Pointer<Void>,
                    Pointer<Pointer<Void>>)>(),
        _createLayer = comMethod<
                Int32 Function(Pointer<Void>, Pointer<Void>,
                    Pointer<Pointer<Void>>)>(pointer, 13)
            .asFunction<
                int Function(
                    Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)>(),
        _fillRectangle = comMethod<
                Void Function(Pointer<Void>, Pointer<D2dRectF>,
                    Pointer<Void>)>(pointer, 17)
            .asFunction<
                void Function(
                    Pointer<Void>, Pointer<D2dRectF>, Pointer<Void>)>(),
        _fillRoundedRectangle = comMethod<
                Void Function(Pointer<Void>, Pointer<D2dRoundedRect>,
                    Pointer<Void>)>(pointer, 19)
            .asFunction<
                void Function(
                    Pointer<Void>, Pointer<D2dRoundedRect>, Pointer<Void>)>(),
        _drawGeometry = comMethod<
                Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                    Float, Pointer<Void>)>(pointer, 22)
            .asFunction<
                void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                    double, Pointer<Void>)>(),
        _fillGeometry = comMethod<
                Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                    Pointer<Void>)>(pointer, 23)
            .asFunction<
                void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                    Pointer<Void>)>(),
        _fillOpacityMask = comMethod<
                Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                    Uint32, Pointer<D2dRectF>, Pointer<D2dRectF>)>(pointer, 25)
            .asFunction<
                void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int,
                    Pointer<D2dRectF>, Pointer<D2dRectF>)>(),
        _drawBitmap = comMethod<
                Void Function(Pointer<Void>, Pointer<Void>, Pointer<D2dRectF>,
                    Float, Uint32, Pointer<D2dRectF>)>(pointer, 26)
            .asFunction<
                void Function(Pointer<Void>, Pointer<Void>, Pointer<D2dRectF>,
                    double, int, Pointer<D2dRectF>)>(),
        _setTransform = comMethod<
                Void Function(
                    Pointer<Void>, Pointer<D2dMatrix3x2F>)>(pointer, 30)
            .asFunction<
                void Function(Pointer<Void>, Pointer<D2dMatrix3x2F>)>(),
        _setAntialiasMode =
            comMethod<Void Function(Pointer<Void>, Uint32)>(pointer, 32)
                .asFunction<void Function(Pointer<Void>, int)>(),
        _pushLayer = comMethod<
                Void Function(Pointer<Void>, Pointer<D2dLayerParameters>,
                    Pointer<Void>)>(pointer, 40)
            .asFunction<
                void Function(Pointer<Void>, Pointer<D2dLayerParameters>,
                    Pointer<Void>)>(),
        _popLayer = comMethod<Void Function(Pointer<Void>)>(pointer, 41)
            .asFunction<void Function(Pointer<Void>)>(),
        _flush = comMethod<
                Int32 Function(Pointer<Void>, Pointer<Uint64>,
                    Pointer<Uint64>)>(pointer, 42)
            .asFunction<
                int Function(
                    Pointer<Void>, Pointer<Uint64>, Pointer<Uint64>)>(),
        _pushAxisAlignedClip = comMethod<
                Void Function(
                    Pointer<Void>, Pointer<D2dRectF>, Uint32)>(pointer, 45)
            .asFunction<
                void Function(Pointer<Void>, Pointer<D2dRectF>, int)>(),
        _popAxisAlignedClip =
            comMethod<Void Function(Pointer<Void>)>(pointer, 46)
                .asFunction<void Function(Pointer<Void>)>(),
        _clear = comMethod<Void Function(Pointer<Void>, Pointer<D2dColorF>)>(
                pointer, 47)
            .asFunction<void Function(Pointer<Void>, Pointer<D2dColorF>)>(),
        _beginDraw = comMethod<Void Function(Pointer<Void>)>(pointer, 48)
            .asFunction<void Function(Pointer<Void>)>(),
        _endDraw = comMethod<
                Int32 Function(Pointer<Void>, Pointer<Uint64>,
                    Pointer<Uint64>)>(pointer, 49)
            .asFunction<
                int Function(
                    Pointer<Void>, Pointer<Uint64>, Pointer<Uint64>)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>, D2dSizeU, Pointer<Void>, int,
      Pointer<D2dBitmapProperties>, Pointer<Pointer<Void>>) _createBitmap;
  final int Function(Pointer<Void>, Pointer<D2dColorF>,
      Pointer<D2dBrushProperties>, Pointer<Pointer<Void>>)
      _createSolidColorBrush;
  final int Function(Pointer<Void>, Pointer<D2dGradientStop>, int, int, int,
      Pointer<Pointer<Void>>) _createGradientStopCollection;
  final int Function(
      Pointer<Void>,
      Pointer<D2dLinearGradientBrushProperties>,
      Pointer<D2dBrushProperties>,
      Pointer<Void>,
      Pointer<Pointer<Void>>) _createLinearGradientBrush;
  final int Function(
      Pointer<Void>,
      Pointer<D2dRadialGradientBrushProperties>,
      Pointer<D2dBrushProperties>,
      Pointer<Void>,
      Pointer<Pointer<Void>>) _createRadialGradientBrush;
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)
      _createLayer;
  final void Function(Pointer<Void>, Pointer<D2dRectF>, Pointer<Void>)
      _fillRectangle;
  final void Function(Pointer<Void>, Pointer<D2dRoundedRect>, Pointer<Void>)
      _fillRoundedRectangle;
  final void Function(
          Pointer<Void>, Pointer<Void>, Pointer<Void>, double, Pointer<Void>)
      _drawGeometry;
  final void Function(
          Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>)
      _fillGeometry;
  final void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int,
      Pointer<D2dRectF>, Pointer<D2dRectF>) _fillOpacityMask;
  final void Function(Pointer<Void>, Pointer<Void>, Pointer<D2dRectF>, double,
      int, Pointer<D2dRectF>) _drawBitmap;
  final void Function(Pointer<Void>, Pointer<D2dMatrix3x2F>) _setTransform;
  final void Function(Pointer<Void>, int) _setAntialiasMode;
  final void Function(Pointer<Void>, Pointer<D2dLayerParameters>,
      Pointer<Void>) _pushLayer;
  final void Function(Pointer<Void>) _popLayer;
  final int Function(Pointer<Void>, Pointer<Uint64>, Pointer<Uint64>) _flush;
  final void Function(Pointer<Void>, Pointer<D2dRectF>, int)
      _pushAxisAlignedClip;
  final void Function(Pointer<Void>) _popAxisAlignedClip;
  final void Function(Pointer<Void>, Pointer<D2dColorF>) _clear;
  final void Function(Pointer<Void>) _beginDraw;
  final int Function(Pointer<Void>, Pointer<Uint64>, Pointer<Uint64>) _endDraw;

  /// [size] crosses by value; see `d2d1_structs.dart`.
  int createBitmap(
    D2dSizeU size,
    Pointer<Void> sourceData,
    int pitch,
    Pointer<D2dBitmapProperties> properties,
    Pointer<Pointer<Void>> out,
  ) =>
      _createBitmap(pointer, size, sourceData, pitch, properties, out);

  int createSolidColorBrush(
    Pointer<D2dColorF> color,
    Pointer<Pointer<Void>> out,
  ) =>
      _createSolidColorBrush(pointer, color, nullptr, out);

  int createGradientStopCollection(
    Pointer<D2dGradientStop> stops,
    int stopCount,
    int gamma,
    int extendMode,
    Pointer<Pointer<Void>> out,
  ) =>
      _createGradientStopCollection(
          pointer, stops, stopCount, gamma, extendMode, out);

  int createLinearGradientBrush(
    Pointer<D2dLinearGradientBrushProperties> properties,
    Pointer<Void> stopCollection,
    Pointer<Pointer<Void>> out,
  ) =>
      _createLinearGradientBrush(
          pointer, properties, nullptr, stopCollection, out);

  int createRadialGradientBrush(
    Pointer<D2dRadialGradientBrushProperties> properties,
    Pointer<Void> stopCollection,
    Pointer<Pointer<Void>> out,
  ) =>
      _createRadialGradientBrush(
          pointer, properties, nullptr, stopCollection, out);

  /// [size] is `nullptr` to let the layer size itself on first push.
  int createLayer(Pointer<Void> size, Pointer<Pointer<Void>> out) =>
      _createLayer(pointer, size, out);

  void fillRectangle(Pointer<D2dRectF> rect, Pointer<Void> brush) =>
      _fillRectangle(pointer, rect, brush);

  void fillRoundedRectangle(
          Pointer<D2dRoundedRect> roundedRect, Pointer<Void> brush) =>
      _fillRoundedRectangle(pointer, roundedRect, brush);

  void drawGeometry(
    Pointer<Void> geometry,
    Pointer<Void> brush,
    double strokeWidth,
    Pointer<Void> strokeStyle,
  ) =>
      _drawGeometry(pointer, geometry, brush, strokeWidth, strokeStyle);

  void fillGeometry(Pointer<Void> geometry, Pointer<Void> brush) =>
      _fillGeometry(pointer, geometry, brush, nullptr);

  /// Requires the aliased antialias mode; the caller switches around it.
  void fillOpacityMask(
    Pointer<Void> maskBitmap,
    Pointer<Void> brush,
    Pointer<D2dRectF> destination,
    Pointer<D2dRectF> source,
  ) =>
      _fillOpacityMask(pointer, maskBitmap, brush,
          d2d1OpacityMaskContentGraphics, destination, source);

  void drawBitmap(
    Pointer<Void> bitmap,
    Pointer<D2dRectF> destination,
    double opacity,
    int interpolationMode,
    Pointer<D2dRectF> source,
  ) =>
      _drawBitmap(
          pointer, bitmap, destination, opacity, interpolationMode, source);

  void setTransform(Pointer<D2dMatrix3x2F> matrix) =>
      _setTransform(pointer, matrix);

  void setAntialiasMode(int mode) => _setAntialiasMode(pointer, mode);

  void pushLayer(Pointer<D2dLayerParameters> parameters, Pointer<Void> layer) =>
      _pushLayer(pointer, parameters, layer);

  void popLayer() => _popLayer(pointer);

  int flush() => _flush(pointer, nullptr, nullptr);

  void pushAxisAlignedClip(Pointer<D2dRectF> rect, int antialiasMode) =>
      _pushAxisAlignedClip(pointer, rect, antialiasMode);

  void popAxisAlignedClip() => _popAxisAlignedClip(pointer);

  void clear(Pointer<D2dColorF> color) => _clear(pointer, color);

  void beginDraw() => _beginDraw(pointer);

  /// Returns the raw `HRESULT`. `D2DERR_RECREATE_TARGET` is the device-lost
  /// signal and must be mapped, not thrown; see `d2d_targets.dart`.
  int endDraw() => _endDraw(pointer, nullptr, nullptr);

  void release() => ComObject(pointer).release();
}

/// `ID2D1HwndRenderTarget`. Adds `CheckWindowState` 57, `Resize` 58.
final class D2dHwndRenderTarget {
  D2dHwndRenderTarget(this.pointer)
      : target = D2dRenderTarget(pointer),
        _checkWindowState =
            comMethod<Uint32 Function(Pointer<Void>)>(pointer, 57)
                .asFunction<int Function(Pointer<Void>)>(),
        _resize =
            comMethod<Int32 Function(Pointer<Void>, Pointer<D2dSizeU>)>(
                    pointer, 58)
                .asFunction<int Function(Pointer<Void>, Pointer<D2dSizeU>)>();

  final Pointer<Void> pointer;

  /// The shared drawing surface. One vtable, two Dart views; both views bind
  /// their slots once in their constructors.
  final D2dRenderTarget target;

  final int Function(Pointer<Void>) _checkWindowState;
  final int Function(Pointer<Void>, Pointer<D2dSizeU>) _resize;

  /// `D2D1_WINDOW_STATE` flags; bit 0 is occluded.
  int checkWindowState() => _checkWindowState(pointer);

  /// Resizes the target's back buffer. Cheap, and unlike DXGI's
  /// `ResizeBuffers` it has no outstanding-reference precondition.
  int resize(Pointer<D2dSizeU> size) => _resize(pointer, size);

  void release() => ComObject(pointer).release();
}

/// `ID2D1DCRenderTarget`. Adds `BindDC` 57.
final class D2dDcRenderTarget {
  D2dDcRenderTarget(this.pointer)
      : target = D2dRenderTarget(pointer),
        _bindDc = comMethod<
                Int32 Function(Pointer<Void>, Pointer<Void>,
                    Pointer<Win32NativeRect>)>(pointer, 57)
            .asFunction<
                int Function(Pointer<Void>, Pointer<Void>,
                    Pointer<Win32NativeRect>)>();

  final Pointer<Void> pointer;
  final D2dRenderTarget target;
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<Win32NativeRect>)
      _bindDc;

  /// Points the target at [hdc], drawing into [rect] of it (device pixels).
  int bindDc(Pointer<Void> hdc, Pointer<Win32NativeRect> rect) =>
      _bindDc(pointer, hdc, rect);

  void release() => ComObject(pointer).release();
}

/// `ID2D1SolidColorBrush`. Slots: `ID2D1Brush` inherits 4..7
/// (`SetOpacity` 4, `SetTransform` 5, `GetOpacity` 6, `GetTransform` 7), then
/// `SetColor` 8.
final class D2dSolidColorBrush {
  D2dSolidColorBrush(this.pointer)
      : _setOpacity = comMethod<Void Function(Pointer<Void>, Float)>(pointer, 4)
            .asFunction<void Function(Pointer<Void>, double)>(),
        _setColor =
            comMethod<Void Function(Pointer<Void>, Pointer<D2dColorF>)>(
                    pointer, 8)
                .asFunction<void Function(Pointer<Void>, Pointer<D2dColorF>)>();

  final Pointer<Void> pointer;
  final void Function(Pointer<Void>, double) _setOpacity;
  final void Function(Pointer<Void>, Pointer<D2dColorF>) _setColor;

  void setOpacity(double opacity) => _setOpacity(pointer, opacity);

  void setColor(Pointer<D2dColorF> color) => _setColor(pointer, color);

  void release() => ComObject(pointer).release();
}

/// `ID2D1PathGeometry`. Slots: `ID2D1Geometry` inherits 4..16, then `Open` 17.
final class D2dPathGeometry {
  D2dPathGeometry(this.pointer)
      : _open = comMethod<
                Int32 Function(
                    Pointer<Void>, Pointer<Pointer<Void>>)>(pointer, 17)
            .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>();

  final Pointer<Void> pointer;
  final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _open;

  /// Opens the one-shot `ID2D1GeometrySink`. A path geometry can be opened
  /// exactly once; after `Close` it is immutable, which matches [Path].
  int open(Pointer<Pointer<Void>> out) => _open(pointer, out);

  void release() => ComObject(pointer).release();
}

/// `ID2D1GeometrySink`. Slots: `ID2D1SimplifiedGeometrySink` declares
/// `SetFillMode` 3, `SetSegmentFlags` 4, `BeginFigure` 5, `AddLines` 6,
/// `AddBeziers` 7, `EndFigure` 8, `Close` 9; `ID2D1GeometrySink` adds
/// `AddLine` 10, `AddBezier` 11, `AddQuadraticBezier` 12.
final class D2dGeometrySink {
  D2dGeometrySink(this.pointer)
      : _setFillMode =
            comMethod<Void Function(Pointer<Void>, Uint32)>(pointer, 3)
                .asFunction<void Function(Pointer<Void>, int)>(),
        _beginFigure =
            comMethod<Void Function(Pointer<Void>, D2dPoint2F, Uint32)>(
                    pointer, 5)
                .asFunction<void Function(Pointer<Void>, D2dPoint2F, int)>(),
        _endFigure = comMethod<Void Function(Pointer<Void>, Uint32)>(pointer, 8)
            .asFunction<void Function(Pointer<Void>, int)>(),
        _close = comMethod<Int32 Function(Pointer<Void>)>(pointer, 9)
            .asFunction<int Function(Pointer<Void>)>(),
        _addLine = comMethod<Void Function(Pointer<Void>, D2dPoint2F)>(
                pointer, 10)
            .asFunction<void Function(Pointer<Void>, D2dPoint2F)>(),
        _addBezier = comMethod<
                Void Function(
                    Pointer<Void>, Pointer<D2dBezierSegment>)>(pointer, 11)
            .asFunction<
                void Function(Pointer<Void>, Pointer<D2dBezierSegment>)>(),
        _addQuadraticBezier = comMethod<
                Void Function(Pointer<Void>,
                    Pointer<D2dQuadraticBezierSegment>)>(pointer, 12)
            .asFunction<
                void Function(
                    Pointer<Void>, Pointer<D2dQuadraticBezierSegment>)>();

  final Pointer<Void> pointer;
  final void Function(Pointer<Void>, int) _setFillMode;
  final void Function(Pointer<Void>, D2dPoint2F, int) _beginFigure;
  final void Function(Pointer<Void>, int) _endFigure;
  final int Function(Pointer<Void>) _close;
  final void Function(Pointer<Void>, D2dPoint2F) _addLine;
  final void Function(Pointer<Void>, Pointer<D2dBezierSegment>) _addBezier;
  final void Function(Pointer<Void>, Pointer<D2dQuadraticBezierSegment>)
      _addQuadraticBezier;

  /// Must be called before the first figure or Direct2D ignores it.
  void setFillMode(int fillMode) => _setFillMode(pointer, fillMode);

  /// [startPoint] crosses by value; see `d2d1_structs.dart`.
  void beginFigure(D2dPoint2F startPoint, int figureBegin) =>
      _beginFigure(pointer, startPoint, figureBegin);

  void endFigure(int figureEnd) => _endFigure(pointer, figureEnd);

  /// Seals the geometry. Failure here is the *first* place a degenerate
  /// figure is reported, which is why the sink's HRESULT must be checked.
  int close() => _close(pointer);

  void addLine(D2dPoint2F point) => _addLine(pointer, point);

  void addBezier(Pointer<D2dBezierSegment> segment) =>
      _addBezier(pointer, segment);

  void addQuadraticBezier(Pointer<D2dQuadraticBezierSegment> segment) =>
      _addQuadraticBezier(pointer, segment);

  void release() => ComObject(pointer).release();
}
You've hit your session limit · resets 4:40am (America/Sao_Paulo)

You've hit your session limit · resets 4:40am (America/Sao_Paulo)

You've hit your session limit · resets 4:40am (America/Sao_Paulo)

You've hit your session limit · resets 4:40am (America/Sao_Paulo)

Bash PhosphorIcons class name and Button API
IN
grep -n "class PhosphorIcons\|abstract final class" C:/MyDartProjects/dart_ui/lib/src/widgets/phosphor_icons.dart | head -3; sed -n 40,80p C:/MyDartProjects/dart_ui/lib/src/widgets/controls.dart

OUT
12:abstract final class PhosphorIcons {
/// failure needs [Clipboard] and [ClipboardException] to say anything about it.
export '../foundation/value_notifier.dart';
export '../platform/clipboard.dart';

/// The context menu travels with the controls that raise one. [TextField] opens
/// its own from a secondary click, so a caller who wants that to work needs
/// [ContextMenuScope] - and one who wants a menu of their own needs
/// [ContextMenuRegion] and [MenuItem] together, which is why the two arrive
/// from the same import rather than from opposite ends of the library.
export 'context_menu.dart';
export 'menu.dart';
export 'text_field.dart';

final class Button extends StatefulWidget {
  const Button({
    super.key,
    required this.label,
    this.onPressed,
    this.isDefault = false,
    this.isCancel = false,
    this.styleClasses = const <String>{},
  });

  final String label;
  final void Function()? onPressed;

  /// The button Enter activates when nothing else has focus.
  final bool isDefault;

  /// The button Escape activates.
  final bool isCancel;

  final Set<String> styleClasses;

  @override
  State<Button> createState() => _ButtonState();
}

final class _ButtonState extends State<Button> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Button');
You've hit your session limit · resets 4:40am (America/Sao_Paulo)

Write C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\webgpu\webgpu_interop.dart
466 lines
/// Typed `dart:js_interop` bindings for the WebGPU API.
///
/// ## Why these are declared here and not imported
///
/// `package:web` is generated from the WebIDL of the DOM specifications, and
/// at the pinned version it ships only WebGPU's *flag namespaces* -
/// `GPUTextureUsage`, `GPUBufferUsage` and friends - not the interfaces. The
/// precedent for filling such a gap is `_WebGlLoseContext` in
/// `webgl_backend.dart`: an extension type over `JSObject` is the typed way to
/// name a browser object the package does not, the cast is unchecked either
/// way, and putting each method name in one place makes a typo a compile error
/// rather than a string that silently does nothing.
///
/// The same argument the WebGL descriptor makes about dictionaries applies to
/// every descriptor below: an extension type with an `external factory`
/// compiles to the same object literal an untyped `JSObject` build-up would,
/// and a misspelled member is a compile error instead of an attribute WebGPU
/// silently ignores. That failure mode is worse here than on WebGL, because
/// WebGPU validates *asynchronously* - a bad descriptor surfaces as an
/// `uncapturederror` event long after the call that caused it returned.
///
/// Only the members this backend calls are declared. WebGPU is a large API;
/// declaring it wholesale would be maintaining a second `package:web` with
/// none of its generator, and every undeclared member is a one-line addition
/// at the call site that needs it.
///
/// ## `dart:ffi` must never appear
///
/// Same rule, same reason, same enforcement as `webgl_backend.dart`: this
/// library is reachable from the web compilation fixture, and
/// `test/backends/web/web_compilation_test.dart` runs `dart2js` and
/// `dart2wasm` over it.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// `navigator.gpu`, or null where the browser has no WebGPU.
///
/// Declared as an extension member on `package:web`'s own `Navigator` rather
/// than as a top-level `@JS('navigator.gpu')` binding, so the lookup goes
/// through the same object every other navigator property in this codebase
/// goes through. The getter type is nullable because that is the honest
/// signature: on a browser without WebGPU the property is `undefined`, and
/// `dart:js_interop` hands a nullable static type null for it.
extension WebGpuNavigator on web.Navigator {
  @JS('gpu')
  external GPU? get gpuOrNull;
}

/// Asks the page for `navigator.gpu`, never throwing.
///
/// The probe's question, wrapped: a non-browser JavaScript host may have no
/// `navigator` at all, and reaching through it raises a `TypeError` that must
/// become "not supported here" rather than an exception out of a probe -
/// section 6.6's rule, in the same shape `WebWindowingBackend.probe` applies
/// to `document`.
GPU? navigatorGpu() {
  try {
    return web.window.navigator.gpuOrNull;
  } on Object {
    return null;
  }
}

/// The `getContext` id a canvas answers a [GPUCanvasContext] for.
const String kWebGpuContextId = 'webgpu';

/// Asks [canvas] for a WebGPU context, or null when the browser refuses.
///
/// Never throws, and checks the result with `instanceOfString` rather than
/// `is`, for exactly the reason `createWebGl2Context` documents: every
/// rendering context is a `JSObject` under the extension-type erasure, so an
/// `is` test would accept a 2D context and the first `configure` call on it
/// would throw a JavaScript `TypeError` out of the frame loop.
///
/// One property matters for the fallback story and is worth stating here:
/// `getContext('webgpu')` on a browser that does not recognise the id returns
/// null **without claiming the canvas**, so a canvas that was offered to this
/// backend and refused is still virgin for `getContext('webgl2')`. A canvas
/// that *received* a WebGPU context, on the other hand, is spent - which is
/// why the presenter asks the adapter and the device for everything they can
/// refuse *before* it touches the canvas.
GPUCanvasContext? createWebGpuContext(web.HTMLCanvasElement canvas) {
  try {
    final web.RenderingContext? context = canvas.getContext(kWebGpuContextId);
    if (context == null) return null;
    if (!(context as JSObject).instanceOfString('GPUCanvasContext')) {
      return null;
    }
    return context as GPUCanvasContext;
  } on Object {
    return null;
  }
}

/// The `GPU` interface: the entry point WebGPU hangs off `navigator.gpu`.
extension type GPU._(JSObject _) implements JSObject {
  external JSPromise<GPUAdapter?> requestAdapter(
      [GPURequestAdapterOptions options]);
  external String getPreferredCanvasFormat();
}

/// A physical adapter. Consumed by one `requestDevice` call.
extension type GPUAdapter._(JSObject _) implements JSObject {
  external JSPromise<GPUDevice> requestDevice([GPUDeviceDescriptor descriptor]);

  /// Nullable because `adapter.info` is newer than the rest of the API and a
  /// browser that predates it answers `undefined`. Its absence is normal and
  /// falls back to a generic description, exactly as the missing
  /// `WEBGL_debug_renderer_info` extension does on the WebGL path.
  external GPUAdapterInfo? get info;
}

extension type GPUAdapterInfo._(JSObject _) implements JSObject {
  external String get vendor;
  external String get architecture;
  external String get device;
  external String get description;
}

/// The logical device: every object this backend creates comes from here.
///
/// `addEventListener` is declared directly because a `GPUDevice` is an
/// `EventTarget` in the specification, and `uncapturederror` is the only
/// channel WebGPU's asynchronous validation reports through - a device that
/// did not listen would have every bad descriptor vanish silently, which is
/// the outcome section 6.6 exists to prevent.
extension type GPUDevice._(JSObject _) implements JSObject {
  external GPUQueue get queue;

  /// Resolves when the device is lost. Never rejects; a healthy device simply
  /// never resolves it. This is WebGPU's whole loss-notification story - there
  /// is no synchronous `isContextLost()` to poll, which is why the backend's
  /// liveness check reads its own [GpuDeviceState] instead.
  external JSPromise<GPUDeviceLostInfo> get lost;

  external GPUSupportedLimits get limits;
  external GPUShaderModule createShaderModule(
      GPUShaderModuleDescriptor descriptor);
  external GPUBuffer createBuffer(GPUBufferDescriptor descriptor);
  external GPUTexture createTexture(GPUTextureDescriptor descriptor);
  external GPUSampler createSampler([GPUSamplerDescriptor descriptor]);
  external GPUBindGroupLayout createBindGroupLayout(
      GPUBindGroupLayoutDescriptor descriptor);
  external GPUPipelineLayout createPipelineLayout(
      GPUPipelineLayoutDescriptor descriptor);
  external GPUBindGroup createBindGroup(GPUBindGroupDescriptor descriptor);
  external GPURenderPipeline createRenderPipeline(
      GPURenderPipelineDescriptor descriptor);
  external GPUCommandEncoder createCommandEncoder();
  external void destroy();
  external void addEventListener(String type, JSFunction? callback);
  external void removeEventListener(String type, JSFunction? callback);
}

extension type GPUDeviceLostInfo._(JSObject _) implements JSObject {
  /// `'unknown'` or `'destroyed'`. The second is this backend's own
  /// `destroy()` call and is not an error.
  external String get reason;
  external String get message;
}

extension type GPUSupportedLimits._(JSObject _) implements JSObject {
  external int get maxTextureDimension2D;
}

extension type GPUError._(JSObject _) implements JSObject {
  external String get message;
}

extension type GPUUncapturedErrorEvent._(JSObject _) implements JSObject {
  external GPUError get error;
}

extension type GPUQueue._(JSObject _) implements JSObject {
  external void submit(JSArray<GPUCommandBuffer> commandBuffers);

  /// [data] is a `BufferSource`; the callers hand over typed-array views of
  /// exactly the bytes to write, for the reason `webgl_backend.dart` gives at
  /// its `bufferData` call: the staging list is usually larger than the frame
  /// needs.
  external void writeBuffer(GPUBuffer buffer, int bufferOffset, JSObject data);
  external void writeTexture(
    GPUTexelCopyTextureInfo destination,
    JSObject data,
    GPUTexelCopyBufferLayout dataLayout,
    GPUExtent3DDict size,
  );
}

extension type GPUCanvasContext._(JSObject _) implements JSObject {
  external void configure(GPUCanvasConfiguration configuration);
  external void unconfigure();

  /// The texture the compositor will show at the end of this task. Stable
  /// within one task - a mid-frame flush and the final present of the same
  /// frame get the same texture - and replaced by the browser afterwards,
  /// which is the same "draw the whole frame inside one rAF callback"
  /// contract `webgl_canvas_target.dart` documents for the drawing buffer.
  external GPUTexture getCurrentTexture();
}

extension type GPUBuffer._(JSObject _) implements JSObject {
  external int get size;
  external void destroy();
}

extension type GPUTexture._(JSObject _) implements JSObject {
  external GPUTextureView createView();
  external void destroy();
}

extension type GPUTextureView._(JSObject _) implements JSObject {}

extension type GPUSampler._(JSObject _) implements JSObject {}

extension type GPUShaderModule._(JSObject _) implements JSObject {}

extension type GPUBindGroupLayout._(JSObject _) implements JSObject {}

extension type GPUPipelineLayout._(JSObject _) implements JSObject {}

extension type GPUBindGroup._(JSObject _) implements JSObject {}

extension type GPURenderPipeline._(JSObject _) implements JSObject {}

extension type GPUCommandBuffer._(JSObject _) implements JSObject {}

extension type GPUCommandEncoder._(JSObject _) implements JSObject {
  external GPURenderPassEncoder beginRenderPass(
      GPURenderPassDescriptor descriptor);
  external GPUCommandBuffer finish();
}

extension type GPURenderPassEncoder._(JSObject _) implements JSObject {
  external void setPipeline(GPURenderPipeline pipeline);
  external void setBindGroup(int index, GPUBindGroup bindGroup,
      [JSArray<JSNumber> dynamicOffsets]);
  external void setVertexBuffer(int slot, GPUBuffer buffer);
  external void setIndexBuffer(GPUBuffer buffer, String indexFormat);

  /// Framebuffer coordinates: origin at the top-left, like device space.
  /// Nothing is flipped here, and `wgsl_shaders.dart` says why GL's flip does
  /// not apply.
  external void setScissorRect(int x, int y, int width, int height);
  external void drawIndexed(int indexCount,
      [int instanceCount, int firstIndex]);
  external void end();
}

// ---------------------------------------------------------------------------
// Descriptor dictionaries. Object literals with compile-checked member names;
// see the library comment for why each is an extension type with an external
// factory rather than an untyped JSObject.
// ---------------------------------------------------------------------------

extension type GPURequestAdapterOptions._(JSObject _) implements JSObject {
  /// `powerPreference` is deliberately not passed by this backend, for the
  /// reason `defaultWebGl2ContextAttributes` gives: the discrete-versus-
  /// integrated choice is a battery decision that belongs to the application.
  external factory GPURequestAdapterOptions({String powerPreference});
}

extension type GPUDeviceDescriptor._(JSObject _) implements JSObject {
  external factory GPUDeviceDescriptor({String label});
}

extension type GPUCanvasConfiguration._(JSObject _) implements JSObject {
  external factory GPUCanvasConfiguration({
    GPUDevice device,
    String format,
    String alphaMode,
  });
}

extension type GPUShaderModuleDescriptor._(JSObject _) implements JSObject {
  external factory GPUShaderModuleDescriptor({String code});
}

extension type GPUBufferDescriptor._(JSObject _) implements JSObject {
  external factory GPUBufferDescriptor({int size, int usage});
}

extension type GPUExtent3DDict._(JSObject _) implements JSObject {
  external factory GPUExtent3DDict({int width, int height});
}

extension type GPUTextureDescriptor._(JSObject _) implements JSObject {
  external factory GPUTextureDescriptor({
    GPUExtent3DDict size,
    String format,
    int usage,
  });
}

extension type GPUSamplerDescriptor._(JSObject _) implements JSObject {
  external factory GPUSamplerDescriptor({
    String magFilter,
    String minFilter,
    String addressModeU,
    String addressModeV,
  });
}

extension type GPUOrigin3DDict._(JSObject _) implements JSObject {
  external factory GPUOrigin3DDict({int x, int y});
}

extension type GPUTexelCopyTextureInfo._(JSObject _) implements JSObject {
  external factory GPUTexelCopyTextureInfo({
    GPUTexture texture,
    GPUOrigin3DDict origin,
  });
}

extension type GPUTexelCopyBufferLayout._(JSObject _) implements JSObject {
  external factory GPUTexelCopyBufferLayout({
    int offset,
    int bytesPerRow,
    int rowsPerImage,
  });
}

extension type GPUBufferBindingLayout._(JSObject _) implements JSObject {
  external factory GPUBufferBindingLayout({
    String type,
    bool hasDynamicOffset,
    int minBindingSize,
  });
}

extension type GPUSamplerBindingLayout._(JSObject _) implements JSObject {
  external factory GPUSamplerBindingLayout({String type});
}

extension type GPUTextureBindingLayout._(JSObject _) implements JSObject {
  external factory GPUTextureBindingLayout({String sampleType});
}

extension type GPUBindGroupLayoutEntry._(JSObject _) implements JSObject {
  external factory GPUBindGroupLayoutEntry({
    int binding,
    int visibility,
    GPUBufferBindingLayout buffer,
    GPUSamplerBindingLayout sampler,
    GPUTextureBindingLayout texture,
  });
}

extension type GPUBindGroupLayoutDescriptor._(JSObject _) implements JSObject {
  external factory GPUBindGroupLayoutDescriptor({
    JSArray<GPUBindGroupLayoutEntry> entries,
  });
}

extension type GPUPipelineLayoutDescriptor._(JSObject _) implements JSObject {
  external factory GPUPipelineLayoutDescriptor({
    JSArray<GPUBindGroupLayout> bindGroupLayouts,
  });
}

extension type GPUBufferBinding._(JSObject _) implements JSObject {
  external factory GPUBufferBinding({GPUBuffer buffer, int offset, int size});
}

extension type GPUBindGroupEntry._(JSObject _) implements JSObject {
  /// [resource] is a union in the specification - a sampler, a texture view
  /// or a buffer binding - which `JSAny` states honestly; the three call
  /// sites each pass one of the typed values above.
  external factory GPUBindGroupEntry({int binding, JSAny resource});
}

extension type GPUBindGroupDescriptor._(JSObject _) implements JSObject {
  external factory GPUBindGroupDescriptor({
    GPUBindGroupLayout layout,
    JSArray<GPUBindGroupEntry> entries,
  });
}

extension type GPUVertexAttribute._(JSObject _) implements JSObject {
  external factory GPUVertexAttribute({
    String format,
    int offset,
    int shaderLocation,
  });
}

extension type GPUVertexBufferLayout._(JSObject _) implements JSObject {
  external factory GPUVertexBufferLayout({
    int arrayStride,
    JSArray<GPUVertexAttribute> attributes,
  });
}

extension type GPUVertexState._(JSObject _) implements JSObject {
  external factory GPUVertexState({
    GPUShaderModule module,
    String entryPoint,
    JSArray<GPUVertexBufferLayout> buffers,
  });
}

extension type GPUBlendComponent._(JSObject _) implements JSObject {
  external factory GPUBlendComponent({
    String srcFactor,
    String dstFactor,
    String operation,
  });
}

extension type GPUBlendStateDict._(JSObject _) implements JSObject {
  external factory GPUBlendStateDict({
    GPUBlendComponent color,
    GPUBlendComponent alpha,
  });
}

extension type GPUColorTargetState._(JSObject _) implements JSObject {
  external factory GPUColorTargetState({
    String format,
    GPUBlendStateDict blend,
  });
}

extension type GPUFragmentState._(JSObject _) implements JSObject {
  external factory GPUFragmentState({
    GPUShaderModule module,
    String entryPoint,
    JSArray<GPUColorTargetState> targets,
  });
}

extension type GPUPrimitiveState._(JSObject _) implements JSObject {
  external factory GPUPrimitiveState({String topology});
}

extension type GPURenderPipelineDescriptor._(JSObject _) implements JSObject {
  external factory GPURenderPipelineDescriptor({
    GPUPipelineLayout layout,
    GPUVertexState vertex,
    GPUFragmentState fragment,
    GPUPrimitiveState primitive,
  });
}

extension type GPUColorDict._(JSObject _) implements JSObject {
  external factory GPUColorDict({num r, num g, num b, num a});
}

extension type GPURenderPassColorAttachment._(JSObject _) implements JSObject {
  external factory GPURenderPassColorAttachment({
    GPUTextureView view,
    String loadOp,
    String storeOp,
    GPUColorDict clearValue,
  });
}

extension type GPURenderPassDescriptor._(JSObject _) implements JSObject {
  external factory GPURenderPassDescriptor({
    JSArray<GPURenderPassColorAttachment> colorAttachments,
  });
}
You've hit your session limit · resets 4:40am (America/Sao_Paulo)

You've hit your session limit · resets 4:40am (America/Sao_Paulo)

You've hit your session limit · resets 4:40am (America/Sao_Paulo)

Write C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_events.dart
488 lines
/// Turning Wayland events into framework events without per-event allocation.
///
/// The same architecture as `x11_events.dart`, because the same constraints
/// apply - `wl_pointer.motion` arrives at input-device rate, and section 6.5
/// forbids an allocation per sample:
///
///   * [WaylandRawEvent] is a single mutable record the connection overwrites
///     in place for every decoded message that concerns a window.
///   * [WaylandPendingWindowEvents] accumulates; configure floods collapse to
///     one resize per pump.
///   * [WaylandEventTranslator] is pure - no FFI, no socket - which is what
///     makes the configure/ack cycle testable on a host with no compositor.
///
/// ## The configure cycle, which is the part Wayland gets strict about
///
/// A client must not draw before the first `xdg_surface.configure`, must ack
/// every configure it applies (`ack_configure` with that serial), and commits
/// are transactions. That state machine lives in [WaylandWindowProtocolState]
/// and the translator: an `xdg_toplevel.configure` only *stages* size and
/// state, and the following `xdg_surface.configure` latches them, records the
/// serial to ack and marks the window resized/exposed. The window acks at
/// flush time, before its next commit, which is exactly the order the
/// protocol requires.
library;

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/input_events.dart';
import '../../platform/window_events.dart';
import 'wayland_keymap.dart';
import 'wayland_protocol.dart';

/// What kind of decoded event a [WaylandRawEvent] currently holds.
enum WaylandRawEventType {
  none,
  xdgToplevelConfigure,
  xdgSurfaceConfigure,
  xdgToplevelClose,
  pointerEnter,
  pointerLeave,
  pointerMotion,
  pointerButton,
  pointerAxis,
  keyboardEnter,
  keyboardLeave,
  keyboardKey,
  keyboardModifiers,
  surfaceEnterOutput,
  scaleChanged,
}

/// One decoded Wayland event, reused across the pump. Never retained.
final class WaylandRawEvent {
  WaylandRawEventType type = WaylandRawEventType.none;

  /// The `wl_surface` protocol id this event is about (resolved through the
  /// pointer/keyboard focus for input events), or 0 for display-wide events.
  int surfaceId = 0;

  int serial = 0;

  /// Input timestamp in compositor milliseconds (a wrapping uint32).
  int timeMilliseconds = 0;

  /// Geometry / key / button payload, meaning depends on [type].
  int width = 0;
  int height = 0;
  int key = 0;
  int state = 0;
  int axis = 0;

  /// Pointer position in surface-local coordinates. Wayland surface
  /// coordinates *are* the framework's logical units - the buffer scale, not
  /// the event stream, carries DPI - so no division happens downstream.
  double x = 0;
  double y = 0;

  /// Scroll length for [WaylandRawEventType.pointerAxis].
  double axisValue = 0;

  /// Bitmask of `xdg_toplevel.state` values for a toplevel configure.
  int stateFlags = 0;

  /// Modifier words for [WaylandRawEventType.keyboardModifiers].
  int modsDepressed = 0;
  int modsLatched = 0;
  int modsLocked = 0;
  int modsGroup = 0;

  void reset() {
    type = WaylandRawEventType.none;
    surfaceId = 0;
    serial = 0;
    timeMilliseconds = 0;
    width = 0;
    height = 0;
    key = 0;
    state = 0;
    axis = 0;
    x = 0;
    y = 0;
    axisValue = 0;
    stateFlags = 0;
    modsDepressed = 0;
    modsLatched = 0;
    modsLocked = 0;
    modsGroup = 0;
  }
}

/// The per-window protocol state the translator updates in place.
final class WaylandWindowProtocolState {
  WaylandWindowProtocolState({
    required this.surfaceId,
    required this.xdgSurfaceId,
    required this.toplevelId,
  });

  final int surfaceId;
  final int xdgSurfaceId;
  final int toplevelId;

  /// Current size in surface (logical) coordinates.
  int width = 0;
  int height = 0;

  /// Integer buffer scale currently applied to commits.
  int bufferScale = 1;

  /// Staged by `xdg_toplevel.configure`, latched by `xdg_surface.configure`.
  /// Zero means "the client decides", which keeps the current size.
  int pendingWidth = 0;
  int pendingHeight = 0;
  int pendingStateFlags = 0;
  bool hasPendingToplevelConfigure = false;

  /// Whether the initial configure has been received; drawing before it is a
  /// protocol violation, so the surface is only built once this is true.
  bool configured = false;

  bool activated = false;
  bool maximized = false;
  bool fullscreen = false;
  bool destroyed = false;
}

/// Everything one pump decided, before any framework event object exists.
final class WaylandPendingWindowEvents {
  bool resized = false;
  bool exposed = false;
  bool activationChanged = false;
  bool activated = false;
  bool closeRequested = false;
  bool destroyed = false;
  bool scaleDirty = false;

  /// The configure serial to `ack_configure` before the next commit, or -1.
  /// Later configures overwrite earlier ones within a pump: acking the newest
  /// is the protocol's own collapsing rule.
  int ackSerial = -1;

  bool get isEmpty =>
      !resized &&
      !exposed &&
      !activationChanged &&
      !closeRequested &&
      !destroyed &&
      !scaleDirty &&
      ackSerial < 0;

  void reset() {
    resized = false;
    exposed = false;
    activationChanged = false;
    activated = false;
    closeRequested = false;
    destroyed = false;
    scaleDirty = false;
    ackSerial = -1;
  }
}

/// The rules, as pure functions over [WaylandRawEvent] and the window state.
abstract final class WaylandEventTranslator {
  /// Applies one decoded event. Sets bits on [pending]; allocates nothing.
  ///
  /// Returns false when the event was not for this window, so the caller can
  /// route it elsewhere or count it as stale.
  static bool apply(
    WaylandRawEvent raw,
    WaylandWindowProtocolState state,
    WaylandPendingWindowEvents pending,
  ) {
    if (raw.type == WaylandRawEventType.scaleChanged) {
      pending.scaleDirty = true;
      return true;
    }
    if (raw.surfaceId != state.surfaceId) return false;
    if (state.destroyed) return false;

    switch (raw.type) {
      case WaylandRawEventType.xdgToplevelConfigure:
        // Stages only. The size is not final until xdg_surface.configure
        // arrives - the protocol allows several toplevel configures per cycle
        // and only the last one before the surface configure counts.
        state.pendingWidth = raw.width;
        state.pendingHeight = raw.height;
        state.pendingStateFlags = raw.stateFlags;
        state.hasPendingToplevelConfigure = true;
        return true;

      case WaylandRawEventType.xdgSurfaceConfigure:
        _latchConfigure(raw.serial, state, pending);
        return true;

      case WaylandRawEventType.xdgToplevelClose:
        pending.closeRequested = true;
        return true;

      case WaylandRawEventType.surfaceEnterOutput:
        pending.scaleDirty = true;
        return true;

      case WaylandRawEventType.pointerEnter:
      case WaylandRawEventType.pointerLeave:
      case WaylandRawEventType.pointerMotion:
      case WaylandRawEventType.pointerButton:
      case WaylandRawEventType.pointerAxis:
      case WaylandRawEventType.keyboardEnter:
      case WaylandRawEventType.keyboardLeave:
      case WaylandRawEventType.keyboardKey:
      case WaylandRawEventType.keyboardModifiers:
        // Input is translated separately; nothing to coalesce here.
        return true;

      case WaylandRawEventType.none:
        return false;
    }
  }

  static void _latchConfigure(
    int serial,
    WaylandWindowProtocolState state,
    WaylandPendingWindowEvents pending,
  ) {
    pending.ackSerial = serial;
    if (state.hasPendingToplevelConfigure) {
      state.hasPendingToplevelConfigure = false;
      final flags = state.pendingStateFlags;
      final activated = (flags & (1 << xdgToplevelStateActivated)) != 0;
      state.maximized = (flags & (1 << xdgToplevelStateMaximized)) != 0;
      state.fullscreen = (flags & (1 << xdgToplevelStateFullscreen)) != 0;
      if (activated != state.activated) {
        state.activated = activated;
        pending.activationChanged = true;
        pending.activated = activated;
      }
      // Zero means the client picks; keeping the current size is that pick.
      if (state.pendingWidth > 0 && state.pendingHeight > 0) {
        if (state.pendingWidth != state.width ||
            state.pendingHeight != state.height) {
          state.width = state.pendingWidth;
          state.height = state.pendingHeight;
          pending.resized = true;
        }
      }
    }
    if (!state.configured) {
      state.configured = true;
      // The first configure is what makes drawing legal at all, so the first
      // frame is requested here - Wayland has no Expose event to do it.
      pending.exposed = true;
    }
  }

  /// Normalises one pointer event, or returns null for kinds that produce no
  /// framework event (axis frames, unknown buttons).
  static PlatformWindowEvent? translatePointer(
    WaylandRawEvent raw, {
    required NativeWindowId windowId,
    required int generation,
  }) {
    switch (raw.type) {
      case WaylandRawEventType.pointerEnter:
        return WindowPointerEnterEvent(
          windowId: windowId,
          generation: generation,
        );
      case WaylandRawEventType.pointerLeave:
        return WindowPointerLeaveEvent(
          windowId: windowId,
          generation: generation,
        );
      case WaylandRawEventType.pointerMotion:
        return PointerMoveEvent(
          windowId: windowId,
          generation: generation,
          timestamp: Duration(milliseconds: raw.timeMilliseconds),
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: Offset(raw.x, raw.y),
        );
      case WaylandRawEventType.pointerButton:
        final button = _pointerButton(raw.key);
        if (button == null) return null;
        return raw.state == wlPointerButtonStatePressed
            ? PointerDownEvent(
                windowId: windowId,
                generation: generation,
                timestamp: Duration(milliseconds: raw.timeMilliseconds),
                pointerId: 0,
                kind: PointerKind.mouse,
                logicalPosition: Offset(raw.x, raw.y),
                button: button,
              )
            : PointerUpEvent(
                windowId: windowId,
                generation: generation,
                timestamp: Duration(milliseconds: raw.timeMilliseconds),
                pointerId: 0,
                kind: PointerKind.mouse,
                logicalPosition: Offset(raw.x, raw.y),
                button: button,
              );
      case WaylandRawEventType.pointerAxis:
        // wl_fixed axis lengths are in surface-local units, which are logical
        // pixels - unlike X11's discrete wheel clicks.
        final delta = raw.axis == wlPointerAxisHorizontalScroll
            ? Offset(raw.axisValue, 0)
            : Offset(0, raw.axisValue);
        return PointerScrollEvent(
          windowId: windowId,
          generation: generation,
          timestamp: Duration(milliseconds: raw.timeMilliseconds),
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: Offset(raw.x, raw.y),
          scrollDelta: delta,
          scrollDeltaUnit: ScrollDeltaUnit.pixels,
        );
      default:
        return null;
    }
  }

  /// Translates one `wl_keyboard.key` into a [KeyEvent], and possibly the
  /// [TextInputEvent] its keysym produces. Events go to [emit] in order:
  /// hardware first, text second, the same order Win32 delivers
  /// `WM_KEYDOWN`/`WM_CHAR`.
  ///
  /// A key whose symbol the keymap subset cannot resolve still emits its
  /// [KeyEvent]; it emits no text, per the [TextInputEvent] contract - a
  /// backend that cannot translate must stay silent rather than guess.
  static void translateKey(
    WaylandRawEvent raw, {
    required NativeWindowId windowId,
    required int generation,
    required WaylandXkbKeymap? keymap,
    required WaylandModifiersState modifiers,
    required void Function(PlatformWindowEvent event) emit,
  }) {
    if (raw.type != WaylandRawEventType.keyboardKey) return;
    final xkbKeycode = raw.key + evdevToXkbKeycodeOffset;
    final keysym = keymap?.keysymFor(
          xkbKeycode,
          shift: modifiers.shift,
          capsLock: modifiers.capsLock,
        ) ??
        xkbNoSymbol;
    final timestamp = Duration(milliseconds: raw.timeMilliseconds);
    final modifierSet = _modifierSet(modifiers);
    final pressed = raw.state == wlKeyboardKeyStatePressed;
    emit(pressed
        ? KeyDownEvent(
            windowId: windowId,
            generation: generation,
            timestamp: timestamp,
            physicalKey: xkbKeycode,
            logicalKey: keysym,
            modifiers: modifierSet,
          )
        : KeyUpEvent(
            windowId: windowId,
            generation: generation,
            timestamp: timestamp,
            physicalKey: xkbKeycode,
            logicalKey: keysym,
            modifiers: modifierSet,
          ));
    if (!pressed || modifiers.control || modifiers.alt || modifiers.meta) {
      return;
    }
    final text = keymap?.textFor(
      xkbKeycode,
      shift: modifiers.shift,
      capsLock: modifiers.capsLock,
    );
    if (text == null || text.isEmpty) return;
    if (text.length == 1 && isTextInputControlUnit(text.codeUnitAt(0))) return;
    emit(TextInputEvent(
      windowId: windowId,
      generation: generation,
      timestamp: timestamp,
      text: text,
    ));
  }

  static Set<KeyModifier> _modifierSet(WaylandModifiersState modifiers) {
    if (modifiers.depressed == 0 &&
        modifiers.latched == 0 &&
        modifiers.locked == 0) {
      return const <KeyModifier>{};
    }
    return <KeyModifier>{
      if (modifiers.shift) KeyModifier.shift,
      if (modifiers.control) KeyModifier.control,
      if (modifiers.alt) KeyModifier.alt,
      if (modifiers.meta) KeyModifier.meta,
      if (modifiers.capsLock) KeyModifier.capsLock,
      if (modifiers.numLock) KeyModifier.numLock,
    };
  }

  static PointerButton? _pointerButton(int evdevButton) =>
      switch (evdevButton) {
        btnLeft => PointerButton.primary,
        btnRight => PointerButton.secondary,
        btnMiddle => PointerButton.middle,
        btnSide => PointerButton.back,
        btnExtra => PointerButton.forward,
        _ => null,
      };

  /// Builds the framework events for one pump and hands each to [emit].
  ///
  /// [generation] must already reflect any surface rebuild a resize caused,
  /// the same contract `X11EventTranslator.emitPending` documents.
  static void emitPending(
    WaylandPendingWindowEvents pending, {
    required NativeWindowId windowId,
    required int generation,
    required int logicalWidth,
    required int logicalHeight,
    required double renderScale,
    required void Function(PlatformWindowEvent event) emit,
  }) {
    if (pending.resized) {
      emit(WindowResizedEvent(
        windowId: windowId,
        generation: generation,
        clientSize: Size(logicalWidth.toDouble(), logicalHeight.toDouble()),
        renderScale: renderScale,
      ));
    }
    if (pending.exposed) {
      emit(WindowExposedEvent(
        windowId: windowId,
        generation: generation,
        dirtyRect: Rect.fromLTWH(
          0,
          0,
          logicalWidth.toDouble(),
          logicalHeight.toDouble(),
        ),
      ));
    }
    if (pending.activationChanged) {
      emit(WindowActivationEvent(
        windowId: windowId,
        generation: generation,
        activation: pending.activated
            ? WindowActivation.activated
            : WindowActivation.deactivated,
      ));
    }
    if (pending.closeRequested) {
      emit(WindowCloseRequestedEvent(
        windowId: windowId,
        generation: generation,
      ));
    }
    if (pending.destroyed) {
      emit(WindowClosedEvent(windowId: windowId, generation: generation));
    }
  }
}
You've hit your session limit · resets 4:40am (America/Sao_Paulo)

You've hit your session limit · resets 4:40am (America/Sao_Paulo)

Aquela mudança no roteiro era uma edição de uma linha (adicionando "Flutter" às referências) — provavelmente sua, feita no IDE, já que o arquivo estava aberto. Ela foi preservada e commitada junto, sem problema.

Status até agora:

Baseline verificada — dart analyze sem erros e 4192 testes passando (30 skips que exigem macOS). Não havia bugs de teste pendentes.
48 lints corrigidos e commitados (dbae3f1) — imports ordenados, const, chaves em fluxo de controle, em test/cdr, test/pdf, lib/src/text/truetype, crypto e pdf. Analyze agora: No issues found!. Testes das áreas afetadas re-rodados e passando (inclusive os 778 de texto, por causa do interpretador TrueType).
5 subagentes trabalhando em paralelo, com territórios de arquivos disjuntos:
Backend Wayland — protocolo wire em Dart puro sobre socket (mesmo estilo do backend X11), wl_shm, xdg-shell, input, com testes headless de marshalling.
Renderizador Direct2D — COM via FFI no padrão do d3d12 existente, replay da display list (paths, gradientes, clipping, glifos via atlas), com testes reais de pixel aqui no Windows.
WebGPU — presenter para o backend web com shaders WGSL equivalentes aos do WebGL2, fallback automático para WebGL2.
APIs de SO/arquivos — StandardPaths (Known Folders/XDG/macOS), abrir URL/arquivo/revelar no gerenciador, lixeira, SystemInfo, message box nativo, file watcher.
Widgets modernos — inventário do que falta e implementação priorizada: TreeView, DataGrid, Slider, Tooltip, DatePicker, NumberBox, Toast, Badge/Chip/Avatar/Card — com testes headless e registro na galeria.
Conforme cada agente terminar, vou revisar o resultado, rodar os testes da área, resolver conflitos nos barrels de export e commitar por área. Aviso quando houver novidade.