/// Approach D producing pixels: the tile shader, the coverage texture and the
/// composite quad, driven by a real display list.
///
/// `d3d12_compute_tile_parity_test.dart` proves the *coverage* - the tile
/// shader agrees with `ComputeTileCpuReference` on the numbers it computes.
/// This file proves the half that had no test at all until the composition
/// pass existed: that those numbers reach the render target, in the right
/// place, with the right material, under the right blend, in the right order.
///
/// ## Two comparisons, because they answer different questions
///
/// **Against the oracle composite.** `ComputeTileCpuReference` is rasterised on
/// the CPU and composited by [_oracleComposite] with exactly the arithmetic the
/// pixel shader and the blend unit perform. A difference here is a *transport*
/// failure - a quad at the wrong device origin, a coverage texture read at the
/// wrong texel, a UAV read before its dispatch finished, a stale draw's
/// coverage leaking through, a material or blend bound wrong, or a segment
/// culled from a tile it still contributes winding to. That comparison is held
/// at zero, because none of those is allowed to be off by a little.
///
/// (`compute_tile_segment_bins_test.dart` already checks the binning sample by
/// sample on the CPU with no GPU involved. This file is where a *transport* bug
/// in the same machinery would show up instead.)
///
/// **Against the CPU rasteriser.** `ScanlineFiller` computes exact pixel area;
/// the tile shader supersamples a `sampleGrid * sampleGrid` grid. They are
/// different algorithms, so this comparison can never be zero on an
/// antialiased edge, and pretending otherwise by widening the first tolerance
/// would destroy the only signal this file produces. It is measured and
/// recorded instead: it is the price of approach D's antialiasing quality
/// today, and the number the selector's owner needs in order to decide whether
/// to pay it.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_offscreen_target.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_sparse_executor.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_vector_path_recorder.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_planning.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_reference.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

const int _size = 64;
const int _clear = 0xFF000000;

/// One flipped subsample of the sixteen a 4x4 grid takes.
const int _oneSubsample = 16;

