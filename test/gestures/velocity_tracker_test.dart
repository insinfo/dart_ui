import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/gestures/velocity_tracker.dart';
import 'package:test/test.dart';

/// The naive estimate this whole file exists to reject: the last two samples.
double twoPointEstimate(
  double newer,
  double older,
  Duration gap,
) =>
    (newer - older) / (gap.inMicroseconds / Duration.microsecondsPerSecond);

void main() {
  group('least squares fit', () {
    test('recovers the coefficients of a known quadratic exactly', () {
      // y = 3 + 5x + 7x^2, sampled at six points.
      final x = Float64List.fromList(<double>[-5, -4, -3, -2, -1, 0]);
      final y = Float64List.fromList(<double>[
        for (final double v in x) 3 + 5 * v + 7 * v * v,
      ]);
      final PolynomialFit? fit = fitPolynomial(x: x, y: y, count: 6, degree: 2);

      expect(fit, isNotNull);
      expect(fit!.coefficients[0], closeTo(3, 1e-9));
      expect(fit.coefficients[1], closeTo(5, 1e-9));
      expect(fit.coefficients[2], closeTo(7, 1e-9));
      expect(fit.confidence, closeTo(1.0, 1e-9));
    });

    test('returns null rather than zero when there is no answer', () {
      final x = Float64List.fromList(<double>[0, 1]);
      final y = Float64List.fromList(<double>[0, 1]);
      // Two points cannot determine three coefficients.
      expect(fitPolynomial(x: x, y: y, count: 2, degree: 2), isNull);
      // Repeated abscissae leave the basis rank deficient.
      final same = Float64List.fromList(<double>[1, 1, 1]);
      expect(
        fitPolynomial(x: same, y: y, count: 2, degree: 1),
        isNull,
      );
    });
  });

  group('velocity from motion', () {
    test('constant 1000 px/s is recovered to within a billionth', () {
      final tracker = VelocityTracker();
      for (var i = 0; i <= 6; i++) {
        tracker.addPosition(
          Duration(milliseconds: 16 * i),
          Offset(0, 16.0 * i),
        );
      }

      final VelocityEstimate estimate = tracker.estimate()!;
      expect(estimate.pixelsPerSecond.dy, closeTo(1000, 1e-6));
      expect(estimate.pixelsPerSecond.dx, closeTo(0, 1e-9));
      expect(estimate.confidence, closeTo(1.0, 1e-9));
      expect(estimate.offset, const Offset(0, 96));
      expect(estimate.duration, const Duration(milliseconds: 96));
    });

    test('an accelerating swipe: 200.0 px/s exact, two-point says 184.0', () {
      // y(t) = t^2/1000 px with t in ms, i.e. a constant 2000 px/s^2. At the
      // release instant t = 100 ms the true speed is 200 px/s.
      //
      // This is the measurement that justifies fitting a *quadratic*: a
      // finger still speeding up as it leaves the glass is the ordinary case
      // of a flick, and the two-point estimate reports the average over the
      // last frame instead of the speed at release - 8% low, every time, in
      // the same direction. A user feels that as a fling that under-shoots.
      final tracker = VelocityTracker();
      const List<int> times = <int>[4, 20, 36, 52, 68, 84, 100];
      for (final int ms in times) {
        tracker.addPosition(
          Duration(milliseconds: ms),
          Offset(0, ms * ms / 1000),
        );
      }

      final VelocityEstimate estimate = tracker.estimate()!;
      expect(estimate.pixelsPerSecond.dy, closeTo(200.0, 1e-6));
      expect(estimate.confidence, closeTo(1.0, 1e-9));

      final double naive = twoPointEstimate(
        100 * 100 / 1000,
        84 * 84 / 1000,
        const Duration(milliseconds: 16),
      );
      expect(naive, closeTo(184.0, 1e-9));
      expect((naive - 200).abs() / 200, greaterThan(0.07));
    });

    test('with jitter: 1007.5 px/s from the fit, 2000.0 from two points', () {
      // A perfectly steady 1000 px/s (4 px every 4 ms) with the position
      // rounded alternately 2 px either side - which is what an integer
      // coordinate stream plus a trembling hand actually looks like.
      double positionAt(int i) => 4.0 * i + (i.isEven ? 2.0 : -2.0);

      final tracker = VelocityTracker();
      for (var i = 0; i <= 24; i++) {
        tracker.addPosition(
          Duration(milliseconds: 4 * i),
          Offset(0, positionAt(i)),
        );
      }

      final double fitted = tracker.estimate()!.pixelsPerSecond.dy;
      final double naive = twoPointEstimate(
        positionAt(24),
        positionAt(23),
        const Duration(milliseconds: 4),
      );

      // The fit is off by 0.75%; the two-point estimate is off by 100%, and
      // would have flung twice as far as the user asked for.
      expect(fitted, closeTo(1007.52, 0.01));
      expect((fitted - 1000).abs() / 1000, lessThan(0.01));
      expect(naive, closeTo(2000.0, 1e-9));
      expect((naive - 1000).abs() / 1000, greaterThan(0.9));
    });

    test('velocity is a vector: a diagonal swipe reports both axes', () {
      final tracker = VelocityTracker();
      for (var i = 0; i <= 6; i++) {
        tracker.addPosition(
          Duration(milliseconds: 10 * i),
          Offset(3.0 * i, -5.0 * i),
        );
      }

      final Offset velocity = tracker.estimate()!.pixelsPerSecond;
      expect(velocity.dx, closeTo(300, 1e-6));
      expect(velocity.dy, closeTo(-500, 1e-6));
    });
  });

  group('what the tracker refuses to guess', () {
    test('no samples at all is null, not zero', () {
      expect(VelocityTracker().estimate(), isNull);
      expect(
        VelocityTracker().estimateAt(const Duration(milliseconds: 5)),
        isNull,
      );
    });

    test('a pointer that stopped before release reports zero', () {
      final tracker = VelocityTracker();
      for (var i = 0; i <= 6; i++) {
        tracker.addPosition(
          Duration(milliseconds: 16 * i),
          Offset(0, 16.0 * i),
        );
      }

      // Released 41 ms after the last movement: the finger was resting.
      final VelocityEstimate estimate =
          tracker.estimateAt(const Duration(milliseconds: 96 + 41))!;
      expect(estimate.pixelsPerSecond, Offset.zero);
      expect(estimate, same(VelocityEstimate.stationary));

      // One millisecond earlier it is still moving.
      expect(
        tracker
            .estimateAt(const Duration(milliseconds: 96 + 40))!
            .pixelsPerSecond
            .dy,
        closeTo(1000, 1e-6),
      );
    });

    test('fewer than three samples is zero with the travel still reported', () {
      final tracker = VelocityTracker()
        ..addPosition(Duration.zero, Offset.zero)
        ..addPosition(const Duration(milliseconds: 10), const Offset(0, 40));

      final VelocityEstimate estimate = tracker.estimate()!;
      expect(estimate.pixelsPerSecond, Offset.zero);
      expect(estimate.offset, const Offset(0, 40));
    });

    test('a pause in the middle ends the run of continuous motion', () {
      final tracker = VelocityTracker();
      // Fast motion, a 60 ms pause, then slow motion. Only the slow tail is
      // continuous with the release, and averaging across the pause would
      // report a fling the user did not make.
      for (var i = 0; i <= 3; i++) {
        tracker.addPosition(
          Duration(milliseconds: 5 * i),
          Offset(0, 50.0 * i),
        );
      }
      for (var i = 0; i <= 3; i++) {
        tracker.addPosition(
          Duration(milliseconds: 75 + 5 * i),
          Offset(0, 150 + 5.0 * i),
        );
      }

      expect(
        tracker.estimate()!.pixelsPerSecond.dy,
        closeTo(1000, 1e-6),
        reason: '5 px per 5 ms in the tail, not 10 px per ms from the burst',
      );
    });

    test('the horizon drops motion older than 100 ms', () {
      final tracker = VelocityTracker();
      // 200 ms of upward motion, then 96 ms of downward motion. A tracker
      // without a horizon would average the reversal to nearly zero.
      for (var i = 0; i <= 12; i++) {
        tracker.addPosition(
          Duration(milliseconds: 16 * i),
          Offset(0, -16.0 * i),
        );
      }
      for (var i = 1; i <= 6; i++) {
        tracker.addPosition(
          Duration(milliseconds: 192 + 16 * i),
          Offset(0, -192 + 16.0 * i),
        );
      }

      expect(tracker.estimate()!.pixelsPerSecond.dy, closeTo(1000, 1e-6));
    });

    test('history is bounded: only the newest 20 samples are kept', () {
      final tracker = VelocityTracker();
      for (var i = 0; i < 100; i++) {
        tracker.addPosition(Duration(milliseconds: i), Offset(0, i.toDouble()));
      }
      expect(tracker.sampleCount, VelocityTracker.historySize);
      expect(tracker.estimate()!.pixelsPerSecond.dy, closeTo(1000, 1e-6));
    });

    test('reset forgets everything', () {
      final tracker = VelocityTracker()
        ..addPosition(Duration.zero, Offset.zero)
        ..reset();
      expect(tracker.sampleCount, 0);
      expect(tracker.estimate(), isNull);
    });
  });

  group('Velocity', () {
    test('clamps magnitude while keeping direction', () {
      const velocity = Velocity(pixelsPerSecond: Offset(30, 40)); // 50 long
      final Velocity raised = velocity.clampMagnitude(100, 8000);
      expect(raised.pixelsPerSecond.dx, closeTo(60, 1e-9));
      expect(raised.pixelsPerSecond.dy, closeTo(80, 1e-9));

      final Velocity lowered = velocity.clampMagnitude(0, 25);
      expect(lowered.magnitude, closeTo(25, 1e-9));
      expect(
        lowered.pixelsPerSecond.dx / lowered.pixelsPerSecond.dy,
        closeTo(30 / 40, 1e-9),
      );
    });

    test('a zero velocity has no direction to preserve and stays zero', () {
      expect(Velocity.zero.clampMagnitude(100, 8000), Velocity.zero);
    });
  });
}
