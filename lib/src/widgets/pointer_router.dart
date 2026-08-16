/// Routes platform pointer events through the render tree.
library;

import '../gestures/arena.dart';
import '../gestures/binding.dart';
import '../gestures/pointer_signal_resolver.dart';
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
  /// Creates a router, optionally sharing an existing [GestureBinding].
  ///
  /// One binding per router is the default, so two windows never arbitrate in
  /// the same arena - platform pointer ids are only unique within a window, and
  /// a mouse is pointer 0 everywhere.
  PointerRouter({GestureBinding? gestures})
      : _gestures = gestures ?? GestureBinding();

  final GestureBinding _gestures;
  final HitTestPath _path = HitTestPath();
  final Map<int, List<PointerEventTarget>> _captures =
      <int, List<PointerEventTarget>>{};

  /// Where gesture recognizers under this router negotiate.
  GestureArenaManager get gestureArena => _gestures.arena;

  /// Which node consumes a wheel notch under this router.
  PointerSignalResolver get signalResolver => _gestures.signalResolver;

  /// The binding this router publishes while it dispatches.
  GestureBinding get gestures => _gestures;

  /// Hit-tests [root] and dispatches [event] deepest-first.
  ///
  /// Returns whether the event reached anything: a hit-tested node, or the
  /// target holding this pointer's capture. The root must have completed its
  /// first layout, as hit testing depends on current render geometry.
  ///
  /// ## Arena phases
  ///
  /// Dispatch is only half of what an event does. The other half happens
  /// *after* every target has seen it, and it is what makes gesture
  /// disambiguation possible at all:
  ///
  ///   * a **press** closes the pointer's arena. Not before: a recognizer
  ///     deeper in the path has not been offered the press yet, and an arena
  ///     that resolved mid-dispatch would decide a negotiation somebody had
  ///     not entered;
  ///   * a **release** sweeps it, forcing a winner among whoever is left, so
  ///     two politely passive recognizers cannot deadlock and leave the user's
  ///     tap doing nothing;
  ///   * a **cancel** ends it with no winner at all. A lost capture is the
  ///     input going away, not the user finishing, and awarding the gesture to
  ///     somebody would fire an `onTap` for a press that was never released.
  ///     Leaving it unresolved is worse still: the arena, and every
  ///     recognizer's state with it, would outlive the gesture and swallow the
  ///     next press on the same pointer id;
  ///   * a **scroll signal** is resolved, awarding the wheel notch to the
  ///     first - innermost - candidate that registered for it.
  ///
  /// The whole call also publishes this router's [GestureBinding], so a
  /// recognizer created without one finds the right arena for the window the
  /// event came from.
  bool route(PointerEvent event, {required RenderBox root}) =>
      _gestures.dispatching(() => _routeAndSettle(event, root));

  bool _routeAndSettle(PointerEvent event, RenderBox root) {
    final bool reached = _dispatch(event, root);
    _settleArena(event);
    return reached;
  }

  void _settleArena(PointerEvent event) {
    switch (event) {
      case PointerDownEvent():
        _gestures.arena.close(event.pointerId);
      case PointerUpEvent():
        _gestures.arena.sweep(event.pointerId);
      case PointerCancelEvent():
        _gestures.arena.cancel(event.pointerId);
      case PointerScrollEvent():
        _gestures.signalResolver.resolve(event);
      case PointerMoveEvent():
        break;
    }
  }

  bool _dispatch(PointerEvent event, RenderBox root) {
    // ---- capture ----------------------------------------------------------
    //
    // A pointer that went down on a target belongs to that target until it is
    // released, wherever it travels in between. This is the rule that makes a
    // drag work at all: hit testing every move would hand the pointer to
    // whatever happens to be underneath, so dragging a slider thumb past the
    // edge of its track would silently stop moving it - and dragging across
    // another button would light that button up.
    //
    // While captured, the hit-test path is not consulted for this pointer at
    // all. Targets that need to know where the pointer *is* ask, using
    // RenderBox.globalToLocal; targets that need to know whether it is inside
    // them check their own bounds. Neither can be expressed by routing to
    // whoever is underneath.
    final List<PointerEventTarget>? captured = _captures[event.pointerId];
    if (captured != null && event is! PointerDownEvent) {
      _path.reset();
      for (final PointerEventTarget target in captured) {
        target.handlePointerEvent(event);
      }
      if (event is PointerUpEvent || event is PointerCancelEvent) {
        _captures.remove(event.pointerId);
      }
      return true;
    }

    _path.reset();
    final bool hit = root.hitTest(event.logicalPosition, path: _path) != null;

    if (event is PointerDownEvent) {
      _cancelCapture(event.pointerId, event);
      final targets = <PointerEventTarget>[];
      _dispatchPath(event, captureInto: targets);
      if (targets.isNotEmpty) _captures[event.pointerId] = targets;
      return hit;
    }

    // No capture: an up or a move is offered to whatever is under it, which is
    // the ordinary case of a pointer that never pressed anything.
    _dispatchPath(event);
    return hit;
  }

  /// Whether [pointerId] is currently held by a target.
  bool hasCapture(int pointerId) => _captures.containsKey(pointerId);

  /// The targets holding [pointerId], deepest first.
  List<PointerEventTarget> captureHolders(int pointerId) =>
      List<PointerEventTarget>.unmodifiable(
        _captures[pointerId] ?? const <PointerEventTarget>[],
      );

  /// Ends [target]'s hold on every pointer it captured.
  ///
  /// Section 27.4 calls this capture-lost, and it is what an unmounting
  /// control must call: a capture held by a node that is no longer in the tree
  /// swallows every subsequent event for that pointer, and the window stops
  /// responding to the mouse with nothing in the logs.
  void releaseCaptureFor(PointerEventTarget target) {
    for (final int pointerId in _captures.keys.toList()) {
      final List<PointerEventTarget> holders = _captures[pointerId]!;
      if (!holders.any((PointerEventTarget held) => identical(held, target))) {
        continue;
      }
      holders.removeWhere((PointerEventTarget held) => identical(held, target));
      if (holders.isEmpty) _captures.remove(pointerId);
    }
  }

  /// Drops every capture, for a window that lost focus or a tree teardown.
  void releaseAllCaptures() => _captures.clear();

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
    // The old gesture goes with the old capture. A press arriving on a pointer
    // that never released leaves an arena from the previous sequence, and the
    // new press would join members that are still answering for the old one.
    _gestures.arena.cancel(pointerId);
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
}
