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
        child: _FollowSystemBrightness(
          builder: (Brightness? systemBrightness) => Theme(
            data: theme ?? ThemeData.studioDark.adaptedToPlatform(),
            child: MainWindow(
              initialDoc: initialDoc,
              initialName: initialName,
              onReady: onReady,
              systemBrightness: systemBrightness,
            ),
          ),
        ),
      );
}

/// Hands [builder] the desktop's brightness, and rebuilds the window below
/// only when that brightness changes.
///
/// The window's "Follow the system" theme needs the brightness, and the only
/// place it lives is [MediaQuery] - which is one inherited widget for the
/// whole query, so a widget that read it directly would also be rebuilt on
/// every step of a resize. [MainWindow] is the whole editor; rebuilding it per
/// resize frame would re-run its docking layout for nothing. So this widget
/// is the one that depends on the query, and it returns the *same* subtree
/// object while the brightness is unchanged, which the framework skips
/// without looking inside.
///
/// Null outside any [MediaQuery] - a widget test mounting the editor alone -
/// so the editor keeps its own dark default there.
class _FollowSystemBrightness extends StatefulWidget {
  const _FollowSystemBrightness({required this.builder});

  final Widget Function(Brightness? brightness) builder;

  @override
  State<_FollowSystemBrightness> createState() =>
      _FollowSystemBrightnessState();
}

class _FollowSystemBrightnessState extends State<_FollowSystemBrightness> {
  Brightness? _builtFor;
  Widget? _built;

  @override
  void didUpdateWidget(_FollowSystemBrightness oldWidget) {
    super.didUpdateWidget(oldWidget);
    _built = null;
  }

  @override
  Widget build(BuildContext context) {
    final Brightness? brightness =
        MediaQuery.maybePlatformBrightnessOf(context);
    if (_built == null || brightness != _builtFor) {
      _builtFor = brightness;
      _built = widget.builder(brightness);
    }
    return _built!;
  }
}
