/// What each rasterisation route costs on the CPU, with no GPU in the middle.
///
/// ## Why this measurement is separate
///
/// The head-to-head in `gl_vector_cost_test.dart` measures whole frames, which
/// mixes two hypotheses that have different answers: *the Dart encoding is
/// expensive* and *the upload is not the bottleneck on a shared-memory GPU*.
/// This separates them by timing only the CPU half - geometry in, coverage
/// out - for the three routes that exist:
///
///   * **dense**, `ScanlineFiller` writing an alpha8 mask, which is what
///     `GpuMaskAtlas` does;
///   * **sparse (re-encoded)**, `SparseStripGenerator`, which runs the same
///     filler and then packs its spans into strips;
///   * **sparse (native)**, `NativeStripRasterizer`, where the strips *are*
///     the rasteriser and no scanline pass exists.
///
/// ## Why three scene classes
///
/// The rounded panel everything was measured against until now has few edges
/// and a lot of area, which is the best possible case for a dense mask and the
/// worst for strips: the mask's cost is area, the strips' cost is edges. A
/// verdict taken on that scene alone measures one side's favourable terrain.
///
/// So the sweep below covers the shape of the curve rather than a single
/// point: a panel (little edge, much area), a star polygon (much edge,
/// moderate area), and many small shapes (much edge, little area each, and the
/// per-command overhead that a list of icons really pays).
///
/// To take the numbers: `DART_UI_GPU_BENCHMARK=1 dart test <this file>`.
library;

import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/vector/native_strip_rasterizer.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/path/coverage_span_sink.dart';
import 'package:dart_ui/src/rendering/path/scanline_filler.dart';
import 'package:test/test.dart';

const int _size = 256;
const Rect _clip = Rect.fromLTRB(0, 0, 256, 256);

/// Iterations per measurement, and iterations thrown away before each one.
const int _iterations = 51;
const int _warmup = 15;

const String _benchmarkVariable = 'DART_UI_GPU_BENCHMARK';

final String? _benchmarkSkip = Platform.environment[_benchmarkVariable] == '1'
    ? null
    : 'a measurement rather than a correctness test; set '
        '$_benchmarkVariable=1 to take the numbers';

