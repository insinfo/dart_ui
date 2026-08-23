/// What the sparse plan cache is worth on the OpenGL route, measured.
///
/// ## Why this is a separate file, and why it is gated
///
/// `gl_device_test.dart` counts cache hits and misses, which is the part of
/// the claim that can be asserted: a static scene must encode once. It cannot
/// assert a *duration* - a shared machine makes any threshold either flaky or
/// meaningless - so the numbers live here, behind an environment variable, and
/// the file prints them rather than failing on them.
///
/// The one assertion that does run unconditionally is the encoding-count one
/// at the bottom: it needs no device and no clock, and it is what would break
/// if the cache stopped being consulted.
///
/// To take the numbers: `DART_UI_GPU_BENCHMARK=1 dart test <this file>`.
library;

import 'dart:io' show Platform;

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/vector/vector_plan_cache.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

/// A surface the size of a real UI panel rather than a test swatch: the cache
/// saves an *area*-proportional rasterisation, so a 32-pixel scene would
/// measure the fixed costs and nothing else.
const int _size = 256;
const int _clear = 0xFF101418;

/// Frames per measurement, and frames thrown away before each one.
const int _iterations = 21;
const int _warmupFrames = 5;

const String _benchmarkVariable = 'DART_UI_GPU_BENCHMARK';

final String? _benchmarkSkip = Platform.environment[_benchmarkVariable] == '1'
    ? null
    : 'a measurement rather than a correctness test; set '
        '$_benchmarkVariable=1 to take the numbers';

