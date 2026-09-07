/// The circuit's geometry, and the projection everything else is built on.
///
/// Two kinds of test here and they answer different questions. The ones on
/// [TrackPath] are about the *algorithm* and are run against a shape with a
/// known closed form - a circle, where the arc length, the tangent, the normal
/// and the curvature are all things arithmetic can be held against. The ones
/// on [buildCircuit] are about the *content*: a hand-placed loop is data, and
/// the two ways data goes wrong are that it crosses itself and that it has a
/// corner nothing can drive.
library;

import 'dart:math' as math;

import 'package:test/test.dart';

import '../../../examples/kart_racer/game/track.dart';

/// A circle of [radius], as sixteen control points.
///
/// Sixteen because Catmull-Rom through fewer visibly under-cuts a circle, and
/// the point of this fixture is that the answers are known.
TrackPath circle(double radius) => TrackPath.fromControlPoints(
      <(double, double)>[
        for (int i = 0; i < 16; i++)
          (
            radius * math.sin(i * 2 * math.pi / 16),
            radius * math.cos(i * 2 * math.pi / 16),
          ),
      ],
      halfWidth: 5,
      // The smoothing rounds off pinches, and a circle has none. Left on it
      // would shrink the fixture and every expectation below would need a
      // fudge factor that hid real error.
      smoothingPasses: 0,
    );

