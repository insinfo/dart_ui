/// Raw pointer events for a widget that needs more than a gesture.
///
/// [GestureDetector] answers the question "what did the user *do*" - a tap, a
/// drag, a pinch - and for a button or a list that is the right question. Three
/// kinds of widget need the other one, "what did the pointer report", and until
/// this widget existed the only way to ask it was to write a render object:
///
///   * **the wheel.** A [PointerScrollEvent] is not a gesture and no recognizer
///     will ever see one. It is claimed from the [PointerSignalResolver] during
///     dispatch, which only a [PointerEventTarget] can do. A 3D viewer with no
///     scroll-wheel zoom is the concrete failure this closes: the framework
///     delivered the wheel to a scrollable, to a data grid and to the vector
///     canvas, each of which had written its own render object, and to nothing
///     else.
///   * **the middle and right buttons.** Every drag recognizer here declines a
///     press whose button is not the one it was built for, by design, and there
///     is no middle-button or right-button drag callback to ask for. Pan with
///     the right button - the near-universal 3D convention - is not expressible
///     as a gesture in this framework.
///   * **where the press landed.** `DragStartDetails.globalPosition` is where
///     the slop was crossed, deliberately. A widget that needs the pixel the
///     user actually pressed has to read the press itself.
///
/// The same three reasons are written out at length in the header of
/// `vector_editor/vector_canvas.dart`, which solved them by making its leaf a
/// [PointerEventTarget]. This widget is that solution, made reusable, so the
/// next application does not have to write a render object to read a wheel.
///
/// It arbitrates nothing. Anything wrapped in it that also wants gestures can
/// still put a [GestureDetector] inside or outside it; the events are offered
/// to every target on the hit path.
library;

import '../geometry/offset.dart';
import '../gestures/binding.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import 'element.dart';
import 'gesture_detector.dart' show GestureHitTestBehavior;
import 'pointer_router.dart';
import 'widget.dart';

/// Reports raw pointer events over its child.
///
/// Every callback is optional. Positions are in root (window) coordinates, the
/// way the backend reports them; use `RenderBox.globalToLocal` on the render
/// object of whatever needs them locally, or subtract the child's origin.
final class PointerListener extends SingleChildRenderObjectWidget {
  const PointerListener({
    super.key,
    this.onPointerDown,
    this.onPointerMove,
    this.onPointerUp,
    this.onPointerCancel,
    this.onPointerScroll,
    this.behavior = GestureHitTestBehavior.opaque,
    super.child,
  });

  final void Function(PointerDownEvent event)? onPointerDown;
  final void Function(PointerMoveEvent event)? onPointerMove;
  final void Function(PointerUpEvent event)? onPointerUp;
  final void Function(PointerCancelEvent event)? onPointerCancel;

  /// One wheel or trackpad report over this widget.
  ///
  /// Claimed through the [PointerSignalResolver], so a notch over this widget
  /// is not *also* applied by a scrollable that happens to contain it - which
  /// is what makes a zoomable view inside a scrolling page usable at all.
  final void Function(PointerScrollEvent event)? onPointerScroll;

  /// Defaults to [GestureHitTestBehavior.opaque], unlike [GestureDetector].
  ///
  /// A listener is nearly always wrapped around a surface the user is meant to
  /// press anywhere on - a canvas, a viewport - and `deferToChild` would make
  /// the wheel work over the model and do nothing over the empty margin beside
  /// it, which reads as an intermittent bug rather than as a hit-test rule.
  final GestureHitTestBehavior behavior;

  @override
  RenderPointerListener createRenderObject(BuildContext context) =>
      RenderPointerListener(behavior: behavior)
        ..onPointerDown = onPointerDown
        ..onPointerMove = onPointerMove
        ..onPointerUp = onPointerUp
        ..onPointerCancel = onPointerCancel
        ..onPointerScroll = onPointerScroll;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderPointerListener renderObject,
  ) {
    renderObject
      ..behavior = behavior
      ..onPointerDown = onPointerDown
      ..onPointerMove = onPointerMove
      ..onPointerUp = onPointerUp
      ..onPointerCancel = onPointerCancel
      ..onPointerScroll = onPointerScroll;
  }
}

/// The render-tree endpoint for [PointerListener].
final class RenderPointerListener extends RenderSingleChildBox
    implements PointerEventTarget {
  RenderPointerListener({
    this.behavior = GestureHitTestBehavior.opaque,
    super.child,
  });

  GestureHitTestBehavior behavior;

  void Function(PointerDownEvent event)? onPointerDown;
  void Function(PointerMoveEvent event)? onPointerMove;
  void Function(PointerUpEvent event)? onPointerUp;
  void Function(PointerCancelEvent event)? onPointerCancel;
  void Function(PointerScrollEvent event)? onPointerScroll;

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
    switch (event) {
      case PointerDownEvent():
        onPointerDown?.call(event);
      case PointerMoveEvent():
        onPointerMove?.call(event);
      case PointerUpEvent():
        onPointerUp?.call(event);
      case PointerCancelEvent():
        onPointerCancel?.call(event);
      case PointerScrollEvent():
        final void Function(PointerScrollEvent event)? handler =
            onPointerScroll;
        if (handler == null) return;
        // Registered rather than handled outright: the resolver awards the
        // notch to the innermost registrant once dispatch is over, so a nested
        // listener and the scrollable around it do not both act on it. With no
        // binding - a render object driven directly by a test - there is
        // nobody to arbitrate with, so it is applied at once.
        final GestureBinding? binding = GestureBinding.current;
        if (binding == null) {
          handler(event);
        } else {
          binding.signalResolver.register(event, handler);
        }
    }
  }
}
