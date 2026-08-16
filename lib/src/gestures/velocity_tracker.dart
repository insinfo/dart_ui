/// How fast a pointer was moving when the user let go.
///
/// This is the number `ScrollPosition.fling` has been waiting for. It is also
/// the one place in the gesture layer where the obvious implementation is
/// visibly wrong, so it is worth stating what it is and why it is not used
/// here.
///
/// **The obvious implementation is `(last - previous) / dt`.** It fails for
/// three independent reasons, each of which alone would be enough:
///
///  1. *The last sample is the worst sample.* A finger decelerates as it
///     leaves the glass and the final contact wobbles as pressure drops. The
///     two most recent points are precisely the two least representative of
///     the motion the user intended.
///  2. *dt is quantised and small.* Samples arrive on the input tick - 8 ms,
///     16 ms, sometimes 4 - and one sample landing a tick early doubles the
///     computed speed. That is a fling that varies by 2x between two
///     identical-feeling swipes.
///  3. *Positions are integers.* One pixel of rounding across a 4 ms gap is
///     250 px/s of pure noise, injected into a number that then drives a
///     multi-second animation.
///
/// So the estimate here is a **least-squares fit of a quadratic** to the last
/// ~100 ms of samples, and the velocity is the fit's first-order coefficient.
/// Fitting many points averages the noise away; fitting a *quadratic* rather
/// than a line means the fit can represent acceleration instead of smearing it,
/// so a finger that was still speeding up at release reports the speed it had
/// at release and not its average over the window. Empirically this is the
/// difference between a fling that feels native and one that trembles - and it
/// is measurable: see `test/gestures/velocity_tracker_test.dart`, where an
/// accelerating swipe is recovered exactly while the two-point estimate is 8%
/// low, and a jittered constant-speed swipe is recovered to within 0.6% while
/// the two-point estimate is off by more than 100%.
///
/// The design follows Flutter's `VelocityTracker` and `LeastSquaresSolver`,
/// which in turn follow Android's `VelocityTracker`; the code is this
/// repository's.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../geometry/offset.dart';
import '../platform/input_events.dart';

/// A speed, in logical pixels per second, along both axes.
final class Velocity {
  const Velocity({required this.pixelsPerSecond});

  static const Velocity zero = Velocity(pixelsPerSecond: Offset.zero);

  final Offset pixelsPerSecond;

  /// The speed along [axis]-less magnitude, for the fling threshold test.
  double get magnitude => pixelsPerSecond.distance;

  /// Clamps the magnitude into `[minimum, maximum]`, preserving direction.
  ///
  /// A zero-length velocity has no direction to preserve and stays zero, which
  /// is why this is not simply a multiply.
  Velocity clampMagnitude(double minimum, double maximum) {
    final double length = pixelsPerSecond.distance;
    if (length == 0 || (length >= minimum && length <= maximum)) return this;
    final double target = length < minimum ? minimum : maximum;
    return Velocity(pixelsPerSecond: pixelsPerSecond * (target / length));
  }

  @override
  bool operator ==(Object other) =>
      other is Velocity && other.pixelsPerSecond == pixelsPerSecond;

  @override
  int get hashCode => pixelsPerSecond.hashCode;

  @override
  String toString() => 'Velocity(${pixelsPerSecond.dx.toStringAsFixed(1)}, '
      '${pixelsPerSecond.dy.toStringAsFixed(1)})';
}

/// A velocity plus the evidence behind it.
///
/// [confidence] and [offset] are not decoration: a recognizer decides whether a
/// release was a *fling* partly on how far the pointer actually travelled, and
/// a fit nobody should trust reports it here rather than pretending.
final class VelocityEstimate {
  const VelocityEstimate({
    required this.pixelsPerSecond,
    required this.confidence,
    required this.duration,
    required this.offset,
  });

