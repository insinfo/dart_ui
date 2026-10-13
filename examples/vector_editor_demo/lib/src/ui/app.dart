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
  const VectorEditorApp({
    super.key,
    this.initialDoc,
    this.initialName,
    this.theme,
    this.onReady,
  });

  final VectorDocument? initialDoc;
  final String? initialName;
  final ThemeData? theme;

  /// Told when the window's commands are registered - where a control
  /// channel or a test reaches them.
  final void Function(MainWindowState window)? onReady;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.leftToRight,
        child: Theme(
          data: theme ?? ThemeData.studioDark.adaptedToPlatform(),
          child: MainWindow(
            initialDoc: initialDoc,
            initialName: initialName,
            onReady: onReady,
          ),
        ),
      );
}
