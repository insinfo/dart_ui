/// The same display list down both paths, compared pixel by pixel.
///
/// Section 35.4 asks for differential tests, and this is the file that pays
/// for them. Everything else in the suite checks one backend against an
/// expectation written by the same person who wrote the backend; that catches
/// a wrong number and misses a wrong *idea*, because an idea held on both
/// sides of a boundary is asserted identically on both sides of it. The bug
/// this file exists because of is exactly that shape: `beginLayer` on the CPU
/// turned a layer into a clip, `gpu_raster_sink.dart` gave the GPU real
/// offscreen layers, and a subtree at 50% opacity rendered at 100% on one
/// backend and 50% on the other. Both suites were green. Nothing compared
/// them.
///
/// So the rule here is: one [DisplayList], two renderers, one comparison, and
/// **no reference written by hand**. Where the two disagree, one of them is
/// wrong, and the tolerance is not the place to record that.
///
/// ## The tolerance, declared: **zero, on every scene**
///
/// The two backends compute the same compositing arithmetic in different
/// number systems, so a tolerance is *justifiable* in principle. The CPU folds
/// 8-bit channels through `mul255`, which is exact round-to-nearest of
/// `v * a / 255`. The GPU multiplies floats in a fragment shader, quantises
/// once at the end, and hands the result to a fixed-function blend unit that
/// the spec only requires to be accurate to within one least-significant bit
/// of the framebuffer format. A driver is therefore *allowed* to round a tie
/// the other way, and a scene whose arithmetic lands on a tie would differ by
/// one level with nothing wrong.
///
/// It was measured instead of assumed. On the driver this was written against,
/// **every scene below matches in all four channels on all 576 pixels** - the
/// antialiased path fills included, where a rounding difference was most
/// expected. So every test declares `tolerance: 0`, and the measurement is
/// recorded next to each one.
///
/// The `tolerance` parameter stays even though nothing uses it, because it is
/// the honest place to record a driver that genuinely rounds differently. What
/// it must never become is the place a failure is made to go away: a scene
/// that has been exact and stops being exact is a regression, a scene that has
/// always been one level out is noise, and a margin wide enough to cover both
/// destroys the only signal this file produces. If a scene here starts
/// differing, the answer is to find which backend moved.
///
/// ## What is not compared here, and why
///
/// **Even-odd fills.** The display list has no fill-rule operand: a `Path` is
/// an opaque interned object with no rule attached, and both sinks fill
/// non-zero. So an even-odd scene cannot be *encoded*, and the pair of path
/// tests below covers what can be: one shape where the two rules would give
/// different answers, which pins down that both backends use the same one, and
/// one where they agree.
///
/// It skips rather than fails where no driver answers, because "this machine
/// has no GPU" is not a defect in the renderer.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

/// One size for every scene, so a coordinate reads the same in all of them and
/// a diff can be found by eye in the failure output.
const int _size = 24;

/// Opaque, so a scene that gets its alpha wrong shows up as a colour and not
/// as a difference in transparency nobody looks at.
const int _clear = 0xFF000000;

