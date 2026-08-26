/// Flattening, executed on the GPU for the first time, against its oracle.
///
/// Approach D's coverage stage has run on the device since
/// `d3d12_compute_tile_shader.dart`; every segment it consumed had been
/// produced by `Path.flattenTo` on the CPU. This file is the first time a
/// **curve** reaches a GPU in this framework and comes back as line segments.
///
/// ## What a disagreement here would mean
///
/// Three different things, and the test is built so they cannot be confused:
///
///   * **A count disagreement** is not a rounding difference. The counts feed a
///     prefix sum, so one curve counted differently moves every later segment
///     in the buffer. Either the segment-count formula was transcribed wrong,
///     or the scene reached the shader with the wrong stride. The counts are
///     compared **exactly**, and `compute_flatten_reference_test.dart` first
///     establishes that no curve in these scenes sits near the `ceil` boundary
///     where a last-bit difference could legitimately move one.
///   * **An offset disagreement with matching counts** is the scan: a missing
///     barrier between the block scan and the apply, a block sum read before it
///     was written, or the grand total written by the wrong lane. Compared
///     exactly, because a prefix sum of integers has no rounding to forgive.
///   * **A coordinate disagreement with matching counts and offsets** is the
///     evaluation, and this is the only one that is allowed to be non-zero. The
///     reference rounds to float32 after every operation, but a compiler may
///     still contract `a * b + c` into one operation with a single rounding,
///     and no HLSL flag forbids it. The bound is stated below and the observed
///     number is printed.
///
/// ## The tolerance on coordinates, derived rather than tried
///
/// A device-space coordinate here is at most a few hundred pixels, and float32
/// carries about `6e-8` of relative precision. The evaluation chain is a
/// handful of operations deep, so a contracted rounding can move a coordinate
/// by a few ulps of its own magnitude - on the order of `1e-4` pixels at these
/// sizes. [_coordinateTolerance] is `1 / 1024` of a pixel, an order of
/// magnitude above that and two orders below the quarter-pixel flatten
/// tolerance, so it cannot hide a curve that was subdivided differently. Each
/// test records what was actually observed.
///
/// ## And the picture, which is the point
///
/// Matching floats are not the claim; matching pixels are. Every scene is also
/// rasterised twice through the same crossing evaluator - once from the GPU's
/// segments and once from `Path.flatten`'s - and compared. That is the check
/// that would fail if the flatten stage were self-consistently wrong.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_compute_flatten_driver.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_curve_scene.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_flatten_reference.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_flatten_executor.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_flatten_shader.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

/// A thousandth of a pixel. See the library comment for where it comes from.
const double _coordinateTolerance = 1.0 / 1024.0;

/// One flipped subsample of a 4x4 grid, in coverage levels.
const int _oneSubsample = 16;

const int _width = 80;
const int _height = 60;

