@TestOn('browser')

/// WebGL2 against the CPU rasteriser, pixel for pixel, in a real browser.
///
/// The fourth member of a family: `test/differential/cpu_gpu_parity_test.dart`
/// does this for OpenGL and states the argument in full,
/// `test/rendering/gpu/d3d11/d3d11_cpu_parity_test.dart` and its D3D12
/// neighbour repeat it. The claim each of them makes is that one display list
/// drawn by two completely different rasterisers produces the same pixels, and
/// the reason it is worth making four times is that each backend can break it
/// in its own way - a projection off by a row, a blend factor transcribed
/// wrongly, a texture filter that resamples coverage.
///
/// The tolerance is a **declared ceiling, not a margin**. Every test names the
/// deviation actually observed, and `0` means the two agree exactly. A scene
/// that has been exact and stops being exact is a regression even if it stays
/// under some looser bound, which is why the numbers are not padded.
///
/// ## How this one skips, and why that matters more here than elsewhere
///
/// Two gates, and both are needed:
///
///   1. **`@TestOn('browser')`** at the top. This file is not compiled or run
///      by a plain `dart test`, which is what the CI for this repository runs -
///      it has neither Chrome nor a GPU. The annotation is what makes the file
///      invisible there rather than a failure, and it is why the whole
///      directory needs no `dart_test.yaml` entry.
///   2. **A context check inside**, because `dart test -p chrome` on a machine
///      whose browser has no usable GPU process gets a null context from
///      `getContext('webgl2')`. That is not a bug in this backend and must not
///      read as one, so every test skips with the reason printed.
///
/// Run it with:
///
/// ```
/// dart test -p chrome test/rendering/gpu/webgl/
/// ```
///
/// ## Why the scenes have no text in them
///
/// The GL parity file ends with two glyph tests, and they read Ahem off disk
/// with `File(...).readAsBytesSync()`. There is no `dart:io` in a browser, so
/// the same scenes cannot be built here without an asset-loading path that
/// exists for one test.
///
/// **So glyph coverage parity is not measured on this backend**, and that gap
/// is stated rather than left to be found. What is known: the glyph path is the
/// same `GpuGlyphAtlas` and the same alpha8 upload the GL backend uses, wired
/// identically in `webgl_backend.dart`; the gallery in `web/` renders text
/// correctly in Chrome, which exercises it end to end; and
/// `webgl_device_test.dart` covers the layer and texture plumbing that the
/// glyph path shares. What is *not* known is whether a glyph's coverage bytes
/// land within one level of the CPU rasteriser's, the way the six exact scenes
/// below establish for geometry. Closing it needs a font the browser can fetch,
/// which `web/fonts` now has a precedent for.
library;

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_backend.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import 'webgl_session.dart';

/// One size for every scene, so a coordinate reads the same in all of them and
/// a diff can be found by eye in the failure output.
const int _size = 24;

/// Opaque, so a scene that gets its alpha wrong shows up as a colour and not as
/// a difference in transparency nobody looks at.
const int _clear = 0xFF000000;