void main() {
  final session = _GlSession.open();
  // At the root, not inside each group: one device serves the whole file, and
  // a per-group teardown would dispose it before the next group opened a
  // target on it.
  tearDownAll(session.close);

  group('CPU and GPU render the same display list', () {
    test('solid, pixel-aligned rectangles: 0', () async {
      // The floor of the whole comparison. Both backends round an aliased
      // rectangle's edges with `pixelEdge` and write a constant colour, so
      // there is no arithmetic left for a driver to round differently.
      // Observed deviation: 0. Anything above 0 here is a real difference.
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
      // Two overlapping rectangles wound the *same* way. Non-zero fills the
      // union; even-odd would punch the overlap out. Both backends agree, and
      // the shape they agree on is the non-zero one, which is what pins the
      // shared default down - see the library comment on why an even-odd
      // scene cannot be encoded.
      //
      // Observed deviation: 0, antialiased boundary included, and that is the
      // scene where a difference was most expected: both sides rasterise the
      // coverage with the same `ScanlineFiller` - the GPU stages it into a
      // mask atlas - but the CPU folds the byte into the source alpha with
      // `mul255` while the shader multiplies floats. They agree anyway.
      await _expectParity(session, _overlappingPath(), tolerance: 0);
    });

    test('a filled path with a hole, opposite winding: 0', () async {
      // The case where non-zero and even-odd agree: an inner contour wound
      // against the outer one is a hole under both rules. Included next to the
      // test above so the pair says which rule is in force rather than only
      // that the two backends match.
      // Observed deviation: 0.
      await _expectParity(session, _holePath(), tolerance: 0);
    });

    test('a layer at opacity 0.5: 0', () async {
      // The scene this whole file exists for. Before layers were real on the
      // CPU, the content came out at full opacity here and the GPU composited
      // it at half - a difference of 60 levels of red, on 64 pixels.
      // Observed deviation: 0.
      await _expectParity(session, _opacityLayer(), tolerance: 0);
    });

    test('nested layers, 0x80 inside 0x40: 0', () async {
      // Two composites on each side rather than one, so a backend that
      // multiplied opacities instead of compositing through the intermediate
      // buffer lands somewhere else entirely.
      // Observed deviation: 0.
      await _expectParity(session, _nestedLayers(), tolerance: 0);
    });

    test('a layer composited with plus: 0', () async {
      // The blend mode belongs to the *composite*, not to anything inside the
      // layer, and it saturates. GL's `ONE, ONE` clamps in its fixed-function
      // blend; `addSaturating` clamps in `blend.dart`. Equal by construction,
      // and measured here rather than assumed.
      // Observed deviation: 0.
      await _expectParity(session, _plusLayer(), tolerance: 0);
    });

    test('a layer composited with src: 0', () async {
      // `src` is the mode that proves a layer really is an isolated image: it
      // copies the layer's own transparency over the parent, so the parts of
      // the layer nothing drew into erase the background. A backend that
      // flattened the layer would have nothing to copy.
      // Observed deviation: 0.
      await _expectParity(session, _srcLayer(), tolerance: 0);
    });

    test('rectangles composited with plus, overlapping: 0', () async {
      // Until primitives honoured `paint.blendMode` on the CPU, this scene
      // could not be written: the GPU added and the CPU drew source-over, so
      // the two backends rendered different pictures and no test said so.
      // Observed deviation: 0.
      await _expectParity(session, _plusRects(), tolerance: 0);
    });

    test('a translucent rectangle composited with src: 0', () async {
      // `src` replaces all four channels, alpha included. Both backends agree
      // that the result is a half-transparent hole in an opaque surface -
      // which is the reading `gl_shaders.dart` forces, since it hands
      // `premultipliedColour * coverage` to a fixed-function ONE, ZERO blend
      // and keeps none of the destination.
      // Observed deviation: 0.
      await _expectParity(session, _srcRect(), tolerance: 0);
    });

    test('a filled path composited with plus: 0', () async {
      // The span loop rather than the rectangle loop: on the CPU those are two
      // separate paint paths, and the mode has to reach both.
      // Observed deviation: 0.
      await _expectParity(session, _plusPath(), tolerance: 0);
    });

    test('a rectangular clip: 0', () async {
      // A clip is a scissor on the GPU and a clip stack on the CPU, and the
      // two round a fractional edge with different code. The scene uses a
      // half-pixel clip edge on purpose.
      // Observed deviation: 0.
      await _expectParity(session, _clipped(), tolerance: 0);
    });

    test('a layer inside a clip, and a clip inside a layer: 0', () async {
      // The interaction, because each side handles it in a different place:
      // the GPU scissors the composite quad to the layer's saved clip, and the
      // CPU narrows the parent's clip stack around the composite blit. A
      // backend that applied the wrong one of the two clips draws the layer
      // outside the region it was clipped to.
      // Observed deviation: 0.
      await _expectParity(session, _clippedLayer(), tolerance: 0);
    });
  });

  group('a glyph run', () {
    test('lands on the exact pixels Ahem predicts, fractional rows included',
        () async {
      // Ahem's letters are solid boxes, so the CPU's output can be asserted as
      // exact pixels rather than as "some ink appeared". The box runs from
      // 0.8 em above the baseline to 0.2 em below it and spans one em: at 8 px
      // with the pen at (8, 14) that is x in [8, 16) and y in [7.6, 15.6), so
      // columns 8..15 are whole, rows 8..14 are whole, and rows 7 and 15 are
      // the fractional ends. Naming all three is what makes this a test of
      // *placement* rather than of ink.
      final Typeface ahem = Typeface.parse(_ahemBytes());
      final ScaledTypeface font = ahem.atSize(8);
      final DisplayList list = _textScene(font, ahem.glyphForCodePoint(0x58));

      final cpu = _cpuTarget(_size, _size);
      await cpu.renderDisplayList(list, clearColor: _clear);
      // The solid interior, at both corners of the whole-pixel block.
      expect(_rgba(cpu.framebuffer, 8, 8), (0xFF, 0xFF, 0xFF, 0xFF));
      expect(_rgba(cpu.framebuffer, 15, 14), (0xFF, 0xFF, 0xFF, 0xFF));
      // The horizontal edges are whole pixels - the pen's x is an integer here
      // - so the columns either side of the block carry no ink at all.
      expect(_rgba(cpu.framebuffer, 7, 10), (0, 0, 0, 0xFF));
      expect(_rgba(cpu.framebuffer, 16, 10), (0, 0, 0, 0xFF));
      // The vertical ones are not: 0.4 of row 7 is covered and 0.6 of row 15,
      // which is 102 and 153 levels of white over black. A rasteriser that
      // snapped the glyph to a whole row would put 0 or 255 in both.
      expect(_rgba(cpu.framebuffer, 10, 7), (102, 102, 102, 0xFF));
      expect(_rgba(cpu.framebuffer, 10, 15), (153, 153, 153, 0xFF));
      expect(_rgba(cpu.framebuffer, 10, 6), (0, 0, 0, 0xFF));
      expect(_rgba(cpu.framebuffer, 10, 16), (0, 0, 0, 0xFF));
      cpu.dispose();
    });

    test('and the GPU stages the same run through a glyph atlas: 0', () async {
      // Until the GL targets wired a `GpuGlyphAtlas`, this assertion was its
      // own opposite: it required the GPU to *refuse* the run by name, so that
      // a declared limit could not be mistaken for agreement on a blank
      // rectangle. Wiring the atlas made the refusal false, the assertion
      // failed, and turning the comparison on was the fix - which is the whole
      // reason it was written that way round.
      //
      // Both backends rasterise coverage with the same `GlyphRasterizer`; the
      // GPU only stages it in an atlas texture first. Both snap the baseline
      // to a whole pixel and keep x subpixel, so the fractional rows 7 and 15
      // asserted above have to survive the round trip through the atlas.
      // Observed deviation: 0.
      final Typeface ahem = Typeface.parse(_ahemBytes());
      await _expectParity(
        session,
        _textScene(ahem.atSize(8), ahem.glyphForCodePoint(0x58)),
        tolerance: 0,
      );
    }, skip: session.skipReason);
  });
}

