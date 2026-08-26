/// The GPU flatten specification, checked before any GPU is involved.
///
/// `d3d12_compute_flatten_parity_test.dart` compares the shader against
/// [ComputeFlattenReference], and that comparison can only say the two agree.
/// It cannot say whether what they agree on is *right* - two transcriptions of
/// the same mistake agree perfectly. So this file checks the specification
/// itself, on the CPU, on every runner:
///
///   * the encoder turns a path into the curves the path is made of, and closes
///     open contours;
///   * the flattened polyline stays inside the tolerance of the curve it
///     replaces - the property `kDefaultFlattenTolerance` exists to state;
///   * direct evaluation is at least as accurate as the forward differences
///     `Path.flattenTo` uses, which is the claim `compute_curve_scene.dart`
///     makes about why the parallel form is not a compromise;
///   * adjacent segments meet exactly, so the outline is watertight;
///   * the picture matches `Path.flatten`'s, which is what "flattening moved to
///     the GPU" has to mean if it is not to change how the framework draws;
///   * zero-length segments, which this stage keeps and the CPU sink drops,
///     change no pixel.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_curve_scene.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_flatten_reference.dart';
import 'package:test/test.dart';

void main() {
  group('the encoder produces the curves the path is made of', () {
    test('a rectangle is four lines and no closing duplicate', () {
      final ComputeCurveScene scene = ComputeCurveScene();
      expect(scene.appendPath(Path.rect(const Rect.fromLTRB(2, 3, 20, 30))), 0);
      // addRect emits moveTo plus three lineTo plus close, so the fourth edge
      // is the close and there is nothing left over to duplicate it.
      expect(scene.curveCount, 4);
      for (var curve = 0; curve < scene.curveCount; curve++) {
        expect(scene.curveKind(curve), kComputeCurveKindLine);
        expect(scene.curvePath(curve), 0);
      }
      final ComputeFlattenReference reference =
          ComputeFlattenReference(scene.upload());
      expect(reference.counts, everyElement(1));
      expect(reference.totalSegments, 4);
    });

    test('an open contour gets its closing edge', () {
      final PathBuilder builder = PathBuilder()
        ..moveTo(0, 0)
        ..lineTo(10, 0)
        ..lineTo(10, 10);
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(builder.build());
      // Two lineTo verbs, and a third curve that exists only because filling
      // treats an open contour as closed.
      expect(scene.curveCount, 3);
      expect(scene.curvePoint(2, 0), 10);
      expect(scene.curvePoint(2, 1), 10);
      expect(scene.curvePoint(2, 6), 0);
      expect(scene.curvePoint(2, 7), 0);
    });

    test('a curve verb keeps its control points untransformed', () {
      final PathBuilder builder = PathBuilder()
        ..moveTo(0, 0)
        ..quadraticBezierTo(5, 20, 10, 0)
        ..close();
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(
        builder.build(),
        transform: const Transform2D.scaling(3, 3),
      );
      expect(scene.curveKind(0), kComputeCurveKindQuadratic);
      // Source space: the transform travels in the path record, because the
      // kernel needs it to choose a segment count in device space.
      expect(scene.curvePoint(0, 2), 5);
      expect(scene.curvePoint(0, 3), 20);
      expect(scene.pathTransform(0).a, 3);
    });

    test('an empty path is refused without touching the scene', () {
      final ComputeCurveScene scene = ComputeCurveScene();
      expect(scene.appendPath(Path.empty), -1);
      expect(scene.curveCount, 0);
      expect(scene.pathCount, 0);
    });

    test('a non-finite transform is rejected by name', () {
      final ComputeCurveScene scene = ComputeCurveScene();
      expect(
        () => scene.appendPath(
          Path.rect(const Rect.fromLTRB(0, 0, 4, 4)),
          transform: const Transform2D(1, 0, 0, 1, double.nan, 0),
        ),
        throwsA(isA<ComputeCurveError>().having(
          (ComputeCurveError error) => error.rejection,
          'rejection',
          ComputeCurveRejection.nonFiniteGeometry,
        )),
      );
      expect(scene.pathCount, 0);
    });

    test('a curve limit refuses transactionally', () {
      final ComputeCurveScene scene = ComputeCurveScene(maxCurves: 3);
      expect(
        () => scene.appendPath(Path.rect(const Rect.fromLTRB(0, 0, 4, 4))),
        throwsA(isA<ComputeCurveError>().having(
          (ComputeCurveError error) => error.rejection,
          'rejection',
          ComputeCurveRejection.curveLimitExceeded,
        )),
      );
      expect(scene.curveCount, 0);
      expect(scene.pathCount, 0);
    });
  });

  group('the flattened polyline is inside the tolerance', () {
    for (final (String name, Path path, Transform2D transform)
        in _toleranceScenes()) {
      test(name, () {
        const double tolerance = kDefaultFlattenTolerance;
        final ComputeCurveScene scene = ComputeCurveScene();
        scene.appendPath(path,
            transform: transform, flattenTolerance: tolerance);
        final ComputeFlattenReference reference =
            ComputeFlattenReference(scene.upload());

        var worst = 0.0;
        for (var curve = 0; curve < reference.curveCount; curve++) {
          worst = math.max(worst, _deviationOfCurve(reference, curve));
        }
        // The bound the tolerance promises, with room for the float32 rounding
        // of the evaluation itself. A polyline outside it is a curve drawn
        // visibly faceted, which is what the segment count formula exists to
        // prevent.
        expect(worst, lessThan(tolerance),
            reason: 'worst deviation from the true curve: $worst px');
      });
    }

    test('direct evaluation is no worse than forward differences', () {
      // The claim `compute_curve_scene.dart` makes about why the parallel form
      // is not a compromise. Forward differences accumulate rounding over n
      // steps; evaluating B(t) does not. Measured on a curve long enough for
      // the accumulation to be visible.
      final PathBuilder builder = PathBuilder()
        ..moveTo(0, 0)
        ..cubicTo(400, 900, 900, -500, 1200, 300)
        ..close();
      final Path path = builder.build();
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(path);
      final ComputeFlattenReference reference =
          ComputeFlattenReference(scene.upload());
      final double direct = _deviationOfCurve(reference, 0);

      final FlattenedPath flattened = path.flatten(kDefaultFlattenTolerance);
      var forward = 0.0;
      // Contour 0 spans the cubic's polyline; the closing edge is contour-level
      // and is not part of the curve being measured.
      final int end = flattened.contourStarts[1];
      for (var point = 1; point < end - 1; point++) {
        forward = math.max(
          forward,
          _distanceToCurve(
            reference,
            0,
            flattened.pointX(point),
            flattened.pointY(point),
          ),
        );
      }
      expect(direct, lessThanOrEqualTo(forward + 1e-9),
          reason: 'direct $direct px, forward differences $forward px');
    });
  });

  group('the segment stream is watertight and ordered', () {
    test('adjacent segments of a curve meet exactly', () {
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(_roundedPanel());
      final ComputeFlattenReference reference =
          ComputeFlattenReference(scene.upload());
      final Float32List segments = reference.segments;
      for (var curve = 0; curve < reference.curveCount; curve++) {
        final int first = reference.offsets[curve];
        final int count = reference.counts[curve];
        for (var index = 0; index + 1 < count; index++) {
          final int a = (first + index) * 4;
          final int b = (first + index + 1) * 4;
          // Bit equality, not approximate: a gap of one float32 ulp between two
          // segments is a hole the winding leaks through.
          expect(segments[a + 2], segments[b + 0]);
          expect(segments[a + 3], segments[b + 1]);
        }
      }
    });

    test('a closed contour closes on the encoded point', () {
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(_roundedPanel());
      final ComputeFlattenReference reference =
          ComputeFlattenReference(scene.upload());
      final Float32List segments = reference.segments;
      for (var curve = 0; curve + 1 < reference.curveCount; curve++) {
        final int lastOfCurve = (reference.offsets[curve + 1] - 1) * 4;
        final int firstOfNext = reference.offsets[curve + 1] * 4;
        expect(segments[lastOfCurve + 2], segments[firstOfNext + 0]);
        expect(segments[lastOfCurve + 3], segments[firstOfNext + 1]);
      }
      final int lastSegment = (reference.totalSegments - 1) * 4;
      expect(segments[lastSegment + 2], segments[0]);
      expect(segments[lastSegment + 3], segments[1]);
    });

    test('offsets are the exclusive prefix sum with the total appended', () {
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(_roundedPanel());
      scene.appendPath(Path.oval(const Rect.fromLTRB(4, 4, 60, 40)));
      final ComputeFlattenReference reference =
          ComputeFlattenReference(scene.upload());
      expect(reference.offsets.length, reference.curveCount + 1);
      expect(reference.offsets[0], 0);
      for (var curve = 0; curve < reference.curveCount; curve++) {
        expect(
          reference.offsets[curve + 1] - reference.offsets[curve],
          reference.counts[curve],
        );
      }
      expect(reference.offsets[reference.curveCount], reference.totalSegments);
      expect(reference.segments.length, reference.totalSegments * 4);
    });
  });

  group('the picture is the one the CPU route draws', () {
    for (final (String name, Path path, Transform2D transform)
        in _toleranceScenes()) {
      test(name, () {
        const int width = 72;
        const int height = 56;
        final ComputeCurveScene scene = ComputeCurveScene();
        scene.appendPath(path, transform: transform);
        final ComputeFlattenReference reference =
            ComputeFlattenReference(scene.upload());

        final Uint8List mine = coverageOfSegments(
          reference.segments,
          width: width,
          height: height,
        );
        final Uint8List theirs = coverageOfSegments(
          flattenOnCpu(path, transform: transform),
          width: width,
          height: height,
        );

        var worst = 0;
        var differing = 0;
        for (var i = 0; i < mine.length; i++) {
          final int delta = (mine[i] - theirs[i]).abs();
          if (delta != 0) differing++;
          worst = math.max(worst, delta);
        }
        // Two different polylines for the same curve, so an antialiased edge
        // pixel can differ by a subsample. One subsample of a 4x4 grid is 16
        // levels; the interior and the background are identical, which is what
        // makes a whole-shape defect impossible to hide here.
        expect(worst, lessThanOrEqualTo(16),
            reason: '$differing pixels differ, worst $worst levels');
      });
    }

    test('zero-length segments change nothing', () {
      // The argument `compute_curve_scene.dart` makes for not compacting the
      // stream on the GPU: a degenerate edge fails `y0 <= y && y1 > y` for
      // every y, so it contributes to no sample's winding.
      const int width = 40;
      const int height = 32;
      final ComputeCurveScene scene = ComputeCurveScene();
      scene.appendPath(_roundedPanel());
      final ComputeFlattenReference reference =
          ComputeFlattenReference(scene.upload());
      final Float32List kept = reference.segments;

      final List<double> compacted = <double>[];
      var dropped = 0;
      for (var segment = 0; segment < kept.length ~/ 4; segment++) {
        final double x0 = kept[segment * 4 + 0];
        final double y0 = kept[segment * 4 + 1];
        final double x1 = kept[segment * 4 + 2];
        final double y1 = kept[segment * 4 + 3];
        if (x0 == x1 && y0 == y1) {
          dropped++;
          continue;
        }
        compacted.addAll(<double>[x0, y0, x1, y1]);
      }
      // A deliberately degenerate edge, so the test proves the equality rather
      // than proving that this scene happened to have none.
      compacted.addAll(<double>[12.5, 9.25, 12.5, 9.25]);

      expect(
        coverageOfSegments(Float32List.fromList(compacted),
            width: width, height: height),
        coverageOfSegments(kept, width: width, height: height),
        reason: '$dropped degenerate edges in the stream',
      );
    });
  });

  group('the count boundary is far enough away to compare exactly', () {
    test('every curve of every scene clears the boundary by a margin', () {
      // The number `d3d12_compute_flatten_parity_test.dart` relies on: it
      // asserts that the shader's integer counts equal these, and that is only
      // a fair test if no curve sits where a last-bit difference in
      // `sqrt(ratio)` would move `ceil` to the next integer.
      var tightest = double.infinity;
      var checked = 0;
      for (final (String _, Path path, Transform2D transform)
          in _toleranceScenes()) {
        final ComputeCurveScene scene = ComputeCurveScene();
        scene.appendPath(path, transform: transform);
        final ComputeFlattenReference reference =
            ComputeFlattenReference(scene.upload());
        for (var curve = 0; curve < reference.curveCount; curve++) {
          final double margin = reference.segmentCountMargin(curve);
          if (!margin.isFinite) continue;
          checked++;
          tightest = math.min(tightest, margin);
        }
      }
      expect(checked, greaterThan(0));
      // float32 carries about 6e-8 of relative precision, so a margin of 1e-4
      // is three orders of magnitude of room. A scene that failed this would
      // not be a broken shader; it would be a scene the exact comparison must
      // not be run on.
      expect(tightest, greaterThan(1e-4),
          reason: 'tightest count margin across $checked curves: $tightest');
    });
  });
}