void main() {
  final WebGlSession session = WebGlSession.open();
  // At the root, not inside the group: one device serves the whole file, and a
  // per-group teardown would dispose it before the next group opened a target.
  tearDownAll(session.close);

  group('WebGL2 agrees with the CPU rasteriser', () {
    test('solid, pixel-aligned rectangles: 0', () async {
      // Observed deviation: 0.
      await _expectParity(session, _solidRects(), tolerance: 0);
    });

    test('translucent rectangles, source-over: 0', () async {
      // Observed deviation: 0. The premultiplied blend arithmetic is the same
      // on both sides; a blend factor transcribed wrongly shows here first.
      await _expectParity(session, _alphaRects(), tolerance: 0);
    });

    test('a path whose contours overlap, non-zero: 0', () async {
      // Observed deviation: 0.
      await _expectParity(session, _overlappingPath(), tolerance: 0);
    });

    test('a path with a hole: 0', () async {
      // Observed deviation: 0.
      await _expectParity(session, _holePath(), tolerance: 0);
    });

    test('a layer with an opacity: 0', () async {
      // Observed deviation: 0. This is the scene that needs the framebuffer
      // pool, the layer stack and the y-flip uniform all to be right at once -
      // a layer written the wrong way up fails here and nowhere else.
      await _expectParity(session, _opacityLayer(), tolerance: 0);
    });

    test('nested layers: 0', () async {
      // Observed deviation: 0.
      await _expectParity(session, _nestedLayers(), tolerance: 0);
    });

    test('a clip that does not fall on pixel boundaries: 1, on one pixel',
        () async {
      // Observed deviation: 1, on 1 pixel of 576. See the note below on why
      // one level is the floor for a fractional edge and not a defect.
      await _expectParity(session, _clipped(), tolerance: 1);
    });

    test('an antialiased edge on a fractional boundary: 1, on two pixels',
        () async {
      // Observed deviation: 1, on 2 pixels of 576, one channel each -
      // (3, 5) cpu (114, 81, 16) gpu (114, 82, 16), and (18, 17) cpu
      // (29, 21, 4) gpu (29, 20, 4).
      //
      // ## Why one level is the honest ceiling here and zero is not
      //
      // This is the bound `gl_shaders.dart` states in its own header, reached
      // rather than assumed: "the CPU rounds positions to 1/255ths of a pixel
      // to make adjacent spans telescope exactly, while this stays in float.
      // The difference is bounded by one coverage level per axis."
      //
      // The six scenes above are exactly 0, and *which* six is the evidence
      // that this is quantisation and not a bug. The two path scenes have
      // antialiased edges too and agree perfectly, because a path's coverage is
      // rasterised on the CPU into the mask atlas and uploaded - so both sides
      // read the identical bytes. Only a rectangle's edge is computed by the
      // shader's analytic `boxCoverage`, and only the rectangle scenes with
      // fractional coordinates deviate. A transcription error in a blend
      // factor, a projection off by a row or a wrong texture filter would not
      // land on one level on two pixels; it would land on every pixel of an
      // edge, or on the whole surface.
      //
      // The same reasoning and the same number appear in
      // `d3d11_cpu_parity_test.dart`, which is the only other suite whose
      // scenes exercise a fractional rectangle edge.
      await _expectParity(session, _fractionalRect(), tolerance: 1);
    });
  });
}

/// Renders [list] through both backends and asserts they agree.
///
/// [tolerance] is a per-channel level, and every test states the deviation it
/// actually observed. Skips when there is no WebGL2 context, naming the reason.
Future<void> _expectParity(
  WebGlSession session,
  DisplayList list, {
  required int tolerance,
}) async {
  final String? reason = session.skipReason;
  if (reason != null) {
    // Not a silent return: a run with no GPU says so instead of looking like a
    // run that compared something.
    printOnFailure('skipped: $reason');
    markTestSkipped('no WebGL2 device: $reason');
    return;
  }

  final MemoryRenderTarget cpu = _cpuTarget(_size, _size);
  await cpu.renderDisplayList(list, clearColor: _clear);

  final WebGlOffscreenTarget gpu = session.target(_size, _size);
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
    reason: 'CPU and WebGL2 disagree by up to ${diff.maxDeviation} levels on '
        '${diff.differingPixels} pixels, over a declared tolerance of '
        '$tolerance.\n${diff.report}',
  );

  cpu.dispose();
  gpu.dispose();
}

/// A CPU target in the same pixel format the WebGL readback uses, so a
/// comparison that went wrong cannot be a channel-order mistake in the test.
MemoryRenderTarget _cpuTarget(int width, int height) =>
    MemoryRenderTarget(MemorySurfaceDescriptor(
      pixelWidth: width,
      pixelHeight: height,
      format: PixelFormat.rgba8888Premultiplied,
    ));

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

/// Two rectangles wound the same way, so non-zero fills their union.
DisplayList _overlappingPath() {
  final PathBuilder builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(3, 3, 14, 14), clockwise: true);
  _addRectContour(builder, const Rect.fromLTRB(9, 9, 20, 20), clockwise: true);
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFF33AA55, antiAlias: true);
  list.drawPath(list.addPath(builder.build()), paint);
  return list;
}

/// An outer contour and an inner one wound the other way, so the middle is a
/// hole under either fill rule.
DisplayList _holePath() {
  final PathBuilder builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(2, 2, 22, 22), clockwise: true);
  _addRectContour(builder, const Rect.fromLTRB(8, 8, 16, 16), clockwise: false);
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFCC8800, antiAlias: true);
  list.drawPath(list.addPath(builder.build()), paint);
  return list;
}

