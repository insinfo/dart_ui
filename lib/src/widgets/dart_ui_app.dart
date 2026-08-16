/// High-level root defaults for a dart_ui widget tree.
library;

import '../text/shaper.dart' show TextDirection;
import 'directionality.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'theme.dart';
import 'widget.dart';

/// Installs the ambient values expected by ordinary application widgets.
///
/// [Application] adds window-owned services such as `MediaQuery`, clipboard
/// and context menus outside this widget. [DartUiApp] owns the values that are
/// part of the widget tree itself: theme, reading direction and the top-level
/// focus scope. A nested [Theme], [Directionality] or [FocusScope] remains the
/// nearest value and therefore overrides these defaults normally.
final class DartUiApp extends StatefulWidget {
  const DartUiApp({
    super.key,
    required this.home,
    this.theme = ThemeData.neutralLight,
    this.textDirection = TextDirection.leftToRight,
  });

  final Widget home;
  final ThemeData theme;
  final TextDirection textDirection;

  @override
  State<DartUiApp> createState() => _DartUiAppState();
}

final class _DartUiAppState extends State<DartUiApp> {
  final FocusScopeNode _focusScope =
      FocusScopeNode(debugLabel: 'DartUiApp root');

  @override
  Widget build(BuildContext context) => Theme(
        data: widget.theme,
        child: Directionality(
          textDirection: widget.textDirection,
          child: FocusScope(
            node: _focusScope,
            child: widget.home,
          ),
        ),
      );

  @override
  void dispose() {
    _focusScope.dispose();
    super.dispose();
  }
}