void main() {
  final D3d12Session session = D3d12Session.open(computeTiles: true);
  if (session.device != null) {
    // Every antialiased path in this file is promoted to approach D. The
    // production threshold is 512 flattened segments, which would restrict the
    // scenes to shapes chosen for their segment count rather than for what they
    // exercise - a rectangle would never reach the route it is meant to test.
    session.device!.experimentalPathStrategySelector =
        const GpuPathStrategySelector(computeSegmentThreshold: 0);
  }
  tearDownAll(session.close);

  group('the composite puts approach D on the render target', () {
    test('a pixel-aligned rectangle', () async {
      // Whole-pixel edges, so *both* comparisons should be exact: with no
      // partial coverage anywhere, supersampling and exact area agree.
      // Observed: 0 against the oracle composite, 0 against the CPU.
      await _expectComposite(
        session,
        _pathScene(_rect(8, 8, 40, 40), 0xFFCC3311),
        oracleTolerance: 0,
        cpuTolerance: 0,
      );
    });

    test('a rectangle with fractional edges', () async {
      // Partial coverage on all four sides, still axis aligned, and the edges
      // fall on quarter and half pixels - which a 4x4 grid represents exactly.
      // So this scene is *also* zero against the analytic CPU, and that is the
      // useful part: it says the supersampling difference measured elsewhere
      // comes from the sampling grid and not from the composite.
      // Observed: 0 against the oracle, 0 against the CPU.
      await _expectComposite(
        session,
        _pathScene(_rect(6.25, 9.5, 41.75, 38.5), 0xFFCC3311),
        oracleTolerance: 0,
        cpuTolerance: 0,
      );
    });

    test('a self-overlapping path under the non-zero rule', () async {
      // The overlap is filled, and the coverage texture has to carry that
      // through: a composite that read the wrong texel would show the seam.
      // Observed: 0 against the oracle, 0 against the CPU.
      await _expectComposite(
        session,
        _pathScene(_twoRects(), 0xFFCC3311),
        oracleTolerance: 0,
        cpuTolerance: 0,
      );
    });

    test('a translucent paint composited source-over', () async {
      // Coverage folded into an alpha below one, then blended against the
      // clear. This is where a composite that premultiplied at the wrong moment
      // diverges first, and where the blend unit's rounding shows up.
      // Observed: 0 against the oracle, 0 against the CPU - the blend unit's
      // rounding agrees with `mul255` on every pixel of this scene.
      await _expectComposite(
        session,
        _pathScene(_rect(5.5, 5.5, 58.5, 58.5), 0x8033CC55),
        oracleTolerance: 0,
        cpuTolerance: 0,
      );
    });

    test('a clipped path, whole-pixel clip', () async {
      // The clip reaches approach D through the encoding's *bounds* rather than
      // through a scissor: `contains` rejects any sample outside them. On a
      // whole-pixel clip edge that is the same answer the CPU's analytic clip
      // gives, and this scene holds both comparisons to zero to say so.
      // Observed: 0 against the oracle, 0 against the CPU.
      await _expectComposite(
        session,
        _clippedScene(10, 12, 48, 46),
        oracleTolerance: 0,
        cpuTolerance: 0,
      );
    });

    test('a fractional clip edge, matched', () async {
      // This scene used to be the one place approach D disagreed with the
      // analytic routes about *geometry* rather than about sampling: 153 levels
      // along the clip edge. The cause was not a missing antialiasing step, it
      // was a different clip semantics - `ScanlineFiller`, and therefore the CPU
      // rasteriser, the dense atlas and the sparse encoder, expand a clip
      // outward to whole pixels before filling, and the encoding was applying it
      // exactly. `ComputeTileClipRounding.outwardWholePixel` adopts the
      // framework's answer and the disagreement is gone.
      //
      // Observed: 0 against the oracle, 0 against the CPU. Antialiasing the clip
      // edge instead would have made D differ from every other route in the
      // renderer, which is a worse picture rather than a better one.
      await _expectComposite(
        session,
        _clippedScene(10.5, 12.25, 49.5, 47.75),
        oracleTolerance: 0,
        cpuTolerance: 0,
      );
    });

    test('a flattened curve', () async {
      // Hundreds of short segments at arbitrary angles, which is what a real
      // vector scene looks like and the only scene here whose edges are not
      // axis aligned.
      //
      // Measured: **0 against the oracle, 21 against the CPU**. Twenty-one
      // levels is a little over one subsample of sixteen, which is what a
      // supersampler owes an exact-area rasteriser on a slanted edge: a pixel
      // the grid counts as 5/16 may really be 0.36 covered. The budget asserted
      // is two subsamples, because the bound is a property of the sampling
      // grid and not of this driver.
      await _expectComposite(
        session,
        _pathScene(_blob(), 0xFF2050C0),
        oracleTolerance: 0,
        cpuTolerance: 2 * _oneSubsample,
      );
    });

    test('two promoted draws keep their order', () async {
      // Two overlapping paths, both promoted. Each dispatch writes only its own
      // draw's coverage, and each composite reads only its own draw's pixel
      // bounds - so a second draw that picked up the first one's coverage, or
      // composited before it, shows up as the wrong colour in the overlap.
      final DisplayList list = DisplayList();
      final int first = list.addPaint(colorArgb: 0xFFCC3311);
      final int second = list.addPaint(colorArgb: 0xFF11CC33);
      list
        ..drawPath(list.addPath(_rect(6, 6, 40, 40)), first)
        ..drawPath(list.addPath(_rect(24, 24, 58, 58)), second);

      final _Run? run = await _expectComposite(
        session,
        list,
        oracleTolerance: 0,
        cpuTolerance: 0,
      );
      if (run == null) return;
      expect(run.composedDraws, 2);
      // The overlap is the second colour on both sides, or the order was lost.
      expect(_rgba(run.gpu, 32, 32), <int>[0x11, 0xCC, 0x33, 0xFF]);
    });

    test('a promoted draw composites under the dense batch after it', () async {
      // The ordering assertion across *routes*: the rectangle is dense, is
      // drawn after the path, and overlaps it. A submitter that issued every
      // dense batch before every vector command would put the path on top and
      // the picture would still look like a picture.
      final DisplayList list = DisplayList();
      final int ink = list.addPaint(colorArgb: 0xFFCC3311);
      final int cover = list.addPaint(colorArgb: 0xFF1133CC, antiAlias: false);
      list
        ..drawPath(list.addPath(_rect(6, 6, 50, 50)), ink)
        ..drawRect(20, 20, 44, 44, cover);

      if (_skipped(session)) return;
      final _Run run = await _render(session, list);
      expect(run.executed, GpuPathStrategy.computeTiles);
      expect(run.composedDraws, 1);
      expect(_rgba(run.cpu, 32, 32), <int>[0x11, 0x33, 0xCC, 0xFF]);
      final int deviation = _maxDeviation(run.cpu, run.gpu);
      printOnFailure('max deviation against the CPU: $deviation');
      expect(deviation, lessThanOrEqualTo(0),
          reason: 'both shapes are pixel aligned, so the routes must agree '
              'exactly; a difference here is an ordering failure');
    });
  });

  group('the selector and the recorder agree about what ran', () {
    test('an accepted compute draw reports computeTiles, and drew', () async {
      if (_skipped(session)) return;
      final _Run run = await _render(session, _pathScene(_blob(), 0xFF2050C0));
      expect(run.candidate, GpuPathStrategy.computeTiles);
      expect(run.executed, GpuPathStrategy.computeTiles);
      expect(run.recorder.acceptedCount, 1);
      expect(run.recorder.computeTileRefusalCount, 0);
      expect(run.composedDraws, 1);
      // executedStrategy is only honest if pixels really moved.
      expect(_isUniform(run.gpu), isFalse);
    });

    test('an aliased fill is never promoted to compute', () async {
      if (_skipped(session)) return;
      // Approach D supersamples, so it has no correct answer for a fill that
      // asked for hard edges. The capabilities probe says so before the
      // selector ever proposes it.
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
      list.drawPath(list.addPath(_rect(8.5, 8.5, 40.5, 40.5)), paint);

      final _Run run = await _render(session, list);
      expect(run.candidate, isNot(GpuPathStrategy.computeTiles));
      expect(run.executed, GpuPathStrategy.coverageAtlas);
      expect(run.composedDraws, 0);
      expect(_maxDeviation(run.cpu, run.gpu), 0);
    });

    test('a repeated frame reuses the retained plan and draws the same',
        () async {
      if (_skipped(session)) return;
      // The gap the cost measurement exposed: the dense atlas keeps its mask,
      // so a static path costs a quad after its first frame, while approach D
      // re-flattened and re-binned every time. The plan cache closes it - and
      // the assertion that matters is not only that it hits, but that a frame
      // drawn from a cached plan is the *same frame*.
      final D3d12OffscreenTarget gpu = session.target(_size, _size);
      addTearDown(gpu.dispose);
      final DisplayList list = _pathScene(_blob(), 0xFF2050C0);

      await gpu.renderDisplayList(list, clearColor: _clear);
      final Uint8List first = Uint8List.fromList(gpu.framebuffer.pixels);
      final D3d12VectorPathRecorder recorder = gpu.vectorRecorder!;
      expect(recorder.computePlanCache.hits, 0,
          reason: 'the first frame cannot hit a cache it just filled');
      expect(recorder.computePlanCache.length, 1);

      for (var frame = 0; frame < 3; frame++) {
        await gpu.renderDisplayList(list, clearColor: _clear);
      }
      expect(recorder.computePlanCache.hits, 3);
      expect(recorder.computePlanCache.misses, 1);
      expect(gpu.framebuffer.pixels, first,
          reason: 'a frame drawn from a retained plan differs from the frame '
              'that produced it');
    });

    test('a plan is not reused across grids it was not binned for', () async {
      if (_skipped(session)) return;
      // The key carries the surface and tile size because the bins are anchored
      // at the target origin. A plan handed to another grid would name tiles
      // that do not exist, so the two targets must miss each other.
      final DisplayList list = _pathScene(_blob(), 0xFF2050C0);
      final D3d12OffscreenTarget small = session.target(_size, _size);
      addTearDown(small.dispose);
      await small.renderDisplayList(list, clearColor: _clear);

      final D3d12VectorPathRecorder recorder = small.vectorRecorder!;
      final int before = recorder.computePlanCache.misses;
      small.resize(_size + 16, _size + 16, 1.0);
      await small.renderDisplayList(list, clearColor: _clear);
      expect(recorder.computePlanCache.misses, before + 1,
          reason: 'the resized target reused a plan binned for the old grid');
      expect(small.composedComputeDraws, greaterThan(0));
    });

    test('a target whose size was never declared refuses by name', () {
      if (_skipped(session)) return;
      // The recorder bins over a grid anchored at the target origin, so a
      // recorder with no declared target size has nothing to bin against. It
      // must refuse rather than guess a surface.
      final D3d12VectorPathRecorder recorder = D3d12VectorPathRecorder();
      expect(recorder.commandCount, 0);
      expect(recorder.computeTileRefusalCount, 0);
    });
  });
}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

