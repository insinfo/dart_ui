/// Routes platform pointer events through the render tree.
library;

import '../layout/render_box.dart';
import '../platform/input_events.dart';

/// A render node that consumes pointer events after hit testing.
///
/// Events are offered deepest-first and then bubble through ancestors in the
/// [HitTestPath]. Implement this on a [RenderBox] rather than on a widget: the
/// render tree owns the geometry used by hit testing.
abstract interface class PointerEventTarget {
  void handlePointerEvent(PointerEvent event);
}

/// Connects backend [PointerEvent]s to the render nodes under their position.
///
/// One path is retained and reset for every event so dispatch itself does not
/// allocate a list on the pointer hot path. The caller owns the root because
/// one router is normally paired with one window/render tree.
final class PointerRouter {
  final HitTestPath _path = HitTestPath();
  final Map<int, List<PointerEventTarget>> _captures =
      <int, List<PointerEventTarget>>{};

  /// Hit-tests [root] and dispatches [event] deepest-first.
  ///
  /// Returns whether any render node was hit. A hit does not imply that the
  /// path contained a [PointerEventTarget]. The root must have completed its
  /// first layout, as hit testing depends on current render geometry.
  bool route(PointerEvent event, {required RenderBox root}) {
    _path.reset();
    final bool hit = root.hitTest(event.logicalPosition, path: _path) != null;

    if (event is PointerDownEvent) {
      _cancelCapture(event.pointerId, event);
      final targets = <PointerEventTarget>[];
      _dispatchPath(event, captureInto: targets);
      if (targets.isNotEmpty) _captures[event.pointerId] = targets;
      return hit;
    }

    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _dispatchPath(event);
      final captured = _captures.remove(event.pointerId);
      if (captured != null) {
        final cancel = PointerCancelEvent(
          windowId: event.windowId,
          generation: event.generation,
          timestamp: event.timestamp,
          pointerId: event.pointerId,
          kind: event.kind,
          logicalPosition: event.logicalPosition,
        );
        for (final target in captured) {
          if (!_pathContains(target)) target.handlePointerEvent(cancel);
        }
      }
      return hit;
    }

    _dispatchPath(event);
    return hit;
  }

  void _dispatchPath(
    PointerEvent event, {
    List<PointerEventTarget>? captureInto,
  }) {
    for (int i = 0; i < _path.length; i++) {
      final RenderBox entry = _path[i];
      if (entry case final PointerEventTarget target) {
        target.handlePointerEvent(event);
        captureInto?.add(target);
      }
    }
  }

  void _cancelCapture(int pointerId, PointerEvent cause) {
    final captured = _captures.remove(pointerId);
    if (captured == null) return;
    final cancel = PointerCancelEvent(
      windowId: cause.windowId,
      generation: cause.generation,
      timestamp: cause.timestamp,
      pointerId: cause.pointerId,
      kind: cause.kind,
      logicalPosition: cause.logicalPosition,
    );
    for (final target in captured) {
      target.handlePointerEvent(cancel);
    }
  }

  bool _pathContains(PointerEventTarget target) {
    for (int i = 0; i < _path.length; i++) {
      if (identical(_path[i], target)) return true;
    }
    return false;
  }
}
