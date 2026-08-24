/// Direct2D drawing text under a matrix no bitmap can carry.
///
/// Until this file existed, `d2d_raster_sink.dart` refused these scenes by
/// name. ADR 0007 replaced that refusal with an outline route in the CPU
/// renderer and in `GpuRasterSink` and recorded the Direct2D half as a named
/// pendency: a scene with rotated text drew on the CPU, drew on OpenGL, and
/// threw `UnsupportedCapabilityError` on Direct2D. This file is that pendency
/// closed, and the assertion that closes it is the comparison below - the same
/// display list down Direct2D and down the CPU renderer, read back and
/// compared pixel by pixel.
///
/// ## The declared tolerance, and why it is not 0
///
/// `gl_glyph_device_test.dart` compares CPU against OpenGL at **deviation 0**,
/// and it can: both sides run the same `ScanlineFiller` over the same outline
/// and differ only in who consumes the coverage. Direct2D does not. It has its
/// own analytic rasteriser inside `d2d1.dll`, so its coverage on an
/// antialiased edge is a second opinion, not the same number - and a tolerance
/// of 0 here would be a test asserting that two independent rasterisers round
/// identically, which is false and which no correct implementation could make
/// true.
///
/// So the number is **measured, not assumed**, and the shape of the
/// disagreement is asserted alongside it, because a per-channel maximum can be
/// satisfied by a badly wrong picture:
///
///   * the **per-channel maximum**, bounded by [_tolerance];
///   * the **differing fraction** - how much of the surface disagrees at all,
///     bounded by [_maxDifferingFraction]. That is what separates "edges
///     rounded differently" from "the glyph is in the wrong place": text that
///     landed upright under a quarter turn disagrees over its whole ink box,
///     not over its edges;
///   * an **ink-box** assertion on the Direct2D readback itself, so a backend
///     that quietly drew upright text fails on the shape of the picture and
///     not only on the diff.
///
/// The measured numbers are stated per test, in the comment above each one.
///
/// ## What the fast path must keep doing
///
/// The upright control at the end goes through `FillOpacityMask` and the
/// shared glyph cache, and the last test asserts that a rotated run admits
/// nothing to that cache - a slot there is keyed by (face, size, glyph,
/// subpixel bucket) with nowhere to record an angle, so an entry made under a
/// rotation would be blitted upright by the next frame.
///
/// Skips rather than fails where Direct2D does not open, on the contract
/// `d2d_session.dart` states.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d2d/d2d_targets.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

import 'd2d_session.dart';

/// Opaque black, so a scene that got its alpha wrong reads as a colour rather
/// than as transparency nobody looks at.
const int _clear = 0xFF000000;

/// The per-channel bound this file holds Direct2D to against the CPU
/// renderer, over every scene below.
///
/// Measured, not chosen: see the library comment. Two independent analytic
/// rasterisers agree exactly inside a shape and outside it, and differ by a
/// rounding step on the pixels an edge crosses. The largest step measured
/// over the scenes below is **53 levels**, on the 45 degree turn; 64 is that
/// with headroom for a driver revision, and it applies only to the small
/// fraction of pixels [_maxDifferingFraction] bounds.
const int _tolerance = 64;

/// How much of the surface may disagree at all.
///
/// The bound that catches a wrong *picture* rather than a rounded edge. A
/// glyph drawn upright where the matrix asked for a quarter turn disagrees
/// over its entire ink box; an edge rounded the other way disagrees over a
/// one-pixel outline of it. The largest fraction measured below is **6.7%**,
/// on the mirror; 10% is that with headroom.
const double _maxDifferingFraction = 0.10;