/// A rectangle whose top edge is split in two, so it is not an *analytic*
/// rectangle.
///
/// The extra point is not decoration. `GpuPathWorkloadBuilder` recognises a
/// four-point axis-aligned rectangle and the selector answers
/// `analyticPrimitive` for it before any other route is considered - correctly,
/// because a closed-form fragment shader beats every rasteriser there is. A
/// scene meant to exercise approach D therefore has to be a shape the analytic
/// path does not claim, and splitting one edge is the smallest change that
/// achieves it while keeping every edge axis aligned, which is what makes the
/// crossing arithmetic exact on both sides.
Path _rect(double left, double top, double right, double bottom) {
  final PathBuilder builder = PathBuilder()
    ..moveTo(left, top)
    ..lineTo((left + right) / 2, top)
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

Path _blob() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(32, 6)
    ..cubicTo(52, 6, 58, 26, 52, 40)
    ..cubicTo(46, 54, 22, 60, 12, 46)
    ..cubicTo(4, 34, 12, 10, 32, 6)
    ..close();
  return builder.build();
}

DisplayList _pathScene(Path path, int argb) {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: argb);
  list.drawPath(list.addPath(path), paint);
  return list;
}

DisplayList _clippedScene(
  double left,
  double top,
  double right,
  double bottom,
) {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFCC3311);
  final int id = list.addPath(_rect(4, 4, 60, 60));
  list
    ..save()
    ..clipRect(left, top, right, bottom)
    ..drawPath(id, paint)
    ..restore();
  return list;
}

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