void main() {
  group('the centreline', () {
    test('a circle has the circumference it should', () {
      expect(circle(50).length, closeTo(2 * math.pi * 50, 0.6));
    });

    test('samples are evenly spaced in arc length', () {
      final TrackPath path = circle(50);
      double worst = 0;
      for (int i = 0; i < path.sampleCount; i++) {
        final TrackSample a = path.sampleAt(i);
        final TrackSample b = path.sampleAt(i + 1);
        final double gap =
            math.sqrt((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z));
        worst = math.max(worst, (gap - path.sampleSpacing).abs());
      }
      // Under a millimetre. A spline resampled by *parameter* rather than by
      // arc length would be out by tens of centimetres in the corners, and
      // every kerb quad round the lap would be a different size.
      expect(worst, lessThan(0.001));
    });

    test('the frame is orthonormal and the normal is the right of travel', () {
      final TrackPath path = circle(50);
      for (final TrackSample sample in path.samples) {
        expect(
          sample.tangentX * sample.tangentX + sample.tangentZ * sample.tangentZ,
          closeTo(1, 1e-9),
        );
        expect(
          sample.tangentX * sample.normalX + sample.tangentZ * sample.normalZ,
          closeTo(0, 1e-9),
        );
        expect(sample.normalX, closeTo(-sample.tangentZ, 1e-12));
        expect(sample.normalZ, closeTo(sample.tangentX, 1e-12));
      }
    });

    test('curvature is one over the radius', () {
      // Fifteen per cent, and the slack is honest rather than sloppy: see
      // [TrackSample.curvature]. What is being checked is that the estimate
      // scales as 1/r and has the right magnitude, which is all the
      // opponent's `sqrt(a/k)` needs of it.
      for (final double radius in <double>[20, 50, 120]) {
        final TrackPath path = circle(radius);
        for (final TrackSample sample in path.samples) {
          expect(sample.curvature.abs(), closeTo(1 / radius, 0.15 / radius));
        }
      }
    });

    test('frameAt wraps and interpolates', () {
      final TrackPath path = circle(50);
      final TrackSample zero = path.frameAt(0);
      final TrackSample lap = path.frameAt(path.length);
      expect(lap.x, closeTo(zero.x, 1e-9));
      expect(lap.z, closeTo(zero.z, 1e-9));
      // Negative distance is a kart on the grid, behind the line.
      final TrackSample behind = path.frameAt(-3);
      expect(behind.distance, closeTo(path.length - 3, 1e-6));
    });

    test('a loop with fewer than four points is refused by name', () {
      expect(
        () => TrackPath.fromControlPoints(const <(double, double)>[(0, 0)]),
        throwsArgumentError,
      );
    });

    test('a degenerate loop is refused rather than producing NaN', () {
      expect(
        () => TrackPath.fromControlPoints(
          const <(double, double)>[(0, 0), (0, 0), (0, 0), (0, 0)],
        ),
        throwsArgumentError,
      );
    });
  });

  group('project', () {
    test('a point on the centreline reports its own arc length and no offset',
        () {
      final TrackPath path = circle(50);
      for (final double at in <double>[0, 40, 120, 300]) {
        final TrackSample frame = path.frameAt(at);
        final TrackProjection where = path.project(frame.x, frame.z);
        expect(where.distance, closeTo(at, 0.05));
        expect(where.lateral, closeTo(0, 0.02));
      }
    });

    test('an offset point reports the offset, signed to the right of travel',
        () {
      final TrackPath path = circle(50);
      final TrackSample frame = path.frameAt(90);
      for (final double offset in <double>[-4, -1.5, 2, 4.5]) {
        final TrackProjection where = path.project(
          frame.x + frame.normalX * offset,
          frame.z + frame.normalZ * offset,
        );
        expect(where.lateral, closeTo(offset, 0.06));
        expect(where.distance, closeTo(90, 0.4));
      }
    });

    test('a hint gives the same answer as a full search', () {
      // The whole point of the hint is speed, so the one thing that must never
      // differ is the answer. A window that silently disagreed with the full
      // search would put a kart on the wrong part of the lap.
      final TrackPath path = buildCircuit();
      for (double at = 0; at < path.length; at += 3.1) {
        final TrackSample frame = path.frameAt(at);
        final double x = frame.x + frame.normalX * 3;
        final double z = frame.z + frame.normalZ * 3;
        final TrackProjection full = path.project(x, z);
        final TrackProjection hinted =
            path.project(x, z, hint: full.sampleIndex);
        expect(hinted.distance, closeTo(full.distance, 1e-9));
        expect(hinted.lateral, closeTo(full.lateral, 1e-9));
      }
    });

    test('a stale hint falls back to the full search', () {
      // A kart that spun, was rammed or was reset is nowhere near its hint,
      // and a window search that trusted itself would report the wrong half of
      // the lap - and count a lap that was never driven.
      final TrackPath path = buildCircuit();
      final TrackSample frame = path.frameAt(path.length * 0.5);
      final TrackProjection truth = path.project(frame.x, frame.z);
      final TrackProjection stale = path.project(frame.x, frame.z, hint: 0);
      expect(stale.distance, closeTo(truth.distance, 1e-9));
    });
  });

  group('the shipped circuit', () {
    final TrackPath path = buildCircuit();

    test('is a closed loop of a plausible length', () {
      expect(path.length, greaterThan(400));
      expect(path.length, lessThan(900));
    });

    test('never comes within a road width of itself', () {
      // The failure a hand-placed loop actually has. Two parts of the circuit
      // closer together than two half-widths plus the barriers share road, and
      // the *first* symptom is not a visual one - it is a kart projecting onto
      // the wrong part of the lap and teleporting a third of a lap forward.
      final double needed = 2 * path.wallOffset + 4;
      double worst = double.infinity;
      int worstAt = -1;
      for (int i = 0; i < path.sampleCount; i++) {
        for (int j = i + 1; j < path.sampleCount; j++) {
          final int gap = math.min(j - i, path.sampleCount - (j - i));
          // Neighbours along the ribbon are supposed to be close.
          if (gap * path.sampleSpacing < 40) continue;
          final TrackSample a = path.sampleAt(i);
          final TrackSample b = path.sampleAt(j);
          final double d =
              math.sqrt((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z));
          if (d < worst) {
            worst = d;
            worstAt = i;
          }
        }
      }
      expect(
        worst,
        greaterThan(needed),
        reason: 'the circuit doubles back on itself near sample $worstAt',
      );
    });

    test('has no corner tighter than a kart can hold', () {
      // 12 m is the floor, and it is not arbitrary: a corner of radius r takes
      // `sqrt(a·r)` at best, so 12 m is a 13 m/s hairpin - slow, and drivable.
      // The first draft of this circuit had a 3.2 m pinch where two control
      // points met at a sharp angle, which is a corner no speed takes and
      // which reads from the cockpit as the track being broken.
      double tightest = 0;
      for (final TrackSample sample in path.samples) {
        tightest = math.max(tightest, sample.curvature.abs());
      }
      expect(1 / tightest, greaterThan(12));
    });

    test('the start line sits on a straight, not in a corner', () {
      // The grid is behind the line; a start line at an apex points the whole
      // field across the road for the countdown.
      for (double at = -14; at <= 6; at += 2) {
        expect(
          path.frameAt(at).curvature.abs(),
          lessThan(1 / 40),
          reason: 'the start line is in a corner at $at m',
        );
      }
    });
  });
}