void main() {
  final List<_Scene> scenes = <_Scene>[
    _Scene('panel     (few edges, much area)', _panel()),
    _Scene('star      (many edges, much area)', _star(points: 61, skip: 29)),
    _Scene('spirograph(many edges, thin)', _spirograph()),
    _Scene('icons     (many small shapes)', _icons()),
  ];

  test('CPU cost per route, by scene', () {
    // ignore: avoid_print
    print('CPU rasterisation cost at ${_size}x$_size, '
        'median of $_iterations, microseconds:');
    for (final _Scene scene in scenes) {
      final double dense = _median(() => _rasteriseDense(scene.path));
      final double reencoded = _median(() => _rasteriseReencoded(scene.path));
      final double native = _median(() => _rasteriseNative(scene.path));
      final _Sizes sizes = _measureSizes(scene.path);
      // ignore: avoid_print
      print('  ${scene.name}: '
          'dense ${dense.toStringAsFixed(1)}  '
          're-encoded ${reencoded.toStringAsFixed(1)}  '
          'native ${native.toStringAsFixed(1)}  '
          '| bytes: mask ${sizes.maskBytes}, strips ${sizes.stripBytes} '
          '(${sizes.segments} segments, ${sizes.crossings} tile crossings)');
    }
  }, skip: _benchmarkSkip);

  test('the selector picks the route the measurement says is cheaper', () {
    // The rule, checked against the same four scenes it was derived from.
    // This is what authorises the promotion: sparse chosen where it wins,
    // refused where it loses, with the reason naming the numbers.
    const selector = GpuPathStrategySelector();
    const capabilities = GpuPathStrategyCapabilities(sparseStrips: true);
    final rasterizer = NativeStripRasterizer();
    const int area = _size * _size;

    final List<String> report = <String>[];
    final Map<String, GpuPathStrategy> chosen = <String, GpuPathStrategy>{};
    for (final _Scene scene in scenes) {
      final StripBuffer strips = rasterizer.fill(scene.path, _clip);
      final plan = SparseStripDrawPlan()..append(strips, materialIndex: 0);
      final SparseStripPlanMetrics metrics = plan.metrics;
      final GpuPathStrategyDecision decision = selector.select(
        GpuPathWorkload(
          pixelWidth: _size,
          pixelHeight: _size,
          segmentCount: rasterizer.lineCount,
          tileCrossings: rasterizer.tileCount,
          sparseEstimatedDrawCalls: metrics.estimatedDrawCallCount,
          sparseAtlasPageCount: metrics.atlasPageCount,
        ),
        capabilities,
      );
      chosen[scene.name.substring(0, 5)] = decision.strategy;
      report.add('  ${scene.name}: ${decision.strategy.name}  '
          '(${rasterizer.tileCount} crossings, '
          '${(rasterizer.tileCount / area).toStringAsFixed(4)}/px) '
          '- ${decision.reason}');
    }
    // ignore: avoid_print
    print('selector decision by scene:\n${report.join('\n')}');

    expect(chosen['panel'], GpuPathStrategy.sparseStrips,
        reason: 'few crossings over much area: sparse measured 2x faster');
    expect(chosen['icons'], GpuPathStrategy.coverageAtlas,
        reason: 'sparse measured ~15% slower here, so it must be refused');
    expect(chosen['spiro'], GpuPathStrategy.coverageAtlas,
        reason: 'sparse measured ~2x slower');
    expect(chosen['star '], GpuPathStrategy.coverageAtlas,
        reason: 'sparse measured ~1.8x slower');
  });

  test('the rule follows area, not just shape', () {
    // The same panel on a larger surface has the same perimeter and four
    // times the area, so its crossings-per-pixel falls and sparse wins by
    // more - which is the asymptotic claim the whole route rests on.
    const selector = GpuPathStrategySelector();
    const capabilities = GpuPathStrategyCapabilities(sparseStrips: true);
    final rasterizer = NativeStripRasterizer();
    for (final int size in <int>[256, 512, 1024]) {
      final Rect clip = Rect.fromLTRB(0, 0, size.toDouble(), size.toDouble());
      rasterizer.fill(_panel(), clip);
      final GpuPathStrategyDecision decision = selector.select(
        GpuPathWorkload(
          pixelWidth: size,
          pixelHeight: size,
          segmentCount: rasterizer.lineCount,
          tileCrossings: rasterizer.tileCount,
        ),
        capabilities,
      );
      expect(decision.strategy, GpuPathStrategy.sparseStrips,
          reason: '${size}x$size: ${decision.reason}');
    }
  });

  test('every scene really is the shape class it claims', () {
    // A benchmark whose "edge-dense" scene turned out to be a rectangle would
    // print numbers that mean nothing, so the classes are asserted rather than
    // described. Segment counts come from the rasteriser that flattens them.
    final rasterizer = NativeStripRasterizer();
    final List<int> segments = <int>[];
    for (final _Scene scene in scenes) {
      rasterizer.fill(scene.path, _clip);
      segments.add(rasterizer.lineCount);
    }
    expect(segments[0], lessThan(64),
        reason: 'the panel is the low-edge control, got ${segments[0]}');
    expect(segments[1], greaterThan(segments[0] * 4),
        reason: 'the star has to be materially denser in edges: $segments');
    expect(segments[2], greaterThan(200), reason: 'spirograph: $segments');
    expect(segments[3], greaterThan(200), reason: 'icons: $segments');
  });

  test('the native rasteriser agrees with the dense one on every scene', () {
    // The benchmark is only meaningful if the routes produce the same picture,
    // so the equality is checked on exactly the scenes being timed rather than
    // trusting the separate parity suite to have covered their shapes.
    for (final _Scene scene in scenes) {
      final Uint8List dense = _rasteriseDense(scene.path);
      final Uint8List native = _flatten(
        NativeStripRasterizer().fill(scene.path, _clip),
      );
      var worst = 0;
      for (var i = 0; i < dense.length; i++) {
        final int deviation = (dense[i] - native[i]).abs();
        if (deviation > worst) worst = deviation;
      }
      expect(worst, lessThanOrEqualTo(1), reason: '${scene.name}: $worst');
    }
  });
}

