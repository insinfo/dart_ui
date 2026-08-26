/// The selector, the recorder and the ordered submitter, end to end on a real
/// Direct3D 12 device.
///
/// The two files beside this one prove the executors: `d3d12_sparse_parity_test`
/// that a hand-built plan draws what the CPU draws, `d3d12_compute_tile_parity_test`
/// that the tile shader agrees with its oracle. Neither says anything about the
/// path a *display list* takes, and that is where the interesting failures are:
///
///   * a promoted path that draws in the wrong order relative to the dense
///     batches around it, which on an opaque scene looks almost right;
///   * a refusal that leaves the draw promoted anyway, so nothing is drawn;
///   * a refusal that reports `executedStrategy` as the candidate rather than
///     as the atlas, so the telemetry says a route ran that did not.
///
/// Every scene here is therefore compared with the CPU rasteriser **and** has
/// its recorded decision asserted. Pixels alone would pass a frame that
/// silently fell back; counters alone would pass a frame that recorded the
/// right decision and drew the wrong picture.
///
/// The tolerance is zero throughout. The promoted route and the dense route
/// take their coverage from the same `ScanlineFiller`, so a difference is a
/// bug in submission and never in rounding - the same argument
/// `d3d12_sparse_parity_test.dart` makes at length.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_offscreen_target.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_vector_path_recorder.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_dispatch.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_planning.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';

import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

const int _size = 64;
const int _clear = 0xFF000000;

