/// The same display list down the CPU rasteriser and Direct3D 12, compared
/// pixel by pixel.
///
/// `test/differential/cpu_gpu_parity_test.dart` does this for OpenGL and
/// explains at length why it is the only kind of test that catches a wrong
/// *idea* rather than a wrong number: an expectation written by the author of
/// a backend is asserted identically on both sides of a boundary they held in
/// their head. This file is the same argument applied to a second GPU backend,
/// and it is the reason the HLSL in `d3d12_shaders.dart` was written as a
/// transposition of the GLSL rather than from scratch.
///
/// It lives here rather than in `test/differential/` because that directory
/// belongs to another agent's change; the scenes below are deliberately the
/// same ones, so the two files can be merged into one parameterised comparison
/// once both backends are in.
///
/// ## The tolerance, declared: **zero, on every scene**
///
/// A tolerance is *justifiable* in principle. The CPU folds 8-bit channels
/// through `mul255`, which is exact round-to-nearest of `v * a / 255`. The GPU
/// multiplies floats in a pixel shader, quantises once at the end, and hands
/// the result to a fixed-function blend unit that the specification only
/// requires to be accurate within one least-significant bit of the render
/// target format. A driver is therefore *allowed* to round a tie the other way.
///
/// It was measured instead of assumed. On the adapter this was written against
/// - Intel UHD Graphics, feature level 12_1 - **every scene below matches in
/// all four channels on all 576 pixels**, the antialiased path fills included,
/// where a rounding difference was most expected. So every test declares
/// `tolerance: 0` and records the deviation it observed.
///
/// What the parameter must never become is the place a failure is made to go
/// away. A scene that has been exact and stops being exact is a regression; a
/// margin wide enough to hide it destroys the only signal this file produces.
///
/// ## What is not compared here, and why
///
/// **Layers.** This backend passes no `GpuLayerStack` to its sink and refuses a
/// `saveLayer` that needs an offscreen pass, by name. The refusal is asserted
/// in `test/backends/win32/d3d12/d3d12_device_test.dart` so that the gap
/// cannot quietly become a wrong picture; it is not compared here because
/// there is nothing to compare.
///
/// **Even-odd fills.** The display list has no fill-rule operand, so an
/// even-odd scene cannot be encoded. The pair of path scenes below covers what
/// can be: one shape where the two rules would disagree, which pins down that
/// both backends use non-zero, and one where they agree.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_offscreen_target.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

/// One size for every scene, so a coordinate reads the same in all of them and
/// a diff can be found by eye in the failure output.
const int _size = 24;

/// Opaque, so a scene that gets its alpha wrong shows up as a colour and not
/// as a difference in transparency nobody looks at.
const int _clear = 0xFF000000;