// ---------------------------------------------------------------------
// The scenes. Each one is a display list and nothing else: no reference, no
// expected buffer, no per-backend variation.
// ---------------------------------------------------------------------

DisplayList _solidRects() {
  final list = DisplayList();
  final red = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  final blue = list.addPaint(colorArgb: 0xFF1133CC, antiAlias: false);
  list
    ..drawRect(2, 2, 12, 10, red)
    ..drawRect(10, 8, 22, 20, blue)
    // Touching the surface edge, where a projection off by a row shows up.
    ..drawRect(0, 22, 24, 24, red);
  return list;
}

DisplayList _alphaRects() {
  final list = DisplayList();
  final base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  final half = list.addPaint(colorArgb: 0x80CC3311, antiAlias: false);
  final quarter = list.addPaint(colorArgb: 0x4011CC33, antiAlias: false);
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(2, 2, 16, 16, half)
    // Overlapping the one above: two translucent layers of arithmetic.
    ..drawRect(8, 8, 22, 22, quarter);
  return list;
}

/// Two rectangles wound the same way, so non-zero fills their union.
DisplayList _overlappingPath() {
  final builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(3, 3, 14, 14), clockwise: true);
  _addRectContour(builder, const Rect.fromLTRB(9, 9, 20, 20), clockwise: true);

  final list = DisplayList();
  final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawPath(list.addPath(builder.build()), paint);
  return list;
}

/// An inner contour wound against the outer one: a hole under either rule.
DisplayList _holePath() {
  final builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(3, 3, 21, 21), clockwise: true);
  _addRectContour(builder, const Rect.fromLTRB(8, 8, 16, 16), clockwise: false);

  final list = DisplayList();
  final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawPath(list.addPath(builder.build()), paint);
  return list;
}

DisplayList _opacityLayer() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  // Only the alpha of a layer paint means anything; the colour is not a tint.
  final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
  list.saveLayer(4, 4, 20, 20, layerPaint);
  final content = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  // Deliberately not centred in the layer: a composite that is upside down or
  // off by a row is invisible against a symmetric shape.
  list
    ..drawRect(6, 6, 18, 12, content)
    ..restore();
  return list;
}

