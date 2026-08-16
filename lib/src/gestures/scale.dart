/// Pinch to zoom, two-finger rotate, and the pan that comes with them.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../platform/input_events.dart';
import 'arena.dart';
import 'constants.dart';
import 'recognizer.dart';
import 'velocity_tracker.dart';

/// The moment a scale gesture was recognized.
final class ScaleStartDetails {
  const ScaleStartDetails({
    required this.focalPoint,
    required this.pointerCount,
    required this.timestamp,
  });

  /// The average of the contact points, in root coordinates. This is the point
  /// the transform must hold still, or the content slides out from under the
  /// fingers.
  final Offset focalPoint;

  final int pointerCount;
  final Duration timestamp;

  @override
  String toString() => 'ScaleStartDetails($focalPoint, $pointerCount pointers)';
}

/// One step of a scale gesture.
final class ScaleUpdateDetails {
  const ScaleUpdateDetails({
    required this.focalPoint,
    required this.focalPointDelta,
    required this.scale,
    required this.rotation,
    required this.pointerCount,
    required this.timestamp,
  });

  final Offset focalPoint;

  /// Movement of the focal point since the previous update: the pan component,
  /// which arrives free with a pinch and which every zoomable surface needs.
  final Offset focalPointDelta;

  /// The current span divided by the span at the baseline. 1.0 means unchanged.
  ///
  /// It is *relative to the baseline*, not cumulative across the gesture: see
  /// [ScaleGestureRecognizer] for when the baseline is re-taken and why a
  /// consumer must multiply rather than assign.
  final double scale;

  /// The angle between the two contact points now and at the baseline, in
  /// radians, positive clockwise in a y-down coordinate system.
  final double rotation;

  final int pointerCount;
  final Duration timestamp;

  @override
  String toString() => 'ScaleUpdateDetails(scale: '
      '${scale.toStringAsFixed(3)}, rotation: '
      '${rotation.toStringAsFixed(3)})';
}

/// The end of a scale gesture.
final class ScaleEndDetails {
  const ScaleEndDetails({
    required this.velocity,
    required this.pointerCount,
    required this.timestamp,
  });

  /// The focal point's velocity at release, for a two-finger pan that flings.
  final Velocity velocity;

  /// How many pointers were still down. Zero for an ordinary release.
  final int pointerCount;

  final Duration timestamp;

  @override
  String toString() => 'ScaleEndDetails($velocity)';
}