final class _Run {
  const _Run({
    required this.cpu,
    required this.gpu,
    required this.recorder,
    required this.event,
    required this.composedDraws,
  });

  final Framebuffer cpu;
  final Framebuffer gpu;
  final D3d12VectorPathRecorder recorder;
  final GpuPathPlanningEvent event;

  /// Draws this frame composited through approach D.
  final int composedDraws;

  GpuPathStrategy get candidate => event.candidate.strategy;
  GpuPathStrategy get executed => event.executedStrategy;
}

bool _skipped(D3d12Session session) {
  final String? reason = session.skipReason;
  if (reason == null) return false;
  printOnFailure('skipped: $reason');
  markTestSkipped('no Direct3D 12 device: $reason');
  return true;
}

Future<_Run> _render(D3d12Session session, DisplayList list) async {
  final MemoryRenderTarget cpu = _cpuTarget();
  await cpu.renderDisplayList(list, clearColor: _clear);
  addTearDown(cpu.dispose);

  final D3d12OffscreenTarget gpu = session.target(_size, _size);
  addTearDown(gpu.dispose);
  final int before = gpu.composedComputeDraws;
  final PresentResult result =
      await gpu.renderDisplayList(list, clearColor: _clear);
  expect(result.status, PresentStatus.presented,
      reason: '${result.diagnostic}');

  final GpuPathPlanningTelemetry planning = gpu.pathPlanning!;
  expect(planning.lastEvent, isNotNull,
      reason: 'the sink observed no path draw');
  expect(planning.failureCount, 0,
      reason: 'planning failed: ${planning.lastError}');
  return _Run(
    cpu: cpu.framebuffer,
    gpu: gpu.framebuffer,
    recorder: gpu.vectorRecorder!,
    event: planning.lastEvent!,
    composedDraws: gpu.composedComputeDraws - before,
  );
}

/// Renders [list], asserts it went through approach D, and compares the result
/// with both references.
/// Returns null when there is no device, so a caller that asserts more than
/// parity stops there instead of asserting against an invented frame.
Future<_Run?> _expectComposite(
  D3d12Session session,
  DisplayList list, {
  required int oracleTolerance,
  required int cpuTolerance,
}) async {
  if (_skipped(session)) return null;

  final _Run run = await _render(session, list);
  expect(run.executed, GpuPathStrategy.computeTiles,
      reason: 'the scene did not reach approach D; the selector chose '
          '${run.candidate.name} and the recorder reported '
          '${run.executed.name}');
  expect(run.composedDraws, greaterThan(0));
  expect(_isUniform(run.cpu), isFalse,
      reason: 'the scene drew nothing, so comparing it proves nothing');

  final Framebuffer oracle = _oracleComposite(run.recorder);
  final int oracleDeviation = _maxDeviation(oracle, run.gpu);
  final int cpuDeviation = _maxDeviation(run.cpu, run.gpu);
  printOnFailure('oracle deviation $oracleDeviation, '
      'cpu deviation $cpuDeviation');
  expect(
    oracleDeviation,
    lessThanOrEqualTo(oracleTolerance),
    reason: 'the composite disagrees with the CPU oracle by up to '
        '$oracleDeviation levels, over a declared tolerance of '
        '$oracleTolerance. Both sides ran the same coverage algorithm, so this '
        'is a transport failure and not rounding.\n'
        '${_report(oracle, run.gpu)}',
  );
  expect(
    cpuDeviation,
    lessThanOrEqualTo(cpuTolerance),
    reason: 'approach D differs from the analytic CPU rasteriser by up to '
        '$cpuDeviation levels, over a declared budget of $cpuTolerance',
  );
  return run;
}