void main() {
  final D2dSession session = D2dSession.open();
  final String? skip = D2dSession.platformSkip ?? session.skipReason;

  tearDownAll(session.close);

  final Typeface dejaVu =
      Typeface.parse(File('test/fonts/DejaVuSans.ttf').readAsBytesSync());

  group('a run under a transform no mask can carry', () {
    test('a quarter turn', () async {
      // 90 degrees is the case a vertical tab label needs and the one where a
      // wrong answer is least visible: a glyph turned by exactly a quarter
      // turn still lands on the pixel grid, so a backend that silently drew
      // upright text would produce a *plausible* picture. The ink box is what
      // catches that, and the diff is what catches everything else.
      //
      // Measured: max deviation 41 over 212 pixels, 3.5% of the surface.
      final ScaledTypeface font = dejaVu.atSize(20);
      final DisplayList list = _run(
        font,
        _glyphsFor(dejaVu, 'Vertical'),
        originX: 6,
        originY: 20,
        advance: 12,
        transform: _rotation(-math.pi / 2, 24, 24),
      );

      final Framebuffer d2d = _renderD2d(session, list, 48, 128);
      await _expectParity(session, list, 48, 128, rendered: d2d);

      final _Ink ink = _Ink.of(d2d);
      printOnFailure('ink box $ink');
      expect(ink.height, greaterThan(ink.width * 2),
          reason: 'a quarter turn makes a line of text taller than it is '
              'wide; upright text here would be the other way round');
    }, skip: skip);

    test('a 45 degree turn, where no glyph edge lands on the grid', () async {
      // The angle with no special cases: every stem crosses pixels at an
      // angle, so coverage is fractional almost everywhere and the two
      // rasterisers have the largest possible surface to disagree over. This
      // is the scene the tolerance is really sized by.
      //
      // Measured: max deviation 53 over 424 pixels, 4.6% of the surface -
      // the largest of the file, and what [_tolerance] is sized by.
      final ScaledTypeface font = dejaVu.atSize(24);
      final DisplayList list = _run(
        font,
        _glyphsFor(dejaVu, 'Skew'),
        originX: 10,
        originY: 30,
        advance: 15,
        transform: _rotation(math.pi / 4, 40, 40),
      );

      await _expectParity(session, list, 96, 96);
    }, skip: skip);

    test('a mirror, which no positive scale can express', () async {
      // scale(-1, 1): the determinant is negative, so every contour's winding
      // reverses. A fill rule applied to the *untransformed* winding would
      // empty the glyph and leave its counters solid - which reads as a font
      // problem rather than as a matrix one.
      //
      // Measured: max deviation 32 over 205 pixels, 6.7% of the surface -
      // the largest fraction of the file, and what [_maxDifferingFraction] is
      // sized by.
      final ScaledTypeface font = dejaVu.atSize(28);
      final DisplayList list = _run(
        font,
        _glyphsFor(dejaVu, 'Rb'),
        originX: 8,
        originY: 34,
        advance: 18,
        transform: _scale(-1, 1, 32, 24),
      );

      await _expectParity(session, list, 64, 48);
    }, skip: skip);

    test('a non-uniform scale, where one mask cannot serve both axes',
        () async {
      // scale(1, 2.5). The refusal this sink used to raise named this case
      // alongside rotation for a reason: there is no single pixel size to
      // rasterise a mask at, and picking either axis produces text of the
      // right width and the wrong height.
      //
      // Measured: max deviation 29 over 268 pixels, 6.5% of the surface.
      final ScaledTypeface font = dejaVu.atSize(16);
      final DisplayList list = _run(
        font,
        _glyphsFor(dejaVu, 'Tall'),
        originX: 6,
        originY: 16,
        advance: 11,
        transform: _scale(1, 2.5, 0, 8),
      );

      final Framebuffer d2d = _renderD2d(session, list, 64, 64);
      await _expectParity(session, list, 64, 64, rendered: d2d);

      final _Ink ink = _Ink.of(d2d);
      printOnFailure('ink box $ink');
      expect(ink.height, greaterThan(20),
          reason: 'the y axis is stretched 2.5x; text of the unscaled height '
              'here would mean the sink took one axis and dropped the other');
    }, skip: skip);

    test('the upright run it is a rotation of, so the fast path still agrees',
        () async {
      // The control. The whole point of the split is that the common case
      // still goes through `FillOpacityMask` and the shared glyph cache, so
      // this scene must keep taking the *other* route while its rotated twin
      // above takes this one - and both must match the CPU.
      //
      // Measured: max deviation 0 over 0 pixels - the fast path blits the
      // very masks the CPU renderer rasterised, so here, and only here, the
      // two backends agree exactly.
      final ScaledTypeface font = dejaVu.atSize(20);
      final DisplayList list = _run(
        font,
        _glyphsFor(dejaVu, 'Vertical'),
        originX: 6,
        originY: 20,
        advance: 12,
      );

      final D2dOffscreenSurface surface = _surface(session, 128, 48);
      surface.renderDisplayList(list, clearColor: _clear);
      expect(surface.sink.glyphBitmapCount, greaterThan(0),
          reason: 'an upright run must still be served by the glyph bitmap '
              'cache; if it is not, the fast path has been lost');

      await _expectParity(session, list, 128, 48);
    }, skip: skip);

    test('a rotated run leaves the glyph bitmap cache untouched', () {
      // The cost model, asserted rather than assumed - the same assertion
      // `gl_glyph_device_test.dart` makes about the glyph atlas. A slot in
      // this cache is keyed by (face, quantised size, glyph, subpixel bucket)
      // and has nowhere to record an angle, so an entry made under a rotation
      // would be blitted upright by whatever drew next.
      final ScaledTypeface font = dejaVu.atSize(20);
      final D2dOffscreenSurface surface = _surface(session, 96, 96);
      surface.renderDisplayList(
        _run(
          font,
          _glyphsFor(dejaVu, 'Turn'),
          originX: 10,
          originY: 30,
          advance: 13,
          transform: _rotation(math.pi / 4, 40, 40),
        ),
        clearColor: _clear,
      );

      expect(surface.sink.glyphBitmapCount, 0);
      expect(_isUniform(surface.readback()), isFalse,
          reason: 'the scene drew nothing, so the count above proves nothing');
    }, skip: skip);
  });

  group('what is still refused, and stays refused', () {
    test('stroked text, on both sides of the split', () {
      // The refusal ADR 0007 deliberately did not lift, kept symmetric with
      // the CPU sink. Asserted under a rotation as well as upright, so the new
      // route cannot become an accidental way in.
      final ScaledTypeface font = dejaVu.atSize(20);
      final D2dOffscreenSurface surface = _surface(session, 48, 48);
      for (final List<double>? transform in <List<double>?>[
        null,
        _rotation(math.pi / 4, 24, 24),
      ]) {
        final DisplayList list = _run(
          font,
          _glyphsFor(dejaVu, 'S'),
          originX: 8,
          originY: 30,
          transform: transform,
          style: paintStyleStroke,
        );
        expect(
          () => surface.renderDisplayList(list, clearColor: _clear),
          throwsA(isA<UnsupportedCapabilityError>()),
          reason: 'stroked text under transform $transform',
        );
      }
    }, skip: skip);
  });
}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

