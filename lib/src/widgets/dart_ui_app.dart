/// High-level root defaults for a dart_ui widget tree.
library;

import '../animation/clock.dart';
import '../scheduler/frame_scheduler.dart';
import '../text/shaper.dart' show TextDirection;
import 'animation_scope.dart';
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
    this.frameScheduler,
  });

  final Widget home;
  final ThemeData theme;
  final TextDirection textDirection;
  final FrameScheduler? frameScheduler;

  @override
  State<DartUiApp> createState() => _DartUiAppState();
}

final class _DartUiAppState extends State<DartUiApp> {
  final FocusScopeNode _focusScope =
      FocusScopeNode(debugLabel: 'DartUiApp root');
  AnimationClock? _animationClock;

  @override
  void initState() {
    super.initState();
    _bindClock(widget.frameScheduler);
  }

  @override
  void didUpdateWidget(DartUiApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.frameScheduler, oldWidget.frameScheduler)) {
      _bindClock(widget.frameScheduler);
    }
  }

  void _bindClock(FrameScheduler? scheduler) {
    _animationClock?.detach();
    _animationClock =
        scheduler == null ? null : (AnimationClock()..attachTo(scheduler));
  }

  @override
  Widget build(BuildContext context) {
    Widget result = Theme(
      data: widget.theme,
      child: Directionality(
        textDirection: widget.textDirection,
        child: FocusScope(
          node: _focusScope,
          child: widget.home,
        ),
      ),
    );
    final AnimationClock? clock = _animationClock;
    if (clock != null) {
      result = AnimationScope(clock: clock, child: result);
    }
    return result;
  }

  @override
  void dispose() {
    _animationClock?.detach();
    _focusScope.dispose();
    super.dispose();
  }
}