void main() {
  // Sparse only. Approach D is deliberately *not* enabled here: this file is
  // about the sparse route, and a device that also advertised compute would
  // send the many-segment scene below down approach D instead - which is
  // covered, with its own oracle, in `d3d12_compute_composite_parity_test.dart`.
  final D3d12Session session = D3d12Session.open(sparseStrips: true);
  tearDownAll(session.close);

  group('a display list reaches the sparse executor through the selector', () {
    test('a large antialiased path is promoted, and matches the CPU', () async {
      if (_skipped(session)) return;
      final _Run run = await _render(session, _thinDiagonal());
      expect(run.executed, GpuPathStrategy.sparseStrips,
          reason: 'the selector chose ${run.candidate} and the recorder '
              'reported ${run.executed}; the scene was chosen because sparse '
              'strips beat the dense mask on it');
      expect(run.recorder.acceptedCount, 1);
      expect(run.stats, isNotNull);
      expect(run.stats!.drawCalls, greaterThan(0));
      _expectParity(run, tolerance: 0);
    });

    test('a promoted path composites under the dense batch after it: 0',
        () async {
      if (_skipped(session)) return;
      // The ordering assertion, and the reason `_submitOrdered` exists: the
      // rectangle is drawn *after* the path in the display list and overlaps
      // it, so a submitter that issued every dense batch before every vector
      // command would put the path on top and the picture would still look
      // like a picture.
      final DisplayList list = DisplayList();
      final int ink = list.addPaint(colorArgb: 0xFFCC3311);
      final int cover = list.addPaint(colorArgb: 0xFF1133CC, antiAlias: false);
      list
        ..drawPath(list.addPath(_thinDiagonalPath()), ink)
        ..drawRect(20, 20, 44, 44, cover);

      final _Run run = await _render(session, list);
      expect(run.executed, GpuPathStrategy.sparseStrips);
      expect(run.recorder.acceptedCount, 1);
      // The overlap really is opaque blue on both sides, which is what makes
      // the order observable at all.
      expect(_rgba(run.cpu, 32, 32), <int>[0x11, 0x33, 0xCC, 0xFF]);
      _expectParity(run, tolerance: 0);
    });

    test('two promoted paths keep their relative order: 0', () async {
      if (_skipped(session)) return;
      final DisplayList list = DisplayList();
      final int first = list.addPaint(colorArgb: 0xFFCC3311);
      final int second = list.addPaint(colorArgb: 0xFF11CC33);
      list
        ..drawPath(list.addPath(_thinDiagonalPath()), first)
        ..drawPath(list.addPath(_thinAntiDiagonalPath()), second);

      final _Run run = await _render(session, list);
      expect(run.recorder.acceptedCount, 2);
      _expectParity(run, tolerance: 0);
    });
  });

  group('a refusal returns the draw to the dense atlas', () {
    test('an aliased fill is never promoted', () async {
      if (_skipped(session)) return;
      // Sparse coverage is analytic antialiasing, so the capabilities probe
      // reports it unavailable for an aliased draw and the selector never
      // proposes it. The picture must still be the CPU's.
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
      list.drawPath(list.addPath(_thinDiagonalPath()), paint);

      final _Run run = await _render(session, list);
      expect(run.candidate, isNot(GpuPathStrategy.sparseStrips));
      expect(run.executed, GpuPathStrategy.coverageAtlas);
      expect(run.recorder.acceptedCount, 0);
      _expectParity(run, tolerance: 0);
    });

    test('a gradient paint is refused by the recorder, with no device', () {
      // Not a rendered scene: `GpuRasterSink` refuses gradient replay outright
      // on this backend, so a gradient display list never reaches the recorder
      // at all. The refusal is still asserted, directly, because the recorder
      // is the layer that would otherwise build a sparse material with no LUT
      // and fail at submission - after dense work had already drawn.
      final D3d12VectorPathRecorder recorder = D3d12VectorPathRecorder();
      final bool accepted = recorder.tryRecord(_requestFor(
        _thinDiagonalPath(),
        const ReplayPaint(
          argbColor: 0xFFFFFFFF,
          style: paintStyleFill,
          strokeWidth: 0,
          blendMode: blendModeSrcOver,
          antiAlias: true,
        ).withShaderTransform(Transform2D.identity),
        gradient: LinearGradient(
          startX: 8,
          startY: 8,
          endX: 56,
          endY: 56,
          stops: <GradientStop>[
            const GradientStop(0, 0xFF2040C0),
            const GradientStop(1, 0xFF20C040),
          ],
        ),
      ));
      expect(accepted, isFalse);
      expect(recorder.commandCount, 0);
      expect(recorder.refusalCount, 1);
    });

    test('an out-of-order batch index is refused, with no device', () {
      // A vector command recorded before dense work that preceded it in the
      // display list would reorder compositing. The recorder refuses rather
      // than sorting, because the sink is the only side that knows the order.
      final D3d12VectorPathRecorder recorder = D3d12VectorPathRecorder();
      expect(
        recorder.tryRecord(_requestFor(_thinDiagonalPath(), _opaque, batch: 4)),
        isTrue,
      );
      expect(
        recorder.tryRecord(_requestFor(_thinDiagonalPath(), _opaque, batch: 2)),
        isFalse,
      );
      expect(recorder.commandCount, 1);
      expect(recorder.commandAt(0).batchIndex, 4);
    });

    test('a many-segment path never reaches compute on a device without it',
        () async {
      if (_skipped(session)) return;
      // The capability is not a constant: this device did not build a compute
      // pipeline, so it must not advertise one, and the selector must not pick
      // approach D however many segments the path has. Whatever it does pick
      // has to draw the same picture the CPU does.
      expect(session.device!.experimentalComputeTilesEnabled, isFalse);
      expect(session.device!.capabilities.supportsCompute, isFalse);

      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFCC3311);
      list.drawPath(list.addPath(_manySegments()), paint);

      final _Run run = await _render(session, list);
      expect(run.candidate, isNot(GpuPathStrategy.computeTiles));
      expect(run.executed, isNot(GpuPathStrategy.computeTiles));
      expect(run.recorder.computeTileRefusalCount, 0);
      _expectParity(run, tolerance: 0);
    });
  });

  group('a retained encoding survives the frame', () {
    test('a repeated frame reuses the sparse plan and draws the same',
        () async {
      if (_skipped(session)) return;
      // Sparse coverage is an analytic rasterisation on the CPU, and it was
      // being paid on every frame for a shape that had not moved - the dense
      // atlas keeps its mask, this route kept nothing. `VectorPlanCache` closes
      // that, and the frame has to come out identical from the retained plan.
      final D3d12OffscreenTarget gpu = session.target(_size, _size);
      addTearDown(gpu.dispose);
      final DisplayList list = _thinDiagonal();

      await gpu.renderDisplayList(list, clearColor: _clear);
      final Uint8List first = Uint8List.fromList(gpu.framebuffer.pixels);
      final D3d12VectorPathRecorder recorder = gpu.vectorRecorder!;
      expect(recorder.acceptedCount, 1);
      expect(recorder.sparsePlanCache.length, 1);

      final int before = recorder.sparsePlanCache.hits;
      for (var frame = 0; frame < 3; frame++) {
        await gpu.renderDisplayList(list, clearColor: _clear);
      }
      expect(recorder.sparsePlanCache.hits, greaterThan(before));
      expect(gpu.framebuffer.pixels, first,
          reason: 'a frame drawn from a retained plan differs from the frame '
              'that produced it');
      // A retained plan is read, never rewound: a `reset()` on a cached plan
      // would submit an empty frame, so the count has to be intact.
      expect(recorder.commandAt(0), isA<D3d12SparsePathCommand>());
    });

    test('geometry that moves misses, and still matches the CPU', () async {
      if (_skipped(session)) return;
      // The other half of the contract: the key contains the device transform
      // and the path's contents, so an animating shape misses on every frame -
      // which costs what the route cost before the cache, and never draws a
      // stale encoding.
      final D3d12OffscreenTarget gpu = session.target(_size, _size);
      addTearDown(gpu.dispose);
      final D3d12VectorPathRecorder recorder;
      await gpu.renderDisplayList(_thinDiagonal(), clearColor: _clear);
      recorder = gpu.vectorRecorder!;
      final int misses = recorder.sparsePlanCache.misses;

      final DisplayList moved = DisplayList();
      final int paint = moved.addPaint(colorArgb: 0xFFCC3311);
      moved.drawPath(moved.addPath(_thinAntiDiagonalPath()), paint);
      await gpu.renderDisplayList(moved, clearColor: _clear);
      expect(recorder.sparsePlanCache.misses, greaterThan(misses));

      final MemoryRenderTarget cpu = _cpuTarget();
      addTearDown(cpu.dispose);
      await cpu.renderDisplayList(moved, clearColor: _clear);
      expect(_maxDeviation(cpu.framebuffer, gpu.framebuffer), 0);
    });
  });

  group('the production path is untouched', () {
    test('a device opened without the flag has no recorder at all', () async {
      if (_skipped(session)) return;
      final D3d12Session plain = D3d12Session.open();
      addTearDown(plain.close);
      if (plain.skipReason != null) {
        markTestSkipped('no second device: ${plain.skipReason}');
        return;
      }
      final D3d12OffscreenTarget target = plain.target(_size, _size);
      addTearDown(target.dispose);
      expect(target.vectorRecorder, isNull);
      expect(target.pathPlanning, isNull);

      // And it still draws the same scene correctly through the dense atlas.
      final MemoryRenderTarget cpu = _cpuTarget();
      await cpu.renderDisplayList(_thinDiagonal(), clearColor: _clear);
      final PresentResult result =
          await target.renderDisplayList(_thinDiagonal(), clearColor: _clear);
      expect(result.status, PresentStatus.presented);
      expect(_maxDeviation(cpu.framebuffer, target.framebuffer), 0);
      cpu.dispose();
    });
  });
}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

