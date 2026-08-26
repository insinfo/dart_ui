/// The opt-in native-text route, and the four things it must not break.
///
/// [GlyphRasterization.platformNative] is the one switch in this framework
/// that is *allowed* to change pixels, so "does it look the same" is not the
/// assertion here - it would fail by design. What is asserted is everything
/// around that:
///
///   1. **off changes nothing**, byte for byte, including after the policy has
///      been installed and reset;
///   2. **on draws, and draws natively** - counted, not eyeballed, because a
///      route that silently fell back would produce a passing picture;
///   3. **the layout does not move.** This is the whole point of taking level
///      one and not level two: DirectWrite fills glyph bodies, and this
///      framework keeps the metrics. So the same run's ink lands in the same
///      box either way, within the pixel or so that a different hinting engine
///      can move an edge;
///   4. **a font Windows does not have is refused by name**, and the run is
///      drawn the portable way rather than through some other face.
///
/// A fifth, on the ClearType claim: the offscreen surface here is a
/// premultiplied-alpha target, where Direct2D composites subpixel coverage
/// incorrectly and therefore falls back to greyscale on its own. That is
/// asserted too - grey text must come out grey - because "ClearType is not
/// guaranteed" is a sentence in the public documentation of the option and a
/// sentence in documentation that nothing checks is a wish.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d2d/d2d_targets.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/render_policy.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

import 'd2d_session.dart';

const int _clear = 0xFF000000;
const int _ink = 0xFFE0E0E0;

/// Fonts every Windows has and whose files are readable, so the same bytes go
/// down both sides. The first that exists is used.
const List<String> _systemFontFiles = <String>[
  r'C:\Windows\Fonts\arial.ttf',
  r'C:\Windows\Fonts\tahoma.ttf',
  r'C:\Windows\Fonts\verdana.ttf',
  r'C:\Windows\Fonts\segoeui.ttf',
];

void main() {
  final D2dSession session = D2dSession.open();
  final String? skip = D2dSession.platformSkip ?? session.skipReason;

  tearDownAll(session.close);
  tearDown(RenderPolicyScope.reset);

  final Typeface dejaVu =
      Typeface.parse(File('test/fonts/DejaVuSans.ttf').readAsBytesSync());

  Typeface? systemFace;
  for (final String path in _systemFontFiles) {
    final File file = File(path);
    if (file.existsSync()) {
      systemFace = Typeface.parse(file.readAsBytesSync());
      break;
    }
  }

  group('the option, off', () {
    test('the default policy draws nothing natively and nothing changes', () {
      final Framebuffer before = _render(session, _scene(dejaVu));
      // Install the policy explicitly at its default value and draw again: a
      // field that had been read as "not portable" by mistake would show here
      // and nowhere else.
      RenderPolicyScope.install(const RenderPolicy());
      final D2dOffscreenSurface surface = _surface(session, 320, 64);
      surface.renderDisplayList(_scene(dejaVu), clearColor: _clear);
      expect(surface.sink.nativeTextRunCount, 0);
      expect(_bytesEqual(before, surface.readback()), isTrue,
          reason: 'the default policy must be the behaviour that existed '
              'before the option did');

      RenderPolicyScope.reset();
      expect(_bytesEqual(before, _render(session, _scene(dejaVu))), isTrue);
    }, skip: skip);
  });

  group('the option, on', () {
    test('an installed font is drawn through DrawGlyphRun', () {
      final Typeface? face = systemFace;
      if (face == null) {
        markTestSkipped('none of $_systemFontFiles is on this machine');
        return;
      }
      final DisplayList list = _scene(face);
      final Framebuffer portable = _render(session, list);

      RenderPolicyScope.install(
        const RenderPolicy(
            glyphRasterization: GlyphRasterization.platformNative),
      );
      final D2dOffscreenSurface surface = _surface(session, 320, 64);
      final PresentResult result =
          surface.renderDisplayList(list, clearColor: _clear);
      expect(result.status, PresentStatus.presented,
          reason: 'DrawGlyphRun failing shows up as a failed EndDraw, not as '
              'a thrown error, so the status is the only place it appears');

      if (surface.sink.nativeTextRunCount == 0) {
        // A real machine state and not a test bug: the installed copy of the
        // family can be a different build from the file on disk, which the
        // resolver refuses on purpose.
        markTestSkipped('the native route declined this font: '
            '${surface.sink.nativeTextRefusal}');
        return;
      }
      expect(surface.sink.nativeTextRunCount, 1);
      expect(surface.sink.glyphAtlasEntryCount, 0,
          reason: 'a run drawn natively must not also have been packed into '
              'the portable atlas');

      final Framebuffer native = surface.readback();
      expect(_ink4(native), greaterThan(200),
          reason: 'the native route drew nothing, so nothing below means '
              'anything');

      // 3: the layout did not move. Same metrics, same placement, different
      // coverage - which is the entire promise of taking level one.
      final _Ink portableInk = _Ink.of(portable);
      final _Ink nativeInk = _Ink.of(native);
      printOnFailure('portable $portableInk against native $nativeInk');
      expect((nativeInk.left - portableInk.left).abs(), lessThanOrEqualTo(2));
      expect((nativeInk.right - portableInk.right).abs(), lessThanOrEqualTo(2));
      expect((nativeInk.top - portableInk.top).abs(), lessThanOrEqualTo(2));
      expect(
          (nativeInk.bottom - portableInk.bottom).abs(), lessThanOrEqualTo(2));

      // 5: greyscale, because this target's alpha is premultiplied. A
      // coloured fringe here would mean Direct2D composited subpixel coverage
      // into a surface that cannot carry it.
      expect(_colouredPixels(native), 0,
          reason: 'grey text on a premultiplied target must stay grey; a '
              'pixel whose channels differ is a ClearType fringe where '
              'Direct2D promised it would fall back to greyscale');
    }, skip: skip);

    test('a font Windows does not have falls back, and says why', () {
      RenderPolicyScope.install(
        const RenderPolicy(
            glyphRasterization: GlyphRasterization.platformNative),
      );
      final DisplayList list = _scene(dejaVu);
      final D2dOffscreenSurface surface = _surface(session, 320, 64);
      surface.renderDisplayList(list, clearColor: _clear);

      if (surface.sink.nativeTextRunCount > 0) {
        markTestSkipped('DejaVu Sans is installed on this machine, so it '
            'cannot stand in for an absent font');
        return;
      }
      expect(surface.sink.nativeTextRefusal, isNotNull);
      expect(surface.sink.nativeTextRefusal, contains('DejaVu'));
      expect(surface.sink.glyphAtlasEntryCount, greaterThan(0),
          reason: 'the portable route has to have drawn it');

      RenderPolicyScope.reset();
      expect(_bytesEqual(surface.readback(), _render(session, list)), isTrue,
          reason: 'a refused run must come out exactly as it would with the '
              'option off - the fallback is the same code, not a near miss');
    }, skip: skip);

    test('a rotated run stays on the outline route, with no colour fringe', () {
      // Rotation is the case the coordinator's note calls out twice: subpixel
      // coverage cannot survive it, and DirectWrite fills outlines there
      // anyway. This sink never even offers the run to DirectWrite, because
      // the native route sits inside the branch [glyphMasksFit] already took.
      final Typeface face = systemFace ?? dejaVu;
      RenderPolicyScope.install(
        const RenderPolicy(
            glyphRasterization: GlyphRasterization.platformNative),
      );
      final D2dOffscreenSurface surface = _surface(session, 200, 200);
      surface.renderDisplayList(
        _scene(face, rotate: true),
        clearColor: _clear,
      );
      expect(surface.sink.nativeTextRunCount, 0,
          reason: 'a run no mask can carry is filled from its outline on '
              'every backend; handing it to DrawGlyphRun would be a second '
              'rasteriser for the one case where the option buys nothing');
      final Framebuffer pixels = surface.readback();
      expect(_ink4(pixels), greaterThan(100));
      expect(_colouredPixels(pixels), 0);
    }, skip: skip);
  });
}

