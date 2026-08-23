/// What the three routes actually cost on this machine, measured.
///
/// `GpuPathStrategySelector` decides by cost. Every threshold it carries is a
/// number somebody chose, and until now they were chosen from first principles:
/// a sparse encoding is smaller than a dense mask, a compute dispatch has a
/// higher fixed cost. Those are true and they are not measurements, and a
/// selector tuned on beliefs is a selector that will pick the wrong route on
/// hardware nobody profiled.
///
/// So this file measures, on one representative scene, what the parts really
/// are: the CPU time to encode, the bytes each route hands the GPU, and the
/// incremental wall time of a frame that takes it. The numbers it prints are
/// the ones quoted in `doc/architecture/ACELERACAO_GPU_VETORIAL.md`.
///
/// ## What the timings include, stated so they are not over-read
///
/// The offscreen target reads its pixels back, which means every frame here
/// ends in a fence wait and a full-surface copy. That cost is identical for all
/// three routes and swamps them, so each route is reported **relative to a
/// baseline frame that clears and reads back and draws nothing**. What is left
/// is the route's own CPU work plus its GPU work plus whatever the readback
/// cannot overlap - which is an honest *upper* bound on the route's cost and
/// not a GPU timer. A real GPU timestamp query would need
/// `ID3D12QueryHeap`, which this backend does not bind; that is the measurement
/// to add when these numbers start deciding something.
///
/// ## This is a measurement, not a threshold
///
/// The assertions are deliberately weak - a byte count that is *ordered* the
/// way the representation guarantees, and a route that really ran. Asserting a
/// time would make the file fail on a busy machine and teach everyone to ignore
/// it. The numbers belong in the document, where a human reads them.
///
/// ## The timing tests are opt-in, and that was measured too
///
/// They render several hundred frames that each end in a fence wait and a
/// full-surface readback. `package:test` runs suites concurrently, so on the
/// integrated adapter this was written against, running them alongside the rest
/// of the Direct3D 12 directory pushes the GPU past its timeout-detection
/// limit: the adapter resets and every *other* suite then reports
/// `DXGI_ERROR_DEVICE_REMOVED` and skips. A benchmark that makes the
/// correctness tests stop running is worse than no benchmark, so the timing
/// tests are gated on [_benchmarkVariable] and the sweep only pays for the
/// encoding measurement below, which needs no device at all.
///
/// To take the numbers: `DART_UI_GPU_BENCHMARK=1 dart test <this file>`.
library;

import 'dart:io' show Platform;

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_offscreen_target.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_vector_path_recorder.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

/// A surface the size of a real UI panel rather than a test swatch: the three
/// routes differ by *area* against *perimeter*, so a 32-pixel scene would
/// measure the fixed costs and nothing else.
const int _size = 256;
const int _clear = 0xFF101418;

/// Frames per measurement. Enough for a median to mean something, few enough
/// that the file stays under a second.
const int _iterations = 21;

/// Frames rendered and thrown away before each measurement.
const int _warmupFrames = 5;

/// Set to `1` to run the timing tests. See the library comment.
const String _benchmarkVariable = 'DART_UI_GPU_BENCHMARK';

/// Null when the timing tests should run; otherwise the reason they did not.
final String? _benchmarkSkip =
    Platform.environment[_benchmarkVariable] == '1'
        ? null
        : 'a measurement rather than a correctness test, and one heavy enough '
            'to reset the adapter out from under the suites running beside it; '
            'set $_benchmarkVariable=1 to take the numbers';