/// A long, thin, antialiased band across the surface.
///
/// Chosen so the selector really prefers sparse strips rather than being
/// forced: its bounding box is nearly the whole surface, so the dense mask
/// costs the area, while its boundary is two edges and its interior is solid
/// runs - which is exactly the trade `SparseStripDrawPlan` exists to make.
Path _thinDiagonalPath() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(2.5, 8.5)
    ..lineTo(61.5, 40.5)
    ..lineTo(61.5, 49.5)
    ..lineTo(2.5, 17.5)
    ..close();
  return builder.build();
}

Path _thinAntiDiagonalPath() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(2.5, 55.5)
    ..lineTo(61.5, 23.5)
    ..lineTo(61.5, 32.5)
    ..lineTo(2.5, 46.5)
    ..close();
  return builder.build();
}

DisplayList _thinDiagonal() {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFCC3311);
  list.drawPath(list.addPath(_thinDiagonalPath()), paint);
  return list;
}

/// A convex polygon with enough segments to cross the selector's compute
/// threshold, which defaults to 512.
///
/// Convex and simple on purpose: a self-intersecting star would also be
/// refused by the tessellator's inspection, and the point of this scene is
/// that the *compute* branch is what the selector reaches, not a fallback.
Path _manySegments() {
  const int sides = 720;
  final PathBuilder builder = PathBuilder();
  for (var i = 0; i < sides; i++) {
    final double angle = i * 2 * math.pi / sides;
    final double x = 32 + 28 * math.sin(angle);
    final double y = 32 - 28 * math.cos(angle);
    if (i == 0) {
      builder.moveTo(x, y);
    } else {
      builder.lineTo(x, y);
    }
  }
  builder.close();
  return builder.build();
}