void main() {
  final _CostSession session = _CostSession.open();
  tearDownAll(session.close);

  test('sparse against the dense atlas, same scene and same clock', () async {
    // The central promotion criterion, and the one frame time alone cannot
    // answer: two *different devices* draw the identical display list, one
    // with the sparse executor available and one without, and every number
    // below is taken the same way on the same hardware in the same run.
    //
    // Two devices rather than one with a flag, because the choice is made by
    // the selector from the device's capabilities - there is no per-draw
    // override, and inventing one for a benchmark would measure a code path
    // that does not exist in either build.
    final _CostSession dense = _CostSession.open(sparse: false);
    if (dense.skipReason != null) {
      markTestSkipped('no second GL device: ${dense.skipReason}');
      return;
    }
    final GlOffscreenTarget sparseTarget = _target(session.device!);
    final GlOffscreenTarget denseTarget = _target(dense.device!);
    try {
      final double sparseMs = await _median(sparseTarget, () => _panelScene(0));
      final double denseMs = await _median(denseTarget, () => _panelScene(0));

      // Both devices take the dense route for a *static* scene, and that is the
      // repetition model working rather than a measurement failure: a shape
      // that repeats is one the atlas would be caching, and no encoding beats
      // a resident quad. The head-to-head that means something is the
      // deforming one below and in the area sweep, where neither cache helps.
      expect(
          sparseTarget.lastExecutedPathStrategy, GpuPathStrategy.coverageAtlas);
      // Null rather than `coverageAtlas`: a build with no experimental
      // executor creates no planning telemetry and no ordered stream at all,
      // so it does not even walk the mixed submitter. That *is* the control -
      // the renderer as it ships today - and the atlas counter below is the
      // positive evidence that it rasterised the shape rather than skipping it.
      expect(denseTarget.lastExecutedPathStrategy, isNull,
          reason: 'the control has to be the plain dense build');
      expect(denseTarget.maskAtlas.rasterizationCount, greaterThan(0),
          reason: 'the control has to actually have drawn the path');
      expect(denseTarget.maskUploadBytes, greaterThan(0));

      // Transfer, which is the cost the two routes differ in by construction:
      // the atlas uploads an area, the strips upload a boundary. Counted over
      // the whole measured run so a per-frame figure is a division rather than
      // a sample.
      final int denseBytes = denseTarget.maskUploadBytes;
      final SparseStripPlanMetrics metrics = _encodeOnce();

      // ignore: avoid_print
      print(
        'sparse against dense at ${_size}x$_size, '
        'median of $_iterations frames:\n'
        '  frame   sparse ${sparseMs.toStringAsFixed(3)} ms   '
        'dense ${denseMs.toStringAsFixed(3)} ms\n'
        '  upload  sparse ${metrics.alphaUploadBytes} B/draw   '
        'dense $denseBytes B over the run '
        '(${denseTarget.maskUploadCount} uploads)\n'
        '  sparse encode: ${metrics.alphaTexelBytes} alpha texels, '
        '${metrics.solidInstanceCount} solid + '
        '${metrics.alphaInstanceCount} alpha instances, '
        '${metrics.estimatedDrawCallCount} draws\n'
        '  dense: ${denseTarget.maskAtlas.rasterizationCount} '
        'rasterisations, ${denseTarget.maskAtlas.cacheHitCount} hits',
      );
      // The other half, and the one that decides the policy. The scene above
      // is *static*, so the dense atlas rasterises once and hits for every
      // frame after - which is unbeatable, because the sparse route re-uploads
      // its strips even on a cache hit. A shape that changes every frame is
      // where the two actually compete: neither cache can help, and the
      // comparison is area-proportional work against perimeter-proportional
      // work.
      var frame = 0;
      DisplayList moving() => _panelScene(frame++ * 0.0625);
      final double sparseMoving = await _median(sparseTarget, moving);
      frame = 0;
      final double denseMoving = await _median(denseTarget, moving);
      final int denseMovingBytes = denseTarget.maskUploadBytes - denseBytes;

      // ignore: avoid_print
      print(
        'deforming, same two devices:\n'
        '  frame   sparse ${sparseMoving.toStringAsFixed(3)} ms   '
        'dense ${denseMoving.toStringAsFixed(3)} ms\n'
        '  upload  dense $denseMovingBytes B over the run '
        '(${denseTarget.maskAtlas.rasterizationCount} rasterisations total)',
      );
    } finally {
      sparseTarget.dispose();
      denseTarget.dispose();
      dense.close();
    }
  }, skip: _benchmarkSkip ?? session.skipReason);

  test('the crossover, swept by surface area', () async {
    // Sparse transfers a *perimeter* and the dense atlas transfers an *area*,
    // so whatever the constants are, sparse has to win somewhere as the shape
    // grows. This finds out where, on this hardware, instead of assuming the
    // asymptotics decide it at UI sizes.
    final _CostSession dense = _CostSession.open(sparse: false);
    if (dense.skipReason != null) {
      markTestSkipped('no second GL device: ${dense.skipReason}');
      return;
    }
    try {
      for (final int size in <int>[256, 512, 1024, 2048]) {
        final GlOffscreenTarget s = _targetOf(session.device!, size);
        final GlOffscreenTarget d = _targetOf(dense.device!, size);
        try {
          // Deforming, because a static scene is decided by the dense atlas
          // cache rather than by either route's per-frame work.
          var frame = 0;
          DisplayList moving() => _panelScene(frame++ * 0.0625, size: size);
          final double sparseMs = await _median(s, moving);
          frame = 0;
          final double denseMs = await _median(d, moving);
          // ignore: avoid_print
          print('  ${size}x$size deforming: '
              'sparse ${sparseMs.toStringAsFixed(3)} ms   '
              'dense ${denseMs.toStringAsFixed(3)} ms   '
              '${denseMs > sparseMs ? "sparse wins" : "dense wins"}');
        } finally {
          s.dispose();
          d.dispose();
        }
      }
    } finally {
      dense.close();
    }
  }, skip: _benchmarkSkip ?? session.skipReason);

  test('sparse frame cost, cold cache against warm', () async {
    final GlOffscreenTarget target = session.device!.createTarget(
      const MemorySurfaceDescriptor(
        pixelWidth: _size,
        pixelHeight: _size,
        format: PixelFormat.rgba8888Premultiplied,
      ),
    ) as GlOffscreenTarget;
    final VectorPlanCache<SparseStripDrawPlan> cache = target.sparsePlanCache!;
    try {
      // Cold: the cache is emptied before every frame, which is exactly what
      // this route did before it had one - re-encode the analytic coverage
      // from scratch each time.
      final double cold = await _median(
        target,
        () => _panelScene(0),
        beforeEach: cache.clear,
      );
      // Warm: the same static scene, the display list rebuilt every frame so
      // the hit has to come from keying on content rather than on identity.
      final double warm = await _median(target, () => _panelScene(0));
      // Deforming: a new shape every frame, which cannot hit by construction.
      // Reported because a cache that only ever helped the easy case would
      // still show a good "warm" number.
      // Sub-pixel offsets: a new key every frame - which is the point - while
      // the shape stays the same size and the same distance inside the
      // surface (the whole sweep moves it under two pixels), so this measures
      // the cache missing rather than a smaller
      // shape being cheaper to rasterise.
      var frame = 0;
      final double deforming = await _median(
        target,
        () => _panelScene(frame++ * 0.0625),
      );

      // ignore: avoid_print
      print('sparse frame cost at ${_size}x$_size, median of $_iterations:\n'
          '  cold cache   ${cold.toStringAsFixed(3)} ms\n'
          '  warm cache   ${warm.toStringAsFixed(3)} ms\n'
          '  deforming    ${deforming.toStringAsFixed(3)} ms\n'
          '  $cache');
      expect(target.lastExecutedPathStrategy, GpuPathStrategy.sparseStrips,
          reason: 'a measurement of the dense route by accident would be '
              'worse than no measurement');
    } finally {
      target.dispose();
    }
  }, skip: _benchmarkSkip ?? session.skipReason);

  test('a rebuilt-but-identical path hits, which is what makes it work', () {
    // The property the frame numbers rest on, asserted without a device or a
    // clock: an animation rebuilds its display list every frame, so the key
    // has to compare paths by *content*. Identity would miss every time and
    // the warm number above would be the cold one.
    final VectorPlanCache<SparseStripDrawPlan> cache =
        VectorPlanCache<SparseStripDrawPlan>();
    const Rect clip = Rect.fromLTRB(0, 0, 256, 256);
    VectorPlanCacheKey keyFor(Path path) => VectorPlanCacheKey(
          path,
          transform: Transform2D.identity,
          clip: clip,
          fillRule: FillRule.nonZero,
          flattenTolerance: kDefaultFlattenTolerance,
        );

    final SparseStripDrawPlan plan = SparseStripDrawPlan();
    cache.store(keyFor(_panel(0)), plan);
    for (var frame = 0; frame < 5; frame++) {
      // A fresh Path object with the same verbs and points, exactly as a
      // rebuilt widget tree produces.
      expect(cache.lookup(keyFor(_panel(0))), same(plan),
          reason: 'frame $frame missed: $cache');
    }
    expect(cache.misses, 0);
    expect(cache.lookup(keyFor(_panel(0.25))), isNull,
        reason: 'different geometry has to miss, or the key is too wide');
  });
}

