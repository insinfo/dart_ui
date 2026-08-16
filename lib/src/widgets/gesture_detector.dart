/// The widget that turns pointer events into gestures.
///
/// It owns the recognizers that arbitrate taps, long presses, drags, pans and
/// scale gestures. Keeping that arbitration here means nested detectors make
/// one decision per pointer sequence instead of every node firing separately.
library;

import '../geometry/offset.dart';
import '../gestures/arena.dart';
import '../gestures/constants.dart';
import '../gestures/drag.dart';
import '../gestures/long_press.dart';
import '../gestures/recognizer.dart';
import '../gestures/scale.dart';
import '../gestures/tap.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import '../scheduler/ui_dispatcher.dart';
import 'element.dart';
import 'pointer_router.dart';
import 'widget.dart';

/// How a [GestureDetector] takes part in hit testing.
///
/// There is deliberately no `translucent` member. In Flutter it means "be hit,
/// but let the thing behind you be hit too", which needs a hit-test result that
/// can hold several independent branches. This repository's [HitTestPath] is a
/// single ancestor chain from one deepest hit, so a translucent member here
/// would be a name with no behaviour behind it.
enum GestureHitTestBehavior {
  /// Hittable only where the child is. A detector wrapped around a transparent
  /// subtree does not invent an interactive region.
  deferToChild,

  /// Hittable anywhere inside its own bounds, child or not.
  opaque,
}

/// Publishes the dispatcher a gesture's deadlines are armed on.
///
/// Only long press needs it, and only because a long press fires with no event
/// to trigger it. Install one above the tree - an application shell does this
/// once - or pass a dispatcher to the individual [GestureDetector].
final class GestureScope extends InheritedWidget {
  const GestureScope({
    super.key,
    required this.dispatcher,
    required super.child,
  });

  final UiDispatcher dispatcher;

  /// The nearest dispatcher, or null when none is installed.
  static UiDispatcher? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GestureScope>()?.dispatcher;

  @override
  bool updateShouldNotify(GestureScope oldWidget) =>
      !identical(dispatcher, oldWidget.dispatcher);
}

/// Recognizes gestures on its child.
///
/// Every callback is optional and a recognizer is only built for the ones that
/// are set, so a detector with a single `onTap` puts exactly one member in the
/// arena and a press on it resolves by walkover on the press itself.
///
/// Recognizers that share a detector share its arena entries per pointer, which
/// is what makes the combinations work: `onTap` together with
/// `onVerticalDragUpdate` gives a target that taps when tapped and scrolls when
/// dragged, decided by [kTouchSlop] rather than by which callback was declared
/// first.
final class GestureDetector extends SingleChildRenderObjectWidget {
  const GestureDetector({
    super.key,
    this.onTapDown,
    this.onTapUp,
    this.onTap,
    this.onDoubleTap,
    this.onTapCancel,
    this.onLongPress,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressEnd,
    this.onLongPressCancel,
    this.onHorizontalDragStart,
    this.onHorizontalDragUpdate,
    this.onHorizontalDragEnd,
    this.onHorizontalDragCancel,
    this.onVerticalDragStart,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
    this.onVerticalDragCancel,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
    this.onPanCancel,
    this.onScaleStart,
    this.onScaleUpdate,
    this.onScaleEnd,
    this.behavior = GestureHitTestBehavior.deferToChild,
    this.dispatcher,
    this.longPressDuration,
    super.child,
  });

  final void Function(TapDetails details)? onTapDown;
  final void Function(TapDetails details)? onTapUp;
  final void Function()? onTap;
  final void Function(TapDetails details)? onDoubleTap;
  final void Function()? onTapCancel;

  final void Function()? onLongPress;
  final void Function(LongPressStartDetails details)? onLongPressStart;
  final void Function(LongPressMoveUpdateDetails details)?
      onLongPressMoveUpdate;
  final void Function(LongPressEndDetails details)? onLongPressEnd;
  final void Function()? onLongPressCancel;

  final void Function(DragStartDetails details)? onHorizontalDragStart;
  final void Function(DragUpdateDetails details)? onHorizontalDragUpdate;
  final void Function(DragEndDetails details)? onHorizontalDragEnd;
  final void Function()? onHorizontalDragCancel;

