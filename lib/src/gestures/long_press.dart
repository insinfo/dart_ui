/// Press and hold: the touch equivalent of a right click, and the start of
/// every drag-to-reorder.
library;

import '../geometry/offset.dart';
import '../platform/input_events.dart';
import '../scheduler/ui_dispatcher.dart';
import 'arena.dart';
import 'constants.dart';
import 'recognizer.dart';
import 'velocity_tracker.dart';

/// Where and when a long press began.
final class LongPressStartDetails {
  const LongPressStartDetails({
    required this.globalPosition,
    required this.timestamp,
    required this.kind,
  });

  final Offset globalPosition;
  final Duration timestamp;
  final PointerKind kind;

  @override
  String toString() => 'LongPressStartDetails($globalPosition)';
}

/// Movement after a long press has already been recognized.
final class LongPressMoveUpdateDetails {
  const LongPressMoveUpdateDetails({
    required this.globalPosition,
    required this.offsetFromOrigin,
    required this.timestamp,
  });

  final Offset globalPosition;

  /// How far the pointer has travelled since the press landed. This is the
  /// number a drag-to-reorder uses to place the item it picked up.
  final Offset offsetFromOrigin;

  final Duration timestamp;

  @override
  String toString() => 'LongPressMoveUpdateDetails($offsetFromOrigin)';
}

/// The release that ended a long press.
final class LongPressEndDetails {
  const LongPressEndDetails({
    required this.globalPosition,
    required this.velocity,
    required this.timestamp,
  });

  final Offset globalPosition;

  /// How fast the pointer was moving at release. Non-zero when the long press
  /// turned into a drag - a reorder that ends with a flick.
  final Velocity velocity;

  final Duration timestamp;

  @override
  String toString() => 'LongPressEndDetails($globalPosition, $velocity)';
}

/// Recognizes a press held still for [PrimaryPointerGestureRecognizer.deadline].
///
/// ## Two conditions, and both are load-bearing
///
/// **Time**: [kLongPressTimeout], 500 ms, armed on the press. **Stillness**:
/// the pointer must not travel more than the slop for its device before the
/// deadline. Dropping either one produces a gesture users hate:
///
///  * without the movement test, every scroll that starts slowly becomes a
///    long press, and the context menu opens in the middle of a swipe;
///  * without the time test, a long press is just a tap, and there is no way
///    to offer both on the same target.
///
/// After the press is recognized the movement test stops applying. That is not
/// laxness - it is the entire point of the gesture in a reorderable list: the
/// user holds to pick an item up, and then drags it, and the drag must not
/// cancel the hold. [onLongPressMoveUpdate] reports that phase.
///
/// ## The deadline needs a dispatcher, and only a dispatcher
///
/// A long press is the one gesture that fires with no event to trigger it -
/// the user does nothing, and 500 ms later something happens. That requires a
/// timer, so this recognizer requires a [UiDispatcher]. It never reads a clock:
/// the deadline is armed with [UiDispatcher.schedule] and every timestamp comes
/// from the events themselves, which is what lets the whole gesture be tested
/// against `ManualDispatcher`'s virtual clock with no tolerance for jitter.
final class LongPressGestureRecognizer extends PrimaryPointerGestureRecognizer
    with VelocityTrackingRecognizer {
  LongPressGestureRecognizer({
    required UiDispatcher dispatcher,
    super.arena,
    super.debugOwner,
    super.slop,
    super.button,
    Duration duration = kLongPressTimeout,
    this.onLongPressStart,
    this.onLongPress,
    this.onLongPressMoveUpdate,
    this.onLongPressEnd,
    this.onLongPressCancel,
  }) : super(dispatcher: dispatcher, deadline: duration);

  /// The press has been held long enough and won its arena.
  void Function(LongPressStartDetails details)? onLongPressStart;

  /// The zero-argument form of [onLongPressStart].
  void Function()? onLongPress;

  /// The pointer moved while the long press was active.
  void Function(LongPressMoveUpdateDetails details)? onLongPressMoveUpdate;

  /// The pointer was released after a recognized long press.
  void Function(LongPressEndDetails details)? onLongPressEnd;

  /// A press that could have become a long press will not.
  void Function()? onLongPressCancel;

  bool _deadlineElapsed = false;
  bool _started = false;

  /// Whether the press has been recognized and not yet released.
  bool get isActive => _started;

  @override
  void didPressDown(PointerDownEvent event) {
    _deadlineElapsed = false;
    _started = false;
    trackerFor(event.pointerId, event.kind)
        .addPosition(event.timestamp, event.logicalPosition);
  }

  @override
  void didExceedDeadline() {
    _deadlineElapsed = true;
    // Claiming, not merely becoming eligible: a press held for half a second
    // is conclusive evidence against every gesture that would have needed
    // movement, so there is nothing left to wait for.
    resolve(GestureDisposition.accepted);
    _maybeStart();
  }

  @override
  void acceptGesture(int pointer) {
    super.acceptGesture(pointer);
    // A lone recognizer wins its arena by walkover on the press itself, long
    // before the deadline. Winning is permission to fire, not a reason to.
    _maybeStart();
  }

  @override
  void handlePrimaryPointer(PointerEvent event) {
    switch (event) {
      case PointerMoveEvent():
        trackVelocity(event);
        if (_started) {
          onLongPressMoveUpdate?.call(
            LongPressMoveUpdateDetails(
              globalPosition: event.logicalPosition,
              offsetFromOrigin: event.logicalPosition - initialPosition,
              timestamp: event.timestamp,
            ),
          );
          return;
        }
        if (distanceFromOrigin(event.logicalPosition) > slop) {
          concede();
        }
      case PointerUpEvent():
        trackVelocity(event);
        if (!_started) {
          concede();
          return;
        }
        final int pointer = event.pointerId;
        final Velocity velocity = flingVelocityFor(pointer, event.timestamp);
        _started = false;
        forgetVelocity(pointer);
        stopTracking();
        onLongPressEnd?.call(
          LongPressEndDetails(
            globalPosition: event.logicalPosition,
            velocity: velocity,
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
      final bool wasCandidate = !_started;
      _started = false;
      _deadlineElapsed = false;
      forgetVelocity(pointer);
      if (wasCandidate) onLongPressCancel?.call();
    }
    super.rejectGesture(pointer);
  }

  void _maybeStart() {
    if (_started || !_deadlineElapsed || !hasWonArena) return;
    _started = true;
    onLongPressStart?.call(
      LongPressStartDetails(
        globalPosition: initialPosition,
        timestamp: initialTime,
        kind: pointerKind,
      ),
    );
    onLongPress?.call();
  }
}
