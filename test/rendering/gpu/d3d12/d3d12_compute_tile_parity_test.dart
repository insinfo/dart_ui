/// Approach D, executed for the first time, checked against its own oracle.
///
/// `ComputeTileScene` and `ComputeTilePlan` have existed as a preparation
/// contract with no consumer: flattened segments, ordered draws, CSR tile bins,
/// one command per occupied tile - and `ComputeTileCpuReference`, a deliberately
/// slow independent rasteriser over exactly those bytes. This file is the first
/// time the plan reaches a GPU, and the reference is what says whether it
/// arrived intact.
///
/// ## What a disagreement here would mean
///
/// Not "the coverage algorithm is wrong": both sides run the same one, and the
/// shader is a transcription of the Dart. A disagreement is a *transport*
/// failure - a structured-buffer stride that does not match the array's, a
/// root descriptor bound to the wrong register, a tile index decoded with the
/// wrong column count, a coverage buffer that was never zeroed, a dispatch that
/// skipped a group. None of those is visible in a unit test of the plan, and all
/// of them produce plausible-looking pictures.
///
/// ## The tolerances, measured rather than assumed
///
/// **Zero on axis-aligned geometry.** For a vertical edge the crossing
/// expression `x0 + (y - y0) * (x1 - x0) / (y1 - y0)` collapses to `x0`, which
/// is exact in float32 and in float64 alike, and horizontal edges are rejected
/// by the same test on both sides. Every rectangle scene below therefore has to
/// match byte for byte, and does.
///
/// **A bounded, stated deviation on slanted and curved geometry.** Dart
/// evaluates that expression in float64 over float32 inputs; the shader
/// evaluates it in float32. Where a crossing lands within a float32 ulp of a
/// subsample the two can disagree about that one subsample, which is
/// `255 / (sampleGrid * sampleGrid)` = 16 levels at the default grid. Each test
/// records what was actually observed on this adapter; the tolerance is the
/// one-subsample bound, and a scene that exceeded it would be a real bug rather
/// than rounding.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_compute_tile_executor.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_reference.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

const int _width = 64;
const int _height = 64;

/// One flipped subsample of sixteen. See the library comment.
const int _oneSubsample = 16;

