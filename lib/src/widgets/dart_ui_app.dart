/// High-level root defaults for a dart_ui widget tree.
library;

import '../animation/clock.dart';
import '../scheduler/frame_scheduler.dart';
import '../text/shaper.dart' show TextDirection;
import 'animation_scope.dart';
import 'directionality.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'popup_host.dart';
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
    this.popupHost,
  });

  final Widget home;
  final ThemeData theme;
  final TextDirection textDirection;
  final FrameScheduler? frameScheduler;

  /// Where menus, dropdowns and tooltips are presented, or null to composite
  /// them into this window's own surface.
  ///
  /// Null is the portable answer and the only one available on a backend with
  /// no windows. The application layer passes a host that opens real popup
  /// windows when the backend has them, which is what lets a menu near the
  /// window edge flip instead of being cropped.
  final PopupHost? popupHost;

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
          // The popup host goes here, inside the theme and the reading
          // direction and inside the focus scope, because a menu is themed
          // like the window that opened it and its items take focus in the
          // same scope. Installed by the application widget rather than left
          // to the caller for the reason the clipboard is: a Tooltip or a
          // MenuAnchor in an application that forgot the wrapper would
          // silently show nothing, which reads as a broken control rather
          // than as a missing ancestor.
          //
          // A caller that wants popups in real windows passes its own host
          // through [popupHost]; the application layer does exactly that.
          child: PopupScope(
            host: widget.popupHost,
            child: widget.home,
          ),
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
