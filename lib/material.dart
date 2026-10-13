/// Material Design for dart_ui - what a Flutter app imports instead of
/// `package:flutter/material.dart`.
///
/// ```dart
/// import 'package:dart_ui/material.dart';
/// ```
///
/// Re-exports the whole widgets layer (`dart_ui.dart`) and adds Material on
/// top. The names Material redefines with Flutter's meaning are hidden from
/// `dart_ui.dart` here, so in a Material app they resolve to the Material
/// ones: `Theme`, `ThemeData`, `ColorScheme`, `TextTheme`, `Colors` and
/// `Icons`. `package:dart_ui/dart_ui.dart` itself stays Material-free.
///
/// Implemented so far: the theme (`ThemeData`, `ColorScheme.fromSeed` with
/// Material 3 tonal palettes, `TextTheme`/`Typography`, `Colors` with
/// shades, the component themes of the app shell), Flutter's `Icons` names
/// and the `Material` surface. The app shell widgets (`MaterialApp`,
/// `Scaffold`, `AppBar`, ...) are not yet here.
library;

export 'dart_ui.dart'
    hide ColorScheme, Colors, Icons, TextTheme, Theme, ThemeData;
export 'src/material/app_bar_theme.dart';
export 'src/material/color_scheme.dart';
export 'src/material/colors.dart';
export 'src/material/component_themes.dart';
export 'src/material/hct.dart' show Hct, TonalPalette;
export 'src/material/icons.dart';
export 'src/material/material.dart';
export 'src/material/target_platform.dart';
export 'src/material/theme.dart';
export 'src/material/theme_data.dart';
export 'src/material/typography.dart';
export 'src/material/widget_state.dart';