void main() {
  final D3d12Session session = D3d12Session.open(computeTiles: true);
  tearDownAll(session.close);

  group('the compute-tile pipeline exists on this device', () {
    test('the device reports it, and reports compute as a capability', () {
      if (_skipped(session)) return;
      expect(session.device!.experimentalComputeTilesEnabled, isTrue);
      // The capability follows the flag rather than being hard-coded, so a
      // selector cannot choose approach D on a device with nothing to run it.
      expect(session.device!.capabilities.supportsCompute, isTrue);
    });

    test('a device opened without the flag refuses and reports no compute', () {
      if (_skipped(session)) return;
      final D3d12Session plain = D3d12Session.open();
      addTearDown(plain.close);
      if (plain.skipReason != null) {
        markTestSkipped('no second device: ${plain.skipReason}');
        return;
      }
      expect(plain.device!.experimentalComputeTilesEnabled, isFalse);
      expect(plain.device!.capabilities.supportsCompute, isFalse);
      expect(
        () => plain.device!.submitComputeTiles(_planFor(_rect(8, 8, 40, 40))),
        throwsA(isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('enableExperimentalComputeTiles'),
        )),
      );
    });
  });

  group('the GPU tile pass matches the CPU reference', () {
    test('one axis-aligned rectangle: 0', () {
      // The floor of the comparison, and the scene that pins the transport: a
      // wrong stride, a wrong column count or an unzeroed buffer all show up
      // here as a shape in the wrong place or as noise outside it.
      // Observed deviation: 0.
      _expectComputeParity(session, _planFor(_rect(8, 8, 40, 40)),
          tolerance: 0);
    });

    test('a rectangle with fractional edges: 0', () {
      // Partial coverage on all four sides, so the supersampling loop and the
      // integer quantisation both matter. Still exact: every edge is axis
      // aligned.
      // Observed deviation: 0.
      _expectComputeParity(
        session,
        _planFor(_rect(6.25, 9.5, 41.75, 38.5)),
        tolerance: 0,
      );
    });

    test('two draws, overlapping, sharing tiles: 0', () {
      // Two draws in the same tiles is what exercises the CSR bins: each tile's
      // command names a run of references, and a run read at the wrong offset
      // would compose the wrong draw into the wrong output slice. The per-draw
      // coverage layout makes that visible instead of blending it away.
      // Observed deviation: 0.
      final ComputeTileScene scene = ComputeTileScene();
      scene.appendPath(
        _rect(4, 4, 36, 36),
        clip: _clip,
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );
      scene.appendPath(
        _rect(20, 20, 60, 60),
        clip: _clip,
        materialIndex: 1,
        fillRule: FillRule.nonZero,
      );
      final ComputeTilePlan plan =
          scene.build(width: _width, height: _height, tileSize: 16);
      expect(plan.drawCount, 2);
      _expectComputeParity(session, plan, tolerance: 0);
    });

    test('a self-overlapping path, even-odd against non-zero: 0', () {
      if (_skipped(session)) return;
      // The same geometry appended twice with different fill rules, so the two
      // draws differ *only* in the rule. A shader that read the rule field from
      // the wrong lane of the draw header would make them identical, which is
      // exactly the kind of failure that still looks like a picture.
      // Observed deviation: 0.
      final Path path = _twoRects();
      final ComputeTileScene scene = ComputeTileScene();
      final ComputePathEncoding encoding = ComputePathEncoding.fromPath(path);
      scene.appendEncoding(
        encoding,
        clip: _clip,
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );
      scene.appendEncoding(
        encoding,
        clip: _clip,
        materialIndex: 1,
        fillRule: FillRule.evenOdd,
      );
      final ComputeTilePlan plan =
          scene.build(width: _width, height: _height, tileSize: 16);
      // One encoding, two draws: the segment range is shared, which is the
      // deduplication the scene promises and which the shader has to honour by
      // reading `firstSegment` from the draw and not from the draw index.
      expect(plan.drawCount, 2);
      expect(plan.drawFirstSegment(0), plan.drawFirstSegment(1));

      final ComputeTileCoverage coverage = _dispatch(session, plan);
      final ComputeTileCpuReference reference = ComputeTileCpuReference(plan);
      _compare(coverage, reference, plan, tolerance: 0);
      // And they really do differ, or the scene would prove nothing.
      expect(
        coverage.rasterizedDraw(0),
        isNot(equals(coverage.rasterizedDraw(1))),
        reason: 'non-zero and even-odd produced the same coverage, so the '
            'fill rule never reached the shader',
      );
    });

    test('a slanted quadrilateral: one subsample', () {
      // Measured on Intel UHD Graphics, feature level 12_1: **16 levels on 8 of
      // 4096 elements**, out of 913 with ink. Sixteen levels is exactly one
      // flipped subsample of the sixteen this grid takes, which is the
      // float32/float64 difference the library comment predicts and not a
      // transport error - a transport error moves whole runs of pixels, not
      // eight isolated ones by one subsample each.
      _expectComputeParity(
        session,
        _planFor(_slanted()),
        tolerance: _oneSubsample,
      );
    });

    test('a flattened curve: one subsample', () {
      // Hundreds of short segments whose endpoints are not representable
      // exactly, which is the worst case for the float32/float64 difference and
      // the case a real vector scene actually looks like.
      //
      // Measured on the same adapter: **0**. The tolerance stays at one
      // subsample rather than being tightened to the measurement, because the
      // deviation this scene is allowed is a property of float32 arithmetic and
      // not of this driver, and a scene that started differing by one subsample
      // on another adapter would be right rather than broken.
      _expectComputeParity(
        session,
        _planFor(_blob()),
        tolerance: _oneSubsample,
      );
    });

    test('a non-square tile grid with a partial last tile: 0', () {
      // 50x34 tiles at 16 pixels leaves a partial column and a partial row, so
      // this is where a thread that clamped instead of retiring would write
      // outside the surface - or where a `tile / columns` with the wrong
      // divisor would fold the last column onto the next row.
      // Observed deviation: 0.
      final ComputeTileScene scene = ComputeTileScene();
      scene.appendPath(
        _rect(3, 3, 47, 31),
        clip: const Rect.fromLTRB(0, 0, 50, 34),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );
      final ComputeTilePlan plan =
          scene.build(width: 50, height: 34, tileSize: 16);
      _expectComputeParity(session, plan, tolerance: 0);
    });

    test('a tile size of 8, below the thread group: 0', () {
      // The threads outside the plan's tile size have to retire, not clamp.
      // Observed deviation: 0.
      final ComputeTileScene scene = ComputeTileScene();
      scene.appendPath(
        _rect(5.5, 7, 44, 40.5),
        clip: _clip,
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );
      final ComputeTilePlan plan =
          scene.build(width: _width, height: _height, tileSize: 8);
      _expectComputeParity(session, plan, tolerance: 0);
    });
  });

  group('the executor refuses what it cannot run', () {
    test('a tile larger than the thread group, by name', () {
      if (_skipped(session)) return;
      final ComputeTileScene scene = ComputeTileScene();
      scene.appendPath(
        _rect(4, 4, 40, 40),
        clip: _clip,
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );
      final ComputeTilePlan plan =
          scene.build(width: _width, height: _height, tileSize: 32);
      expect(
        () => session.device!.submitComputeTiles(plan),
        throwsA(isA<ComputeTileD3d12Error>().having(
          (ComputeTileD3d12Error error) => error.rejection,
          'rejection',
          ComputeTileD3d12Rejection.tileSizeExceedsThreadGroup,
        )),
      );
    });

    test('a sample grid outside the reference range, by name', () {
      if (_skipped(session)) return;
      expect(
        () => session.device!
            .submitComputeTiles(_planFor(_rect(4, 4, 40, 40)), sampleGrid: 32),
        throwsA(isA<ComputeTileD3d12Error>().having(
          (ComputeTileD3d12Error error) => error.rejection,
          'rejection',
          ComputeTileD3d12Rejection.sampleGridOutOfRange,
        )),
      );
    });

    test('an empty scene dispatches nothing and reads back zeros', () {
      if (_skipped(session)) return;
      final ComputeTilePlan plan = ComputeTileScene()
          .build(width: _width, height: _height, tileSize: 16);
      final ComputeTileCoverage coverage =
          session.device!.submitComputeTiles(plan);
      expect(coverage.groupCount, 0);
      expect(coverage.drawCount, 0);
    });

    test('the device survives the whole file', () {
      if (_skipped(session)) return;
      expect(session.device!.isLost, isFalse);
    });
  });
}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