/// The scenes both the tolerance check and the picture check run over.
///
/// One list rather than two so that a scene added for one property is checked
/// for the other, and so the count-margin test above covers exactly the
/// geometry the GPU parity test uses.
List<(String, Path, Transform2D)> _toleranceScenes() =>
    <(String, Path, Transform2D)>[
      ('a rounded panel', _roundedPanel(), Transform2D.identity),
      (
        'an ellipse',
        Path.oval(const Rect.fromLTRB(6.5, 4.25, 64.5, 48.75)),
        Transform2D.identity
      ),
      ('an S-curve', _sCurve(), Transform2D.identity),
      (
        'a quadratic arc under a rotation',
        _quadraticArc(),
        const Transform2D(0.866, 0.5, -0.5, 0.866, 30, 6)
      ),
      (
        'a rounded panel magnified four times',
        _smallPanel(),
        const Transform2D.scaling(4, 4)
      ),
    ];

Path _roundedPanel() {
  final PathBuilder builder = PathBuilder()
    ..addRoundedRect(const Rect.fromLTRB(5.5, 6.25, 66.5, 47.75), 12, 10);
  return builder.build();
}

Path _smallPanel() {
  final PathBuilder builder = PathBuilder()
    ..addRoundedRect(const Rect.fromLTRB(1.5, 1.25, 16.5, 12.75), 3, 2.5);
  return builder.build();
}