DisplayList _nestedLayers() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final outer = list.addPaint(colorArgb: 0x80FFFFFF);
  list.saveLayer(3, 3, 21, 21, outer);
  final inner = list.addPaint(colorArgb: 0x40FFFFFF);
  list.saveLayer(6, 6, 18, 18, inner);
  final content = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  list
    ..drawRect(6, 6, 18, 12, content)
    ..restore()
    ..restore();
  return list;
}

/// Two `plus` rectangles that overlap, so the saturating add is on trial.
///
/// `0xC0` red over `0xC0` red is `0xFF`, not `0x80`: wrapping instead of
/// clamping is the classic `plus` bug, and it only shows where two of them
/// meet.
DisplayList _plusRects() {
  final list = DisplayList();
  final base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  final add = list.addPaint(
    colorArgb: 0xC0CC3311,
    antiAlias: false,
    blendMode: blendModePlus,
  );
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(2, 2, 16, 16, add)
    ..drawRect(10, 10, 22, 22, add);
  return list;
}

/// A translucent `src` rectangle over an opaque background.
///
/// `src` replaces the destination including its **alpha**, so the result is a
/// half-transparent hole in an opaque surface - not a blend towards the paint.
/// A backend that treated `src` as "source-over with the destination cleared"
/// would keep the surface opaque and pass every other scene in this file.
DisplayList _srcRect() {
  final list = DisplayList();
  final base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  final replace = list.addPaint(
    colorArgb: 0x80CC3311,
    antiAlias: false,
    blendMode: blendModeSrc,
  );
  list
    ..drawRect(0, 0, 24, 24, base)
    ..drawRect(4, 4, 20, 20, replace);
  return list;
}

/// The union-by-winding path, drawn with `plus` onto a lit background.
///
/// The rect path and the span path are different loops on the CPU; this is the
/// one that proves the span loop carries the mode too.
DisplayList _plusPath() {
  final builder = PathBuilder();
  _addRectContour(builder, const Rect.fromLTRB(3, 3, 14, 14), clockwise: true);
  _addRectContour(builder, const Rect.fromLTRB(9, 9, 20, 20), clockwise: true);

  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final paint = list.addPaint(
    colorArgb: 0xFF443322,
    blendMode: blendModePlus,
  );
  list.drawPath(list.addPath(builder.build()), paint);
  return list;
}

DisplayList _plusLayer() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final layerPaint =
      list.addPaint(colorArgb: 0xFFFFFFFF, blendMode: blendModePlus);
  list.saveLayer(4, 4, 20, 20, layerPaint);
  final content = list.addPaint(colorArgb: 0xFF443322, antiAlias: false);
  list
    ..drawRect(6, 6, 18, 12, content)
    ..restore();
  return list;
}

DisplayList _srcLayer() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final layerPaint =
      list.addPaint(colorArgb: 0xFFFFFFFF, blendMode: blendModeSrc);
  list.saveLayer(4, 4, 20, 20, layerPaint);
  final content = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  list
    ..drawRect(6, 6, 18, 12, content)
    ..restore();
  return list;
}

DisplayList _clipped() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final content = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  list
    ..save()
    // A half-pixel edge: the two backends round it in different code.
    ..clipRect(4.5, 4, 18, 17.5)
    ..drawRect(0, 0, 24, 24, content)
    ..restore()
    // And something outside the clip afterwards, so a clip that leaked past
    // its restore is visible as well.
    ..drawRect(20, 20, 24, 24, content);
  return list;
}

DisplayList _clippedLayer() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  list.drawRect(0, 0, 24, 24, background);
  final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
  final content = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  list
    ..save()
    // The clip is tighter than the layer, so the composite has to obey it.
    ..clipRect(6, 6, 16, 16)
    ..saveLayer(3, 3, 21, 21, layerPaint);
  // And a clip inside the layer, narrower still.
  list
    ..save()
    ..clipRect(8, 8, 20, 14)
    ..drawRect(0, 0, 24, 24, content)
    ..restore()
    ..restore()
    ..restore();
  return list;
}