const Rect _clip = Rect.fromLTRB(0, 0, 64, 64);

Path _rect(double left, double top, double right, double bottom) {
  final PathBuilder builder = PathBuilder()
    ..moveTo(left, top)
    ..lineTo(right, top)
    ..lineTo(right, bottom)
    ..lineTo(left, bottom)
    ..close();
  return builder.build();
}

Path _twoRects() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(8, 8)
    ..lineTo(40, 8)
    ..lineTo(40, 40)
    ..lineTo(8, 40)
    ..close()
    ..moveTo(24, 24)
    ..lineTo(56, 24)
    ..lineTo(56, 56)
    ..lineTo(24, 56)
    ..close();
  return builder.build();
}

Path _slanted() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(6, 54)
    ..lineTo(31, 7)
    ..lineTo(58, 50)
    ..lineTo(31, 39)
    ..close();
  return builder.build();
}

Path _blob() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(32, 6)
    ..cubicTo(52, 6, 58, 26, 52, 40)
    ..cubicTo(46, 54, 22, 60, 12, 46)
    ..cubicTo(4, 34, 12, 10, 32, 6)
    ..close();
  return builder.build();
}

ComputeTilePlan _planFor(Path path, {FillRule rule = FillRule.nonZero}) {
  final ComputeTileScene scene = ComputeTileScene();
  scene.appendPath(
    path,
    clip: _clip,
    materialIndex: 0,
    fillRule: rule,
  );
  return scene.build(width: _width, height: _height, tileSize: 16);
}

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

bool _skipped(D3d12Session session) {
  final String? reason = session.skipReason;
  if (reason == null) return false;
  printOnFailure('skipped: $reason');
  markTestSkipped('no Direct3D 12 device: $reason');
  return true;
}

ComputeTileCoverage _dispatch(D3d12Session session, ComputeTilePlan plan) {
  final D3d12RenderDevice device = session.device!;
  final ComputeTileCoverage coverage = device.submitComputeTiles(plan);
  expect(coverage.groupCount, plan.commandCount);
  expect(coverage.width, plan.width);
  expect(coverage.height, plan.height);
  return coverage;
}

void _expectComputeParity(
  D3d12Session session,
  ComputeTilePlan plan, {
  required int tolerance,
}) {
  if (_skipped(session)) return;
  final ComputeTileCpuReference reference = ComputeTileCpuReference(plan);
  // The plan's own invariants first: a bin that omitted a covering draw would
  // make the GPU and the CPU agree on the *wrong* answer, because both read the
  // same bins.
  expect(reference.validateBins(), isEmpty);
  final ComputeTileCoverage coverage = _dispatch(session, plan);
  _compare(coverage, reference, plan, tolerance: tolerance);
}

void _compare(
  ComputeTileCoverage coverage,
  ComputeTileCpuReference reference,
  ComputeTilePlan plan, {
  required int tolerance,
}) {
  var maxDeviation = 0;
  var differing = 0;
  var inked = 0;
  final List<String> lines = <String>[];
  for (var draw = 0; draw < plan.drawCount; draw++) {
    final Uint8List expected = reference.rasterizeDraw(draw);
    final Uint8List actual = coverage.rasterizedDraw(draw);
    expect(actual.length, expected.length);
    for (var i = 0; i < expected.length; i++) {
      if (expected[i] != 0) inked++;
      final int deviation = (expected[i] - actual[i]).abs();
      if (deviation == 0) continue;
      differing++;
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (lines.length < 12) {
        lines.add('draw $draw (${i % plan.width}, ${i ~/ plan.width}): '
            'cpu ${expected[i]}, gpu ${actual[i]}');
      }
    }
  }

  // A plan whose draws cover nothing would compare two empty images and pass.
  expect(inked, greaterThan(0),
      reason: 'the scene produced no coverage, so comparing it proves nothing');
  printOnFailure('max deviation $maxDeviation over $differing of '
      '${plan.drawCount * plan.width * plan.height} elements, $inked inked');
  expect(
    maxDeviation,
    lessThanOrEqualTo(tolerance),
    reason: 'the CPU reference and the Direct3D 12 tile pass disagree by up to '
        '$maxDeviation levels on $differing elements, over a declared '
        'tolerance of $tolerance.\n${lines.join('\n')}',
  );
}