void main() {
  final D3d12Session session = D3d12Session.open();
  tearDownAll(session.close);

  group('the CPU and Direct3D 12 render the same display list', () {
    test('solid, pixel-aligned rectangles: 0', () async {
      // The floor of the whole comparison. Both backends round an aliased
      // rectangle's edges with `pixelEdge` and write a constant colour, so
      // there is no arithmetic left for a driver to round differently.
      // Observed deviation: 0.
      await _expectParity(session, _solidRects(), tolerance: 0);
    });

    test('rectangles with alpha, overlapping: 0', () async {
      // Source-over on premultiplied bytes, three times over, including where
      // two translucent rectangles overlap - which is where a backend that
      // premultiplies at the wrong moment diverges first.
      // Observed deviation: 0.
      await _expectParity(session, _alphaRects(), tolerance: 0);
    });

    test('a filled path whose winding decides the answer: 0', () async {
      // Two overlapping rectangles wound the same way. Non-zero fills the
      // union; even-odd would punch the overlap out.
      //
      // Observed deviation: 0, antialiased boundary included, and that is the
      // scene where a difference was most expected: both sides rasterise the
      // coverage with the same `ScanlineFiller` - this backend stages it into
      // an alpha8 atlas through an upload heap and a CopyTextureRegion - but
      // the CPU folds the byte into the source alpha with `mul255` while the
      // pixel shader multiplies floats. They agree anyway.
      await _expectParity(session, _overlappingPath(), tolerance: 0);
    });

    test('a filled path with a hole, opposite winding: 0', () async {
      // The case where non-zero and even-odd agree: an inner contour wound
      // against the outer one is a hole under both rules.
      // Observed deviation: 0.
      await _expectParity(session, _holePath(), tolerance: 0);
    });

    test('rectangles composited with plus, overlapping: 0', () async {
      // Direct3D 12 has no dynamic blend state - the factors are baked into a
      // pipeline state object - so this scene is also the check that the right
      // one of the three was selected. A backend that left the previous PSO
      // bound would composite source-over and look almost right.
      // Observed deviation: 0.
      await _expectParity(session, _plusRects(), tolerance: 0);
    });

    test('a translucent rectangle composited with src: 0', () async {
      // `src` replaces all four channels, alpha included: the result is a
      // half-transparent hole in an opaque surface, which is the reading a
      // ONE / ZERO blend forces.
      // Observed deviation: 0.
      await _expectParity(session, _srcRect(), tolerance: 0);
    });

    test('a filled path composited with plus: 0', () async {
      // The span loop rather than the rectangle loop: on the CPU those are two
      // separate paint paths, and the mode has to reach both. On this backend
      // it is the coverage-mask pipeline rather than the solid one, under the
      // additive pipeline state.
      // Observed deviation: 0.
      await _expectParity(session, _plusPath(), tolerance: 0);
    });

    test('a rectangular clip: 0', () async {
      // A clip is a scissor on the GPU and a clip stack on the CPU, and the
      // two round a fractional edge with different code. The scene uses a
      // half-pixel clip edge on purpose.
      //
      // It is also the check that no y flip crept in from the OpenGL backend:
      // `D3D12_RECT` is y-down from the top-left corner, exactly like the
      // device space the batcher produces, while GL's scissor origin is the
      // bottom-left and has to be converted. A scissor flipped here would clip
      // the mirror image of the region and only a clip test would notice.
      // Observed deviation: 0.
      await _expectParity(session, _clipped(), tolerance: 0);
    });

    test('a drawn image, texel for texel: 0', () async {
      // The textured pipeline, the upload heap and the placed-footprint copy.
      // Every texel of a four-by-four image carries a different colour, so a
      // row pitch that was not rounded up to 256 - or was rounded up and then
      // read back as if it had not been - shears the picture visibly.
      //
      // Drawn at 1:1 on purpose. A *scaled* image would compare resampling
      // policy instead of the upload: this backend samples an image with a
      // linear filter, like the OpenGL one, and `CpuRasterizer` does not
      // resample at all - so a four-times upscale differs by up to 192 levels
      // on both GPU backends and says nothing about either one's upload. That
      // is measured, not assumed, and it is why `cpu_gpu_parity_test.dart` has
      // no image scene either. Comparing resampling needs the CPU side to grow
      // a filter first.
      // Observed deviation: 0.
      await _expectParity(session, _image(), tolerance: 0);
    });
  });

  group('a glyph run', () {
    test('is staged through the glyph atlas and matches the CPU: 0', () async {
      // Both backends rasterise coverage with the same `GlyphRasterizer`; this
      // one stages it in an alpha8 atlas texture first, uploaded region by
      // region through the frame's upload heap. Both snap the baseline to a
      // whole pixel and keep x subpixel, so the fractional top and bottom rows
      // of an Ahem box have to survive the round trip.
      //
      // Ahem is used because its letters are solid boxes, so a difference is a
      // difference in *placement* rather than in hinting - and because an
      // atlas uploaded upside down would be invisible on a symmetric glyph.
      // Observed deviation: 0.
      final Typeface ahem = Typeface.parse(_ahemBytes());
      await _expectParity(
        session,
        _textScene(ahem.atSize(8), ahem.glyphForCodePoint(0x58)),
        tolerance: 0,
      );
    });
  });
}

// ---------------------------------------------------------------------
// The scenes. Each one is a display list and nothing else: no reference, no
// expected buffer, no per-backend variation.
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

DisplayList _overlappingPath() {
  final PathBuilder builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(3, 3, 14, 14), clockwise: true);
  _addRectContour(builder, const Rect.fromLTRB(9, 9, 20, 20), clockwise: true);

  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawPath(list.addPath(builder.build()), paint);
  return list;
}

DisplayList _holePath() {
  final PathBuilder builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(3, 3, 21, 21), clockwise: true);
  _addRectContour(builder, const Rect.fromLTRB(8, 8, 16, 16), clockwise: false);

  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawPath(list.addPath(builder.build()), paint);
  return list;
}

DisplayList _plusRects() {
  final DisplayList list = DisplayList();
  final int base = list.addPaint(colorArgb: 0xFF102030, antiAlias: false);
  final int a = list.addPaint(
      colorArgb: 0xFF402010, antiAlias: false, blendMode: blendModePlus);
  final int b = list.addPaint(
      colorArgb: 0xFF104020, antiAlias: false, blendMode: blendModePlus);
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(2, 2, 16, 16, a)
    ..drawRect(8, 8, 22, 22, b);
  return list;
}

DisplayList _srcRect() {
  final DisplayList list = DisplayList();
  final int base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  final int replace = list.addPaint(
      colorArgb: 0x80CC3311, antiAlias: false, blendMode: blendModeSrc);
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(4, 4, 20, 20, replace);
  return list;
}

DisplayList _plusPath() {
  final PathBuilder builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(3, 3, 14, 14), clockwise: true);

  final DisplayList list = DisplayList();
  final int base = list.addPaint(colorArgb: 0xFF102030, antiAlias: false);
  final int paint =
      list.addPaint(colorArgb: 0xFF403020, blendMode: blendModePlus);
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawPath(list.addPath(builder.build()), paint);
  return list;
}