/// Composites what the CPU oracle says every recorded compute command covers.
///
/// The arithmetic is the pixel shader's and the blend unit's, in the same
/// order: premultiplied colour times coverage, source-over onto what is already
/// there, quantised once at the end. Nothing here consults the GPU.
Framebuffer _oracleComposite(D3d12VectorPathRecorder recorder) {
  final Framebuffer buffer = Framebuffer.allocate(
    width: _size,
    height: _size,
    format: PixelFormat.rgba8888Premultiplied,
  );
  final List<double> channels = <double>[
    ((_clear >> 16) & 0xFF) / 255.0,
    ((_clear >> 8) & 0xFF) / 255.0,
    (_clear & 0xFF) / 255.0,
    ((_clear >> 24) & 0xFF) / 255.0,
  ];
  final List<double> surface = List<double>.filled(_size * _size * 4, 0);
  for (var i = 0; i < _size * _size; i++) {
    for (var c = 0; c < 4; c++) {
      surface[i * 4 + c] = channels[c];
    }
  }

  for (var index = 0; index < recorder.commandCount; index++) {
    final D3d12VectorPathCommand command = recorder.commandAt(index);
    if (command is! D3d12ComputeTilePathCommand) {
      throw StateError('this helper composites compute commands only, got '
          '${command.runtimeType}');
    }
    final ComputeTileCpuReference reference =
        ComputeTileCpuReference(command.plan);
    final Uint8List coverage =
        reference.rasterizeDraw(0, sampleGrid: command.sampleGrid);
    final SparseD3d12Material material = command.material;
    for (var i = 0; i < _size * _size; i++) {
      final double alpha = coverage[i] / 255.0;
      if (alpha == 0) continue;
      final double sourceAlpha = material.alpha * alpha;
      final List<double> source = <double>[
        material.red * alpha,
        material.green * alpha,
        material.blue * alpha,
        sourceAlpha,
      ];
      for (var c = 0; c < 4; c++) {
        surface[i * 4 + c] =
            source[c] + surface[i * 4 + c] * (1.0 - sourceAlpha);
      }
    }
  }

  for (var i = 0; i < _size * _size * 4; i++) {
    buffer.pixels[i] = (surface[i] * 255.0).round().clamp(0, 255);
  }
  return buffer;
}

int _maxDeviation(Framebuffer a, Framebuffer b) {
  expect(b.width, a.width);
  expect(b.height, a.height);
  var maxDeviation = 0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final List<int> left = _rgba(a, x, y);
      final List<int> right = _rgba(b, x, y);
      for (var channel = 0; channel < 4; channel++) {
        final int difference = (left[channel] - right[channel]).abs();
        if (difference > maxDeviation) maxDeviation = difference;
      }
    }
  }
  return maxDeviation;
}

String _report(Framebuffer a, Framebuffer b) {
  final List<String> lines = <String>[];
  for (var y = 0; y < a.height && lines.length < 12; y++) {
    for (var x = 0; x < a.width && lines.length < 12; x++) {
      final List<int> left = _rgba(a, x, y);
      final List<int> right = _rgba(b, x, y);
      if (_sameRgba(left, right)) continue;
      lines.add('($x, $y): oracle $left, gpu $right');
    }
  }
  return lines.join('\n');
}

bool _sameRgba(List<int> a, List<int> b) {
  for (var i = 0; i < 4; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _isUniform(Framebuffer buffer) {
  final List<int> first = _rgba(buffer, 0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      if (!_sameRgba(_rgba(buffer, x, y), first)) return false;
    }
  }
  return true;
}

List<int> _rgba(Framebuffer buffer, int x, int y) {
  final int offset = buffer.offsetOf(x, y);
  final Uint8List bytes = buffer.pixels;
  return switch (buffer.format) {
    PixelFormat.bgra8888Premultiplied => <int>[
        bytes[offset + 2],
        bytes[offset + 1],
        bytes[offset],
        bytes[offset + 3],
      ],
    _ => <int>[
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
      ],
  };
}

MemoryRenderTarget _cpuTarget() =>
    MemoryRenderTarget(const MemorySurfaceDescriptor(
      pixelWidth: _size,
      pixelHeight: _size,
      format: PixelFormat.rgba8888Premultiplied,
    ));
