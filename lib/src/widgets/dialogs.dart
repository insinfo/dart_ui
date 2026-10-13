/// Modal dialogs: [showDialog], and the layer in every window they open in.
///
/// A dialog here is drawn inside its window, over a dimmed copy of it - the
/// WinUI ContentDialog, the GTK and macOS sheet - rather than in a window of
/// its own. That is what makes "modal" hold on every backend with one
/// implementation:
///
///   * **the pointer**: the dimming is a barrier that takes every press, so
///     nothing behind the dialog can be clicked, hovered or scrolled;
///   * **focus**: the dialog is a modal [FocusScopeNode], so Tab cycles
///     through its controls and never reaches the window behind, and focus
///     goes back where it was when the dialog closes;
///   * **the keyboard**: [BuildOwner.modalDepth] silences the window's
///     shortcuts while the dialog is up, so Delete in a dialog's field does
///     not delete the files behind it, and Escape closes the dialog.
///
/// Popups the dialog opens - a combo box's list, a context menu - still go
/// through the window's popup host, which sits above this layer.
library;

import 'dart:async';

import '../graphics/color.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_stack.dart' as layout;
import '../platform/input_events.dart';
import '../text/shaper.dart' show TextDirection;
import 'basic.dart';
import 'directionality.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'gesture_detector.dart';
import 'layout_builder.dart' show Builder;
import 'overlay.dart' show WidgetBuilder;
import 'proxy.dart' show Center;
import 'sizing.dart';
import 'theme.dart';
import 'widget.dart';

/// Opens the dialog [builder] makes, over the window [context] is in, and
/// completes with what [closeDialog] was given - null when it was dismissed
/// with Escape or a click outside.
///
/// [dismissible]: whether Escape closes it (always, unless false) and
/// [barrierDismissible] whether a click on the dimmed window does - off by
/// default, as in WinUI, because a click that misses a dialog's button by a
/// pixel should not throw away what was typed into it.
///
/// [builder] runs in the dialog layer's own context; read what it needs from
/// there, not from [context].
Future<T?> showDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool dismissible = true,
  bool barrierDismissible = false,
  Color? barrierColor,
}) {
  final _DialogLayerState? layer =
      context.getInheritedWidgetOfExactType<_DialogLayerScope>()?.layer;
  if (layer == null) {
    throw StateError(
      'showDialog needs a DialogLayer above the context; every PopupScope '
      'has one - so every window an Application opens, and every DartUiApp.',
    );
  }
  // The builder runs in the layer's context, above whatever the caller sat
  // under; the caller's theme and reading direction travel with it, so a
  // dialog opened from a dark editor is dark - Flutter's captured themes.
  final ThemeData theme = Theme.of(context);
  final TextDirection? direction =
      context.getInheritedWidgetOfExactType<Directionality>()?.textDirection;
  final _DialogEntry<T> entry = _DialogEntry<T>(
    builder: (BuildContext inner) => Theme(
      data: theme,
      child: direction == null
          ? Builder(builder: builder)
          : Directionality(
              textDirection: direction,
              child: Builder(builder: builder),
            ),
    ),
    dismissible: dismissible,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
  );
  layer._open(entry);
  return entry.completer.future;
}

/// Closes the dialog [context] is inside, completing its [showDialog] with
/// [result]. Does nothing outside a dialog, or for a dialog already closed.
void closeDialog<T>(BuildContext context, [T? result]) {
  final _DialogScope? scope =
      context.getInheritedWidgetOfExactType<_DialogScope>();
  scope?.close(result);
}

/// The dialog depth of [context]: 0 in the window itself, 1 inside the first
/// dialog, and so on. What a window-level handler registers with, so that a
/// dialog's own shortcuts keep working while the window's are silenced.
int modalDepthOf(BuildContext context) =>
    context.getInheritedWidgetOfExactType<_DialogScope>()?.depth ?? 0;

/// Where the dialogs of a window open: above [child], each over the dimmed
/// window.
///
/// [PopupScope] puts one in every window, under its popups; a test that
/// mounts a tree with neither adds its own.
final class DialogLayer extends StatefulWidget {
  const DialogLayer({super.key, required this.child});

  final Widget child;

  @override
  State<DialogLayer> createState() => _DialogLayerState();
}

final class _DialogEntry<T> {
  _DialogEntry({
    required this.builder,
    required this.dismissible,
    required this.barrierDismissible,
    required this.barrierColor,
  });

  final WidgetBuilder builder;
  final bool dismissible;
  final bool barrierDismissible;
  final Color? barrierColor;
  final Completer<T?> completer = Completer<T?>();
  final FocusScopeNode scope = FocusScopeNode(
    debugLabel: 'dialog',
    modal: true,
  );