/// A `saveLayer` with an opacity, its content deliberately off-centre so a
/// layer drawn upside down or mirrored does not accidentally match.
DisplayList _opacityLayer() {
  final DisplayList list = DisplayList();
  final int background = list.addPaint(colorArgb: 0xFF203040, antiAlias: false);
  final int layerPaint = list.addPaint(colorArgb: 0x80FFFFFF, antiAlias: false);
  final int red = list.addPaint(colorArgb: 0xFFDD2222, antiAlias: false);
  final int blue = list.addPaint(colorArgb: 0xFF2222DD, antiAlias: false);
  list
    ..drawRect(0, 0, 24, 24, background)
    ..saveLayer(4, 4, 20, 20, layerPaint)
    // Asymmetric on both axes on purpose.
    ..drawRect(5, 5, 14, 10, red)
    ..drawRect(10, 12, 19, 19, blue)
    ..restore();
  return list;
}

DisplayList _nestedLayers() {
  final DisplayList list = DisplayList();
  final int background = list.addPaint(colorArgb: 0xFF102030, antiAlias: false);
  final int outer = list.addPaint(colorArgb: 0x40FFFFFF, antiAlias: false);
  final int inner = list.addPaint(colorArgb: 0x80FFFFFF, antiAlias: false);
  final int fill = list.addPaint(colorArgb: 0xFFEE7711, antiAlias: false);
  list
    ..drawRect(0, 0, 24, 24, background)
    ..saveLayer(2, 2, 22, 22, outer)
    ..drawRect(3, 3, 12, 12, fill)
    ..saveLayer(6, 6, 20, 20, inner)
    ..drawRect(7, 9, 18, 18, fill)
    ..restore()
    ..restore();
  return list;
}

/// A clip on fractional boundaries, plus a draw after the restore so a clip
/// that leaked past its scope shows up.
DisplayList _clipped() {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFF22AACC, antiAlias: true);
  final int after = list.addPaint(colorArgb: 0xFFCC2222, antiAlias: false);
  list
    ..save()
    ..clipRect(4.5, 4, 18, 17.5)
    ..drawRect(0, 0, 24, 24, paint)
    ..restore()
    ..drawRect(0, 20, 6, 24, after);
  return list;
}

/// All four edges on fractional coordinates, so every one of them is decided by
/// the analytic coverage term rather than by pixel snapping.
DisplayList _fractionalRect() {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFEEAA22, antiAlias: true);
  list.drawRect(3.2, 5.4, 18.6, 17.2, paint);
  return list;
}

/// Adds [rect] as a closed contour wound the way [clockwise] says.
///
/// Written out rather than using `PathBuilder.addRect` because the direction is
/// the point of the two path scenes: the fill rule is what is under test, and a
/// helper that chose the winding would be testing itself.
void _addRectContour(
  PathBuilder builder,
  Rect rect, {
  required bool clockwise,
}) {
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

final class _Diff {
  _Diff(this.maxDeviation, this.differingPixels, this.report);

  final int maxDeviation;
  final int differingPixels;

  /// The first handful of differing pixels, both sides shown. Not all of them:
  /// a wrong picture differs everywhere, and a thousand-line failure hides the
  /// one number that matters.
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
      if (lines.length < 12) lines.add('($x, $y): cpu $a, gpu $b');
    }
  }
  return _Diff(maxDeviation, differing, lines.join('\n'));
}

/// Whether every pixel of [buffer] is the same colour, which is what a scene
/// that drew nothing produces.
bool _isUniform(Framebuffer buffer) {
  final (int, int, int, int) first = _rgba(buffer, 0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      if (_rgba(buffer, x, y) != first) return false;
    }
  }
  return true;
}

/// A pixel as (r, g, b, a), whatever byte order the surface uses.
(int, int, int, int) _rgba(Framebuffer buffer, int x, int y) {
  final int i = buffer.offsetOf(x, y);
  final List<int> bytes = buffer.pixels;
  return switch (buffer.format) {
    PixelFormat.bgra8888Premultiplied => (
        bytes[i + 2],
        bytes[i + 1],
        bytes[i],
        bytes[i + 3]
      ),
    PixelFormat.rgba8888Premultiplied => (
        bytes[i],
        bytes[i + 1],
        bytes[i + 2],
        bytes[i + 3]
      ),
  };
}