void main() {
  final D3d12Session session = D3d12Session.open();
  D3d12ComputeFlattenDriver? driver;
  ComputeFlattenExecutor? executor;

  tearDownAll(() {
    executor?.dispose();
    driver?.dispose();
    session.close();
  });

  ComputeFlattenExecutor? open() {
    if (session.device == null) return null;
    if (executor != null) return executor;
    final D3d12ComputeFlattenDriver made =
        D3d12ComputeFlattenDriver(session.device!);
    driver = made;
    final ComputeFlattenExecutor built = ComputeFlattenExecutor(made)
      ..initialize();
    return executor = built;
  }

  group('the flatten kernels build on this device', () {
    test('the shader contract holds without a device', () {
      // Cheap, and it runs on every platform: a root constant renamed on one
      // side of the seam and not the other compiles and binds and draws wrong.
      expect(validateComputeFlattenShaderContract, returnsNormally);
      expect(kComputeFlattenEntryPoints.length, 5);
      expect(kComputeFlattenMaxCurves,
          kComputeFlattenGroupSize * kComputeFlattenGroupSize);
    });

    test('five compute pipelines are created', () {
      if (_skipped(session)) return;
      final ComputeFlattenExecutor? built = open();
      expect(built, isNotNull);
      expect(built!.isInitialized, isTrue);
      expect(driver!.isBuilt, isTrue);
    });
  });

  group('the GPU flatten matches the CPU reference', () {
    for (final _Scene scene in _scenes()) {
      test(scene.name, () {
        if (_skipped(session)) return;
        final ComputeFlattenExecutor built = open()!;
        final ComputeCurveScene curves = ComputeCurveScene();
        curves.appendPath(scene.path, transform: scene.transform);
        final ComputeCurveUpload upload = curves.upload();
        final ComputeFlattenReference reference =
            ComputeFlattenReference(upload);
        final ComputeFlattenResult result = built.flatten(upload);

        expect(result.counts, reference.counts,
            reason: 'segment counts must agree exactly; see the library '
                'comment on why a count is not a rounding difference');
        expect(result.offsets, reference.offsets,
            reason: 'the prefix sum is integer arithmetic and has no rounding '
                'to forgive');
        expect(result.totalSegments, reference.totalSegments);
        expect(result.segments.length, reference.segments.length);

        var worst = 0.0;
        var worstAt = -1;
        for (var i = 0; i < result.segments.length; i++) {
          final double delta =
              (result.segments[i] - reference.segments[i]).abs();
          if (delta > worst) {
            worst = delta;
            worstAt = i;
          }
        }
        printOnFailure(
          'worst coordinate deviation $worst px at float $worstAt of '
          '${result.segments.length}, over ${result.totalSegments} segments',
        );
        expect(worst, lessThan(_coordinateTolerance),
            reason: 'observed $worst px');

        // The picture, which is what any of this is for.
        final Uint8List fromGpu = coverageOfSegments(
          result.segments,
          width: _width,
          height: _height,
        );
        final Uint8List fromCpu = coverageOfSegments(
          flattenOnCpu(scene.path, transform: scene.transform),
          width: _width,
          height: _height,
        );
        var levels = 0;
        var differing = 0;
        for (var i = 0; i < fromGpu.length; i++) {
          final int delta = (fromGpu[i] - fromCpu[i]).abs();
          if (delta != 0) differing++;
          levels = math.max(levels, delta);
        }
        printOnFailure(
          '$differing of ${fromGpu.length} pixels differ from the CPU '
          'polyline, worst $levels levels',
        );
        // The GPU polyline and `Path.flattenTo`'s are two different
        // approximations of the same curve - direct evaluation against forward
        // differences - so an antialiased edge pixel may move by a subsample.
        // The interior and the background may not.
        expect(levels, lessThanOrEqualTo(_oneSubsample),
            reason: '$differing pixels differ, worst $levels levels');
      });
    }

    test('several paths in one scene keep their own transforms', () {
      if (_skipped(session)) return;
      // One dispatch, three paths, three different affine maps and two
      // different tolerances. A kernel that read the transform of the wrong
      // path - or of path 0 for everything - draws a plausible picture, so the
      // check is per segment against the oracle rather than by eye.
      final ComputeFlattenExecutor built = open()!;
      final ComputeCurveScene curves = ComputeCurveScene();
      curves.appendPath(_roundedPanel());
      curves.appendPath(
        Path.oval(const Rect.fromLTRB(0, 0, 20, 14)),
        transform: const Transform2D(1.5, 0.4, -0.4, 1.5, 34, 22),
      );
      curves.appendPath(
        _sCurve(),
        transform: const Transform2D.scaling(0.5, 0.5),
        flattenTolerance: 0.05,
      );
      final ComputeCurveUpload upload = curves.upload();
      final ComputeFlattenReference reference = ComputeFlattenReference(upload);
      final ComputeFlattenResult result = built.flatten(upload);

      expect(upload.pathCount, 3);
      expect(result.counts, reference.counts);
      expect(result.offsets, reference.offsets);
      expect(_worstDeviation(result.segments, reference.segments),
          lessThan(_coordinateTolerance));
    });
  });

  group('the prefix sum survives more than one block', () {
    test('a scene of more than one scan block sums across blocks', () {
      if (_skipped(session)) return;
      // The bug this catches is specific and invisible in a small scene:
      // `csScanApply` adds the wrong block's offset, or `csScanBlockSums`
      // scans an unwritten sum. Both need at least two blocks to exist, and
      // one path of 256 curves is not a scene anybody would draw - which is why
      // it is built here rather than hoped for.
      final ComputeFlattenExecutor built = open()!;
      final ComputeCurveScene curves = ComputeCurveScene();
      final PathBuilder builder = PathBuilder()..moveTo(4, 4);
      for (var i = 0; i < 300; i++) {
        final double t = i / 300.0;
        builder.quadraticBezierTo(
          6 + 60 * t,
          4 + 40 * math.sin(t * 9),
          8 + 60 * t,
          6 + 40 * t * (1 - t),
        );
      }
      builder.close();
      curves.appendPath(builder.build());
      final ComputeCurveUpload upload = curves.upload();
      expect(upload.curveCount, greaterThan(kComputeFlattenGroupSize));

      final ComputeFlattenReference reference = ComputeFlattenReference(upload);
      final ComputeFlattenResult result = built.flatten(upload);
      expect(result.counts, reference.counts);
      expect(result.offsets, reference.offsets,
          reason: 'the two-level scan must agree with a serial prefix sum '
              'across block boundaries');
      expect(_worstDeviation(result.segments, reference.segments),
          lessThan(_coordinateTolerance));
    });
  });

  group('the segment budget behaves like a bump allocator', () {
    test('an overflowing budget grows once and lands exactly', () {
      if (_skipped(session)) return;
      final ComputeFlattenExecutor built = open()!;
      final ComputeCurveScene curves = ComputeCurveScene();
      curves.appendPath(Path.oval(const Rect.fromLTRB(2, 2, 150, 110)));
      final ComputeCurveUpload upload = curves.upload();
      final ComputeFlattenReference reference = ComputeFlattenReference(upload);

      final ComputeFlattenResult result =
          built.flatten(upload, segmentBudget: 4);
      expect(result.passes, 2,
          reason: 'a budget of 4 cannot hold '
              '${reference.totalSegments} segments');
      expect(result.segmentBudget, reference.totalSegments);
      expect(result.totalSegments, reference.totalSegments);
      expect(_worstDeviation(result.segments, reference.segments),
          lessThan(_coordinateTolerance));

      // And the total the overflowing pass reported was already exact: running
      // again with it needs no second pass.
      final ComputeFlattenResult again =
          built.flatten(upload, segmentBudget: result.segmentBudget);
      expect(again.passes, 1);
      expect(again.segments, result.segments);
    });

    test('a repeated scene is deterministic', () {
      if (_skipped(session)) return;
      // Bit equality between two dispatches of the same scene. A pipeline that
      // used an append buffer instead of a scan would pass every test above and
      // fail this one, because the order would follow whichever group retired
      // first.
      final ComputeFlattenExecutor built = open()!;
      final ComputeCurveScene curves = ComputeCurveScene();
      curves.appendPath(_roundedPanel());
      final ComputeCurveUpload upload = curves.upload();
      final ComputeFlattenResult first = built.flatten(upload);
      final ComputeFlattenResult second = built.flatten(upload);
      expect(second.segments, first.segments);
      expect(second.offsets, first.offsets);
    });
  });
}

