/// Immediate-mode UI for dart_ui: the interface as code that runs each frame.
///
/// ```dart
/// import 'package:dart_ui/immediate.dart';
///
/// var brightness = 0.0;
/// var name = '';
///
/// void main() => runImmediateApp((Ui ui) {
///       ui.heading('Ajustes');
///       brightness = ui.slider('Brilho', brightness, min: -1, max: 1);
///       name = ui.textField(name, hint: 'Nome');
///       if (ui.button('Aplicar')) print('$name: $brightness');
///     });
/// ```
///
/// [ImmediateArea] puts the same thing inside a retained widget tree, so an
/// application can use immediate mode where it shines - tool panels, debug
/// views, editors with many small dynamic panels - and widgets everywhere else.
/// See `doc/MODO_IMEDIATO.md`.
library;

import 'dart_ui.dart';
import 'src/immediate/immediate_area.dart';
import 'src/immediate/ui.dart';

export 'src/immediate/immediate_area.dart';
export 'src/immediate/ui.dart';

/// Runs [builder] as a whole application: one window whose content is an
/// immediate-mode area. [options] are those of `runApp` - title, size,
/// theme.
Future<Application> runImmediateApp(
  void Function(Ui ui) builder, {
  ApplicationOptions options = const ApplicationOptions(),
}) =>
    runApp(ImmediateArea(builder: builder), options: options);