DisplayList _textScene(ScaledTypeface font, int glyph) {
  final list = DisplayList();
  final ink = list.addPaint(colorArgb: 0xFFFFFFFF);
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

/// Appends [rect] as one closed contour, wound the way [clockwise] says.
///
/// Written out rather than taken from `PathBuilder.addRect`, because the whole
/// point of the two path scenes is the *direction* of the second contour, and
/// a helper that picked its own would make the pair meaningless.
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
///
/// [tolerance] is a per-channel level, and every test states the deviation it
/// actually observed. Skips when there is no GL device, naming the reason.
Future<void> _expectParity(
  _GlSession session,
  DisplayList list, {
  required int tolerance,
}) async {
  final String? reason = session.skipReason;
  if (reason != null) {
    // Not `markTestSkipped` inside a passing test and not a silent return: the
    // reason is printed, so a run with no GPU says so instead of looking like
    // a run that compared something.
    printOnFailure('skipped: $reason');
    markTestSkipped('no GL device: $reason');
    return;
  }

  final cpu = _cpuTarget(_size, _size);
  await cpu.renderDisplayList(list, clearColor: _clear);

  final gpu = session.target(_size, _size);
  final PresentResult result =
      await gpu.renderDisplayList(list, clearColor: _clear);
  expect(result.status, PresentStatus.presented);

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
    reason: 'CPU and GPU disagree by up to ${diff.maxDeviation} levels on '
        '${diff.differingPixels} pixels, over a declared tolerance of '
        '$tolerance.\n${diff.report}',
  );

  cpu.dispose();
  gpu.dispose();
}

final class _Diff {
  _Diff(this.maxDeviation, this.differingPixels, this.report);

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
  final lines = <String>[];
  for (var y = 0; y < cpu.height; y++) {
    for (var x = 0; x < cpu.width; x++) {
      final a = _rgba(cpu, x, y);
      final b = _rgba(gpu, x, y);
      final deviation = [
        (a.$1 - b.$1).abs(),
        (a.$2 - b.$2).abs(),
        (a.$3 - b.$3).abs(),
        (a.$4 - b.$4).abs(),
      ].reduce((p, q) => p > q ? p : q);
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
  final first = _rgba(buffer, 0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      if (_rgba(buffer, x, y) != first) return false;
    }
  }
  return true;
}

/// A pixel as (r, g, b, a), whatever byte order the surface uses.
(int, int, int, int) _rgba(Framebuffer buffer, int x, int y) {
  final i = buffer.offsetOf(x, y);
  final bytes = buffer.pixels;
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

/// A CPU target in the same pixel format the GL readback uses, so a comparison
/// that went wrong cannot be a channel-order mistake in the test itself.
MemoryRenderTarget _cpuTarget(int width, int height) =>
    MemoryRenderTarget(MemorySurfaceDescriptor(
      pixelWidth: width,
      pixelHeight: height,
      format: PixelFormat.rgba8888Premultiplied,
    ));

Uint8List _ahemBytes() => File('test/fonts/ahem.ttf').readAsBytesSync();

// ---------------------------------------------------------------------
// Session plumbing - the same shape `gl_device_test.dart` uses, and for the
// same reason: a context costs tens of milliseconds and, on Windows, a window.
// ---------------------------------------------------------------------

final class _GlSession {
  _GlSession._(this.device, this.skipReason, this._surface);

  final GlRenderDevice? device;

  /// Null when the device opened. A string when it did not, so a run with no
  /// GPU reports the driver that was missing rather than passing quietly.
  final String? skipReason;

  final Win32GlSurface? _surface;

  static _GlSession open() {
    try {
      return Platform.isWindows ? _openWindows() : _openEgl();
    } on Object catch (error) {
      return _GlSession._(null, 'opening a GL device threw: $error', null);
    }
  }

  static _GlSession _openWindows() {
    final attempt = Win32GlSurface.hidden();
    final surface = attempt.surface;
    if (surface == null) {
      return _GlSession._(
          null, 'no GL surface: ${attempt.diagnostics.join('; ')}', null);
    }
    final contextAttempt = surface.createContext();
    final context = contextAttempt.context;
    if (context == null) {
      surface.dispose();
      return _GlSession._(null,
          'no GL context: ${contextAttempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(context, surface.glLibrary),
        null,
        surface,
      );
    } on BackendSelectionError catch (error) {
      surface.dispose();
      return _GlSession._(null, 'no GL device: $error', null);
    }
  }

  static _GlSession _openEgl() {
    final load = GlLibrary.open();
    if (!load.isLoaded) {
      return _GlSession._(
          null, 'no GL library: ${load.attempted.join(', ')}', null);
    }
    final attempt = const GlContextFactory()
        .create(width: _size, height: _size, glLibrary: load.library!);
    final context = attempt.context;
    if (context == null) {
      return _GlSession._(
          null, 'no EGL context: ${attempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(context, load.library!),
        null,
        null,
      );
    } on BackendSelectionError catch (error) {
      return _GlSession._(null, 'no GL device: $error', null);
    }
  }

  GlOffscreenTarget target(int width, int height) =>
      device!.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.rgba8888Premultiplied,
      )) as GlOffscreenTarget;

  void close() {
    device?.dispose();
    _surface?.dispose();
  }
}
