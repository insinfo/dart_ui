/// Drag: one pointer, one axis or two, and the velocity a fling needs.
library;

import '../geometry/offset.dart';
import '../platform/input_events.dart';
import 'arena.dart';
import 'constants.dart';
import 'recognizer.dart';
import 'velocity_tracker.dart';

/// Which movement a [DragGestureRecognizer] is looking for.
enum DragAxis {
  /// Left and right only. Vertical movement is not evidence for it.
  horizontal,

  /// Up and down only.
  vertical,

  /// Any direction: a pan.
  free,
}

/// The moment a drag was recognized.
final class DragStartDetails {
  const DragStartDetails({
    required this.globalPosition,
    required this.timestamp,
    required this.kind,
  });

  /// Where the pointer was when the slop was crossed - **not** where it
  /// pressed. Starting the drag here is what stops the dragged object jumping
  /// by the slop distance the instant it is picked up.
  final Offset globalPosition;

  final Duration timestamp;
  final PointerKind kind;

  @override
  String toString() => 'DragStartDetails($globalPosition)';
}

/// One step of a drag in progress.
final class DragUpdateDetails {
  const DragUpdateDetails({
    required this.globalPosition,
    required this.delta,
    required this.primaryDelta,
    required this.timestamp,
  });

  final Offset globalPosition;

  /// Movement since the previous update, or since the start for the first one.
  final Offset delta;

  /// [delta] along the recognizer's axis, or null for a pan, which has none.
  final double? primaryDelta;

  final Duration timestamp;

  @override
  String toString() => 'DragUpdateDetails($delta)';
}

/// The release that ended a drag.
final class DragEndDetails {
  const DragEndDetails({
    required this.globalPosition,
    required this.velocity,
    required this.primaryVelocity,
    required this.timestamp,
  });

  final Offset globalPosition;

  /// How fast the pointer was moving at release, in logical pixels per second.
  ///
  /// Already filtered: below [kMinFlingVelocity] this is exactly
  /// [Velocity.zero], and above [kMaxFlingVelocity] it is clamped. Handing an
  /// unfiltered estimate to a momentum simulation is what makes a scroll view
  /// twitch when the user carefully stops before lifting a finger, and
  /// teleport when two samples land 1 ms apart.
  final Velocity velocity;

  /// [velocity] along the recognizer's axis, or null for a pan.
  final double? primaryVelocity;

  final Duration timestamp;

  @override
  String toString() => 'DragEndDetails($velocity)';
}