/// The scene: a rounded panel with a hole, which the tessellator refuses and
/// the selector therefore sends to sparse strips.
Path _panel(double offset, {int size = _size}) {
  final double scale = size / _size;
  final PathBuilder builder = PathBuilder();
  void contour(Rect rect, {required bool clockwise}) {
    builder.moveTo(rect.left, rect.top);
    if (clockwise) {
      builder
        ..lineTo(rect.right, rect.top)
        ..lineTo(rect.right, rect.bottom)
        ..lineTo(rect.left, rect.bottom);
    } else {
      builder
        ..lineTo(rect.left, rect.bottom)
        ..lineTo(rect.right, rect.bottom)
        ..lineTo(rect.right, rect.top);
    }
    builder.close();
  }

  contour(
    Rect.fromLTRB(8.5 * scale + offset, 8.5 * scale + offset,
        247.5 * scale + offset, 247.5 * scale + offset),
    clockwise: true,
  );
  contour(
    Rect.fromLTRB(80 * scale + offset, 80 * scale + offset,
        176 * scale + offset, 176 * scale + offset),
    clockwise: false,
  );
  return builder.build();
}

DisplayList _panelScene(double offset, {int size = _size}) {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFF3080C0);
  list.drawPath(list.addPath(_panel(offset, size: size)), paint);
  return list;
}