void main() {
  final D3d12Session session =
      D3d12Session.open(sparseStrips: true, computeTiles: true);
  tearDownAll(session.close);

  test('the encoded size of one path, by route', () {
    // No device needed: this is the part of the cost that is pure CPU and pure
    // representation, and it is the half the selector actually reads.
    final Path path = _panel(0);
    const Rect clip = Rect.fromLTRB(0, 0, 256, 256);

    final Stopwatch sparseClock = Stopwatch()..start();
    final SparseStripGenerator generator = SparseStripGenerator();
    late SparseStripDrawPlan sparsePlan;
    for (var i = 0; i < _iterations; i++) {
      final StripBuffer strips = generator.fill(path, clip);
      sparsePlan = SparseStripDrawPlan()..append(strips, materialIndex: 0);
    }
    sparseClock.stop();
    final SparseStripPlanMetrics sparse = sparsePlan.metrics;

    final Stopwatch computeClock = Stopwatch()..start();
    late ComputeTilePlan computePlan;
    for (var i = 0; i < _iterations; i++) {
      final ComputeTileScene scene = ComputeTileScene();
      scene.appendPath(
        path,
        clip: clip,
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );
      computePlan = scene.build(width: _size, height: _size, tileSize: 16);
    }
    computeClock.stop();
    final ComputeTilePlanMetrics compute = computePlan.metrics;

    final Rect bounds = path.bounds;
    final int denseBytes = (bounds.right.ceil() - bounds.left.floor()) *
        (bounds.bottom.ceil() - bounds.top.floor());

    _report(<String, Object>{
      'scene': 'one antialiased panel path, ${_size}x$_size surface',
      'dense mask bytes': denseBytes,
      'sparse upload bytes':
          sparse.alphaUploadBytes + sparse.instanceBufferBytes,
      'sparse alpha bytes': sparse.alphaUploadBytes,
      'sparse instance bytes': sparse.instanceBufferBytes,
      'sparse draw calls': sparse.estimatedDrawCallCount,
      'sparse atlas pages': sparse.atlasPageCount,
      'compute upload bytes': compute.uploadBytes,
      'compute segments': compute.segmentCount,
      'compute occupied tiles': compute.occupiedTileCount,
      'compute tile-segment refs': compute.tileSegmentReferenceCount,
      'compute mean segs/tile':
          computePlan.meanSegmentsPerReference.toStringAsFixed(2),
      'compute segs/tile without binning': compute.segmentCount,
      'sparse encode us/frame':
          sparseClock.elapsedMicroseconds ~/ _iterations,
      'compute encode us/frame':
          computeClock.elapsedMicroseconds ~/ _iterations,
    });

    // The one thing the representation *guarantees*, and therefore the only
    // thing worth asserting: a sparse encoding of an antialiased shape is
    // smaller than the dense mask of its bounding box, because it stores the
    // perimeter and describes the interior.
    expect(
      sparse.alphaUploadBytes + sparse.instanceBufferBytes,
      lessThan(denseBytes),
      reason: 'the sparse encoding is no longer smaller than the dense mask, '
          'which removes the reason the route exists',
    );
    expect(compute.occupiedTileCount, greaterThan(0));
  });

  test('the incremental frame cost of a static path', () async {
    if (_skipped(session)) return;
    // The same geometry every frame, which is the case the dense atlas is
    // *designed* for: after frame one its mask is resident and the route costs
    // a quad. Neither experimental route has a retained encoding cache yet, so
    // both pay their full CPU encode on every frame. Reporting this first makes
    // the deforming case below readable rather than surprising.
    final DisplayList scene = _scene(0);
    final double baseline = _median(
      (await _measure(session, (_) => DisplayList(), _denseSelector, null))
          .samples,
    );

    final _RouteCost dense = await _route(
      session, (_) => scene, _denseSelector, GpuPathStrategy.coverageAtlas,
      baseline);
    final _RouteCost sparse = await _route(
      session, (_) => scene, _sparseSelector, GpuPathStrategy.sparseStrips,
      baseline);
    final _RouteCost compute = await _route(
      session, (_) => scene, _computeSelector, GpuPathStrategy.computeTiles,
      baseline);

    _report(<String, Object>{
      'scene': 'one *static* antialiased panel path, ${_size}x$_size, '
          '$_iterations frames',
      'baseline (clear + readback) ms': baseline.toStringAsFixed(3),
      'dense atlas, mask cache warm': dense.incremental.toStringAsFixed(3),
      'sparse strips (plan cache)':
          '${sparse.incremental.toStringAsFixed(3)}  [${sparse.cache}]',
      'compute tiles (plan cache)':
          '${compute.incremental.toStringAsFixed(3)}  [${compute.cache}]',
    });

    // Only that each route really ran. A timing assertion would fail on a busy
    // machine and teach everyone to ignore this file - see the library comment.
    expect(dense.executed, GpuPathStrategy.coverageAtlas);
    expect(sparse.executed, GpuPathStrategy.sparseStrips);
    expect(compute.executed, GpuPathStrategy.computeTiles);
  }, skip: _benchmarkSkip);

  test('the incremental frame cost of a deforming path', () async {
    if (_skipped(session)) return;
    // Geometry that changes every frame, which is the case the experimental
    // routes exist for and the only one where the comparison is like for like:
    // the dense mask cache misses on every frame, so all three pay to encode.
    // A resizing panel, a dragged handle and an animated SVG are all this.
    final double baseline = _median(
      (await _measure(session, (_) => DisplayList(), _denseSelector, null))
          .samples,
    );

    final _RouteCost dense = await _route(
      session, _scene, _denseSelector, GpuPathStrategy.coverageAtlas, baseline);
    final _RouteCost sparse = await _route(
      session, _scene, _sparseSelector, GpuPathStrategy.sparseStrips, baseline);
    final _RouteCost compute = await _route(
      session, _scene, _computeSelector, GpuPathStrategy.computeTiles,
      baseline);

    _report(<String, Object>{
      'scene': 'a *deforming* antialiased panel path, ${_size}x$_size, '
          '$_iterations frames',
      'baseline (clear + readback) ms': baseline.toStringAsFixed(3),
      'dense atlas, cache misses': dense.incremental.toStringAsFixed(3),
      'sparse strips (plan cache)':
          '${sparse.incremental.toStringAsFixed(3)}  [${sparse.cache}]',
      'compute tiles (plan cache)':
          '${compute.incremental.toStringAsFixed(3)}  [${compute.cache}]',
    });

    expect(dense.executed, GpuPathStrategy.coverageAtlas);
    expect(sparse.executed, GpuPathStrategy.sparseStrips);
    expect(compute.executed, GpuPathStrategy.computeTiles);
  }, skip: _benchmarkSkip);
}

