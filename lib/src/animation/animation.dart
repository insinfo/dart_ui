/// Animatable values: the observable, the driver, and the interpolators.
///
/// Section 32.1 names `duration`, `curve`, `implicit` and `explicit` as
/// animation types. This file is the explicit half: an [AnimationController]
/// driven by the frame clock produces a normalized `double`, a [Curve] shapes
/// it, and a [Tween] maps it onto whatever type the property actually holds.
///
/// The split matters. The controller knows about time and nothing about
/// colour; the tween knows about colour and nothing about time. That is why a
/// spring, a keyframe track and a plain duration can all drive the same tween
/// without any of them knowing the others exist.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import 'clock.dart';
import 'curves.dart';

/// Where an animation is in its life.
///
/// Four states, and the pair of them that means "at rest" carries *which* end
/// it is resting at. A single `stopped` state would force every listener to
/// re-read the value to find out whether a fade-out had finished or a fade-in
/// had, which is the check everybody forgets.
enum AnimationStatus {
  /// At rest at the lower bound. The starting state of a fresh controller.
  dismissed,

  /// Running towards the upper bound.
  forward,

  /// Running towards the lower bound.
  reverse,

  /// At rest at the upper bound.
  completed,
}

/// A value that changes over time and says when it changed.
///
/// Deliberately *not* a `Stream`. A stream delivers asynchronously, and an
/// animation value that arrives one microtask after the frame that produced it
/// is a frame of latency on every transition. Listeners here are called
/// synchronously, inside the frame, before layout runs.
abstract class Animation<T> {
  /// The current value.
  T get value;

  /// Where this animation is in its life.
  AnimationStatus get status;

  /// Whether frames are still being consumed.
  bool get isAnimating;

  /// Called after every change to [value].
  void addListener(void Function() listener);

  bool removeListener(void Function() listener);

  /// Called after every change to [status].
  void addStatusListener(void Function(AnimationStatus status) listener);

  bool removeStatusListener(void Function(AnimationStatus status) listener);
}