DisplayList _clipped() {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  list
    ..save()
    ..clipRect(4.5, 4, 18, 17.5)
    ..drawRect(0, 0, 24, 24, paint)
    ..restore();
  return list;
}

DisplayList _image() {
  final Framebuffer image = Framebuffer.allocate(
    width: 8,
    height: 8,
    format: PixelFormat.rgba8888Premultiplied,
  );
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      final int offset = image.offsetOf(x, y);
      image.pixels[offset] = (x + 1) * 0x1F;
      image.pixels[offset + 1] = (y + 1) * 0x1F;
      image.pixels[offset + 2] = 0x40;
      image.pixels[offset + 3] = 0xFF;
    }
  }

  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
  final int id = list.addImage(image);
  list.drawImage(id, 0, 0, 8, 8, 4, 4, 12, 12, paint);
  return list;
}

DisplayList _textScene(ScaledTypeface font, int glyph) {
  final DisplayList list = DisplayList();
  final int ink = list.addPaint(colorArgb: 0xFFFFFFFF);
  // The pen at (8, 14): an integer x so the horizontal edges are whole pixels,
  // and a baseline that puts Ahem's box between rows 7.6 and 15.6 - two
  // fractional rows that an atlas round trip has to preserve.
  list.drawGlyphRun(
    list.addFont(font),
    ink,
    8,
    14,
    Int32List.fromList(<int>[glyph]),
    Float32List.fromList(<double>[0, 0]),
    1,
  );
  return list;
}

/// Appends a rectangle to [builder] in the given winding direction.
void _addRectContour(PathBuilder builder, Rect rect,
    {required bool clockwise}) {
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

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

/// Renders [list] through both backends and asserts they agree.
Future<void> _expectParity(
  D3d12Session session,
  DisplayList list, {
  required int tolerance,
}) async {
  final String? reason = session.skipReason;
  if (reason != null) {
    // Not a silent return: the reason is printed, so a run with no GPU says so
    // instead of looking like a run that compared something.
    printOnFailure('skipped: $reason');
    markTestSkipped('no Direct3D 12 device: $reason');
    return;
  }

  final MemoryRenderTarget cpu = _cpuTarget(_size, _size);
  await cpu.renderDisplayList(list, clearColor: _clear);

  final D3d12OffscreenTarget gpu = session.target(_size, _size);
  final PresentResult result =
      await gpu.renderDisplayList(list, clearColor: _clear);
  expect(result.status, PresentStatus.presented,
      reason: '${result.diagnostic}');

  // Two identically blank surfaces agree perfectly, so a scene that drew
  // nothing - a bad coordinate, a paint that resolved to transparent - would
  // pass this file silently. Every scene here is meant to put ink down.
  expect(_isUniform(cpu.framebuffer), isFalse,
      reason: 'the scene drew nothing, so comparing it proves nothing');

  final _Diff diff = _diff(cpu.framebuffer, gpu.framebuffer);
  printOnFailure('max deviation ${diff.maxDeviation} over '
      '${diff.differingPixels} pixels');
  expect(
    diff.maxDeviation,
    lessThanOrEqualTo(tolerance),
    reason: 'the CPU and Direct3D 12 disagree by up to ${diff.maxDeviation} '
        'levels on ${diff.differingPixels} pixels, over a declared tolerance '
        'of $tolerance.\n${diff.report}',
  );

  cpu.dispose();
  gpu.dispose();
}

final class _Diff {
  const _Diff(this.maxDeviation, this.differingPixels, this.report);

  final int maxDeviation;
  final int differingPixels;

  /// The first handful of differing pixels, both sides shown. Not all of them:
  /// a wrong picture differs everywhere, and a thousand-line failure hides the
  /// one number that matters, which is the maximum above.
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
      final List<int> a = _rgba(cpu, x, y);
      final List<int> b = _rgba(gpu, x, y);
      var deviation = 0;
      for (var channel = 0; channel < 4; channel++) {
        final int difference = (a[channel] - b[channel]).abs();
        if (difference > deviation) deviation = difference;
      }
      if (deviation == 0) continue;
      differing++;
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (lines.length < 12) lines.add('($x, $y): cpu $a, gpu $b');
    }
  }
  return _Diff(maxDeviation, differing, lines.join('\n'));
}

/// Whether every pixel of [buffer] is the same colour, which is what a scene
/// that drew nothing produces.
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

MemoryRenderTarget _cpuTarget(int width, int height) =>
    MemoryRenderTarget(MemorySurfaceDescriptor(
      pixelWidth: width,
      pixelHeight: height,
      format: PixelFormat.rgba8888Premultiplied,
    ));

Uint8List _ahemBytes() => File('test/fonts/ahem.ttf').readAsBytesSync();
