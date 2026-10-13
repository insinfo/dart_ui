/// Flutter's `Listener`: raw pointer events, with Flutter's event shape.
///
/// [PointerListener] is this framework's own raw-pointer widget, and stays:
/// it hands over the backend's events as they are (window coordinates) and
/// claims the wheel for the innermost listener. [Listener] is the widget a
/// Flutter app writes, and differs in exactly the ways Flutter's does:
///
/// * every event arrives [PointerEvent.transformed]: `localPosition` is in
///   the listener's own box, `delta` is the move since the previous event of
///   that pointer, and `buttons` says what is held;
/// * a move with a button held is [onPointerMove]; a move with none is
///   [onPointerHover];
/// * a wheel notch is offered to every listener under the pointer through
///   [onPointerSignal], and arbitrating between them is the handler's job,
///   with the binding's `signalResolver`, as in Flutter.
///
/// ## Differences from Flutter
///
/// * The event classes are this framework's ([PointerDownEvent] and the
///   rest, from the backend), so Flutter's hover, signal and pan-zoom event
///   classes are names for them: [PointerHoverEvent] is a
///   [PointerMoveEvent], [PointerSignalEvent] is any [PointerEvent] (in
///   practice a [PointerScrollEvent]), and the three pan-zoom classes are
///   [PointerPanZoomEvent], whose `phase` says which.
/// * `HitTestBehavior.translucent` is hit like `opaque`; see
///   [GestureHitTestBehavior.translucent].
library;

import '../geometry/offset.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import 'element.dart';
import 'gesture_detector.dart';
import 'pointer_router.dart';
import 'widget.dart';

/// Flutter's `PointerHoverEvent`: a move with no button held.
typedef PointerHoverEvent = PointerMoveEvent;

/// Flutter's `PointerSignalEvent`: a wheel notch, in practice a
/// [PointerScrollEvent].
typedef PointerSignalEvent = PointerEvent;

/// Flutter's `PointerPanZoomStartEvent`: [PointerPanZoomEvent] with
/// [PanZoomPhase.start].
typedef PointerPanZoomStartEvent = PointerPanZoomEvent;

/// Flutter's `PointerPanZoomUpdateEvent`: [PointerPanZoomEvent] with
/// [PanZoomPhase.update].
typedef PointerPanZoomUpdateEvent = PointerPanZoomEvent;

/// Flutter's `PointerPanZoomEndEvent`: [PointerPanZoomEvent] with
/// [PanZoomPhase.end].
typedef PointerPanZoomEndEvent = PointerPanZoomEvent;

typedef PointerDownEventListener = void Function(PointerDownEvent event);
typedef PointerMoveEventListener = void Function(PointerMoveEvent event);
typedef PointerUpEventListener = void Function(PointerUpEvent event);
typedef PointerCancelEventListener = void Function(PointerCancelEvent event);
typedef PointerHoverEventListener = void Function(PointerHoverEvent event);
typedef PointerSignalEventListener = void Function(PointerSignalEvent event);
typedef PointerPanZoomStartEventListener = void Function(
    PointerPanZoomStartEvent event);
typedef PointerPanZoomUpdateEventListener = void Function(
    PointerPanZoomUpdateEvent event);
typedef PointerPanZoomEndEventListener = void Function(
    PointerPanZoomEndEvent event);

/// Calls back for the pointer events over its child - Flutter's `Listener`.
/// See the library comment.
class Listener extends SingleChildRenderObjectWidget {
  const Listener({
    super.key,
    this.onPointerDown,
    this.onPointerMove,
    this.onPointerUp,
    this.onPointerHover,
    this.onPointerCancel,
    this.onPointerPanZoomStart,
    this.onPointerPanZoomUpdate,
    this.onPointerPanZoomEnd,
    this.onPointerSignal,
    this.behavior = HitTestBehavior.deferToChild,
    super.child,
  });

  final PointerDownEventListener? onPointerDown;
  final PointerMoveEventListener? onPointerMove;
  final PointerUpEventListener? onPointerUp;
  final PointerHoverEventListener? onPointerHover;
  final PointerCancelEventListener? onPointerCancel;
  final PointerPanZoomStartEventListener? onPointerPanZoomStart;
  final PointerPanZoomUpdateEventListener? onPointerPanZoomUpdate;
  final PointerPanZoomEndEventListener? onPointerPanZoomEnd;
  final PointerSignalEventListener? onPointerSignal;

  /// Where this listener is hit; [HitTestBehavior.deferToChild] by default,
  /// as in Flutter.
  final HitTestBehavior behavior;