/// Listener bookkeeping shared by every animation in this file.
///
/// Notification iterates over a *copy* of the listener list, because a
/// listener removing itself - the normal way a one-shot reaction unsubscribes
/// - would otherwise skip its neighbour. The copy is only made when there is
/// at least one listener, so an animation nobody watches costs nothing per
/// frame (section 6.5).
mixin _AnimationListeners on Object {
  final List<void Function()> _listeners = <void Function()>[];
  final List<void Function(AnimationStatus)> _statusListeners =
      <void Function(AnimationStatus)>[];

  void addListener(void Function() listener) => _listeners.add(listener);

  bool removeListener(void Function() listener) => _listeners.remove(listener);

  void addStatusListener(void Function(AnimationStatus status) listener) =>
      _statusListeners.add(listener);

  bool removeStatusListener(void Function(AnimationStatus status) listener) =>
      _statusListeners.remove(listener);

  void notifyListeners() {
    if (_listeners.isEmpty) return;
    for (final void Function() listener
        in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void notifyStatusListeners(AnimationStatus status) {
    if (_statusListeners.isEmpty) return;
    for (final void Function(AnimationStatus) listener
        in List<void Function(AnimationStatus)>.of(_statusListeners)) {
      listener(status);
    }
  }
}

/// Drives a `double` from [lowerBound] to [upperBound] over [duration].
///
/// ## Why elapsed time is stored in microseconds, not as a fraction
///
/// The obvious implementation accumulates `value += delta / duration` each
/// frame. It drifts: ten frames of `0.1` sum to `0.9999999999999999`, an
/// animation "completes" one ulp short of its target, and the status never
/// flips. Here the controller instead accumulates *elapsed microseconds* as a
/// double and derives the value from it. Every frame's contribution is an
/// exact integer (times [speed]), sums of integers below 2^53 are exact, and
/// the final division lands on exactly `1.0`. That is what lets a test assert
/// `controller.value == 1.0` rather than `closeTo(1.0, 1e-9)`.
///
/// ## Declared limits
///
/// * The controller is linear in time. Curves are applied *on top* by
///   [CurvedAnimation] rather than inside, so the same controller can drive
///   two properties with different curves - which it cannot if the curve is
///   baked into the driver.
/// * It does not own a timer. It registers with an [AnimationClock] and is
///   advanced once per frame; see `clock.dart` for why.
/// * [speed] scales the *rate*, not the duration, so changing it mid-flight
///   does not teleport the value.
final class AnimationController extends Animation<double>
    with _AnimationListeners
    implements AnimationTicker {
  AnimationController({
    required this.clock,
    this.duration = const Duration(milliseconds: 300),
    this.lowerBound = 0.0,
    this.upperBound = 1.0,
    double? initialValue,
    double speed = 1.0,
  }) : _speed = speed {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(
        duration,
        'duration',
        'must be strictly positive; a zero-duration animation is an '
            'assignment, and pretending otherwise would divide by zero',
      );
    }
    if (!(upperBound > lowerBound)) {
      throw ArgumentError(
        'upperBound ($upperBound) must be strictly greater than lowerBound '
        '($lowerBound)',
      );
    }
    if (!(speed > 0.0)) {
      throw ArgumentError.value(
        speed,
        'speed',
        'must be strictly positive; run an animation backwards with '
            'reverse(), not with a negative speed',
      );
    }
    _durationMicros = duration.inMicroseconds.toDouble();
    if (initialValue != null) {
      _elapsedMicros = _elapsedForValue(initialValue);
    }
    _status = value >= upperBound
        ? AnimationStatus.completed
        : AnimationStatus.dismissed;
    clock.addTicker(this);
  }

  /// The clock this controller is registered with.
  final AnimationClock clock;

  /// How long a full sweep from [lowerBound] to [upperBound] takes at
  /// [speed] 1.
  final Duration duration;

  final double lowerBound;
  final double upperBound;

  late final double _durationMicros;

  double _elapsedMicros = 0.0;
  double _speed;
  bool _running = false;
  bool _disposed = false;
  bool _forward = true;
  bool _repeating = false;
  bool _repeatReverses = false;
  Duration? _origin;
  AnimationStatus _status = AnimationStatus.dismissed;

  /// A multiplier on the rate of time. `2.0` finishes in half the wall time.
  double get speed => _speed;

  set speed(double value) {
    if (!(value > 0.0)) {
      throw ArgumentError.value(value, 'speed', 'must be strictly positive');
    }
    _speed = value;
  }

  @override
  double get value {
    final double t = _durationMicros == 0
        ? 1.0
        : (_elapsedMicros / _durationMicros).clamp(0.0, 1.0);
    if (t == 0.0) return lowerBound;
    if (t == 1.0) return upperBound;
    return lowerBound * (1.0 - t) + upperBound * t;
  }

  /// Sets the value directly, stopping any run in progress.
  ///
  /// The escape hatch for a drag: the finger, not the clock, owns the value
  /// while it is down.
  set value(double newValue) {
    _throwIfDisposed();
    _running = false;
    _repeating = false;
    _origin = null;
    _elapsedMicros = _elapsedForValue(newValue);
    _emitValue();
    _settleStatusAtRest();
  }

  @override
  AnimationStatus get status => _status;

  @override
  bool get isAnimating => _running && !_disposed;

  @override
  bool get isTicking => isAnimating;

  /// The normalized progress, `0` at [lowerBound] and `1` at [upperBound].
  double get progress => _durationMicros == 0
      ? 1.0
      : (_elapsedMicros / _durationMicros).clamp(0.0, 1.0);

  /// Runs towards [upperBound].
  ///
  /// Optionally jumps to [from] first. Already being at the upper bound is not
  /// an error: the controller completes on the next tick without moving, which
  /// is what a hover that re-fires needs.
  void forward({double? from}) {
    _throwIfDisposed();
    if (from != null) _elapsedMicros = _elapsedForValue(from);
    _forward = true;
    _repeating = false;
    _start(AnimationStatus.forward);
  }

  /// Runs towards [lowerBound].
  void reverse({double? from}) {
    _throwIfDisposed();
    if (from != null) _elapsedMicros = _elapsedForValue(from);
    _forward = false;
    _repeating = false;
    _start(AnimationStatus.reverse);
  }

  /// Runs forever.
  ///
  /// With [reverses] false the value snaps back to [lowerBound] at the end of
  /// each period (a spinner); with [reverses] true it ping-pongs (a pulse).
  /// A repeating controller never reports [AnimationStatus.completed], because
  /// it never completes - a status listener waiting for that would wait
  /// forever, so [repeat] is documented as the one mode where that listener is
  /// the wrong tool.
  void repeat({bool reverses = false}) {
    _throwIfDisposed();
    _repeating = true;
    _repeatReverses = reverses;
    _forward = true;
    _start(AnimationStatus.forward);
  }

  /// Stops consuming frames, leaving [value] and [status] exactly as they are.
  ///
  /// The status is *not* reset to a "stopped" value. A controller halted at
  /// 0.4 on its way up is still logically going forward, and that is what a
  /// later `forward()` resumes; erasing the direction here would lose the only
  /// information a resume needs.
  void stop() {
    _running = false;
    _repeating = false;
    _origin = null;
  }

  /// Stops and returns to [lowerBound] and [AnimationStatus.dismissed].
  void reset() {
    _throwIfDisposed();
    stop();
    _elapsedMicros = 0.0;
    _emitValue();
    _emitStatus(AnimationStatus.dismissed);
  }

  /// Unregisters from the clock. Using the controller afterwards throws.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _running = false;
    clock.removeTicker(this);
  }

  @override
  void tick(Duration timestamp) {
    if (!_running || _disposed) return;
    final Duration origin = _origin ??= timestamp;
    final double stepMicros =
        (timestamp - origin).inMicroseconds.toDouble() * _speed;
    // The origin is re-based every tick so `stepMicros` is the *delta* since
    // the previous frame. Re-basing rather than integrating from the start is
    // what makes `speed` changeable mid-flight without a discontinuity.
    _origin = timestamp;
    if (stepMicros == 0.0) return;
    _advanceBy(stepMicros);
  }

  void _advanceBy(double stepMicros) {
    final double before = value;
    _elapsedMicros += _forward ? stepMicros : -stepMicros;

    if (_repeating) {
      _wrapForRepeat();
      if (value != before) _emitValue();
      return;
    }

    if (_forward && _elapsedMicros >= _durationMicros) {
      _elapsedMicros = _durationMicros;
      _running = false;
      if (value != before) _emitValue();
      _emitStatus(AnimationStatus.completed);
      return;
    }
    if (!_forward && _elapsedMicros <= 0.0) {
      _elapsedMicros = 0.0;
      _running = false;
      if (value != before) _emitValue();
      _emitStatus(AnimationStatus.dismissed);
      return;
    }
    if (value != before) _emitValue();
  }

  /// Folds an overrun back into `[0, duration]`.
  ///
  /// A `while` rather than a modulo because [_repeatReverses] flips direction
  /// on every fold, and a single modulo cannot tell you how many flips that
  /// was. In practice the loop runs once; it runs more only if a frame was
  /// longer than the whole period, which a repeat must survive rather than
  /// desynchronize on.
  void _wrapForRepeat() {
    while (true) {
      if (_elapsedMicros > _durationMicros) {
        if (_repeatReverses) {
          _elapsedMicros = 2 * _durationMicros - _elapsedMicros;
          _forward = false;
          _emitStatus(AnimationStatus.reverse);
        } else {
          _elapsedMicros -= _durationMicros;
        }
        continue;
      }
      if (_elapsedMicros < 0.0) {
        if (_repeatReverses) {
          _elapsedMicros = -_elapsedMicros;
          _forward = true;
          _emitStatus(AnimationStatus.forward);
        } else {
          _elapsedMicros += _durationMicros;
        }
        continue;
      }
      return;
    }
  }

  void _start(AnimationStatus status) {
    _running = true;
    // Dropped so the first tick after starting establishes a fresh origin and
    // consumes zero time. A controller started between two frames must not be
    // charged for the part of the frame it was not alive for.
    _origin = null;
    _emitStatus(status);
    clock.requestFrame();
  }

  void _settleStatusAtRest() {
    if (_elapsedMicros <= 0.0) {
      _emitStatus(AnimationStatus.dismissed);
    } else if (_elapsedMicros >= _durationMicros) {
      _emitStatus(AnimationStatus.completed);
    }
  }

  double _elapsedForValue(double target) {
    final double clamped = target.clamp(lowerBound, upperBound);
    final double span = upperBound - lowerBound;
    return (clamped - lowerBound) / span * _durationMicros;
  }

  void _emitValue() => notifyListeners();

  void _emitStatus(AnimationStatus status) {
    if (_status == status) return;
    _status = status;
    notifyStatusListeners(status);
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('AnimationController was used after dispose().');
    }
  }

  @override
  String toString() =>
      'AnimationController(value: $value, status: ${_status.name})';
}