  /// A well-founded "it was not moving".
  static const VelocityEstimate stationary = VelocityEstimate(
    pixelsPerSecond: Offset.zero,
    confidence: 1.0,
    duration: Duration.zero,
    offset: Offset.zero,
  );

  final Offset pixelsPerSecond;

  /// The fit's coefficient of determination, 0 to 1. Higher is better.
  final double confidence;

  /// The span of time the estimate was computed over.
  final Duration duration;

  /// How far the pointer moved over [duration].
  final Offset offset;

  Velocity get velocity => Velocity(pixelsPerSecond: pixelsPerSecond);

  @override
  String toString() => 'VelocityEstimate($pixelsPerSecond, '
      'confidence: ${confidence.toStringAsFixed(3)})';
}

/// The result of fitting a polynomial to a set of points.
final class PolynomialFit {
  PolynomialFit._(this.coefficients, this.confidence);

  /// `coefficients[i]` multiplies the `i`-th power of the variable, so
  /// `coefficients[1]` is the first derivative at the origin.
  final Float64List coefficients;

  /// r-squared: the fraction of the data's variance the fit explains.
  final double confidence;
}

/// Fits a polynomial of [degree] to the first [count] entries of [x] and [y].
///
/// Returns null when the system is underdetermined or degenerate - fewer points
/// than coefficients, or points so collinear in the Vandermonde sense that the
/// basis loses rank. A null is not a zero: the caller must be able to tell "the
/// pointer was still" from "there is no answer", because the first is a fact
/// about the user and the second is a fact about the sampling.
///
/// Solved by Gram-Schmidt QR rather than by the normal equations. `AᵀA` for a
/// quadratic squares the condition number, and with time in milliseconds the
/// entries already span six orders of magnitude between the constant and
/// quadratic columns; QR keeps the arithmetic in the same range as the data.
///
/// All points weigh the same. Flutter's solver carries per-point weights and
/// then passes 1.0 for every point; a parameter that is never varied is a
/// parameter that only costs multiplications.
PolynomialFit? fitPolynomial({
  required Float64List x,
  required Float64List y,
  required int count,
  required int degree,
}) {
  final int m = count;
  final int n = degree + 1;
  if (m < n) return null;

  // a[i * m + h] is the i-th power of the h-th sample's abscissa: the
  // Vandermonde matrix, stored row-major and flat so the whole fit runs on
  // three allocations instead of a list of lists.
  final a = Float64List(n * m);
  for (var h = 0; h < m; h++) {
    a[h] = 1.0;
    for (var i = 1; i < n; i++) {
      a[i * m + h] = a[(i - 1) * m + h] * x[h];
    }
  }

  final q = Float64List(n * m); // Orthonormal basis, one row per column of A.
  final r = Float64List(n * n); // Upper triangular.
  for (var j = 0; j < n; j++) {
    for (var h = 0; h < m; h++) {
      q[j * m + h] = a[j * m + h];
    }
    for (var i = 0; i < j; i++) {
      var dot = 0.0;
      for (var h = 0; h < m; h++) {
        dot += q[j * m + h] * q[i * m + h];
      }
      for (var h = 0; h < m; h++) {
        q[j * m + h] -= dot * q[i * m + h];
      }
    }
    var norm = 0.0;
    for (var h = 0; h < m; h++) {
      norm += q[j * m + h] * q[j * m + h];
    }
    norm = math.sqrt(norm);
    if (norm < 1e-10) return null; // Rank deficient: no unique answer exists.
    final double inverseNorm = 1.0 / norm;
    for (var h = 0; h < m; h++) {
      q[j * m + h] *= inverseNorm;
    }
    for (var i = 0; i < n; i++) {
      if (i < j) {
        r[j * n + i] = 0.0;
        continue;
      }
      var dot = 0.0;
      for (var h = 0; h < m; h++) {
        dot += q[j * m + h] * a[i * m + h];
      }
      r[j * n + i] = dot;
    }
  }

  // R B = Qᵀ Y, back-substituted from the bottom right.
  final coefficients = Float64List(n);
  for (var i = n - 1; i >= 0; i--) {
    var value = 0.0;
    for (var h = 0; h < m; h++) {
      value += q[i * m + h] * y[h];
    }
    for (var j = n - 1; j > i; j--) {
      value -= r[i * n + j] * coefficients[j];
    }
    coefficients[i] = value / r[i * n + i];
  }

  var mean = 0.0;
  for (var h = 0; h < m; h++) {
    mean += y[h];
  }
  mean /= m;

  var sumSquaredError = 0.0;
  var sumSquaredTotal = 0.0;
  for (var h = 0; h < m; h++) {
    var term = 1.0;
    var error = y[h] - coefficients[0];
    for (var i = 1; i < n; i++) {
      term *= x[h];
      error -= term * coefficients[i];
    }
    sumSquaredError += error * error;
    final double deviation = y[h] - mean;
    sumSquaredTotal += deviation * deviation;
  }

  final double confidence = sumSquaredTotal <= 1e-10
      ? 1.0
      : (1.0 - sumSquaredError / sumSquaredTotal).clamp(0.0, 1.0);
  return PolynomialFit._(coefficients, confidence);
}