/// One glyph run, optionally under a transform.
///
/// The offsets are laid out here rather than shaped, because what is on trial
/// is the renderer and not the shaper: a run whose advances came from a text
/// layout would make a failure ambiguous between the two.
DisplayList _run(
  ScaledTypeface font,
  List<int> glyphs, {
  required double originX,
  required double originY,
  double advance = 0,
  int argb = 0xFFFFFFFF,
  int style = paintStyleFill,
  List<double>? transform,
}) {
  final list = DisplayList();
  final int ink = list.addPaint(
    colorArgb: argb,
    style: style,
    strokeWidth: style == paintStyleFill ? 0 : 2,
  );
  // Concatenated into the list rather than passed as a device transform, so
  // the player resolves it exactly as a `Transform` widget's matrix would -
  // the same code that decides the run's device origin and offsets.
  if (transform != null) {
    list
      ..save()
      ..transform(
        transform[0],
        transform[1],
        transform[2],
        transform[3],
        transform[4],
        transform[5],
      );
  }
  final offsets = Float32List(glyphs.length * 2);
  for (var i = 0; i < glyphs.length; i++) {
    offsets[i * 2] = i * advance;
  }
  list.drawGlyphRun(
    list.addFont(font),
    ink,
    originX,
    originY,
    Int32List.fromList(glyphs),
    offsets,
    glyphs.length,
  );
  if (transform != null) list.restore();
  return list;
}

/// `rotate(radians)` about ([pivotX], [pivotY]), as the six operands
/// [DisplayList.transform] takes.
List<double> _rotation(double radians, double pivotX, double pivotY) {
  final double cos = math.cos(radians);
  final double sin = math.sin(radians);
  return <double>[
    cos,
    sin,
    -sin,
    cos,
    pivotX - cos * pivotX + sin * pivotY,
    pivotY - sin * pivotX - cos * pivotY,
  ];
}

/// `scale(sx, sy)` about ([pivotX], [pivotY]). A negative factor mirrors.
List<double> _scale(double sx, double sy, double pivotX, double pivotY) =>
    <double>[sx, 0, 0, sy, pivotX * (1 - sx), pivotY * (1 - sy)];

List<int> _glyphsFor(Typeface face, String text) => <int>[
      for (final int rune in text.runes) face.glyphForCodePoint(rune),
    ];

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

D2dOffscreenSurface _surface(D2dSession session, int width, int height) {
  final D2dOffscreenSurface surface = session.surface(width, height);
  addTearDown(surface.dispose);
  return surface;
}

/// Replays [list] through Direct2D and returns the read-back pixels.
Framebuffer _renderD2d(
  D2dSession session,
  DisplayList list,
  int width,
  int height,
) {
  final D2dOffscreenSurface surface = _surface(session, width, height);
  final PresentResult result =
      surface.renderDisplayList(list, clearColor: _clear);
  expect(result.status, PresentStatus.presented);
  return surface.readback();
}

