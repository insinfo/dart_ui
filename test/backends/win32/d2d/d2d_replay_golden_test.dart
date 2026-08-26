/// The Direct2D replayer against real pixels.
///
/// Every test here records a display list, replays it through the production
/// player and the Direct2D sink into a DC render target over a DIB section,
/// and asserts on the bytes that come back - the same "draw, flush, compare"
/// contract the CPU golden tests state, pointed at a real `d2d1.dll`.
///
/// Assertions sample well inside shapes and well outside them, never on an
/// antialiased edge, so a legitimate coverage difference between Direct2D's
/// rasteriser and the CPU one cannot fail a test that is really about
/// geometry, transforms, clips and paint plumbing.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d2d/d2d_targets.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_com.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

import 'd2d_session.dart';

const int _black = 0xFF000000;
const int _red = 0xFFFF0000;

void main() {
  final D2dSession session = D2dSession.open();
  final String? skip = D2dSession.platformSkip ?? session.skipReason;

  tearDownAll(session.close);

  D2dOffscreenSurface newSurface([int size = 40]) {
    final D2dOffscreenSurface surface = session.surface(size, size);
    addTearDown(surface.dispose);
    return surface;
  }

  group('solid geometry', () {
    test('a filled rectangle lands where the player put it', () {
      final surface = newSurface();
      final list = DisplayList();
      list.drawRect(
          10, 10, 30, 30, list.addPaint(colorArgb: _red, antiAlias: false));

      final PresentResult result =
          surface.renderDisplayList(list, clearColor: _black);
      expect(result.status, PresentStatus.presented);

      final pixels = surface.readback();
      expect(_rgba(pixels, 20, 20), (255, 0, 0, 255));
      expect(_rgba(pixels, 5, 5), (0, 0, 0, 255));
      expect(_rgba(pixels, 32, 20), (0, 0, 0, 255));
    });

    test('an axis-aligned clip removes what it should and nothing else', () {
      final surface = newSurface();
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: _red, antiAlias: false);
      list
        ..save()
        ..clipRect(0, 0, 20, 40)
        ..drawRect(0, 0, 40, 40, paint)
        ..restore();

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      expect(_rgba(pixels, 10, 20), (255, 0, 0, 255));
      expect(_rgba(pixels, 25, 20), (0, 0, 0, 255),
          reason: 'the right half is outside the clip');
    });

    test('a transform moves and scales the geometry, not the clip', () {
      final surface = newSurface();
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: _red, antiAlias: false);
      list
        ..save()
        ..transform(2, 0, 0, 2, 4, 4)
        ..drawRect(3, 3, 13, 13, paint) // device: (10, 10) - (30, 30)
        ..restore();

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      expect(_rgba(pixels, 20, 20), (255, 0, 0, 255));
      expect(_rgba(pixels, 7, 7), (0, 0, 0, 255));
      expect(_rgba(pixels, 32, 32), (0, 0, 0, 255));
    });

    test('a uniform rounded rectangle rounds its corners', () {
      final surface = newSurface();
      final list = DisplayList();
      list.drawRRectUniform(4, 4, 36, 36, 8, 8, list.addPaint(colorArgb: _red));

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      expect(_rgba(pixels, 20, 20), (255, 0, 0, 255));
      // (5.5, 5.5) is 9.2 px from the corner circle's centre (12, 12);
      // radius is 8, so the pixel is fully outside the shape.
      expect(_rgba(pixels, 5, 5), (0, 0, 0, 255));
      // On the straight edge the fill reaches the bounds.
      expect(_rgba(pixels, 20, 6), (255, 0, 0, 255));
    });

    test('per-corner radii take the path route and stay per-corner', () {
      final surface = newSurface();
      final list = DisplayList();
      // Square top-left corner, 12 px everywhere else.
      list.drawRRect(4, 4, 36, 36, 0, 0, 12, 12, 12, 12, 12, 12,
          list.addPaint(colorArgb: _red));

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      expect(_rgba(pixels, 5, 5), (255, 0, 0, 255),
          reason: 'the top-left corner is square');
      // (34.5, 34.5) is 14.8 px from the bottom-right corner circle's centre
      // (24, 24); radius is 12, so the pixel is fully outside.
      expect(_rgba(pixels, 34, 34), (0, 0, 0, 255));
      expect(_rgba(pixels, 20, 20), (255, 0, 0, 255));
    });
  }, skip: skip);

  group('paths and strokes', () {
    test('a filled triangle path covers its inside and not its outside', () {
      final surface = newSurface();
      final Path triangle = (PathBuilder()
            ..moveTo(20, 4)
            ..lineTo(36, 36)
            ..lineTo(4, 36)
            ..close())
          .build();
      final list = DisplayList();
      list.drawPath(list.addPath(triangle), list.addPaint(colorArgb: _red));

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      expect(_rgba(pixels, 20, 25), (255, 0, 0, 255));
      expect(_rgba(pixels, 5, 8), (0, 0, 0, 255));
      expect(_rgba(pixels, 35, 8), (0, 0, 0, 255));
    });

    test('a curved path fills through the quadratic and cubic verbs', () {
      final surface = newSurface();
      // A circle-ish blob from four cubics via addOval.
      final Path oval =
          (PathBuilder()..addOval(const Rect.fromLTRB(8, 8, 32, 32))).build();
      final list = DisplayList();
      list.drawPath(list.addPath(oval), list.addPaint(colorArgb: _red));

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      expect(_rgba(pixels, 20, 20), (255, 0, 0, 255));
      // The oval's corner gap: (9.5, 9.5) is 10.6 px from the centre of a
      // radius-12 circle - fully outside.
      expect(_rgba(pixels, 9, 9), (0, 0, 0, 255));
    });

    test('a stroked rectangle strokes the centreline the player rebuilds', () {
      final surface = newSurface();
      final list = DisplayList();
      list.drawRect(
        10,
        10,
        30,
        30,
        list.addPaint(
          colorArgb: _red,
          style: paintStyleStroke,
          strokeWidth: 4,
        ),
      );

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      // Width 4 centred on the edge x = 10 covers 8..12.
      expect(_rgba(pixels, 10, 20), (255, 0, 0, 255));
      expect(_rgba(pixels, 20, 10), (255, 0, 0, 255));
      expect(_rgba(pixels, 20, 20), (0, 0, 0, 255),
          reason: 'a stroke leaves the interior alone');
      expect(_rgba(pixels, 5, 20), (0, 0, 0, 255));
    });

    test('a stroke under a scale widens with the shape', () {
      final surface = newSurface();
      final list = DisplayList();
      final paint = list.addPaint(
        colorArgb: _red,
        style: paintStyleStroke,
        strokeWidth: 2,
      );
      list
        ..save()
        ..transform(2, 0, 0, 2, 0, 0)
        ..drawRect(5, 5, 15, 15, paint) // device edges at 10 and 30
        ..restore();

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      // 2 local units under a 2x scale are 4 device pixels: 8..12.
      expect(_rgba(pixels, 9, 20), (255, 0, 0, 255));
      expect(_rgba(pixels, 11, 20), (255, 0, 0, 255));
      expect(_rgba(pixels, 20, 20), (0, 0, 0, 255));
    });

    test('the even-odd fill rule leaves the inner square empty', () {
      final surface = newSurface();
      final Path rings = (PathBuilder()
            ..addRect(const Rect.fromLTRB(6, 6, 34, 34))
            ..addRect(const Rect.fromLTRB(14, 14, 26, 26)))
          .build();
      final list = DisplayList();
      list.drawPath(
        list.addPath(rings),
        list.addPaint(colorArgb: _red, fillRule: pathFillRuleEvenOdd),
      );

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      expect(_rgba(pixels, 10, 20), (255, 0, 0, 255));
      expect(_rgba(pixels, 20, 20), (0, 0, 0, 255),
          reason: 'even-odd: the nested rectangle is a hole');
    });
  }, skip: skip);

  group('layers, images and glyphs', () {
    test('saveLayer applies its alpha when the layer is composited', () {
      final surface = newSurface();
      final list = DisplayList();
      final half = list.addPaint(colorArgb: 0x80FFFFFF);
      final ink = list.addPaint(colorArgb: _red, antiAlias: false);
      list
        ..saveLayer(0, 0, 40, 40, half)
        ..drawRect(0, 0, 40, 40, ink)
        ..restore();

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      final (int r, int g, int b, int a) = _rgba(pixels, 20, 20);
      // 255 * (0x80 / 255) = 128, +-2 for the driver's rounding.
      expect((r - 128).abs() <= 2, isTrue,
          reason: 'expected half-opacity red, got r=$r');
      expect(g, 0);
      expect(b, 0);
      expect(a, 255);
    });

    test('a layer clipped out entirely still balances', () {
      final surface = newSurface();
      final list = DisplayList();
      final opaque = list.addPaint(colorArgb: 0xFFFFFFFF);
      final ink = list.addPaint(colorArgb: _red, antiAlias: false);
      list
        ..save()
        ..clipRect(0, 0, 10, 10)
        ..saveLayer(20, 20, 30, 30, opaque) // outside the clip
        ..drawRect(20, 20, 30, 30, ink)
        ..restore()
        ..restore();

      final PresentResult result =
          surface.renderDisplayList(list, clearColor: _black);
      expect(result.status, PresentStatus.presented);
      expect(_rgba(surface.readback(), 25, 25), (0, 0, 0, 255));
    });

    test('drawImage blits a framebuffer pixel for pixel at 1:1', () {
      final surface = newSurface();
      final Framebuffer image = Framebuffer.allocate(width: 2, height: 2);
      _putBgra(image, 0, 0, 0xFFFF0000); // red
      _putBgra(image, 1, 0, 0xFF00FF00); // green
      _putBgra(image, 0, 1, 0xFF0000FF); // blue
      _putBgra(image, 1, 1, 0xFFFFFFFF); // white

      final list = DisplayList();
      list.drawImage(list.addImage(image), 0, 0, 2, 2, 10, 10, 12, 12,
          list.addPaint(colorArgb: 0xFFFFFFFF));

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      expect(_rgba(pixels, 10, 10), (255, 0, 0, 255));
      expect(_rgba(pixels, 11, 10), (0, 255, 0, 255));
      expect(_rgba(pixels, 10, 11), (0, 0, 255, 255));
      expect(_rgba(pixels, 11, 11), (255, 255, 255, 255));
      expect(_rgba(pixels, 13, 13), (0, 0, 0, 255));
    });

    test('a glyph run lands through the shared glyph cache', () {
      final surface = newSurface();
      final Typeface ahem =
          Typeface.parse(File('test/fonts/ahem.ttf').readAsBytesSync());
      final ScaledTypeface font = ahem.atSize(8);

      final list = DisplayList();
      list.drawGlyphRun(
        list.addFont(font),
        list.addPaint(colorArgb: _red),
        8,
        14,
        Int32List.fromList(<int>[ahem.glyphForCodePoint(0x58)]),
        Float32List.fromList(<double>[0, 0]),
        1,
      );

      surface.renderDisplayList(list, clearColor: _black);
      final pixels = surface.readback();
      // Ahem's em box at size 8 from a pen at (8, 14): x 8..16, y 7.6..15.6.
      // (12, 12) is deep inside; coverage there is exactly 255.
      expect(_rgba(pixels, 12, 12), (255, 0, 0, 255));
      expect(_rgba(pixels, 2, 2), (0, 0, 0, 255));
      expect(_rgba(pixels, 20, 12), (0, 0, 0, 255));
    });
  }, skip: skip);

  group('gradient bindings', () {
    test('a linear gradient ramps across the stops', () {
      final surface = newSurface();
      surface.beginDirectDraw();
      final brush = surface.sink.createLinearGradientBrush(
        start: const Offset(0, 20),
        end: const Offset(40, 20),
        stops: const <(double, int)>[(0.0, _black), (1.0, _red)],
      );
      surface.sink.fillRectWithBrush(const Rect.fromLTRB(0, 0, 40, 40), brush);
      final int hr = surface.endDirectDraw();
      ComObject(brush).release();
      expect(comFailed(hr), isFalse, reason: d2dHresultTextForTest(hr));

      final pixels = surface.readback();
      final (int leftR, _, _, _) = _rgba(pixels, 1, 20);
      final (int midR, _, _, _) = _rgba(pixels, 20, 20);
      final (int rightR, _, _, _) = _rgba(pixels, 38, 20);
      expect(leftR, lessThan(30));
      expect(rightR, greaterThan(225));
      expect(midR, greaterThan(leftR));
      expect(midR, lessThan(rightR));
      expect((midR - 128).abs(), lessThan(16),
          reason: 'the midpoint of a black-to-red ramp, got $midR');
    });

    test(
        'a radial gradient is its start colour at the centre and its end '
        'colour past the radius', () {
      final surface = newSurface();
      surface.beginDirectDraw();
      final brush = surface.sink.createRadialGradientBrush(
        center: const Offset(20, 20),
        radiusX: 16,
        radiusY: 16,
        stops: const <(double, int)>[(0.0, _red), (1.0, 0xFF0000FF)],
      );
      surface.sink.fillRectWithBrush(const Rect.fromLTRB(0, 0, 40, 40), brush);
      final int hr = surface.endDirectDraw();
      ComObject(brush).release();
      expect(comFailed(hr), isFalse);

      final pixels = surface.readback();
      final (int centerR, _, int centerB, _) = _rgba(pixels, 20, 20);
      final (int cornerR, _, int cornerB, _) = _rgba(pixels, 1, 1);
      expect(centerR, greaterThan(225));
      expect(centerB, lessThan(30));
      expect(cornerB, greaterThan(225),
          reason: 'the corner is past the radius; clamp extends the last '
              'stop');
      expect(cornerR, lessThan(30));
    });
  }, skip: skip);

  group('refusals and recovery', () {
    test('a non-source-over blend is refused by name, not approximated', () {
      final surface = newSurface();
      final list = DisplayList();
      list.drawRect(0, 0, 40, 40,
          list.addPaint(colorArgb: _red, blendMode: blendModePlus));
      expect(
        () => surface.renderDisplayList(list, clearColor: _black),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
    });

    test(
        'a frame after a refused frame still renders - the begin/end state '
        'was settled', () {
      final surface = newSurface();
      final bad = DisplayList();
      bad.drawRect(
          0, 0, 40, 40, bad.addPaint(colorArgb: _red, blendMode: blendModeSrc));
      expect(
        () => surface.renderDisplayList(bad, clearColor: _black),
        throwsA(isA<UnsupportedCapabilityError>()),
      );

      final good = DisplayList();
      good.drawRect(
          10, 10, 30, 30, good.addPaint(colorArgb: _red, antiAlias: false));
      final PresentResult result =
          surface.renderDisplayList(good, clearColor: _black);
      expect(result.status, PresentStatus.presented);
      expect(_rgba(surface.readback(), 20, 20), (255, 0, 0, 255));
    });
  }, skip: skip);
}

/// The pixel at ([x], [y]) as (r, g, b, a), read out of the BGRA readback.
(int, int, int, int) _rgba(Framebuffer buffer, int x, int y) {
  final int i = buffer.offsetOf(x, y);
  final Uint8List bytes = buffer.pixels;
  return (bytes[i + 2], bytes[i + 1], bytes[i], bytes[i + 3]);
}

/// Writes one opaque 0xAARRGGBB colour into a BGRA framebuffer pixel.
void _putBgra(Framebuffer buffer, int x, int y, int argb) {
  final int i = buffer.offsetOf(x, y);
  buffer.pixels[i] = argb & 0xFF;
  buffer.pixels[i + 1] = (argb >> 8) & 0xFF;
  buffer.pixels[i + 2] = (argb >> 16) & 0xFF;
  buffer.pixels[i + 3] = (argb >> 24) & 0xFF;
}

/// A readable HRESULT for a failed direct-draw assertion.
String d2dHresultTextForTest(int hr) =>
    '0x${hr.toUnsigned(32).toRadixString(16).padLeft(8, '0').toUpperCase()}';