const ReplayPaint _opaque = ReplayPaint(
  argbColor: 0xFFCC3311,
  style: paintStyleFill,
  strokeWidth: 0,
  blendMode: blendModeSrcOver,
  antiAlias: true,
);

/// A dispatch request naming [path] with a sparse-strip candidate.
///
/// The proposal's workload is not read by the recorder - only the candidate
/// strategy is - so it carries the path's real size and nothing invented.
GpuPathDispatchRequest _requestFor(
  Path path,
  ReplayPaint paint, {
  Gradient? gradient,
  int batch = 0,
}) {
  final Rect bounds = path.bounds;
  return GpuPathDispatchRequest(
    proposal: GpuPathPlanningProposal(
      label: 'a path',
      workload: GpuPathWorkload(
        pixelWidth: bounds.width.ceil(),
        pixelHeight: bounds.height.ceil(),
        segmentCount: 4,
      ),
      candidate: const GpuPathStrategyDecision(
        GpuPathStrategy.sparseStrips,
        'the test names the candidate directly',
      ),
    ),
    path: path,
    localToTarget: Transform2D.identity,
    clip: const Rect.fromLTRB(0, 0, 64, 64),
    fillRule: FillRule.nonZero,
    paint: gradient == null
        ? paint
        : ReplayPaint(
            argbColor: paint.argbColor,
            style: paint.style,
            strokeWidth: paint.strokeWidth,
            blendMode: paint.blendMode,
            antiAlias: paint.antiAlias,
            gradient: gradient,
          ),
    batchIndex: batch,
  );
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
    required this.stats,
  });

  final Framebuffer cpu;
  final Framebuffer gpu;
  final D3d12VectorPathRecorder recorder;
  final GpuPathPlanningEvent event;
  final dynamic stats;

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

  final D3d12OffscreenTarget gpu = session.target(_size, _size);
  addTearDown(gpu.dispose);
  final PresentResult result =
      await gpu.renderDisplayList(list, clearColor: _clear);
  expect(result.status, PresentStatus.presented,
      reason: '${result.diagnostic}');

  final GpuPathPlanningTelemetry planning = gpu.pathPlanning!;
  expect(planning.lastEvent, isNotNull,
      reason: 'the sink observed no path draw, so the scene never reached the '
          'selector');
  expect(planning.failureCount, 0,
      reason: 'planning failed: ${planning.lastError}');
  final _Run run = _Run(
    cpu: cpu.framebuffer,
    gpu: gpu.framebuffer,
    recorder: gpu.vectorRecorder!,
    event: planning.lastEvent!,
    stats: gpu.lastSparseStats,
  );
  addTearDown(cpu.dispose);
  return run;
}

void _expectParity(_Run run, {required int tolerance}) {
  expect(_isUniform(run.cpu), isFalse,
      reason: 'the scene drew nothing, so comparing it proves nothing');
  final int deviation = _maxDeviation(run.cpu, run.gpu);
  printOnFailure('max deviation $deviation, executed ${run.executed.name}');
  expect(
    deviation,
    lessThanOrEqualTo(tolerance),
    reason: 'the CPU and the ${run.executed.name} route disagree by up to '
        '$deviation levels, over a declared tolerance of $tolerance',
  );
}

int _maxDeviation(Framebuffer cpu, Framebuffer gpu) {
  expect(gpu.width, cpu.width);
  expect(gpu.height, cpu.height);
  var maxDeviation = 0;
  for (var y = 0; y < cpu.height; y++) {
    for (var x = 0; x < cpu.width; x++) {
      final List<int> a = _rgba(cpu, x, y);
      final List<int> b = _rgba(gpu, x, y);
      for (var channel = 0; channel < 4; channel++) {
        final int difference = (a[channel] - b[channel]).abs();
        if (difference > maxDeviation) maxDeviation = difference;
      }
    }
  }
  return maxDeviation;
}

bool _isUniform(Framebuffer buffer) {
  final List<int> first = _rgba(buffer, 0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      final List<int> pixel = _rgba(buffer, x, y);
      for (var channel = 0; channel < 4; channel++) {
        if (pixel[channel] != first[channel]) return false;
      }
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