/// A `double` animation with a [Curve] applied on top of a parent.
///
/// Separate from the controller on purpose: two properties driven by one
/// controller can use different curves, which is impossible if the curve lives
/// in the driver.
final class CurvedAnimation extends Animation<double> with _AnimationListeners {
  CurvedAnimation({
    required this.parent,
    required this.curve,
    Curve? reverseCurve,
  }) : reverseCurve = reverseCurve ?? curve {
    parent.addListener(notifyListeners);
    parent.addStatusListener(notifyStatusListeners);
  }

  final Animation<double> parent;
  final Curve curve;

  /// The curve used while the parent runs backwards.
  ///
  /// A transition that eases *out* on the way in should ease *in* on the way
  /// back, or the two directions feel like different animations.
  final Curve reverseCurve;

  @override
  double get value {
    final double t = parent.value;
    final Curve active =
        parent.status == AnimationStatus.reverse ? reverseCurve : curve;
    return active.transform(t.clamp(0.0, 1.0));
  }

  @override
  AnimationStatus get status => parent.status;

  @override
  bool get isAnimating => parent.isAnimating;

  /// Detaches from the parent. Required, or the parent keeps this alive and
  /// keeps notifying a listener nobody reads.
  void dispose() {
    parent.removeListener(notifyListeners);
    parent.removeStatusListener(notifyStatusListeners);
  }
}

