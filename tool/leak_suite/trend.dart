/// Turning a series of per-cycle readings into "leak" or "cache".
///
/// The design mistake a leak suite makes once and then gets switched off for
/// is asserting on a **single** open/close. One cycle legitimately grows a
/// process: fonts are interned, a window class is registered, GDI hands out a
/// device context that is then pooled, the JIT compiles the path for the first
/// time. A suite that fails on that is a suite that cries wolf on its third
/// run and is disabled on its fourth.
///
/// What actually separates the two is the **shape over many cycles**:
///
///   * a **cache** grows and then stops - the readings plateau, and the slope
///     over the tail is zero;
///   * a **leak** grows by the same amount every cycle forever - the slope over
///     the tail is the leak, in objects or bytes per cycle.
///
/// So every measurement here runs N cycles, throws away the first few as
/// warm-up, and fits a straight line to the rest. The reported number is the
/// **slope**, never the total, and the verdict is the slope compared against
/// two things at once:
///
///   1. its own standard error, so a slope indistinguishable from the run's
///      noise is not a finding no matter how large it looks; and
///   2. a floor per metric, so a statistically perfect 0.02 objects per cycle -
///      which is what an exact integer counter produces when one object appears
///      once in fifty cycles for a reason that is not a leak - does not fail a
///      build.
///
/// Both numbers are printed. A threshold nobody can see the evidence behind is
/// a threshold nobody trusts.
library;

import 'dart:math' as math;

/// A straight line fitted to one metric's post-warm-up readings.
final class Trend {
  const Trend({
    required this.name,
    required this.unit,
    required this.samples,
    required this.warmup,
    required this.slope,
    required this.slopeStandardError,
    required this.residualStandardDeviation,
    required this.floor,
  });

  /// Fits [samples] from index [warmup] onward.
  ///
  /// Returns a trend with a null [slope] when fewer than three points survive
  /// the warm-up: two points always fit a line perfectly, so a slope from them
  /// has no error bar and would be reported with a confidence it has not
  /// earned.
  factory Trend.fit({
    required String name,
    required String unit,
    required List<num> samples,
    required int warmup,
    required double floor,
  }) {
    final List<num> tail =
        samples.length > warmup ? samples.sublist(warmup) : const <num>[];
    if (tail.length < 3) {
      return Trend(
        name: name,
        unit: unit,
        samples: samples,
        warmup: warmup,
        slope: null,
        slopeStandardError: null,
        residualStandardDeviation: null,
        floor: floor,
      );
    }
    final int n = tail.length;
    final double meanX = (n - 1) / 2;
    double meanY = 0;
    for (final num y in tail) {
      meanY += y;
    }
    meanY /= n;
    double sxx = 0;
    double sxy = 0;
    for (var i = 0; i < n; i++) {
      final double dx = i - meanX;
      sxx += dx * dx;
      sxy += dx * (tail[i] - meanY);
    }
    final double slope = sxx == 0 ? 0 : sxy / sxx;
    final double intercept = meanY - slope * meanX;
    double residuals = 0;
    for (var i = 0; i < n; i++) {
      final double error = tail[i] - (intercept + slope * i);
      residuals += error * error;
    }
    // n - 2 degrees of freedom: a line costs two of them. With n == 3 that is
    // one, which is thin but honest, and the caller sees the sample count.
    final double residualStandardDeviation = math.sqrt(residuals / (n - 2));
    return Trend(
      name: name,
      unit: unit,
      samples: samples,
      warmup: warmup,
      slope: slope,
      slopeStandardError:
          sxx == 0 ? null : residualStandardDeviation / math.sqrt(sxx),
      residualStandardDeviation: residualStandardDeviation,
      floor: floor,
    );
  }

  final String name;

  /// What one unit of [slope] is - `objects`, `blocks`, `bytes`, `instances`.
  final String unit;

  /// Every reading, warm-up included, so a human can see the plateau rather
  /// than trust the verdict.
  final List<num> samples;

  final int warmup;

  /// Units per cycle over the post-warm-up tail, or null when too few points.
  final double? slope;

  /// The regression's own uncertainty about [slope]. A slope smaller than a
  /// few of these is the run's noise wearing a slope's clothes.
  final double? slopeStandardError;

  /// Spread of the readings about the fitted line - the per-cycle variation the
  /// threshold has to clear.
  final double? residualStandardDeviation;

  /// The smallest slope worth calling a leak for this metric, whatever the
  /// statistics say. See the library comment.
  final double floor;

  List<num> get tail =>
      samples.length > warmup ? samples.sublist(warmup) : const <num>[];

  num get first => samples.isEmpty ? 0 : samples.first;
  num get last => samples.isEmpty ? 0 : samples.last;

  /// How many standard errors the slope is away from zero.
  double? get significance {
    final double? s = slope;
    final double? e = slopeStandardError;
    if (s == null || e == null) return null;
    // A perfectly flat run has zero residual and therefore zero standard
    // error; dividing there is an infinity that means "certainly zero", so it
    // is answered as zero significance rather than as a NaN.
    if (e == 0) return s == 0 ? 0 : double.infinity;
    return s / e;
  }

  /// Growing, by more than the noise **and** by more than the floor.
  bool get isLeaking {
    final double? s = slope;
    if (s == null) return false;
    if (s < floor) return false;
    final double? z = significance;
    return z != null && z >= 3;
  }

  /// True when the tail is flat enough that the metric is positively clean,
  /// rather than merely not proven dirty.
  bool get isFlat {
    final double? s = slope;
    return s != null && s.abs() < floor;
  }

  /// One word for the table, in the order the questions are actually asked.
  String get verdict {
    if (slope == null) return 'too few cycles';
    if (isLeaking) return 'LEAK';
    if (isFlat) return 'flat';
    final double? z = significance;
    // Big enough to matter, but the run's own scatter is bigger: a longer run
    // is the answer, not a verdict.
    if (z != null && z.abs() < 3) return 'within noise';
    // Named rather than folded into "below floor", because a metric that
    // shrinks significantly is not a near-miss on a leak - it is a process
    // handing memory back, which is what the coarse counters do the moment a
    // collection runs, and a reader who sees "below floor" against a large
    // negative number stops trusting the column.
    if (slope! < 0) return 'shrinking';
    return 'below floor';
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'unit': unit,
        'warmup': warmup,
        'samples': samples,
        'slopePerCycle': slope,
        'slopeStandardError': slopeStandardError,
        'residualStandardDeviation': residualStandardDeviation,
        'floor': floor,
        'verdict': verdict,
      };
}

/// Formats [value] compactly enough to fit a column.
String formatMeasure(num value) {
  if (value is int) return value.toString();
  final double v = value.toDouble();
  if (v == 0) return '0';
  final double magnitude = v.abs();
  if (magnitude >= 1000) return v.toStringAsFixed(0);
  if (magnitude >= 1) return v.toStringAsFixed(2);
  return v.toStringAsFixed(4);
}
