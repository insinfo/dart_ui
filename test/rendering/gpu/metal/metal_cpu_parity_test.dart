/// The same display list down the CPU path and the Metal path, compared pixel
/// by pixel.
///
/// `test/differential/cpu_gpu_parity_test.dart` states the argument for why
/// this is worth more than any other test in the suite - every other file
/// checks one backend against an expectation written by the person who wrote
/// that backend, which catches a wrong number and misses a wrong *idea*. That
/// argument is not repeated. The rule is: **one [DisplayList], two renderers,
/// one comparison, and no reference written by hand.**
///
/// Metal is the fourth backend held against the CPU rasteriser, after OpenGL,
/// Direct3D 11 and Direct3D 12. All three of those measured **zero** deviation
/// on the two scenes below, which is what makes a Metal deviation meaningful:
/// if this file were the first, a difference would be an open question, and
/// with three prior witnesses agreeing it is a defect in this backend.
///
/// ## The tolerance, declared before it was measured
///
/// A non-zero tolerance is *justifiable* here and it is worth saying why
/// before saying whether it was needed. The CPU folds 8-bit channels through
/// `mul255`, which is exact round-to-nearest of `v * a / 255`. The GPU
/// multiplies 32-bit floats in a fragment shader, quantises once at the end,
/// and hands the result to a fixed-function blend unit; Metal's specification
/// does not promise bit-exact agreement with anyone's integer arithmetic, and
/// a value that lands on a rounding tie may go either way. The
/// Direct3D 11 parity file measured exactly that: one scene, one level, at the
/// three fractions whose coverage times 255 is a half-integer.
///
/// So the tolerance is declared per scene and the **observed** deviation is
/// recorded next to it. What a tolerance must never become is the place a
/// failure is made to go away: a scene that has been exact and stops being
/// exact is a regression, and a margin wide enough to cover both destroys the
/// only signal this file produces.
///
/// ## What is compared, and what this backend cannot draw yet
///
/// Solid rectangles and rectangles with alpha - the two scenes the task names,
/// and the floor of everything else: if those differ, nothing above them means
/// anything. Paths, rounded rectangles, glyphs and compositing layers are
/// **not** here, because `MetalOffscreenTarget` builds its sink without a mask
/// atlas, a glyph atlas or a layer stack and refuses those primitives by name
/// rather than approximating them. A scene that silently drew nothing would
/// compare two backgrounds and pass.
library;

import 'dart:io';

import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_device.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_offscreen.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

/// One size for every scene, so a coordinate reads the same in all of them.
const int _size = 24;

/// Opaque, so a scene that gets its alpha wrong shows as a colour difference
/// and not as transparency nobody looks at.
const int _clear = 0xFF000000;

final String? _needsMac = Platform.isMacOS
    ? null
    : 'needs a Mac: this renders a display list with Metal and reads it back.';