/// Accumulates pointer samples and estimates the velocity at the latest one.
///
/// ## No clock
///
/// Every timestamp comes from the caller, which is always a
/// [PointerEvent.timestamp] reported by the platform. Nothing here reads
/// `DateTime.now` or starts a `Stopwatch` - Flutter's tracker uses a stopwatch
/// to notice a pointer that stopped moving, and that alone would make this
/// framework's test suite depend on how fast the machine ran the test. The
/// same question is answered by comparing the *event's* timestamp against the
/// newest sample, in [estimateAt].
///
/// ## No allocation
///
/// Samples live in three preallocated [Float64List]s used as a ring buffer, and
/// so do the scratch arrays the fit runs on. [addPosition] - which is called
/// for every single `PointerMoveEvent`, i.e. on every mouse movement the OS
/// reports - performs three stores and an increment, and allocates nothing at
/// all. Section 6.5 asks for exactly this.
final class VelocityTracker {
  VelocityTracker({this.kind = PointerKind.touch});

  /// How many samples are retained. 20 at ~120 Hz is ~160 ms of history, which
  /// comfortably covers [horizon] even on a fast input device.
  static const int historySize = 20;

  /// How far back the fit looks. Older motion is a different gesture: the user
  /// may have reversed direction, and averaging across the reversal reports a
  /// fling in the wrong direction, which is the single most jarring failure a
  /// scroll view can produce.
  static const Duration horizon = Duration(milliseconds: 100);

  /// A gap this long means the pointer stopped.
  ///
  /// 40 ms is between two and five input ticks. A press held still for longer
  /// than that and then released is not a fling however fast it moved before,
  /// and a gap in the middle of the history ends the run of "continuous
  /// motion" rather than being interpolated across.
  static const Duration stopTimeout = Duration(milliseconds: 40);

  /// Fewer points than this and a quadratic fit is not evidence, it is
  /// interpolation. Three is the minimum that determines a quadratic at all.
  static const int minSampleSize = 3;

  /// Which device the samples come from; kept so a consumer can pick the slop
  /// that goes with the velocity.
  final PointerKind kind;

  final Float64List _x = Float64List(historySize);
  final Float64List _y = Float64List(historySize);
  final Float64List _timeMicros = Float64List(historySize);

  // Scratch for the fit, so estimating costs no allocation either.
  final Float64List _fitTime = Float64List(historySize);
  final Float64List _fitX = Float64List(historySize);
  final Float64List _fitY = Float64List(historySize);

  int _index = -1;
  int _count = 0;

  /// How many samples are currently retained.
  int get sampleCount => _count;