/// The median frame time in milliseconds, after warmup.
///
/// Median rather than mean because one scheduling hiccup in twenty-one frames
/// should not decide the number this file prints.
Future<double> _median(
  GlOffscreenTarget target,
  DisplayList Function() scene, {
  void Function()? beforeEach,
}) async {
  for (var i = 0; i < _warmupFrames; i++) {
    beforeEach?.call();
    await target.renderDisplayList(scene(), clearColor: _clear);
  }
  final List<double> samples = <double>[];
  for (var i = 0; i < _iterations; i++) {
    beforeEach?.call();
    final DisplayList list = scene();
    final Stopwatch clock = Stopwatch()..start();
    await target.renderDisplayList(list, clearColor: _clear);
    clock.stop();
    samples.add(clock.elapsedMicroseconds / 1000.0);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

/// One GL device for this file, or the reason there is none.
final class _CostSession {
  _CostSession._(this.device, this.skipReason, this._surface, this._context);

  final GlRenderDevice? device;
  final String? skipReason;
  final Win32GlSurface? _surface;
  final GlContext? _context;

  static _CostSession open({bool sparse = true}) {
    if (!Platform.isWindows) {
      return _CostSession._(
          null, 'this file measures the Win32 GL path', null, null);
    }
    try {
      final attempt = Win32GlSurface.hidden();
      final Win32GlSurface? surface = attempt.surface;
      if (surface == null) {
        return _CostSession._(null,
            'no GL surface: ${attempt.diagnostics.join('; ')}', null, null);
      }
      final contextAttempt = surface.createContext();
      final GlContext? context = contextAttempt.context;
      if (context == null) {
        surface.dispose();
        return _CostSession._(
            null,
            'no GL context: ${contextAttempt.diagnostics.join('; ')}',
            null,
            null);
      }
      return _CostSession._(
        GlRendererBackend.adoptContext(
          context,
          surface.glLibrary,
          enableExperimentalSparseStrips: sparse,
        ),
        null,
        surface,
        context,
      );
    } on Object catch (error) {
      return _CostSession._(
          null, 'opening a GL device threw: $error', null, null);
    }
  }

  void close() {
    device?.dispose();
    _context?.dispose();
    _surface?.dispose();
  }
}

GlOffscreenTarget _target(GlRenderDevice device) => _targetOf(device, _size);

GlOffscreenTarget _targetOf(GlRenderDevice device, int size) =>
    device.createTarget(
      MemorySurfaceDescriptor(
        pixelWidth: size,
        pixelHeight: size,
        format: PixelFormat.rgba8888Premultiplied,
      ),
    ) as GlOffscreenTarget;

/// The sparse encoding of the benchmark scene, measured once.
///
/// Pure CPU and pure representation: the half of the cost the selector
/// actually reads, and the half that does not depend on a driver.
SparseStripPlanMetrics _encodeOnce() {
  final StripBuffer strips = SparseStripGenerator().fill(
    _panel(0),
    const Rect.fromLTRB(0, 0, _size + 0.0, _size + 0.0),
  );
  final SparseStripDrawPlan plan = SparseStripDrawPlan()
    ..append(strips, materialIndex: 0);
  return plan.metrics;
}