/// Builds the display list for frame [frame].
typedef _SceneBuilder = DisplayList Function(int frame);

/// Sparse never wins on transfer bytes and compute never reaches its segment
/// threshold, so the draw falls through to the dense atlas.
const GpuPathStrategySelector _denseSelector = GpuPathStrategySelector(
  computeSegmentThreshold: 1 << 30,
  sparseMaximumDenseRatio: 0,
);

/// The production policy with compute out of reach.
const GpuPathStrategySelector _sparseSelector =
    GpuPathStrategySelector(computeSegmentThreshold: 1 << 30);

/// Compute for every dynamic path, whatever its segment count.
const GpuPathStrategySelector _computeSelector =
    GpuPathStrategySelector(computeSegmentThreshold: 0);

final class _RouteCost {
  const _RouteCost(this.executed, this.incremental, this.cache);

  final GpuPathStrategy executed;

  /// Median frame time minus the baseline frame, in milliseconds.
  final double incremental;

  /// What the retained-encoding cache did over the measurement, so a number
  /// that improved can be attributed to it rather than to the weather.
  final String cache;
}

Future<_RouteCost> _route(
  D3d12Session session,
  _SceneBuilder scene,
  GpuPathStrategySelector selector,
  GpuPathStrategy expected,
  double baseline,
) async {
  final _Measurement measured =
      await _measure(session, scene, selector, expected);
  return _RouteCost(
    expected,
    _median(measured.samples) - baseline,
    measured.cache,
  );
}

final class _Measurement {
  const _Measurement(this.samples, this.cache);

  final List<double> samples;
  final String cache;
}