  /// What had focus when the dialog opened, to go back to.
  FocusNode? previousFocus;

  void complete(Object? result) {
    if (completer.isCompleted) return;
    completer.complete(result is T ? result : null);
  }
}

final class _DialogLayerState extends State<DialogLayer> {
  final List<_DialogEntry<Object?>> _dialogs = <_DialogEntry<Object?>>[];
  BuildOwner? _owner;

  @override
  void initState() {
    super.initState();
    _owner = (context as Element).owner;
    // Below every dialog's own handlers, above the window's: Escape reaches
    // here when nothing focused in the dialog wanted it.
    _owner?.addWindowKeyHandler(_escape, modalDepth: 1 << 30);
  }

  @override
  void dispose() {
    _owner?.removeWindowKeyHandler(_escape);
    for (final _DialogEntry<Object?> entry in _dialogs) {
      entry.complete(null);
      entry.scope.dispose();
    }
    _dialogs.clear();
    _owner?.modalDepth = 0;
    super.dispose();
  }

  bool _escape(KeyEvent event) {
    if (_dialogs.isEmpty ||
        event is! KeyDownEvent ||
        event.logicalKey != logicalKeyEscape) {
      return false;
    }
    final _DialogEntry<Object?> top = _dialogs.last;
    if (!top.dismissible) return false;
    _close(top, null);
    return true;
  }

  void _open(_DialogEntry<Object?> entry) {
    entry.previousFocus = _owner?.focusManager.primaryFocus;
    setState(() => _dialogs.add(entry));
    _owner?.modalDepth = _dialogs.length;
  }

  void _close(_DialogEntry<Object?> entry, Object? result) {
    if (!_dialogs.contains(entry)) return;
    setState(() => _dialogs.remove(entry));
    _owner?.modalDepth = _dialogs.length;
    entry.complete(result);
    final FocusNode? previous = entry.previousFocus;
    scheduleMicrotask(() {
      entry.scope.dispose();
      if (previous != null && previous.canRequestFocus) {
        previous.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) => _DialogLayerScope(
        layer: this,
        child: Stack(
          fit: layout.StackFit.passthrough,
          children: <Widget>[
            widget.child,
            for (var i = 0; i < _dialogs.length; i++) _barrier(_dialogs[i], i),
          ],
        ),
      );

  Widget _barrier(_DialogEntry<Object?> entry, int index) => Positioned.fill(
        child: _DialogScope(
          depth: index + 1,
          close: (Object? result) => _close(entry, result),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: GestureDetector(
                  behavior: GestureHitTestBehavior.opaque,
                  onTap: () {
                    if (entry.barrierDismissible) _close(entry, null);
                  },
                  child: ColoredBox(
                    // WinUI's SmokeFillColorDefault, in both themes.
                    color: entry.barrierColor ?? const Color(0x4D000000),
                  ),
                ),
              ),
              Positioned.fill(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _DialogFocus(
                      scope: entry.scope,
                      child: Builder(builder: entry.builder),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

/// The dialog's modal focus scope, focused on its first control once the
/// dialog is built - as WinUI does.
final class _DialogFocus extends StatefulWidget {
  const _DialogFocus({required this.scope, required this.child});

  final FocusScopeNode scope;
  final Widget child;

  @override
  State<_DialogFocus> createState() => _DialogFocusState();
}

final class _DialogFocusState extends State<_DialogFocus> {
  @override
  void initState() {
    super.initState();
    widget.scope.requestFocusOnAttach();
  }

  @override
  Widget build(BuildContext context) =>
      FocusScope(node: widget.scope, child: widget.child);
}

final class _DialogLayerScope extends InheritedWidget {
  const _DialogLayerScope({required this.layer, required super.child});

  final _DialogLayerState layer;

  @override
  bool updateShouldNotify(_DialogLayerScope oldWidget) => false;
}

final class _DialogScope extends InheritedWidget {
  const _DialogScope({
    required this.depth,
    required this.close,
    required super.child,
  });

  final int depth;
  final void Function(Object? result) close;

  @override
  bool updateShouldNotify(_DialogScope oldWidget) => depth != oldWidget.depth;
}

/// The width WinUI gives a ContentDialog: at least 320, at most 548.
final BoxConstraints kDialogConstraints =
    BoxConstraints(minWidth: 320, maxWidth: 548);

/// [child] held to [kDialogConstraints].
final class DialogBody extends StatelessWidget {
  const DialogBody({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ConstrainedBox(constraints: kDialogConstraints, child: child);
}