  /// Discards the history. Used when a gesture ends and the tracker is reused.
  void reset() {
    _index = -1;
    _count = 0;
  }

  /// Records that the pointer was at [position] at [time].
  ///
  /// [time] must be the platform timestamp of the event, not a value derived
  /// from a clock the framework read itself.
  void addPosition(Duration time, Offset position) {
    _index = _index + 1 == historySize ? 0 : _index + 1;
    _x[_index] = position.dx;
    _y[_index] = position.dy;
    _timeMicros[_index] = time.inMicroseconds.toDouble();
    if (_count < historySize) _count++;
  }

  /// The velocity at the newest sample, or null when there is no sample at all.
  VelocityEstimate? estimate() {
    if (_count == 0) return null;
    return estimateAt(Duration(microseconds: _timeMicros[_index].round()));
  }

  /// The velocity as of [now], which is normally the release event's timestamp.
  ///
  /// If the newest sample is older than [stopTimeout], the pointer had already
  /// come to rest before it was lifted and the honest answer is zero. This is
  /// the check Flutter delegates to a `Stopwatch`; taking [now] from the caller
  /// makes it exact and makes the whole tracker testable.
  VelocityEstimate? estimateAt(Duration now) {
    if (_count == 0) return null;

    final int newest = _index;
    final double newestTime = _timeMicros[newest];
    if (now.inMicroseconds - newestTime > stopTimeout.inMicroseconds) {
      return VelocityEstimate.stationary;
    }

    var used = 0;
    var index = newest;
    var previousTime = newestTime;
    var oldest = newest;
    while (used < _count) {
      final double time = _timeMicros[index];
      final double ageMs = (newestTime - time) / 1000.0;
      final double gapMs = (previousTime - time).abs() / 1000.0;
      if (ageMs > horizon.inMilliseconds ||
          gapMs > stopTimeout.inMilliseconds) {
        break;
      }
      previousTime = time;
      oldest = index;
      // Negative ages put the newest sample at the origin, so the fit's
      // first-order coefficient *is* the velocity at release rather than at
      // some arbitrary earlier instant.
      _fitTime[used] = -ageMs;
      _fitX[used] = _x[index];
      _fitY[used] = _y[index];
      used++;
      index = (index == 0 ? historySize : index) - 1;
    }

    final Offset travel = Offset(
      _x[newest] - _x[oldest],
      _y[newest] - _y[oldest],
    );
    final duration = Duration(
      microseconds: (newestTime - _timeMicros[oldest]).round(),
    );

    if (used >= minSampleSize) {
      final PolynomialFit? xFit = fitPolynomial(
        x: _fitTime,
        y: _fitX,
        count: used,
        degree: 2,
      );
      final PolynomialFit? yFit = fitPolynomial(
        x: _fitTime,
        y: _fitY,
        count: used,
        degree: 2,
      );
      if (xFit != null && yFit != null) {
        return VelocityEstimate(
          // The fit is in pixels per millisecond; a fling is quoted per second.
          pixelsPerSecond: Offset(
            xFit.coefficients[1] * 1000.0,
            yFit.coefficients[1] * 1000.0,
          ),
          confidence: xFit.confidence * yFit.confidence,
          duration: duration,
          offset: travel,
        );
      }
    }

    // Not enough continuous motion to fit, but the samples are real: report
    // zero speed with the travel that did happen, so a caller can still tell a
    // stationary press from a short one.
    return VelocityEstimate(
      pixelsPerSecond: Offset.zero,
      confidence: 1.0,
      duration: duration,
      offset: travel,
    );
  }

  /// [estimateAt] reduced to a velocity, zero when there is nothing to report.
  Velocity velocityAt(Duration now) {
    final VelocityEstimate? estimate = estimateAt(now);
    if (estimate == null) return Velocity.zero;
    return Velocity(pixelsPerSecond: estimate.pixelsPerSecond);
  }
}