/// Recognizes two or more pointers changing their distance, angle or centre.
///
/// ## What is measured
///
/// Three quantities, all derived from the set of live contact points:
///
///  * **focal point** - their average. One finger has one, so a scale gesture
///    degenerates gracefully into a pan;
///  * **span** - the mean distance from the focal point, doubled for two
///    pointers so that it equals the distance between them. [ScaleUpdateDetails.scale]
///    is the current span over the baseline span;
///  * **rotation** - the change in the angle of the line between the first two
///    contacts. Undefined for one pointer, and reported as zero rather than
///    guessed.
///
/// ## The baseline, and why `scale` is relative
///
/// The baseline - span, focal point and angle - is re-taken **every time the
/// set of pointers changes**. It has to be: a third finger landing changes the
/// mean distance discontinuously, and a `scale` computed against the old
/// baseline would jump by a factor of two at the instant of contact, which
/// looks exactly like the image being yanked. Re-taking the baseline makes the
/// jump zero.
///
/// The price is that [ScaleUpdateDetails.scale] is relative to the current
/// baseline, so a consumer accumulates by multiplying at each start rather than
/// assigning. That is the same contract Flutter's `ScaleGestureRecognizer`
/// offers, for the same reason.
///
/// ## Claiming the arena
///
/// A second pointer landing is not yet a pinch - it is two fingers resting on a
/// list. The recognizer claims only once the span has changed by more than
/// [scaleSlopForKind] or the focal point has moved more than
/// [panSlopForKind], so a two-finger scroll still reaches the scrollable
/// underneath until the user actually starts to pinch.
final class ScaleGestureRecognizer extends GestureRecognizer
    with VelocityTrackingRecognizer {
  ScaleGestureRecognizer({
    super.arena,
    super.debugOwner,
    this.onStart,
    this.onUpdate,
    this.onEnd,
    double? slop,
  }) : _slopOverride = slop;

  /// The gesture was recognized.
  void Function(ScaleStartDetails details)? onStart;

  /// Span, angle or focal point changed.
  void Function(ScaleUpdateDetails details)? onUpdate;

  /// The last pointer of the gesture was lifted or taken away.
  void Function(ScaleEndDetails details)? onEnd;

  final double? _slopOverride;

  /// Live contact points, in the order they landed. Mutated in place on every
  /// move, so following a pinch allocates nothing per event.
  final Map<int, Offset> _pointers = <int, Offset>{};

  PointerKind _kind = PointerKind.touch;
  bool _accepted = false;
  bool _evidence = false;
  bool _started = false;

  double _baselineSpan = 0;
  Offset _baselineFocal = Offset.zero;
  double _baselineAngle = 0;
  bool _hasBaselineAngle = false;

  Offset _focalPoint = Offset.zero;
  Offset _lastReportedFocal = Offset.zero;
  double _span = 0;

  /// How many pointers are currently down on this recognizer.
  int get pointerCount => _pointers.length;

  /// Whether the gesture has been recognized and not yet ended.
  bool get isActive => _started;

  /// The average of the live contact points.
  Offset get focalPoint => _focalPoint;

  /// The current span over the baseline span; 1.0 with no baseline.
  double get scale => _baselineSpan > 0 ? _span / _baselineSpan : 1.0;

  double get _scaleSlop => _slopOverride ?? scaleSlopForKind(_kind);

  double get _panSlop => _slopOverride ?? panSlopForKind(_kind);

  @override
  bool addPointer(PointerDownEvent event) {
    _kind = event.kind;
    _pointers[event.pointerId] = event.logicalPosition;
    enterArena(event.pointerId);
    if (_accepted) {
      // A finger joining a pinch already in progress opens its own arena, and
      // an entry nobody ever resolves is an arena that never closes.
      resolvePointer(event.pointerId, GestureDisposition.accepted);
    }
    trackerFor(event.pointerId, event.kind)
        .addPosition(event.timestamp, event.logicalPosition);
    _takeBaseline();
    return true;
  }

  @override
  void handleEvent(PointerEvent event) {
    switch (event) {
      case PointerMoveEvent():
        if (!_pointers.containsKey(event.pointerId)) return;
        _pointers[event.pointerId] = event.logicalPosition;
        trackVelocity(event);
        _recompute();
        if (!_evidence && _shouldClaim()) {
          // Winning the arena is not the same as having seen a pinch. A lone
          // recognizer wins by walkover on the first press, and starting there
          // would fire onScaleStart for two fingers resting on a list.
          _evidence = true;
          _accepted = true;
          resolve(GestureDisposition.accepted);
        }
        _maybeStart(event.timestamp);
        if (!_started) return;
        final Offset delta = _focalPoint - _lastReportedFocal;
        _lastReportedFocal = _focalPoint;
        onUpdate?.call(
          ScaleUpdateDetails(
            focalPoint: _focalPoint,
            focalPointDelta: delta,
            scale: scale,
            rotation: _rotation(),
            pointerCount: _pointers.length,
            timestamp: event.timestamp,
          ),
        );
      case PointerUpEvent():
      case PointerCancelEvent():
        _removePointer(event, cancelled: event is PointerCancelEvent);
      case PointerDownEvent():
      case PointerScrollEvent():
        break;
    }
  }

  @override
  void acceptGesture(int pointer) {
    _accepted = true;
  }

  @override
  void rejectGesture(int pointer) {
    _pointers.remove(pointer);
    forgetVelocity(pointer);
    if (_pointers.isEmpty) {
      _started = false;
      _accepted = false;
      _evidence = false;
    } else {
      _takeBaseline();
    }
    super.rejectGesture(pointer);
  }

  void _removePointer(PointerEvent event, {required bool cancelled}) {
    final int pointer = event.pointerId;
    if (!_pointers.containsKey(pointer)) return;
    trackVelocity(event);
    final Velocity velocity = flingVelocityFor(pointer, event.timestamp);
    _pointers.remove(pointer);
    forgetVelocity(pointer);
    // Conceded before the seat is dropped: an entry that is discarded without
    // being resolved leaves its arena with a member that can never answer, and
    // the sweep would then award the gesture to a recognizer that has already
    // let go of the pointer.
    if (!_accepted) resolvePointer(pointer, GestureDisposition.rejected);
    stopTrackingPointer(pointer);

    if (_pointers.isNotEmpty) {
      // The gesture continues with fewer fingers; re-baseline so nothing jumps.
      _takeBaseline();
      return;
    }

    if (!_started) {
      _accepted = false;
      _evidence = false;
      resolve(GestureDisposition.rejected);
      return;
    }
    _started = false;
    _accepted = false;
    _evidence = false;
    onEnd?.call(
      ScaleEndDetails(
        velocity: cancelled ? Velocity.zero : velocity,
        pointerCount: 0,
        timestamp: event.timestamp,
      ),
    );
  }

  void _maybeStart(Duration timestamp) {
    if (_started || !_accepted || !_evidence) return;
    _started = true;
    _lastReportedFocal = _focalPoint;
    onStart?.call(
      ScaleStartDetails(
        focalPoint: _focalPoint,
        pointerCount: _pointers.length,
        timestamp: timestamp,
      ),
    );
  }

  bool _shouldClaim() {
    if (_pointers.length >= 2 && (_span - _baselineSpan).abs() > _scaleSlop) {
      return true;
    }
    return (_focalPoint - _baselineFocal).distance > _panSlop;
  }

  /// Re-reads span, focal point and angle as the new zero of the gesture.
  void _takeBaseline() {
    _recompute();
    _baselineSpan = _span;
    _baselineFocal = _focalPoint;
    _lastReportedFocal = _focalPoint;
    final double? angle = _currentAngle();
    _baselineAngle = angle ?? 0;
    _hasBaselineAngle = angle != null;
  }

  /// Recomputes the focal point and span in place, without allocating a list.
  void _recompute() {
    if (_pointers.isEmpty) {
      _focalPoint = Offset.zero;
      _span = 0;
      return;
    }
    var sumX = 0.0;
    var sumY = 0.0;
    for (final Offset position in _pointers.values) {
      sumX += position.dx;
      sumY += position.dy;
    }
    final int count = _pointers.length;
    _focalPoint = Offset(sumX / count, sumY / count);
    var totalDistance = 0.0;
    for (final Offset position in _pointers.values) {
      totalDistance += (position - _focalPoint).distance;
    }
    // Doubled so that two pointers report the distance between them, which is
    // the number a user would measure with a ruler and the one that makes
    // `scale` mean what it says.
    _span = count == 1 ? 0 : totalDistance / count * 2;
  }

  double? _currentAngle() {
    if (_pointers.length < 2) return null;
    final Iterator<Offset> it = _pointers.values.iterator;
    it.moveNext();
    final Offset first = it.current;
    it.moveNext();
    final Offset second = it.current;
    final Offset line = second - first;
    if (line.dx == 0 && line.dy == 0) return null;
    return math.atan2(line.dy, line.dx);
  }

  double _rotation() {
    if (!_hasBaselineAngle) return 0;
    final double? angle = _currentAngle();
    if (angle == null) return 0;
    var delta = angle - _baselineAngle;
    // Kept in (-pi, pi] so that crossing the branch cut of atan2 reports a
    // small rotation instead of a full turn in the opposite direction.
    while (delta > math.pi) {
      delta -= 2 * math.pi;
    }
    while (delta <= -math.pi) {
      delta += 2 * math.pi;
    }
    return delta;
  }

  @override
  void dispose() {
    _pointers.clear();
    _started = false;
    _accepted = false;
    _evidence = false;
    super.dispose();
  }
}