  final void Function(DragStartDetails details)? onVerticalDragStart;
  final void Function(DragUpdateDetails details)? onVerticalDragUpdate;
  final void Function(DragEndDetails details)? onVerticalDragEnd;
  final void Function()? onVerticalDragCancel;

  final void Function(DragStartDetails details)? onPanStart;
  final void Function(DragUpdateDetails details)? onPanUpdate;
  final void Function(DragEndDetails details)? onPanEnd;
  final void Function()? onPanCancel;

  final void Function(ScaleStartDetails details)? onScaleStart;
  final void Function(ScaleUpdateDetails details)? onScaleUpdate;
  final void Function(ScaleEndDetails details)? onScaleEnd;

  final GestureHitTestBehavior behavior;

  /// Where a long press arms its deadline. Falls back to [GestureScope].
  final UiDispatcher? dispatcher;

  /// How long a press must be held. Defaults to [kLongPressTimeout].
  final Duration? longPressDuration;

  @override
  RenderGestureDetector createRenderObject(BuildContext context) {
    final RenderGestureDetector renderObject = RenderGestureDetector(
      behavior: behavior,
      dispatcher: dispatcher ?? GestureScope.of(context),
      longPressDuration: longPressDuration,
    );
    _apply(renderObject);
    return renderObject;
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderGestureDetector renderObject,
  ) {
    renderObject
      ..behavior = behavior
      ..dispatcher = dispatcher ?? GestureScope.of(context)
      ..longPressDuration = longPressDuration;
    _apply(renderObject);
  }

  void _apply(RenderGestureDetector renderObject) {
    renderObject.configure(
      onTapDown: onTapDown,
      onTapUp: onTapUp,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onTapCancel: onTapCancel,
      onLongPress: onLongPress,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      onLongPressEnd: onLongPressEnd,
      onLongPressCancel: onLongPressCancel,
      onHorizontalDragStart: onHorizontalDragStart,
      onHorizontalDragUpdate: onHorizontalDragUpdate,
      onHorizontalDragEnd: onHorizontalDragEnd,
      onHorizontalDragCancel: onHorizontalDragCancel,
      onVerticalDragStart: onVerticalDragStart,
      onVerticalDragUpdate: onVerticalDragUpdate,
      onVerticalDragEnd: onVerticalDragEnd,
      onVerticalDragCancel: onVerticalDragCancel,
      onPanStart: onPanStart,
      onPanUpdate: onPanUpdate,
      onPanEnd: onPanEnd,
      onPanCancel: onPanCancel,
      onScaleStart: onScaleStart,
      onScaleUpdate: onScaleUpdate,
      onScaleEnd: onScaleEnd,
    );
  }
}