void main() {
  late MetalGpu gpu;
  late MetalPipelineCache pipelines;

  setUpAll(() {
    if (!Platform.isMacOS) return;
    gpu = MetalGpu.open();
    pipelines = MetalPipelineCache.build(gpu);
  });

  tearDownAll(() {
    if (!Platform.isMacOS) return;
    pipelines.dispose();
    gpu.dispose();
  });

  group('the CPU and Metal render the same display list', () {
    test('solid, pixel-aligned rectangles', () async {
      // The floor of the whole comparison. Both backends round an aliased
      // rectangle's edges with `pixelEdge` and write a constant colour, so
      // there is no arithmetic left for a driver to round differently - and no
      // y flip left to hide, because the rectangles are deliberately not
      // vertically symmetric. This is also the scene that would catch the
      // vertex descriptor pointing at the wrong offset: the colour would come
      // out of the shape rectangle and every quad would be a different wrong
      // colour.
      await _expectParity(gpu, pipelines, _solidRects(), tolerance: 0);
    }, skip: _needsMac);

    test('rectangles with alpha, overlapping', () async {
      // Source-over on premultiplied bytes, three times over, including where
      // two translucent rectangles overlap. That overlap is where a backend
      // that premultiplied at the wrong moment diverges first, and where a
      // pipeline descriptor that set the colour blend factors and left the
      // alpha ones at their defaults would show up - which is exactly the
      // mistake metal_device.dart sets both pairs to avoid.
      await _expectParity(gpu, pipelines, _alphaRects(), tolerance: 0);
    }, skip: _needsMac);

    test('a rectangle whose edges are all fractional', () async {
      // The analytic coverage term on all four edges at once. The CPU computes
      // exact area coverage in `ScanlineFiller`; `boxCoverage` in the MSL
      // computes it from an interpolated device position that is only the
      // right answer if it arrives at the **pixel centre**. Metal samples at
      // the centre by default; a backend that had adopted Direct3D 9's
      // half-texel offset would be half a pixel out on every edge here.
      //
      // The four fractions are 0.8, 0.6, 0.6 and 0.2 of a pixel, each of which
      // multiplies out to a whole number of 8-bit levels (204, 153, 153, 51),
      // so no edge sits on a rounding boundary and the byte both sides
      // quantise to is unambiguous.
      await _expectParity(gpu, pipelines, _fractionalRect(), tolerance: 0);
    }, skip: _needsMac);

    test('a clip with a half-pixel edge', () async {
      // A clip is an MTLScissorRect here and a clip stack on the CPU. Metal's
      // scissor origin is the top-left corner of the render target, the same
      // as device space's, so the rectangle is used as the batcher computed it
      // with no `height - bottom` - which GL needs and this backend must not
      // do. The rectangle is asymmetric so that getting it wrong moves the
      // clipped region somewhere visible.
      await _expectParity(gpu, pipelines, _clipped(), tolerance: 0);
    }, skip: _needsMac);
  });
}

// ---------------------------------------------------------------------
// The scenes. Each is a display list and nothing else.
// ---------------------------------------------------------------------

DisplayList _solidRects() {
  final DisplayList list = DisplayList();
  final int red = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  final int blue = list.addPaint(colorArgb: 0xFF1133CC, antiAlias: false);
  list
    ..drawRect(2, 2, 12, 10, red)
    ..drawRect(10, 8, 22, 20, blue)
    // Touching the surface edge, where a projection off by a row shows up.
    ..drawRect(0, 22, 24, 24, red);
  return list;
}

DisplayList _alphaRects() {
  final DisplayList list = DisplayList();
  final int base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  final int half = list.addPaint(colorArgb: 0x80CC3311, antiAlias: false);
  final int quarter = list.addPaint(colorArgb: 0x4011CC33, antiAlias: false);
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(2, 2, 16, 16, half)
    ..drawRect(8, 8, 22, 22, quarter);
  return list;
}

DisplayList _fractionalRect() {
  final DisplayList list = DisplayList();
  final int base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, base);
  final int ink = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawRect(3.2, 5.4, 18.6, 17.2, ink);
  return list;
}

DisplayList _clipped() {
  final DisplayList list = DisplayList();
  final int background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final int content = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  list
    ..save()
    ..clipRect(4.5, 4, 18, 17.5)
    ..drawRect(0, 0, 24, 24, content)
    ..restore()
    // And something outside the clip afterwards, so a clip that leaked past
    // its restore is visible too.
    ..drawRect(20, 20, 24, 24, content);
  return list;
}

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