/// Recognizes a pointer being dragged along [axis].
///
/// ## The threshold, and why a drag and a tap can share a target
///
/// A `PointerDownEvent` is not a tap and not a drag; it is both, and stays both
/// until the movement decides. The decision is the slop - [kTouchSlop] for a
/// finger, [kPrecisePointerSlop] for a mouse or stylus, twice that for a pan -
/// and this recognizer only claims its arena once the pointer has crossed it.
///
/// Both directions of that rule matter:
///
///  * **crossing the slop claims the gesture.** The tap sharing the arena is
///    rejected at that instant, so the button under the finger does not fire
///    when the user was scrolling;
///  * **releasing without crossing it concedes the gesture.** A press and a
///    release in the same spot is not a drag however long it lasted, so this
///    recognizer rejects itself on the release and lets the tap win by
///    walkover. Without that, a tap on a scrollable list would sit in a
///    stalemate until the sweep, and any drag callback would fire for a press
///    that never moved.
///
/// An axis recognizer measures only its own axis, so a purely vertical swipe
/// never satisfies a horizontal one - which is what lets a horizontal carousel
/// live inside a vertical list without stealing its scrolls. A [DragAxis.free]
/// pan has no axis to be unconvinced by, and so is held to
/// [panSlopForKind] - twice the linear threshold - instead.
class DragGestureRecognizer extends PrimaryPointerGestureRecognizer
    with VelocityTrackingRecognizer {
  DragGestureRecognizer({
    required this.axis,
    super.arena,
    super.debugOwner,
    super.slop,
    super.button,
    this.onStart,
    this.onUpdate,
    this.onEnd,
    this.onCancel,
  });

  /// Which movement counts as this drag.
  final DragAxis axis;

  /// The slop was crossed and this recognizer won.
  void Function(DragStartDetails details)? onStart;

  /// The pointer moved while the drag was active.
  void Function(DragUpdateDetails details)? onUpdate;

  /// The pointer was released. Carries the velocity a fling is started from.
  void Function(DragEndDetails details)? onEnd;

  /// A started drag was taken away - a cancelled pointer, a lost capture.
  void Function()? onCancel;

  bool _slopCrossed = false;
  bool _started = false;
  Offset _lastPosition = Offset.zero;
  Offset _lastReported = Offset.zero;
  Duration _lastTime = Duration.zero;

  /// Whether the drag has been recognized and not yet ended.
  bool get isActive => _started;

  @override
  double get slop =>
      slopOverride ??
      (axis == DragAxis.free
          ? panSlopForKind(pointerKind)
          : touchSlopForKind(pointerKind));

  @override
  void didPressDown(PointerDownEvent event) {
    _slopCrossed = false;
    _started = false;
    _lastPosition = event.logicalPosition;
    _lastReported = event.logicalPosition;
    _lastTime = event.timestamp;
    trackerFor(event.pointerId, event.kind)
        .addPosition(event.timestamp, event.logicalPosition);
  }

  @override
  void acceptGesture(int pointer) {
    super.acceptGesture(pointer);
    // Winning is not starting. A lone drag recognizer wins by walkover on the
    // press, and a drag that fired onStart there would pick an item up the
    // instant it was touched.
    _maybeStart();
  }

  @override
  void handlePrimaryPointer(PointerEvent event) {
    switch (event) {
      case PointerMoveEvent():
        trackVelocity(event);
        _lastPosition = event.logicalPosition;
        _lastTime = event.timestamp;
        if (_started) {
          final Offset delta = event.logicalPosition - _lastReported;
          if (delta == Offset.zero) return;
          _lastReported = event.logicalPosition;
          onUpdate?.call(
            DragUpdateDetails(
              globalPosition: event.logicalPosition,
              delta: delta,
              primaryDelta: _primary(delta),
              timestamp: event.timestamp,
            ),
          );
          return;
        }
        if (!_slopCrossed && _exceedsSlop(event.logicalPosition)) {
          _slopCrossed = true;
          resolve(GestureDisposition.accepted);
          _maybeStart();
        }
      case PointerUpEvent():
        trackVelocity(event);
        if (!_started) {
          // Never a drag. Conceding is what lets a tap on the same node win.
          concede();
          return;
        }
        final int pointer = event.pointerId;
        final Velocity velocity = flingVelocityFor(pointer, event.timestamp);
        _started = false;
        _slopCrossed = false;
        forgetVelocity(pointer);
        stopTracking();
        onEnd?.call(
          DragEndDetails(
            globalPosition: event.logicalPosition,
            velocity: velocity,
            primaryVelocity: _primary(velocity.pixelsPerSecond),
            timestamp: event.timestamp,
          ),
        );
      case PointerCancelEvent():
        concede();
      case PointerDownEvent():
      case PointerScrollEvent():
        break;
    }
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer == primaryPointer) {
      final bool wasActive = _started;
      _started = false;
      _slopCrossed = false;
      forgetVelocity(pointer);
      if (wasActive) onCancel?.call();
    }
    super.rejectGesture(pointer);
  }

  void _maybeStart() {
    if (_started || !_slopCrossed || !hasWonArena) return;
    _started = true;
    _lastReported = _lastPosition;
    onStart?.call(
      DragStartDetails(
        globalPosition: _lastPosition,
        timestamp: _lastTime,
        kind: pointerKind,
      ),
    );
  }

  bool _exceedsSlop(Offset position) {
    final Offset moved = position - initialPosition;
    return switch (axis) {
      DragAxis.horizontal => moved.dx.abs() > slop,
      DragAxis.vertical => moved.dy.abs() > slop,
      DragAxis.free => moved.distance > slop,
    };
  }

  double? _primary(Offset value) => switch (axis) {
        DragAxis.horizontal => value.dx,
        DragAxis.vertical => value.dy,
        DragAxis.free => null,
      };
}

/// A drag that only answers to left-and-right movement.
final class HorizontalDragGestureRecognizer extends DragGestureRecognizer {
  HorizontalDragGestureRecognizer({
    super.arena,
    super.debugOwner,
    super.slop,
    super.button,
    super.onStart,
    super.onUpdate,
    super.onEnd,
    super.onCancel,
  }) : super(axis: DragAxis.horizontal);
}

/// A drag that only answers to up-and-down movement.
///
/// This is the one a scrollable list uses, and the one whose
/// [DragEndDetails.velocity] `ScrollPosition.fling` has been waiting for.
final class VerticalDragGestureRecognizer extends DragGestureRecognizer {
  VerticalDragGestureRecognizer({
    super.arena,
    super.debugOwner,
    super.slop,
    super.button,
    super.onStart,
    super.onUpdate,
    super.onEnd,
    super.onCancel,
  }) : super(axis: DragAxis.vertical);
}

/// A drag in any direction: dragging a card, panning a canvas.
final class PanGestureRecognizer extends DragGestureRecognizer {
  PanGestureRecognizer({
    super.arena,
    super.debugOwner,
    super.slop,
    super.button,
    super.onStart,
    super.onUpdate,
    super.onEnd,
    super.onCancel,
  }) : super(axis: DragAxis.free);
}