/// The render-tree endpoint for [GestureDetector].
///
/// Owns the recognizers, forwards every event to all of them, and takes them
/// out of their arenas when it leaves the tree.
final class RenderGestureDetector extends RenderSingleChildBox
    implements PointerEventTarget {
  RenderGestureDetector({
    this.behavior = GestureHitTestBehavior.deferToChild,
    UiDispatcher? dispatcher,
    Duration? longPressDuration,
    GestureArenaManager? arena,
    super.child,
  })  : _dispatcher = dispatcher,
        _longPressDuration = longPressDuration,
        _arena = arena;

  /// How this detector takes part in hit testing.
  GestureHitTestBehavior behavior;

  UiDispatcher? _dispatcher;
  Duration? _longPressDuration;
  final GestureArenaManager? _arena;

  TapGestureRecognizer? _tap;
  LongPressGestureRecognizer? _longPress;
  DragGestureRecognizer? _horizontalDrag;
  DragGestureRecognizer? _verticalDrag;
  DragGestureRecognizer? _pan;
  ScaleGestureRecognizer? _scale;

  /// The recognizers to feed, rebuilt only when the callback set changes so
  /// that dispatching an event walks a list instead of building one.
  List<GestureRecognizer> _recognizers = const <GestureRecognizer>[];

  /// Whether a release at [globalPosition] still lands on this node.
  ///
  /// The pointer is captured on the press, so a release outside these bounds
  /// arrives here anyway - which is exactly how a user takes back a tap they
  /// changed their mind about.
  bool _containsGlobalPosition(Offset globalPosition) =>
      hasSize && size.contains(globalToLocal(globalPosition));

  UiDispatcher? get dispatcher => _dispatcher;

  set dispatcher(UiDispatcher? value) {
    if (identical(value, _dispatcher)) return;
    _dispatcher = value;
    // A long press recognizer is built around its dispatcher, so it cannot be
    // retargeted in place.
    _longPress?.dispose();
    _longPress = null;
  }

  Duration? get longPressDuration => _longPressDuration;

  set longPressDuration(Duration? value) {
    if (value == _longPressDuration) return;
    _longPressDuration = value;
    _longPress?.dispose();
    _longPress = null;
  }

  /// The recognizers currently installed, for tests and diagnostics.
  List<GestureRecognizer> get recognizers =>
      List<GestureRecognizer>.unmodifiable(_recognizers);

  /// Installs the callback set, creating and destroying recognizers to match.
  ///
  /// An existing recognizer keeps its identity when its callbacks change, so a
  /// rebuild in the middle of a drag does not drop the drag.
  void configure({
    void Function(TapDetails details)? onTapDown,
    void Function(TapDetails details)? onTapUp,
    void Function()? onTap,
    void Function(TapDetails details)? onDoubleTap,
    void Function()? onTapCancel,
    void Function()? onLongPress,
    void Function(LongPressStartDetails details)? onLongPressStart,
    void Function(LongPressMoveUpdateDetails details)? onLongPressMoveUpdate,
    void Function(LongPressEndDetails details)? onLongPressEnd,
    void Function()? onLongPressCancel,
    void Function(DragStartDetails details)? onHorizontalDragStart,
    void Function(DragUpdateDetails details)? onHorizontalDragUpdate,
    void Function(DragEndDetails details)? onHorizontalDragEnd,
    void Function()? onHorizontalDragCancel,
    void Function(DragStartDetails details)? onVerticalDragStart,
    void Function(DragUpdateDetails details)? onVerticalDragUpdate,
    void Function(DragEndDetails details)? onVerticalDragEnd,
    void Function()? onVerticalDragCancel,
    void Function(DragStartDetails details)? onPanStart,
    void Function(DragUpdateDetails details)? onPanUpdate,
    void Function(DragEndDetails details)? onPanEnd,
    void Function()? onPanCancel,
    void Function(ScaleStartDetails details)? onScaleStart,
    void Function(ScaleUpdateDetails details)? onScaleUpdate,
    void Function(ScaleEndDetails details)? onScaleEnd,
  }) {
    final bool wantsTap = onTapDown != null ||
        onTapUp != null ||
        onTap != null ||
        onDoubleTap != null ||
        onTapCancel != null;
    if (wantsTap) {
      final TapGestureRecognizer recognizer = _tap ??= TapGestureRecognizer(
        arena: _arena,
        debugOwner: this,
      )..targetContains = _containsGlobalPosition;
      recognizer
        ..onTapDown = onTapDown
        ..onTapUp = onTapUp
        ..onTap = onTap
        ..onDoubleTap = onDoubleTap
        ..onTapCancel = onTapCancel;
    } else if (_tap != null) {
      _tap!.dispose();
      _tap = null;
    }

    final bool wantsLongPress = onLongPress != null ||
        onLongPressStart != null ||
        onLongPressMoveUpdate != null ||
        onLongPressEnd != null ||
        onLongPressCancel != null;
    if (wantsLongPress) {
      final UiDispatcher? dispatcher = _dispatcher;
      if (dispatcher == null) {
        throw StateError(
          'A long press needs a UiDispatcher: it is the one gesture that '
          'fires with no event to trigger it, 500 ms after a press nobody '
          'moved. Pass GestureDetector(dispatcher: ...) or install a '
          'GestureScope above this widget. Reading a clock here instead '
          'would make the gesture untestable and the test suite '
          'intermittent.',
        );
      }
      final LongPressGestureRecognizer recognizer =
          _longPress ??= LongPressGestureRecognizer(
        dispatcher: dispatcher,
        arena: _arena,
        debugOwner: this,
        duration: _longPressDuration ?? kLongPressTimeout,
      )..targetContains = _containsGlobalPosition;
      recognizer
        ..onLongPress = onLongPress
        ..onLongPressStart = onLongPressStart
        ..onLongPressMoveUpdate = onLongPressMoveUpdate
        ..onLongPressEnd = onLongPressEnd
        ..onLongPressCancel = onLongPressCancel;
    } else if (_longPress != null) {
      _longPress!.dispose();
      _longPress = null;
    }

    _horizontalDrag = _syncDrag(
      _horizontalDrag,
      DragAxis.horizontal,
      onHorizontalDragStart,
      onHorizontalDragUpdate,
      onHorizontalDragEnd,
      onHorizontalDragCancel,
    );
    _verticalDrag = _syncDrag(
      _verticalDrag,
      DragAxis.vertical,
      onVerticalDragStart,
      onVerticalDragUpdate,
      onVerticalDragEnd,
      onVerticalDragCancel,
    );
    _pan = _syncDrag(
      _pan,
      DragAxis.free,
      onPanStart,
      onPanUpdate,
      onPanEnd,
      onPanCancel,
    );

    final bool wantsScale =
        onScaleStart != null || onScaleUpdate != null || onScaleEnd != null;
    if (wantsScale) {
      final ScaleGestureRecognizer recognizer =
          _scale ??= ScaleGestureRecognizer(arena: _arena, debugOwner: this);
      recognizer
        ..onStart = onScaleStart
        ..onUpdate = onScaleUpdate
        ..onEnd = onScaleEnd;
    } else if (_scale != null) {
      _scale!.dispose();
      _scale = null;
    }

    _rebuildRecognizerList();
  }

  DragGestureRecognizer? _syncDrag(
    DragGestureRecognizer? existing,
    DragAxis axis,
    void Function(DragStartDetails details)? onStart,
    void Function(DragUpdateDetails details)? onUpdate,
    void Function(DragEndDetails details)? onEnd,
    void Function()? onCancel,
  ) {
    final bool wanted = onStart != null ||
        onUpdate != null ||
        onEnd != null ||
        onCancel != null;
    if (!wanted) {
      existing?.dispose();
      return null;
    }
    final DragGestureRecognizer recognizer = existing ??
        DragGestureRecognizer(axis: axis, arena: _arena, debugOwner: this);
    return recognizer
      ..onStart = onStart
      ..onUpdate = onUpdate
      ..onEnd = onEnd
      ..onCancel = onCancel;
  }

  void _rebuildRecognizerList() {
    final list = <GestureRecognizer>[];
    // Order is the arena's tie-break within one detector. The tap goes first
    // so that a press with no movement resolves in its favour, and the drags
    // follow because they win by claiming rather than by order.
    if (_tap != null) list.add(_tap!);
    if (_longPress != null) list.add(_longPress!);
    if (_horizontalDrag != null) list.add(_horizontalDrag!);
    if (_verticalDrag != null) list.add(_verticalDrag!);
    if (_pan != null) list.add(_pan!);
    if (_scale != null) list.add(_scale!);
    _recognizers = list;
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  @override
  bool hitTestSelf(Offset position) =>
      behavior == GestureHitTestBehavior.opaque;

  @override
  void handlePointerEvent(PointerEvent event) {
    // Indexed, and over a list that is only rebuilt when the callback set
    // changes: this runs for every PointerMoveEvent the OS reports.
    final List<GestureRecognizer> recognizers = _recognizers;
    for (var i = 0; i < recognizers.length; i++) {
      recognizers[i].routeEvent(event);
    }
  }

  @override
  void detach() {
    // A recognizer holding an arena entry from a node that is no longer in the
    // tree keeps that arena unresolved forever, and an unresolved arena
    // swallows every later press on the same pointer.
    for (final GestureRecognizer recognizer in _recognizers) {
      recognizer.cancelPending();
    }
    super.detach();
  }

  /// Disposes every recognizer. For an owner tearing the tree down.
  void disposeRecognizers() {
    for (final GestureRecognizer recognizer in _recognizers) {
      recognizer.dispose();
    }
    _tap = null;
    _longPress = null;
    _horizontalDrag = null;
    _verticalDrag = null;
    _pan = null;
    _scale = null;
    _recognizers = const <GestureRecognizer>[];
  }
}