Future<void> _expectParity(
  MetalGpu gpu,
  MetalPipelineCache pipelines,
  DisplayList list, {
  required int tolerance,
}) async {
  // BGRA, which is the byte order the CPU rasteriser actually produces.
  // `rasterizeDisplayList`'s clear path writes blue into byte 0 whatever the
  // declared format is - see metal_offscreen_test.dart, which found it - so
  // asking for rgba8888 here would put the clear colour in backwards while
  // every drawn primitive landed correctly. `_rgba` reads both surfaces
  // through their declared format, so the comparison is unaffected either way;
  // this simply avoids relying on a path that is known to be wrong.
  final MemoryRenderTarget cpu = MemoryRenderTarget(
    const MemorySurfaceDescriptor(
      pixelWidth: _size,
      pixelHeight: _size,
      format: PixelFormat.bgra8888Premultiplied,
    ),
  );
  final MetalOffscreenTarget metal = MetalOffscreenTarget.create(
    gpu,
    pipelines,
    width: _size,
    height: _size,
  );
  try {
    await cpu.renderDisplayList(list, clearColor: _clear);
    metal.renderDisplayList(list, clearColor: _clear);
    final Framebuffer gpuPixels = metal.readPixels();

    // Two identically blank surfaces agree perfectly, so a scene that drew
    // nothing - a bad coordinate, a paint that resolved to transparent, a draw
    // call that never reached the encoder - would pass this file silently.
    expect(_isUniform(cpu.framebuffer), isFalse,
        reason: 'the CPU scene drew nothing, so comparing it proves nothing');
    expect(_isUniform(gpuPixels), isFalse,
        reason: 'Metal drew nothing: the surface is one colour, which is what '
            'a pass with no draw calls in it looks like');

    final _Diff diff = _diff(cpu.framebuffer, gpuPixels);
    print('metal parity: max deviation ${diff.maxDeviation} over '
        '${diff.differingPixels} pixel(s)');
    expect(
      diff.maxDeviation,
      lessThanOrEqualTo(tolerance),
      reason: 'the CPU and Metal disagree by up to ${diff.maxDeviation} levels '
          'on ${diff.differingPixels} pixels, over a declared tolerance of '
          '$tolerance.\n${diff.report}',
    );
  } finally {
    metal.dispose();
    cpu.dispose();
  }
}

final class _Diff {
  _Diff(this.maxDeviation, this.differingPixels, this.report);

  final int maxDeviation;
  final int differingPixels;

  /// The first handful of differing pixels, both sides shown. Not all of them:
  /// a wrong picture differs everywhere, and a thousand-line failure hides the
  /// maximum, which is the number that matters.
  final String report;
}

_Diff _diff(Framebuffer cpu, Framebuffer gpu) {
  expect(gpu.width, cpu.width);
  expect(gpu.height, cpu.height);
  var maxDeviation = 0;
  var differing = 0;
  final List<String> lines = <String>[];
  for (var y = 0; y < cpu.height; y++) {
    for (var x = 0; x < cpu.width; x++) {
      final (int, int, int, int) a = _rgba(cpu, x, y);
      final (int, int, int, int) b = _rgba(gpu, x, y);
      final int deviation = <int>[
        (a.$1 - b.$1).abs(),
        (a.$2 - b.$2).abs(),
        (a.$3 - b.$3).abs(),
        (a.$4 - b.$4).abs(),
      ].reduce((int p, int q) => p > q ? p : q);
      if (deviation == 0) continue;
      differing++;
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (lines.length < 12) lines.add('($x, $y): cpu $a, metal $b');
    }
  }
  return _Diff(maxDeviation, differing, lines.join('\n'));
}

bool _isUniform(Framebuffer buffer) {
  final (int, int, int, int) first = _rgba(buffer, 0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      if (_rgba(buffer, x, y) != first) return false;
    }
  }
  return true;
}

(int, int, int, int) _rgba(Framebuffer buffer, int x, int y) {
  final int i = buffer.offsetOf(x, y);
  final pixels = buffer.pixels;
  return switch (buffer.format) {
    PixelFormat.bgra8888Premultiplied => (
        pixels[i + 2],
        pixels[i + 1],
        pixels[i],
        pixels[i + 3]
      ),
    PixelFormat.rgba8888Premultiplied => (
        pixels[i],
        pixels[i + 1],
        pixels[i + 2],
        pixels[i + 3]
      ),
  };
}