  @override
  RenderListener createRenderObject(BuildContext context) =>
      RenderListener(behavior: behavior).._apply(this);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderListener renderObject,
  ) {
    renderObject
      ..behavior = behavior
      .._apply(this);
  }
}

/// The render object of [Listener] - Flutter's `RenderPointerListener`
/// under a name that does not clash with this framework's own.
class RenderListener extends RenderSingleChildBox
    implements PointerEventTarget {
  RenderListener({this.behavior = HitTestBehavior.deferToChild, super.child});

  HitTestBehavior behavior;

  PointerDownEventListener? onPointerDown;
  PointerMoveEventListener? onPointerMove;
  PointerUpEventListener? onPointerUp;
  PointerHoverEventListener? onPointerHover;
  PointerCancelEventListener? onPointerCancel;
  PointerPanZoomStartEventListener? onPointerPanZoomStart;
  PointerPanZoomUpdateEventListener? onPointerPanZoomUpdate;
  PointerPanZoomEndEventListener? onPointerPanZoomEnd;
  PointerSignalEventListener? onPointerSignal;

  /// Buttons held per pointer, from the presses this listener saw.
  final Map<int, int> _buttons = <int, int>{};

  /// Where each pointer was at its previous event here, for `delta`.
  final Map<int, Offset> _last = <int, Offset>{};

  void _apply(Listener widget) {
    onPointerDown = widget.onPointerDown;
    onPointerMove = widget.onPointerMove;
    onPointerUp = widget.onPointerUp;
    onPointerHover = widget.onPointerHover;
    onPointerCancel = widget.onPointerCancel;
    onPointerPanZoomStart = widget.onPointerPanZoomStart;
    onPointerPanZoomUpdate = widget.onPointerPanZoomUpdate;
    onPointerPanZoomEnd = widget.onPointerPanZoomEnd;
    onPointerSignal = widget.onPointerSignal;
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
  bool hitTestSelf(Offset position) => behavior != HitTestBehavior.deferToChild;

  PointerEvent _local(PointerEvent event, {int? buttons}) {
    final Offset position = event.logicalPosition;
    final Offset? previous = _last[event.pointerId];
    final Offset delta = previous == null ? Offset.zero : position - previous;
    final Offset local = globalToLocal(position);
    final Offset localDelta = delta == Offset.zero
        ? Offset.zero
        : local - globalToLocal(position - delta);
    return event.transformed(
      localPosition: local,
      delta: delta,
      localDelta: localDelta,
      buttons: buttons,
    );
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    final int id = event.pointerId;
    switch (event) {
      case PointerDownEvent():
        final int held = (_buttons[id] ?? 0) | pointerButtonBit(event.button);
        _buttons[id] = held;
        final PointerEvent local = _local(event, buttons: held);
        _last[id] = event.logicalPosition;
        onPointerDown?.call(local as PointerDownEvent);
      case PointerMoveEvent():
        final int held = _buttons[id] ?? 0;
        final PointerEvent local = _local(event, buttons: held);
        _last[id] = event.logicalPosition;
        if (held != 0) {
          onPointerMove?.call(local as PointerMoveEvent);
        } else {
          onPointerHover?.call(local as PointerMoveEvent);
        }
      case PointerUpEvent():
        final int held = (_buttons[id] ?? 0) & ~pointerButtonBit(event.button);
        if (held == 0) {
          _buttons.remove(id);
        } else {
          _buttons[id] = held;
        }
        final PointerEvent local = _local(event, buttons: held);
        _last[id] = event.logicalPosition;
        onPointerUp?.call(local as PointerUpEvent);
      case PointerCancelEvent():
        _buttons.remove(id);
        final PointerEvent local = _local(event, buttons: 0);
        _last.remove(id);
        onPointerCancel?.call(local as PointerCancelEvent);
      case PointerScrollEvent():
        onPointerSignal?.call(_local(event, buttons: _buttons[id] ?? 0));
      case PointerPanZoomEvent():
        final PointerPanZoomEvent local =
            _local(event, buttons: 0) as PointerPanZoomEvent;
        switch (event.phase) {
          case PanZoomPhase.start:
            onPointerPanZoomStart?.call(local);
          case PanZoomPhase.update:
            onPointerPanZoomUpdate?.call(local);
          case PanZoomPhase.end:
            onPointerPanZoomEnd?.call(local);
        }
    }
  }

  @override
  void detach() {
    _buttons.clear();
    _last.clear();
    super.detach();
  }
}