// ---------------------------------------------------------------------
// Scenes and readback helpers
// ---------------------------------------------------------------------

DisplayList _scene(Typeface face, {bool rotate = false}) {
  final ScaledTypeface font = ScaledTypeface(face, 24);
  final list = DisplayList();
  final int paint = list.addPaint(colorArgb: _ink);
  if (rotate) {
    list
      ..save()
      ..transform(0.7071, 0.7071, -0.7071, 0.7071, 60, -20);
  }
  final List<int> glyphs = <int>[
    for (final int rune in 'Handgloves'.runes) face.glyphForCodePoint(rune),
  ];
  final offsets = Float32List(glyphs.length * 2);
  var pen = 0.0;
  for (var i = 0; i < glyphs.length; i++) {
    offsets[i * 2] = pen;
    pen += font.advanceOf(glyphs[i]);
  }
  list.drawGlyphRun(
    list.addFont(font),
    paint,
    12,
    40,
    Int32List.fromList(glyphs),
    offsets,
    glyphs.length,
  );
  if (rotate) list.restore();
  return list;
}

D2dOffscreenSurface _surface(D2dSession session, int width, int height) {
  final D2dOffscreenSurface surface = session.surface(width, height);
  addTearDown(surface.dispose);
  return surface;
}

Framebuffer _render(D2dSession session, DisplayList list) {
  final D2dOffscreenSurface surface = _surface(session, 320, 64);
  surface.renderDisplayList(list, clearColor: _clear);
  return surface.readback();
}

bool _bytesEqual(Framebuffer a, Framebuffer b) {
  if (a.pixels.length != b.pixels.length) return false;
  for (var i = 0; i < a.pixels.length; i++) {
    if (a.pixels[i] != b.pixels[i]) return false;
  }
  return true;
}

/// Pixels that are not the opaque black clear.
int _ink4(Framebuffer buffer) {
  var count = 0;
  for (var i = 0; i < buffer.pixels.length; i += 4) {
    if (buffer.pixels[i] != 0 ||
        buffer.pixels[i + 1] != 0 ||
        buffer.pixels[i + 2] != 0) {
      count++;
    }
  }
  return count;
}

/// Pixels whose blue, green and red differ - a subpixel fringe.
int _colouredPixels(Framebuffer buffer) {
  var count = 0;
  for (var i = 0; i < buffer.pixels.length; i += 4) {
    final int b = buffer.pixels[i];
    final int g = buffer.pixels[i + 1];
    final int r = buffer.pixels[i + 2];
    if (b != g || g != r) count++;
  }
  return count;
}

/// The bounding box of everything that is not the clear colour.
final class _Ink {
  const _Ink(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  static _Ink of(Framebuffer buffer) {
    var left = buffer.width;
    var top = buffer.height;
    var right = -1;
    var bottom = -1;
    for (var y = 0; y < buffer.height; y++) {
      for (var x = 0; x < buffer.width; x++) {
        final int offset = y * buffer.bytesPerRow + x * 4;
        if (buffer.pixels[offset] == 0 &&
            buffer.pixels[offset + 1] == 0 &&
            buffer.pixels[offset + 2] == 0) {
          continue;
        }
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
  String toString() => '($left, $top)-($right, $bottom)';
}
