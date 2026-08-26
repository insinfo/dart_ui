/// The Direct2D glyph atlas, including the three answers it gives that are
/// not "here is your slot".
///
/// `d2d_glyph_transform_test.dart` covers the happy path through the sink -
/// upright text, both draw routes, deviation 0 against the CPU. What it cannot
/// reach is what happens when the atlas runs out of room or is handed a glyph
/// that would never fit, because a 1024-texel atlas holds a page of body text
/// several times over. So those are driven here directly, against a
/// deliberately tiny atlas, plus one end-to-end case with type large enough to
/// make the real one refuse.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d2d/d2d1_library.dart';
import 'package:dart_ui/src/backends/win32/d2d/d2d_glyph_atlas.dart';
import 'package:dart_ui/src/backends/win32/d2d/d2d_targets.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/rendering/text/glyph_cache.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

import 'd2d_session.dart';

const int _clear = 0xFF000000;

void main() {
  final D2dSession session = D2dSession.open();
  final String? skip = D2dSession.platformSkip ?? session.skipReason;

  tearDownAll(session.close);

  final Typeface dejaVu =
      Typeface.parse(File('test/fonts/DejaVuSans.ttf').readAsBytesSync());

  group('the atlas answers, one by one', () {
    late D2dOffscreenSurface surface;
    late D2dGlyphAtlas atlas;
    late GlyphCache cache;

    setUp(() {
      if (skip != null) return;
      surface = session.surface(8, 8);
      addTearDown(surface.dispose);
      // 128 texels: big enough for a few 20 px glyphs, small enough that a
      // line of text fills it. The size is a constructor argument precisely
      // so this test does not have to draw five thousand glyphs to reach the
      // branch it is about.
      atlas = D2dGlyphAtlas(
        target: surface.renderTarget,
        allocator: D2d1Library.open().library!.allocator,
        backendName: 'direct2d-test',
        size: 128,
      );
      addTearDown(atlas.dispose);
      cache = GlyphCache();
    });

    test('a glyph is placed once and then found', () {
      final ScaledTypeface font = dejaVu.atSize(20);
      final int glyph = dejaVu.glyphForCodePoint(0x41); // A
      final (D2dGlyphAtlasResult first, D2dGlyphSlot? slot) =
          atlas.acquire(cache, font, 1280, glyph, 0);
      expect(first, D2dGlyphAtlasResult.placed);
      expect(slot, isNotNull);
      expect(atlas.entryCount, 1);
      expect(atlas.isDirty, isTrue,
          reason: 'texels were written; the bitmap does not have them yet');

      final (D2dGlyphAtlasResult second, D2dGlyphSlot? again) =
          atlas.acquire(cache, font, 1280, glyph, 0);
      expect(second, D2dGlyphAtlasResult.placed);
      expect(again!.x, slot!.x);
      expect(again.y, slot.y);
      expect(atlas.entryCount, 1,
          reason: 'the second ask must be a lookup, not a second slot');
    });

    test('a space is blank, and stays blank without re-rasterising', () {
      final ScaledTypeface font = dejaVu.atSize(20);
      final int space = dejaVu.glyphForCodePoint(0x20);
      for (var i = 0; i < 2; i++) {
        final (D2dGlyphAtlasResult result, D2dGlyphSlot? slot) =
            atlas.acquire(cache, font, 1280, space, 0);
        expect(result, D2dGlyphAtlasResult.blank);
        expect(slot, isNull);
      }
      expect(atlas.entryCount, 0,
          reason: 'a glyph that draws nothing must not hold a slot');
      expect(atlas.isDirty, isFalse);
    });

    test('a glyph larger than the whole atlas is refused, not retried', () {
      // The answer that must not be [D2dGlyphAtlasResult.full]: full tells the
      // caller to empty the atlas and ask again, and a glyph that cannot fit
      // an empty one would make that a loop.
      final ScaledTypeface font = dejaVu.atSize(400);
      final int glyph = dejaVu.glyphForCodePoint(0x48); // H
      final (D2dGlyphAtlasResult result, D2dGlyphSlot? slot) =
          atlas.acquire(cache, font, 400 * 64, glyph, 0);
      expect(result, D2dGlyphAtlasResult.tooLarge);
      expect(slot, isNull);
      expect(atlas.entryCount, 0);
    });

    test('a full atlas reports full, and reset makes room again', () {
      final ScaledTypeface font = dejaVu.atSize(28);
      var placed = 0;
      D2dGlyphAtlasResult result = D2dGlyphAtlasResult.placed;
      // Distinct subpixel buckets of one glyph, which is the cheapest way to
      // mint arbitrarily many distinct keys with one rasterisable shape.
      final int glyph = dejaVu.glyphForCodePoint(0x57); // W
      for (var i = 0; i < 400 && result != D2dGlyphAtlasResult.full; i++) {
        (result, _) = atlas.acquire(
            cache, font, 28 * 64 + i, glyph, i % kSubpixelBuckets);
        if (result == D2dGlyphAtlasResult.placed) placed++;
      }
      expect(result, D2dGlyphAtlasResult.full,
          reason: 'a 128 texel atlas cannot hold 400 28 px glyphs');
      expect(placed, greaterThan(0));
      final int held = atlas.entryCount;
      expect(held, placed);

      atlas.reset();
      expect(atlas.entryCount, 0);
      expect(atlas.resetCount, 1);
      final (D2dGlyphAtlasResult afterReset, D2dGlyphSlot? slot) =
          atlas.acquire(cache, font, 28 * 64, glyph, 0);
      expect(afterReset, D2dGlyphAtlasResult.placed);
      expect(slot, isNotNull);
    });
  }, skip: skip);

  test('type too large for the atlas still draws, from a bitmap of its own',
      () async {
    // The sink's other half of the same decision, end to end and against the
    // real 1024-texel atlas. 1500 px is chosen so the cap height alone exceeds
    // it: this is the case the atlas cannot serve at any packing, and the run
    // has to come out identical anyway - it is the same mask, blitted through
    // the same call the whole path used before there was an atlas.
    final ScaledTypeface font = dejaVu.atSize(1500);
    final int glyph = dejaVu.glyphForCodePoint(0x48); // H

    const int width = 1100;
    const int height = 1200;
    final DisplayList list = DisplayList();
    final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
    list.drawGlyphRun(
      list.addFont(font),
      paint,
      20,
      1150,
      Int32List.fromList(<int>[glyph]),
      Float32List(2),
      1,
    );

    final D2dOffscreenSurface surface = session.surface(width, height);
    addTearDown(surface.dispose);
    expect(surface.renderDisplayList(list, clearColor: _clear).status,
        PresentStatus.presented);

    expect(surface.sink.glyphBitmapCount, 1,
        reason: 'the oversize fallback is what must have drawn this');
    expect(surface.sink.glyphAtlasEntryCount, 0,
        reason: 'a glyph that cannot fit must not have taken a slot on the '
            'way to being refused');

    final cpu = MemoryRenderTarget(const MemorySurfaceDescriptor(
      pixelWidth: width,
      pixelHeight: height,
      format: PixelFormat.bgra8888Premultiplied,
    ));
    addTearDown(cpu.dispose);
    await cpu.renderDisplayList(list, clearColor: _clear);

    final Framebuffer d2d = surface.readback();
    var maxDeviation = 0;
    var differing = 0;
    for (var i = 0; i < d2d.pixels.length; i++) {
      final int delta = (d2d.pixels[i] - cpu.framebuffer.pixels[i]).abs();
      if (delta == 0) continue;
      differing++;
      if (delta > maxDeviation) maxDeviation = delta;
    }
    printOnFailure('max deviation $maxDeviation over $differing bytes');
    expect(_inkPixels(d2d), greaterThan(1000),
        reason: 'a 1500 px H covers most of the surface; if it drew nothing '
            'the comparison below proves nothing');
    // One level, and not zero: the mask is the very coverage `ScanlineFiller`
    // produced - Direct2D's rasteriser is not involved on either side - but
    // the *blit* is `FillOpacityMask`, and its rounding is not a documented
    // bit-exact copy. It is exact on a developer machine and off by one on the
    // AA fringe on the CI runner, whose d2d1.dll and CPU differ; nothing in
    // this repository is between the two. So the tolerance is one level, and
    // the count of bytes that may reach it is bounded as well - a fallback
    // that placed the glyph wrong, or rasterised it a second time, moves
    // whole percentages of the surface and not a hairline.
    expect(maxDeviation, lessThanOrEqualTo(1),
        reason: 'the oversize fallback disagrees with the CPU renderer by up '
            'to $maxDeviation levels over $differing bytes');
    expect(differing, lessThan(d2d.pixels.length ~/ 1000),
        reason: 'a one-level fringe is rounding; $differing bytes of '
            '${d2d.pixels.length} is a different picture');
  }, skip: skip);
}

/// Pixels that are not the opaque black clear.
int _inkPixels(Framebuffer buffer) {
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
