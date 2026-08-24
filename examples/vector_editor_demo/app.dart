/// Application wrapper for the vector editor.
library;

import 'package:dart_ui/dart_ui.dart';

import 'main_window.dart';

/// Top-level application widget for the vector editor.
///
/// Installs the theme, because everything below reads chrome colours from it
/// and a window with no [Theme] would silently fall back to the framework
/// default rather than the one the editor picked.
class VectorEditorApp extends StatelessWidget {
  const VectorEditorApp({super.key, this.initialDoc, this.initialName, this.theme});

  final VectorDocument? initialDoc;
  final String? initialName;
  final ThemeData? theme;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.leftToRight,
        child: Theme(
          data: theme ?? ThemeData.fluentLight,
          child: MainWindow(initialDoc: initialDoc, initialName: initialName),
        ),
      );
}