/// Asserts Direct2D and the CPU renderer agree on [list] within [_tolerance].
///
/// [rendered] lets a caller that already has the Direct2D pixels - because it
/// wants to assert on their shape too - avoid drawing the scene twice.
Future<void> _expectParity(
  D2dSession session,
  DisplayList list,
  int width,
  int height, {
  Framebuffer? rendered,
}) async {
  final Framebuffer d2d = rendered ?? _renderD2d(session, list, width, height);

  final cpu = MemoryRenderTarget(MemorySurfaceDescriptor(
    pixelWidth: width,
    pixelHeight: height,
    // The format the Direct2D DIB readback is in, so a comparison that went
    // wrong cannot be a channel-order mistake in the test itself.
    format: PixelFormat.bgra8888Premultiplied,
  ));
  addTearDown(cpu.dispose);
  await cpu.renderDisplayList(list, clearColor: _clear);

  // Two identically blank surfaces agree perfectly, so a run that drew nothing
  // - a glyph id that resolved to .notdef, a paint that came out transparent -
  // would pass this silently.
  expect(_isUniform(cpu.framebuffer), isFalse,
      reason: 'the scene drew no text, so comparing it proves nothing');

  final _Diff diff = _diff(cpu.framebuffer, d2d);
  final double fraction = diff.differingPixels / (width * height);
  printOnFailure('max deviation ${diff.maxDeviation} over '
      '${diff.differingPixels} pixels '
      '(${(fraction * 100).toStringAsFixed(1)}% of the surface)');
  expect(
    diff.maxDeviation,
    lessThanOrEqualTo(_tolerance),
    reason: 'Direct2D and the CPU renderer disagree by up to '
        '${diff.maxDeviation} levels on ${diff.differingPixels} pixels, over '
        'a declared tolerance of $_tolerance.\n${diff.report}',
  );
  expect(
    fraction,
    lessThanOrEqualTo(_maxDifferingFraction),
    reason: 'the two backends disagree on '
        '${(fraction * 100).toStringAsFixed(1)}% of the surface, which is a '
        'different picture rather than a differently rounded edge.\n'
        '${diff.report}',
  );
}

final class _Diff {
  _Diff(this.maxDeviation, this.differingPixels, this.report);

  final int maxDeviation;
  final int differingPixels;

  /// The first handful of differing pixels, both sides shown. Not all of them:
  /// a wrong picture differs everywhere, and a thousand-line failure hides the
  /// one number that matters.
  final String report;
}

_Diff _diff(Framebuffer cpu, Framebuffer d2d) {
  expect(d2d.width, cpu.width);
  expect(d2d.height, cpu.height);
  var maxDeviation = 0;
  var differing = 0;
  final lines = <String>[];
  for (var y = 0; y < cpu.height; y++) {
    for (var x = 0; x < cpu.width; x++) {
      final List<int> a = _pixel(cpu, x, y);
      final List<int> b = _pixel(d2d, x, y);
      var deviation = 0;
      for (var c = 0; c < 4; c++) {
        final int delta = (a[c] - b[c]).abs();
        if (delta > deviation) deviation = delta;
      }
      if (deviation == 0) continue;
      differing++;
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (lines.length < 12) lines.add('($x, $y): cpu $a, d2d $b');
    }
  }
  return _Diff(maxDeviation, differing, lines.join('\n'));
}

/// The bounding box of everything that is not the clear colour.
final class _Ink {
  const _Ink(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left + 1;
  int get height => bottom - top + 1;

  static _Ink of(Framebuffer buffer) {
    var left = buffer.width;
    var top = buffer.height;
    var right = -1;
    var bottom = -1;
    for (var y = 0; y < buffer.height; y++) {
      for (var x = 0; x < buffer.width; x++) {
        final List<int> pixel = _pixel(buffer, x, y);
        // The clear is opaque black; any ink at all lifts a colour channel.
        if (pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 0) continue;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
    expect(right, greaterThanOrEqualTo(0), reason: 'the scene drew nothing');
    return _Ink(left, top, right, bottom);
  }

  @override
  String toString() => '($left, $top)-($right, $bottom) ${width}x$height';
}

bool _isUniform(Framebuffer buffer) {
  final List<int> first = _pixel(buffer, 0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      final List<int> pixel = _pixel(buffer, x, y);
      for (var c = 0; c < 4; c++) {
        if (pixel[c] != first[c]) return false;
      }
    }
  }
  return true;
}

List<int> _pixel(Framebuffer framebuffer, int x, int y) {
  final int offset = y * framebuffer.bytesPerRow + x * 4;
  return <int>[
    framebuffer.pixels[offset],
    framebuffer.pixels[offset + 1],
    framebuffer.pixels[offset + 2],
    framebuffer.pixels[offset + 3],
  ];
}