final class _Scene {
  _Scene(this.name, this.path);
  final String name;
  final Path path;
}

final class _Sizes {
  const _Sizes(this.maskBytes, this.stripBytes, this.segments, this.crossings);
  final int maskBytes;
  final int stripBytes;
  final int segments;

  /// (line, tile) pairs the render pass visits. This, not the segment count,
  /// is what the strip route's cost is proportional to: one long edge crossing
  /// the surface costs more than ten short ones in a corner.
  final int crossings;
}

_Sizes _measureSizes(Path path) {
  final rasterizer = NativeStripRasterizer();
  final StripBuffer strips = rasterizer.fill(path, _clip);
  final plan = SparseStripDrawPlan()..append(strips, materialIndex: 0);
  final SparseStripPlanMetrics metrics = plan.metrics;
  // The dense route uploads the shape's whole bounding box as alpha8.
  final Rect bounds = path.bounds.intersect(_clip);
  final int maskBytes =
      (bounds.width.ceil() * bounds.height.ceil()).clamp(0, _size * _size);
  return _Sizes(
    maskBytes,
    metrics.alphaTexelBytes + metrics.instanceBufferBytes,
    rasterizer.lineCount,
    rasterizer.tileCount,
  );
}

// ---------------------------------------------------------------------
// The three routes
// ---------------------------------------------------------------------

final ScanlineFiller _filler = ScanlineFiller();
final SparseStripGenerator _generator = SparseStripGenerator();
final NativeStripRasterizer _native = NativeStripRasterizer();
final Uint8List _mask = Uint8List(_size * _size);

Uint8List _rasteriseDense(Path path) {
  _mask.fillRange(0, _mask.length, 0);
  _filler.fill(path, _clip, _MaskSink(_mask, _size));
  return _mask;
}

Uint8List _rasteriseReencoded(Path path) {
  final StripBuffer strips = _generator.fill(path, _clip);
  return Uint8List.sublistView(strips.alphas, 0, strips.alphaCount);
}

Uint8List _rasteriseNative(Path path) {
  final StripBuffer strips = _native.fill(path, _clip);
  return Uint8List.sublistView(strips.alphas, 0, strips.alphaCount);
}

final class _MaskSink implements CoverageSpanSink {
  _MaskSink(this._mask, this._width);
  final Uint8List _mask;
  final int _width;

  @override
  void span(int y, int xStart, int xEnd, int coverage) {
    _mask.fillRange(y * _width + xStart, y * _width + xEnd, coverage);
  }
}

Uint8List _flatten(StripBuffer strips) {
  final Uint8List pixels = Uint8List(_size * _size);
  for (var i = 0; i < strips.stripCount; i++) {
    final int x = strips.stripX(i);
    final int y = strips.stripY(i);
    final int width = strips.stripWidth(i);
    for (var row = 0; row < kStripHeight; row++) {
      final int py = y + row;
      if (py < 0 || py >= _size) continue;
      for (var column = 0; column < width; column++) {
        final int px = x + column;
        if (px < 0 || px >= _size) continue;
        pixels[py * _size + px] = strips.stripAlpha(i, column, row);
      }
    }
  }
  for (var i = 0; i < strips.fillCount; i++) {
    final int x = strips.fillX(i);
    final int y = strips.fillY(i);
    final int width = strips.fillWidth(i);
    for (var row = 0; row < kStripHeight; row++) {
      final int py = y + row;
      if (py < 0 || py >= _size) continue;
      for (var column = 0; column < width; column++) {
        final int px = x + column;
        if (px < 0 || px >= _size) continue;
        pixels[py * _size + px] = 255;
      }
    }
  }
  return pixels;
}