Path _sCurve() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(8, 8)
    ..cubicTo(58, 2, 12, 46, 62, 40)
    ..lineTo(58, 50)
    ..cubicTo(10, 54, 54, 12, 6, 18)
    ..close();
  return builder.build();
}

Path _quadraticArc() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(2, 20)
    ..quadraticBezierTo(20, -18, 40, 20)
    ..quadraticBezierTo(20, 40, 2, 20)
    ..close();
  return builder.build();
}

/// The largest distance from any point of [curve]'s polyline to the true curve.
///
/// Measured as the distance from each polyline *midpoint* to a dense sampling
/// of the curve, because a subdivision's error is largest between two of its
/// endpoints, and the endpoints themselves lie on the curve by construction.
double _deviationOfCurve(ComputeFlattenReference reference, int curve) {
  final int count = reference.counts[curve];
  final int first = reference.offsets[curve];
  final Float32List segments = reference.segments;
  var worst = 0.0;
  for (var index = 0; index < count; index++) {
    final int base = (first + index) * 4;
    final double midX = (segments[base + 0] + segments[base + 2]) / 2;
    final double midY = (segments[base + 1] + segments[base + 3]) / 2;
    worst = math.max(worst, _distanceToCurve(reference, curve, midX, midY));
  }
  return worst;
}

/// Distance from ([x], [y]) to the nearest of 4096 samples of [curve].
double _distanceToCurve(
  ComputeFlattenReference reference,
  int curve,
  double x,
  double y,
) {
  const int samples = 4096;
  var best = double.infinity;
  for (var i = 0; i <= samples; i++) {
    final (double cx, double cy) = reference.evaluateExact(curve, i / samples);
    final double dx = cx - x;
    final double dy = cy - y;
    final double distance = dx * dx + dy * dy;
    if (distance < best) best = distance;
  }
  return math.sqrt(best);
}