bool _skipped(D3d12Session session) {
  if (session.device != null) return false;
  markTestSkipped(session.skipReason ?? 'no Direct3D 12 device');
  return true;
}

double _worstDeviation(Float32List a, Float32List b) {
  expect(a.length, b.length);
  var worst = 0.0;
  for (var i = 0; i < a.length; i++) {
    worst = math.max(worst, (a[i] - b[i]).abs());
  }
  printOnFailure('worst coordinate deviation $worst px');
  return worst;
}

final class _Scene {
  const _Scene(this.name, this.path, this.transform);
  final String name;
  final Path path;
  final Transform2D transform;
}

/// The same geometry `compute_flatten_reference_test.dart` establishes the
/// count margins for, so the exact integer comparison above is known to be a
/// fair test on every one of them.
List<_Scene> _scenes() => <_Scene>[
      _Scene(
          'a rectangle: four lines, one segment each',
          Path.rect(
            const Rect.fromLTRB(8, 6, 60, 44),
          ),
          Transform2D.identity),
      _Scene('a rounded panel', _roundedPanel(), Transform2D.identity),
      _Scene(
        'an ellipse',
        Path.oval(const Rect.fromLTRB(6.5, 4.25, 64.5, 48.75)),
        Transform2D.identity,
      ),
      _Scene('an S-curve', _sCurve(), Transform2D.identity),
      _Scene(
        'a quadratic arc under a rotation',
        _quadraticArc(),
        const Transform2D(0.866, 0.5, -0.5, 0.866, 30, 6),
      ),
      _Scene(
        'a rounded panel magnified four times',
        _smallPanel(),
        const Transform2D.scaling(4, 4),
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
