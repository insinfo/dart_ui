/// MVP-01: Vertical Slice Windows — Counter app.
///
/// O mesmo widget tree (`CounterApp`) roda em uma janela Win32 real ou no
/// backend headless (testes).
library;

export 'headless.dart';
export 'src/core/bitmap_font.dart' show fontCellHeight, fontCellWidth;
export 'src/core/color.dart';
export 'src/core/geometry.dart';
export 'src/render/canvas.dart';
export 'src/render/cpu_renderer.dart';
export 'src/render/display_list.dart';
export 'src/ui/button.dart';
export 'src/ui/counter_app.dart';
export 'src/ui/label.dart';
export 'src/ui/widget.dart' show UiRoot, Widget, vkReturn, vkSpace, vkTab;
export 'win32_host.dart';