/// Maps normalized progress onto a value of type [T].
///
/// [transform] answers the endpoints without interpolating, so an animation
/// that runs to completion lands on exactly the object it declared as [end] -
/// including for types where interpolation cannot be exact, such as a rounded
/// integer colour channel.
abstract base class Tween<T> {
  const Tween({required this.begin, required this.end});

  final T begin;
  final T end;

  /// The value strictly between the endpoints. Implementations may assume
  /// `0 < t < 1`, and may be called with `t` outside `[0, 1]` only if the
  /// caller deliberately extrapolates via [lerp].
  T lerp(double t);

  /// The value at [t], with the endpoints answered exactly.
  T transform(double t) {
    if (t <= 0.0) return begin;
    if (t >= 1.0) return end;
    return lerp(t);
  }

  /// This tween driven by [animation].
  Animation<T> animate(Animation<double> animation) =>
      _TweenAnimation<T>(parent: animation, tween: this);

  /// The value this tween has at [animation]'s current progress.
  T evaluate(Animation<double> animation) => transform(animation.value);
}

/// A [Tween] over `double`.
final class DoubleTween extends Tween<double> {
  const DoubleTween({required super.begin, required super.end});

  /// Weighted on both ends rather than `begin + (end - begin) * t`, for the
  /// same reason [Offset.lerp] is: the weighted form is exact at the
  /// endpoints.
  @override
  double lerp(double t) => begin * (1.0 - t) + end * t;

  /// Free-standing interpolation for callers that have two values and a `t`
  /// but no tween object to hold.
  static double interpolate(double a, double b, double t) =>
      a * (1.0 - t) + b * t;
}

/// A [Tween] over [Offset].
final class OffsetTween extends Tween<Offset> {
  const OffsetTween({required super.begin, required super.end});

  @override
  Offset lerp(double t) => Offset.lerp(begin, end, t);
}

/// A [Tween] over [Size].
final class SizeTween extends Tween<Size> {
  const SizeTween({required super.begin, required super.end});

  @override
  Size lerp(double t) => Size.lerp(begin, end, t);
}

/// A [Tween] over [Rect].
final class RectTween extends Tween<Rect> {
  const RectTween({required super.begin, required super.end});

  @override
  Rect lerp(double t) => Rect.lerp(begin, end, t);
}