double _median(void Function() body) {
  for (var i = 0; i < _warmup; i++) {
    body();
  }
  final List<double> samples = <double>[];
  for (var i = 0; i < _iterations; i++) {
    final Stopwatch clock = Stopwatch()..start();
    body();
    clock.stop();
    samples.add(clock.elapsedMicroseconds.toDouble());
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

// ---------------------------------------------------------------------
// Scenes, all generated in code so the benchmark is reproducible
// ---------------------------------------------------------------------

Path _panel() {
  final PathBuilder builder = PathBuilder();
  _addRect(builder, 8.5, 8.5, 247.5, 247.5, clockwise: true);
  _addRect(builder, 80, 80, 176, 176, clockwise: false);
  return builder.build();
}

/// A star polygon: many long edges crossing a large area.
Path _star({required int points, required int skip}) {
  final PathBuilder builder = PathBuilder();
  for (var i = 0; i <= points; i++) {
    final double angle = (i * skip) * 2 * 3.141592653589793 / points;
    final double x = 128 + 118.5 * _cos(angle);
    final double y = 128 + 118.5 * _sin(angle);
    if (i == 0) {
      builder.moveTo(x, y);
    } else {
      builder.lineTo(x, y);
    }
  }
  builder.close();
  return builder.build();
}

/// A spirograph: hundreds of short edges over a thin, winding region - the
/// closest cheap stand-in for a map outline or a large vectorised glyph.
Path _spirograph() {
  final PathBuilder builder = PathBuilder();
  const int steps = 720;
  for (var i = 0; i <= steps; i++) {
    final double t = i * 2 * 3.141592653589793 / 60;
    final double r = 60 + 55 * _cos(t * 3.5);
    final double x = 128 + r * _cos(t);
    final double y = 128 + r * _sin(t);
    if (i == 0) {
      builder.moveTo(x, y);
    } else {
      builder.lineTo(x, y);
    }
  }
  builder.close();
  return builder.build();
}

/// Sixty-four small shapes in one path: the list-of-icons case, where the cost
/// is edges and command count rather than area.
Path _icons() {
  final PathBuilder builder = PathBuilder();
  for (var row = 0; row < 8; row++) {
    for (var column = 0; column < 8; column++) {
      final double x = 6.5 + column * 31.25;
      final double y = 6.5 + row * 31.5;
      builder.moveTo(x + 10, y);
      for (var i = 1; i <= 6; i++) {
        final double angle = i * 2 * 3.141592653589793 / 6;
        builder.lineTo(x + 10 * _cos(angle) + 10, y + 10 * _sin(angle));
      }
      builder.close();
    }
  }
  return builder.build();
}

void _addRect(
  PathBuilder builder,
  double left,
  double top,
  double right,
  double bottom, {
  required bool clockwise,
}) {
  builder.moveTo(left, top);
  if (clockwise) {
    builder
      ..lineTo(right, top)
      ..lineTo(right, bottom)
      ..lineTo(left, bottom);
  } else {
    builder
      ..lineTo(left, bottom)
      ..lineTo(right, bottom)
      ..lineTo(right, top);
  }
  builder.close();
}

double _cos(double a) => _sin(a + 1.5707963267948966);

/// A deterministic sine, so the scenes are identical on every machine rather
/// than depending on the platform's libm rounding.
double _sin(double a) {
  var x = a % 6.283185307179586;
  if (x > 3.141592653589793) x -= 6.283185307179586;
  if (x < -3.141592653589793) x += 6.283185307179586;
  final double x2 = x * x;
  return x *
      (1 -
          x2 / 6 +
          x2 * x2 / 120 -
          x2 * x2 * x2 / 5040 +
          x2 * x2 * x2 * x2 / 362880);
}
