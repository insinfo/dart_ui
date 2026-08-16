/// Keyframe tracks: a value defined at several points, interpolated between.
///
/// Section 32.1 lists `keyframes` alongside `duration` and `curve`. The
/// difference is expressive rather than technical: a duration + curve says
/// "get from A to B like *this*", while a track says "be at these values at
/// these moments" - which is how a designer describes a bounce, a shake or a
/// three-colour pulse, and how an imported motion file is shaped.
///
/// ## Time is normalized, not absolute
///
/// A [KeyframeTrack]'s times are fractions of the whole animation, in
/// `[0, 1]`, not [Duration]s. That is a deliberate split of responsibilities:
/// the track owns *shape*, the [AnimationController] owns *duration*. The
/// payoff is that the same track can be retimed - slowed for a first-run
/// tutorial, shortened for reduced motion - without editing its data, and that
/// a track drops straight onto `controller.value` with no unit conversion in
/// between.
///
/// ## The curve belongs to the incoming segment
///
/// Each [Keyframe] carries the curve used to reach it *from the previous
/// keyframe*. The alternative - a curve per keyframe describing the segment
/// that leaves it - reads more naturally right up until you delete the last
/// keyframe and silently change the shape of a segment that no longer exists.
/// With the incoming convention, the first keyframe's curve is unused and says
/// so, and every segment's easing is stored on exactly one endpoint.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import 'animation.dart';
import 'curves.dart';

/// One `(time, value, incoming curve)` triple.
final class Keyframe<T> {
  const Keyframe({
    required this.time,
    required this.value,
    this.curve = Curves.linear,
  });

  /// Normalized position in `[0, 1]`.
  final double time;

  final T value;

  /// The easing applied over the segment *ending* at this keyframe. Ignored on
  /// the first keyframe of a track, which has no incoming segment.
  final Curve curve;

  @override
  String toString() => 'Keyframe($time -> $value)';
}

/// An ordered list of [Keyframe]s and the interpolation between them.
///
/// ## Validation, and why it throws
///
/// The constructor rejects an empty list, a time outside `[0, 1]`, a
/// non-finite time, and any pair of times that is not *strictly* increasing.
/// Sorting the list instead would be friendlier and wrong: a duplicated or
/// out-of-order time is never a formatting preference, it is a typo or a bad
/// export, and the visible symptom - one keyframe silently ignored, or a
/// segment of zero length that divides by zero - is far harder to trace back
/// than a constructor that names the offending pair. Section 6.6.
///
/// ## Declared limits
///
/// * Outside the range covered by the keyframes the track **holds**: it
///   returns the first value before the first time and the last value after
///   the last time. It does not extrapolate. A track that starts at `t = 0.3`
///   therefore reads as "wait, then move", which is what a staggered sequence
///   wants.
/// * Interpolation is pairwise between neighbours. No spline is fitted across
///   keyframes, so a track does not overshoot values its author did not write.
///   Overshoot is expressed by an overshooting [Curve] on a segment, where it
///   is visible in the data.
final class KeyframeTrack<T> {
  KeyframeTrack({
    required List<Keyframe<T>> keyframes,
    required this.lerp,
  }) : _keyframes = List<Keyframe<T>>.unmodifiable(keyframes) {
    if (_keyframes.isEmpty) {
      throw ArgumentError.value(
        keyframes,
        'keyframes',
        'a track needs at least one keyframe; an empty track has no value to '
            'report and would have to invent one',
      );
    }
    for (int i = 0; i < _keyframes.length; i++) {
      final double time = _keyframes[i].time;
      if (time.isNaN || !(time >= 0.0 && time <= 1.0)) {
        throw ArgumentError.value(
          time,
          'keyframes[$i].time',
          'keyframe times are normalized and must be in [0, 1]',
        );
      }
      if (i == 0) continue;
      final double previous = _keyframes[i - 1].time;
      if (time == previous) {
        throw ArgumentError(
          'keyframes[${i - 1}] and keyframes[$i] are both at t=$time. '
          'Duplicate times leave a zero-length segment with no defined '
          'progress inside it.',
        );
      }
      if (time < previous) {
        throw ArgumentError(
          'keyframes[$i] is at t=$time, before keyframes[${i - 1}] at '
          't=$previous. A track is not sorted for you: an out-of-order time '
          'is a data error, and reordering it would hide which entry is '
          'wrong.',
        );
      }
    }
  }

  final List<Keyframe<T>> _keyframes;

  /// How two neighbouring values are blended. Supplied rather than inferred so
  /// a track can be built over any type - including one this layer has never
  /// heard of - without a registry of interpolators.
  final T Function(T a, T b, double t) lerp;

  List<Keyframe<T>> get keyframes => _keyframes;

  /// The number of keyframes.
  int get length => _keyframes.length;

  /// The value at normalized time [t].
  ///
  /// [t] outside `[0, 1]` is clamped rather than rejected, unlike
  /// [Curve.transform]: a track is routinely read at `controller.value` for a
  /// controller with custom bounds, and the hold-at-the-ends behaviour is the
  /// defined answer there, not an arithmetic mistake.
  T valueAt(double t) {
    final double clamped = t.isNaN ? 0.0 : t.clamp(0.0, 1.0);
    final List<Keyframe<T>> frames = _keyframes;
    if (clamped <= frames.first.time) return frames.first.value;
    if (clamped >= frames.last.time) return frames.last.value;

    // Linear scan from the front. Tracks are short - a dozen keyframes is a
    // lot - so a binary search would cost more in branch misprediction than it
    // saves, and this allocates nothing (section 6.5).
    for (int i = 1; i < frames.length; i++) {
      final Keyframe<T> next = frames[i];
      if (clamped > next.time) continue;
      final Keyframe<T> previous = frames[i - 1];
      final double span = next.time - previous.time;
      final double local = (clamped - previous.time) / span;
      return lerp(previous.value, next.value, next.curve.transform(local));
    }
    return frames.last.value;
  }

  /// The value at the current progress of [animation].
  T evaluate(Animation<double> animation) => valueAt(animation.value);

  @override
  String toString() => 'KeyframeTrack(${_keyframes.length} keyframes)';
}

/// Convenience constructors for the types the framework already interpolates.
///
/// Free functions rather than factories on [KeyframeTrack] because a factory
/// on a generic class cannot narrow `T`, and pretending otherwise with a cast
/// is exactly the kind of quiet unsoundness this repository avoids.
abstract final class KeyframeTracks {
  static KeyframeTrack<double> ofDouble(List<Keyframe<double>> keyframes) =>
      KeyframeTrack<double>(
        keyframes: keyframes,
        lerp: DoubleTween.interpolate,
      );

  static KeyframeTrack<Offset> ofOffset(List<Keyframe<Offset>> keyframes) =>
      KeyframeTrack<Offset>(keyframes: keyframes, lerp: Offset.lerp);

  static KeyframeTrack<Size> ofSize(List<Keyframe<Size>> keyframes) =>
      KeyframeTrack<Size>(keyframes: keyframes, lerp: Size.lerp);

  static KeyframeTrack<Rect> ofRect(List<Keyframe<Rect>> keyframes) =>
      KeyframeTrack<Rect>(keyframes: keyframes, lerp: Rect.lerp);

  /// An `0xAARRGGBB` track. See [ColorTween] for why the interpolation is
  /// premultiplied.
  static KeyframeTrack<int> ofColor(List<Keyframe<int>> keyframes) =>
      KeyframeTrack<int>(keyframes: keyframes, lerp: ColorTween.interpolate);
}
