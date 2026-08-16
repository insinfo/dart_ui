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
/// ## The tolerance, measured: **0 where nothing blends, 1 where it does**
///
/// Two of the four scenes match exactly and two differ by one level, and the
/// difference is understood rather than tolerated. It is stated in full on the
/// alpha scene below, and in one line here: the CPU folds 8-bit channels
/// through `mul255` **twice** for a source-over - once premultiplying the
/// source, once attenuating the destination - and each rounds; Metal evaluates
/// the whole expression in floating point and quantises **once**. On a pixel
/// whose exact answer is 57.47 levels the CPU says 58 and Metal says 57. Both
/// are within half a level of the truth and Metal is the closer of the two.
///
/// That is also why the Direct3D 11 run of the same scenes measured 0 and this
/// one does not: Direct3D converts a pixel shader's output to the render
/// target's format *before* blending, which reproduces the CPU's first
/// rounding by accident. Metal, on this device, does not. Neither behaviour is
/// a defect and the difference is not visible at 8 bits per channel to anyone
/// but a test.
///
/// Every tolerance here is a **ceiling with a worked example next to it**, not
/// a margin. What a tolerance must never become is the place a failure is made
/// to go away: a scene that has been exact and stops being exact is a
/// regression, and the two exact scenes below are what would catch it.
///
/// The device these numbers came from is an `Apple Paravirtual device` - the
/// GPU a `macos-14` GitHub runner exposes - and it is worth recording, because
/// "Metal rounds a blend this way" is a statement about a driver.
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
    test('solid, pixel-aligned rectangles: 0', () async {
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

    test('rectangles with alpha, overlapping: 1, and Metal is the closer one',
        () async {
      // Source-over on premultiplied bytes, three times over, including where
      // two translucent rectangles overlap. That overlap is where a backend
      // that premultiplied at the wrong moment diverges first, and where a
      // pipeline descriptor that set the colour blend factors and left the
      // alpha ones at their defaults would show up - which is exactly the
      // mistake metal_device.dart sets both pairs to avoid.
      //
      // **Observed deviation: 1, on 196 pixels, and it was worked out rather
      // than tolerated.** Take pixel (2, 2), where 0x80CC3311 lies over the
      // opaque 0xFF204060 background, green channel:
      //
      //   * the exact answer is 51 * 128/255 + 64 * 127/255
      //     = 25.60 + 31.87 = **57.47** levels;
      //   * the CPU produces **58**: `mul255` rounds the premultiplied source
      //     to 26 and the attenuated destination to 32, then adds. Two
      //     roundings, each up;
      //   * Metal produces **57**: the whole expression is evaluated in
      //     floating point and quantised once, at the end.
      //
      // So neither is wrong - Metal is 0.47 from the truth and the CPU is 0.53
      // - and the difference is *where the arithmetic is quantised*, not what
      // it computes. That also explains why the Direct3D 11 run of the same
      // scene measured 0: Direct3D converts a pixel shader's output to the
      // render target's format **before** blending, which reproduces the CPU's
      // first rounding, and Metal on this device does not.
      //
      // The tolerance is a ceiling, not a margin. If this scene ever exceeds
      // 1, or if the solid scene above ever needs any tolerance at all,
      // something moved and this file is where it will be seen first.
      await _expectParity(gpu, pipelines, _alphaRects(), tolerance: 1);
    }, skip: _needsMac);

    test('a rectangle whose edges are all fractional: 1 on 2 pixels', () async {
      // The analytic coverage term on all four edges at once. The CPU computes
      // exact area coverage in `ScanlineFiller`; `boxCoverage` in the MSL
      // computes it from an interpolated device position that is only the
      // right answer if it arrives at the **pixel centre**. Metal samples at
      // the centre by default; a backend that had adopted Direct3D 9's
      // half-texel offset would be half a pixel out on every edge here.
      //
      // The four fractions are 0.8, 0.6, 0.6 and 0.2 of a pixel, each of which
      // multiplies out to a whole number of 8-bit levels (204, 153, 153, 51),
      // so no edge sits on a rounding boundary.
      //
      // **Observed deviation: 1, on exactly 2 of the 576 pixels** - (3, 5) and
      // (3, 17), both in the x = 3 column, which is the 0.8-covered left edge,
      // and both in a row whose own coverage is fractional too. So the two
      // pixels that differ are the ones where *two* fractional coverages
      // multiply, which is where the second rounding of the CPU's `mul255`
      // chain lands on the other side of a half from Metal's single one - the
      // same mechanism worked out in the scene above, at a tenth of the
      // frequency. The 574 pixels with one fractional edge or none match
      // exactly, which is the useful half of this measurement: the coverage
      // *term* agrees, and only its quantisation does not.
      await _expectParity(gpu, pipelines, _fractionalRect(), tolerance: 1);
    }, skip: _needsMac);

    test('a clip with a half-pixel edge: 0', () async {
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