/// A [Tween] over an `0xAARRGGBB` colour, interpolated in **premultiplied**
/// alpha space.
///
/// ## Why premultiplied, stated in full because getting it wrong is invisible
/// until it is ugly
///
/// The framework stores colours straight (non-premultiplied): the RGB channels
/// are the colour, the A channel is separately how much of it to apply. That
/// storage is right - it round-trips, and it is what a theme file wants to
/// contain - but it is the wrong space to *interpolate* in whenever the two
/// alphas differ.
///
/// Consider fading an opaque red `0xFFFF0000` out to `0x00000000`, which is
/// how "transparent" is spelled essentially everywhere. Interpolating the four
/// channels straight gives, at the halfway point, `0x807F0000`: alpha 50% as
/// wanted, but the RGB has been dragged halfway to black. Composited over a
/// light background that reads as a **grey-brown smear**, not as red getting
/// fainter. Every channel of the destination is meaningless in straight space,
/// because when alpha is zero the colour is not "black", it is *nothing* - and
/// straight interpolation has no way to know that.
///
/// In premultiplied space the same fade is exact. Premultiplying folds the
/// alpha into the channels first (`r * a`), so the transparent endpoint is
/// genuinely the origin, `(0, 0, 0, 0)`, and interpolating towards it scales
/// the colour down in lockstep with its own alpha. Unpremultiplying at the end
/// recovers `0x80FF0000` - fully saturated red at half alpha, which is what
/// "fading out" means.
///
/// The choice costs nothing in the common case: when both endpoints are
/// opaque, premultiplying by `1.0` is the identity and the result is bit-for-
/// bit the straight interpolation.
///
/// ## Declared limits
///
/// * This is **not** perceptual interpolation. Channels are treated as linear
///   in their sRGB-encoded values, matching the rest of the rasterizer, which
///   also blends in encoded space. A red-to-green fade therefore passes
///   through a darker midpoint than a Lab-space blend would. Fixing that means
///   changing the *rasterizer's* blend space too, and doing it here alone
///   would make a tween disagree with the compositor.
/// * Rounding is to nearest, half away from zero, per channel, once, at the
///   end. Interpolating in integers throughout would accumulate a channel of
///   error over a long fade.
final class ColorTween extends Tween<int> {
  const ColorTween({required super.begin, required super.end});

  @override
  int lerp(double t) => interpolate(begin, end, t);

  /// Interpolates two `0xAARRGGBB` colours. Exposed free-standing so a
  /// property transition can use it without allocating a tween per frame.
  static int interpolate(int a, int b, double t) {
    if (t <= 0.0) return a;
    if (t >= 1.0) return b;

    final int alphaA = (a >> 24) & 0xFF;
    final int alphaB = (b >> 24) & 0xFF;

    // Normalized alpha, so the premultiplied channels stay on the 0..255
    // scale and the unpremultiply at the end is a plain division.
    final double fa = alphaA / 255.0;
    final double fb = alphaB / 255.0;

    final double alpha = alphaA + (alphaB - alphaA) * t;
    final double alphaScale = alpha / 255.0;

    final int channels = _lerpChannel(a, b, 16, fa, fb, t, alphaScale) << 16 |
        _lerpChannel(a, b, 8, fa, fb, t, alphaScale) << 8 |
        _lerpChannel(a, b, 0, fa, fb, t, alphaScale);

    return (_toByte(alpha) << 24) | channels;
  }

  static int _lerpChannel(
    int a,
    int b,
    int shift,
    double alphaA,
    double alphaB,
    double t,
    double alphaOut,
  ) {
    final double premultipliedA = ((a >> shift) & 0xFF) * alphaA;
    final double premultipliedB = ((b >> shift) & 0xFF) * alphaB;
    final double premultiplied =
        premultipliedA + (premultipliedB - premultipliedA) * t;
    // A fully transparent result carries no colour. Reporting zero rather
    // than dividing by zero is the only defined answer, and it matches how a
    // transparent pixel is stored everywhere else in the framework.
    if (alphaOut == 0.0) return 0;
    return _toByte(premultiplied / alphaOut);
  }

  static int _toByte(double value) {
    final int rounded = value.round();
    return rounded < 0 ? 0 : (rounded > 255 ? 255 : rounded);
  }
}

/// An [Animation] whose value is a [Tween] read at a parent's progress.
final class _TweenAnimation<T> extends Animation<T> with _AnimationListeners {
  _TweenAnimation({required this.parent, required this.tween}) {
    parent.addListener(notifyListeners);
    parent.addStatusListener(notifyStatusListeners);
  }

  final Animation<double> parent;
  final Tween<T> tween;

  @override
  T get value => tween.transform(parent.value);

  @override
  AnimationStatus get status => parent.status;

  @override
  bool get isAnimating => parent.isAnimating;
}