/// Renders [_iterations] frames and returns their wall times in milliseconds.
///
/// [expected] is checked on the *last* frame rather than the first: the first
/// frame of a static scene warms the mask atlas, and a route asserted before
/// that would be asserting about a cold cache the other frames do not have.
Future<_Measurement> _measure(
  D3d12Session session,
  _SceneBuilder scene,
  GpuPathStrategySelector selector,
  GpuPathStrategy? expected,
) async {
  session.device!.experimentalPathStrategySelector = selector;
  final D3d12OffscreenTarget target = session.target(_size, _size);
  addTearDown(target.dispose);
  // Warm-up frames, discarded. The first frame of a target allocates its
  // readback buffer and its colour texture, the first frame of a route compiles
  // nothing but does touch every pipeline object for the first time, and a
  // median over samples that include those measures the allocator.
  for (var i = 0; i < _warmupFrames; i++) {
    // Frame indices past the measured range, so a deforming scene's warm-up
    // does not seed the plan cache with frames the measurement then repeats -
    // which would report hits a real animation never gets.
    await target.renderDisplayList(scene(_iterations + i), clearColor: _clear);
  }
  final List<double> samples = <double>[];
  for (var i = 0; i < _iterations; i++) {
    final DisplayList list = scene(i);
    final Stopwatch clock = Stopwatch()..start();
    final PresentResult result =
        await target.renderDisplayList(list, clearColor: _clear);
    clock.stop();
    expect(result.status, PresentStatus.presented);
    samples.add(clock.elapsedMicroseconds / 1000.0);
  }
  if (expected != null) {
    expect(
      target.pathPlanning?.lastEvent?.executedStrategy ??
          GpuPathStrategy.coverageAtlas,
      expected,
      reason: 'the scene did not take the route it was measuring',
    );
  }
  final D3d12VectorPathRecorder? recorder = target.vectorRecorder;
  final String cache = recorder == null
      ? 'no recorder'
      : switch (expected) {
          GpuPathStrategy.sparseStrips =>
            '${recorder.sparsePlanCache.hits} hits / '
                '${recorder.sparsePlanCache.misses} misses',
          GpuPathStrategy.computeTiles =>
            '${recorder.computePlanCache.hits} hits / '
                '${recorder.computePlanCache.misses} misses',
          _ => 'mask atlas',
        };
  return _Measurement(samples, cache);
}

double _median(List<double> samples) {
  final List<double> sorted = List<double>.of(samples)..sort();
  return sorted[sorted.length ~/ 2];
}

/// A rounded panel: four cubic corners and four straight edges, which is the
/// shape a card, a button and a dialog all reduce to.
///
/// Deliberately not an analytic rectangle: the selector would answer
/// `analyticPrimitive` for one and none of the three routes would be measured.
Path _panel(int frame) {
  const double left = 12;
  const double top = 16;
  final double right = 244 - frame.toDouble();
  const double bottom = 232;
  const double radius = 28;
  const double control = radius * 0.5523;
  final PathBuilder builder = PathBuilder()
    ..moveTo(left + radius, top)
    ..lineTo(right - radius, top)
    ..cubicTo(right - control, top, right, top + control, right, top + radius)
    ..lineTo(right, bottom - radius)
    ..cubicTo(right, bottom - control, right - control, bottom, right - radius,
        bottom)
    ..lineTo(left + radius, bottom)
    ..cubicTo(
        left + control, bottom, left, bottom - control, left, bottom - radius)
    ..lineTo(left, top + radius)
    ..cubicTo(left, top + control, left + control, top, left + radius, top)
    ..close();
  return builder.build();
}

/// The scene for one frame. [frame] moves the panel's right edge by a pixel,
/// which is enough to miss the dense mask cache: the cache is keyed by the
/// path's contents, so a shape that changes is a shape that must be
/// re-rasterised.
DisplayList _scene(int frame) {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFF3070C0);
  list.drawPath(list.addPath(_panel(frame)), paint);
  return list;
}

bool _skipped(D3d12Session session) {
  final String? reason = session.skipReason;
  if (reason == null) return false;
  printOnFailure('skipped: $reason');
  markTestSkipped('no Direct3D 12 device: $reason');
  return true;
}

/// Prints one measurement block.
///
/// `print` and not `printOnFailure`: the whole point of this file is the
/// numbers, and a measurement nobody can read is a measurement nobody made.
void _report(Map<String, Object> values) {
  final StringBuffer buffer = StringBuffer('\n--- measured on this machine\n');
  for (final MapEntry<String, Object> entry in values.entries) {
    buffer.writeln('  ${entry.key.padRight(34)} ${entry.value}');
  }
  // ignore: avoid_print
  print(buffer);
}
