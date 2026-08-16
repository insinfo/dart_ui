/// The whole text stack, end to end: font bytes to pixels.
///
/// Every layer below has its own tests. What this file proves is that they are
/// *connected* — that a string shaped by the shaper reaches the rasterizer at
/// the position the shaper chose, through the display list, with nothing lost
/// or shifted at a boundary. That is the class of bug unit tests miss.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/display_list_reader.dart';
import 'package:dart_ui/src/platform/system_fonts.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/rendering/text/text_painter.dart';
import 'package:dart_ui/src/text/paragraph.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

Typeface _face(String name) =>
    Typeface.parse(File('test/fonts/$name').readAsBytesSync());

/// Renders [list] and returns the framebuffer, cleared to opaque white.
Future<Framebuffer> _render(DisplayList list, Size size) async {
  final RenderDevice device = await const CpuRendererBackend().createDevice();
  final MemoryRenderTarget target = device.createTarget(
    MemorySurfaceDescriptor(
      pixelWidth: size.width.toInt(),
      pixelHeight: size.height.toInt(),
    ),
  ) as MemoryRenderTarget;
  final result = await target.renderDisplayList(list, clearColor: 0xFFFFFFFF);
  expect(result.isSuccess, isTrue, reason: 'render failed: $result');
  return target.framebuffer;
}

/// How many pixels are not the white background.
int _inkCount(Framebuffer buffer) {
  int ink = 0;
  for (int y = 0; y < buffer.height; y++) {
    for (int x = 0; x < buffer.width; x++) {
      final int index = buffer.offsetOf(x, y);
      if (buffer.pixels[index] != 0xFF ||
          buffer.pixels[index + 1] != 0xFF ||
          buffer.pixels[index + 2] != 0xFF) {
        ink++;
      }
    }
  }
  return ink;
}

void main() {
  late Typeface roboto;
  late Typeface ahem;
  late Typeface dejaVu;

  setUp(() {
    roboto = _face('Roboto-Regular.ttf');
    ahem = _face('ahem.ttf');
    dejaVu = _face('DejaVuSans.ttf');
  });

  group('shaped text reaches the framebuffer', () {
    test('a string draws ink', () async {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      TextPainter().paint(
        list,
        'Hamburgefonstiv',
        roboto.atSize(20),
        const Offset(4, 30),
        paint,
      );

      final Framebuffer frame = await _render(list, const Size(240, 48));

      expect(_inkCount(frame), greaterThan(200));
    });

    test('Portuguese draws as much ink as its accents deserve', () async {
      // The accented string must draw strictly more than the unaccented one:
      // if accents were being dropped somewhere in the pipeline, the counts
      // would match and nothing else would notice.
      Future<int> inkOf(String text) async {
        final DisplayList list = DisplayList();
        final int paint =
            list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
        TextPainter().paint(
          list,
          text,
          roboto.atSize(24),
          const Offset(4, 34),
          paint,
        );
        return _inkCount(await _render(list, const Size(260, 48)));
      }

      expect(
          await inkOf('coracao acao'), lessThan(await inkOf('coração ação')));
    });

    test('nothing is drawn for an empty string', () async {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      TextPainter()
          .paint(list, '', roboto.atSize(20), const Offset(4, 30), paint);

      expect(list.commandCount, 0);
      expect(_inkCount(await _render(list, const Size(64, 40))), 0);
    });
  });

  group('positioning', () {
    test('Ahem lands exactly where the baseline says', () async {
      // Ahem's box runs from 0.8 em above the baseline to 0.2 em below, and
      // its advance is exactly one em - so with a baseline at y=40 and an
      // origin at x=10, a 20 px 'X' must ink [10,30) x [24,44) precisely.
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      TextPainter()
          .paint(list, 'X', ahem.atSize(20), const Offset(10, 40), paint);

      final Framebuffer frame = await _render(list, const Size(64, 64));

      bool isInk(int x, int y) {
        final int index = frame.offsetOf(x, y);
        return frame.pixels[index] < 128;
      }

      expect(isInk(10, 24), isTrue, reason: 'top-left corner of the box');
      expect(isInk(29, 43), isTrue, reason: 'bottom-right corner');
      expect(isInk(9, 30), isFalse, reason: 'one pixel left of the box');
      expect(isInk(30, 30), isFalse, reason: 'one pixel right of the box');
      expect(isInk(20, 23), isFalse, reason: 'one pixel above the box');
      expect(isInk(20, 44), isFalse, reason: 'one pixel below the box');
    });

    test('paintInBox offsets by the ascent so the top-left is the top-left',
        () async {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      TextPainter()
          .paintInBox(list, 'X', ahem.atSize(20), const Offset(10, 10), paint);

      final Framebuffer frame = await _render(list, const Size(64, 64));

      // Ahem's ascent is 0.8 em = 16 px, so the box top lands at exactly 10.
      final int index = frame.offsetOf(10, 10);
      expect(frame.pixels[index], lessThan(128));
      expect(frame.pixels[frame.offsetOf(10, 9)], greaterThan(128));
    });

    test('glyphs advance left to right in the order they were shaped',
        () async {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      TextPainter()
          .paint(list, 'XX', ahem.atSize(10), const Offset(0, 20), paint);

      final Framebuffer frame = await _render(list, const Size(40, 32));

      // Two adjacent solid boxes, so columns 0..19 are inked and 20+ are not.
      expect(frame.pixels[frame.offsetOf(5, 15)], lessThan(128));
      expect(frame.pixels[frame.offsetOf(15, 15)], lessThan(128));
      expect(frame.pixels[frame.offsetOf(25, 15)], greaterThan(128));
    });
  });

  group('the display list encoding', () {
    test('a run becomes one glyph-run command', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      TextPainter()
          .paint(list, 'hello', roboto.atSize(16), const Offset(0, 20), paint);

      int glyphRuns = 0;
      final DisplayListReader reader = DisplayListReader(list);
      while (reader.moveNext()) {
        if (reader.opcode == opDrawGlyphRun) glyphRuns++;
      }
      expect(glyphRuns, 1);
      expect(list.fontCount, 1);
    });

    test('text longer than one run splits, and the split is invisible',
        () async {
      // The opcode caps a run at kMaxGlyphsPerRun. Long text must split into
      // several, each carrying its own origin, so that the seam does not shift
      // a single glyph.
      final String long = 'X' * (kMaxGlyphsPerRun + 40);
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      final GlyphRun run = TextPainter()
          .paint(list, long, ahem.atSize(4), const Offset(0, 10), paint);

      int glyphRuns = 0;
      final DisplayListReader reader = DisplayListReader(list);
      while (reader.moveNext()) {
        if (reader.opcode == opDrawGlyphRun) glyphRuns++;
      }
      expect(glyphRuns, 2);
      expect(run.length, kMaxGlyphsPerRun + 40);

      // The whole string is one continuous band of ink: a wrong continuation
      // origin would leave a gap or an overlap at the seam.
      final Framebuffer frame = await _render(list, Size(run.width + 8, 16));
      final int seamX = (run.xOf(kMaxGlyphsPerRun) + 2).toInt();
      expect(frame.pixels[frame.offsetOf(seamX, 8)], lessThan(128));
    });

    test('two sizes of one face intern as two fonts', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      final TextPainter painter = TextPainter();

      painter.paint(list, 'a', roboto.atSize(12), const Offset(0, 20), paint);
      painter.paint(list, 'a', roboto.atSize(24), const Offset(0, 40), paint);
      painter.paint(list, 'b', roboto.atSize(12), const Offset(20, 20), paint);

      expect(list.fontCount, 2, reason: 'two sizes, one face');
    });
  });

  group('measurement agrees with drawing', () {
    test('measure accounts for kerning and ScaledTypeface.measure does not',
        () {
      // The trap this guards: reserving space with the unkerned measure and
      // drawing with the kerned one leaves text that does not fill its box,
      // and the reverse leaves text that overflows it.
      final ScaledTypeface font = dejaVu.atSize(48);
      final Size measured = TextPainter().measure('AVATAR', font);

      expect(measured.width, lessThan(font.measure('AVATAR')));
      expect(measured.height, closeTo(font.lineHeight, 1e-9));
    });

    test('the measured width is the width that gets drawn', () async {
      final ScaledTypeface font = dejaVu.atSize(32);
      const String text = 'Wave';
      final Size measured = TextPainter().measure(text, font);

      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      TextPainter().paint(list, text, font, const Offset(4, 40), paint);
      final Framebuffer frame = await _render(list, const Size(200, 56));

      // The rightmost inked column must fall inside the measured advance. It
      // is not exactly equal: the last glyph's ink stops short of its advance
      // by its right side bearing.
      int rightmost = 0;
      for (int y = 0; y < frame.height; y++) {
        for (int x = 0; x < frame.width; x++) {
          if (frame.pixels[frame.offsetOf(x, y)] < 128 && x > rightmost) {
            rightmost = x;
          }
        }
      }
      expect(rightmost, lessThanOrEqualTo((4 + measured.width).ceil()));
      expect(rightmost, greaterThan(4 + measured.width * 0.7));
    });

    test('an empty string still has a line height', () {
      final Size measured = TextPainter().measure('', roboto.atSize(16));

      expect(measured.width, 0);
      expect(measured.height, greaterThan(0));
    });
  });

  group('colour', () {
    test('text takes the colour of its paint', () async {
      Future<Framebuffer> draw(int colour) async {
        final DisplayList list = DisplayList();
        final int paint = list.addPaint(colorArgb: colour, antiAlias: false);
        TextPainter()
            .paint(list, 'X', ahem.atSize(16), const Offset(2, 20), paint);
        return _render(list, const Size(32, 32));
      }

      final Framebuffer red = await draw(0xFFFF0000);
      final Framebuffer blue = await draw(0xFF0000FF);

      final int index = red.offsetOf(8, 12);
      // BGRA in memory order: a red glyph has a full red channel and no blue.
      expect(red.pixels[index + 2], 0xFF);
      expect(red.pixels[index], 0x00);
      expect(blue.pixels[index], 0xFF);
      expect(blue.pixels[index + 2], 0x00);
    });
  });

  group('a real system font', () {
    test('the platform UI font parses and draws', () async {
      // Not a fixture: the actual font this machine's interface uses. It is
      // the only test that proves the parser survives fonts nobody curated -
      // and it skips rather than fails where none is found.
      final SystemFontFile? file = const SystemFonts().findPreferred();
      if (file == null) {
        markTestSkipped('no system font found on this machine');
        return;
      }

      final Typeface face = Typeface.parse(file.readBytes());
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      final GlyphRun run = TextPainter().paint(
        list,
        'Olá, mundo',
        face.atSize(18),
        const Offset(4, 26),
        paint,
      );

      expect(run.length, 10);
      expect(run.width, greaterThan(20));
      expect(
          _inkCount(await _render(list, const Size(200, 40))), greaterThan(50));
    });
  });

  test('the run arrays reach the encoder as typed lists', () {
    // The property that keeps text off the allocation path: what the shaper
    // produces is what drawGlyphRun takes.
    final GlyphRun run = LatinShaper().shape('abc', roboto.atSize(16));

    expect(run.glyphIds, isA<Int32List>());
    expect(run.positions, isA<Float32List>());
  });

  group('the default shaper', () {
    test('is the OpenType one, so GSUB and GPOS actually run', () {
      // The line this file exists to guard. LatinShaper applies neither table,
      // so a decomposed accent is drawn at its nominal advance - which for a
      // zero-advance combining mark is the left edge of the letter it belongs
      // to - and no ligature ever forms.
      expect(TextPainter().shaper, isA<OpenTypeShaper>());
    });

    test('a decomposed accent is positioned over its base, not at its left',
        () {
      final ScaledTypeface font = dejaVu.atSize(64);
      final GlyphRun positioned = TextPainter().shaper.shape('á', font);
      final GlyphRun unpositioned = LatinShaper().shape('á', font);

      expect(positioned.length, 2);
      expect(unpositioned.xOf(1),
          closeTo(font.advanceOf(positioned.glyphIds[0]), 1.0));
      expect(positioned.xOf(1), isNot(closeTo(unpositioned.xOf(1), 0.5)));
      expect(positioned.xOf(1), greaterThan(0.0));
    });

    test('an explicit shaper is still honoured, for both APIs', () {
      final Shaper latin = LatinShaper();
      final TextPainter painter = TextPainter(shaper: latin);
      expect(identical(painter.shaper, latin), isTrue);
      expect(identical(painter.paragraphs.shaper, latin), isTrue);
    });
  });

  group('paragraphs reach the framebuffer', () {
    test('a wrapped paragraph draws each line at its own baseline', () async {
      // Ahem at 20 px: every glyph is a 20 px box, 16 px above the baseline and
      // 4 below, so a two-line paragraph drawn with its top-left at (0, 0) inks
      // exactly [0, 40) x [0, 20) on line 0 and [0, 20) x [20, 40) on line 1.
      final TextPainter painter = TextPainter();
      final Paragraph paragraph =
          painter.layout('aa b', ahem.atSize(20), maxWidth: 45);
      expect(paragraph.lines.length, 2);
      expect(paragraph.lines[0].width, 40.0);
      expect(paragraph.lines[1].top, 20.0);

      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      painter.paintParagraph(list, paragraph, Offset.zero, paint);

      final Framebuffer frame = await _render(list, const Size(64, 64));
      bool isInk(int x, int y) => frame.pixels[frame.offsetOf(x, y)] < 128;

      expect(isInk(1, 1), isTrue, reason: 'top-left of line 0');
      expect(isInk(39, 19), isTrue, reason: 'bottom-right of line 0');
      expect(isInk(1, 21), isTrue, reason: 'top-left of line 1');
      expect(isInk(21, 21), isFalse, reason: 'line 1 is only one glyph wide');
      expect(isInk(41, 1), isFalse, reason: 'nothing past line 0');
    });

    test('the top-left offset moves the whole paragraph', () async {
      final TextPainter painter = TextPainter();
      final Paragraph paragraph = painter.layout('X', ahem.atSize(20));

      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      painter.paintParagraph(list, paragraph, const Offset(10, 10), paint);

      final Framebuffer frame = await _render(list, const Size(64, 64));
      expect(frame.pixels[frame.offsetOf(10, 10)], lessThan(128));
      expect(frame.pixels[frame.offsetOf(9, 10)], greaterThan(128));
      expect(frame.pixels[frame.offsetOf(10, 9)], greaterThan(128));
      expect(frame.pixels[frame.offsetOf(29, 29)], lessThan(128));
      expect(frame.pixels[frame.offsetOf(30, 30)], greaterThan(128));
    });

    test('alignment moves the ink, not only the metrics', () async {
      final TextPainter painter = TextPainter();
      final Paragraph paragraph = painter.layout(
        'X',
        ahem.atSize(20),
        maxWidth: 60,
        style: const ParagraphStyle(align: TextAlign.right),
      );
      expect(paragraph.lines.single.left, 40.0);

      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      painter.paintParagraph(list, paragraph, Offset.zero, paint);

      final Framebuffer frame = await _render(list, const Size(64, 32));
      expect(frame.pixels[frame.offsetOf(41, 5)], lessThan(128));
      expect(frame.pixels[frame.offsetOf(39, 5)], greaterThan(128));
    });

    test('a right-to-left run draws in visual order', () async {
      // Two Hebrew letters in Ahem, which has no Hebrew glyphs, would be two
      // identical boxes and prove nothing - so this checks the *positions* the
      // painter emitted instead: the logically first character is drawn on the
      // right.
      final TextPainter painter = TextPainter();
      final Paragraph paragraph = painter.layout('אב', dejaVu.atSize(20));
      final GlyphSpan span = paragraph.lines.single.spans.single;

      expect(span.direction, TextDirection.rightToLeft);
      expect(span.glyphs.clusters[0], 1, reason: 'rightmost glyph is offset 1');
      expect(span.glyphs.xOf(0), 0.0);
      expect(span.edgeOf(0), closeTo(span.right, 1e-9));
      expect(span.edgeOf(2), closeTo(span.left, 1e-9));
    });

    test('an empty paragraph emits no commands', () async {
      final TextPainter painter = TextPainter();
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      painter.paintParagraph(
        list,
        painter.layout('', ahem.atSize(20)),
        Offset.zero,
        paint,
      );
      expect(list.commandCount, 0);
    });

    test('drawing twice does not re-shape', () {
      // The point of laying out once: the spans hold their own copies of the
      // glyphs, so a scrolling list that redraws a line it already measured
      // pays for encoding and nothing else.
      final TextPainter painter = TextPainter();
      final Paragraph first = painter.layout('hello', roboto.atSize(16));
      final Paragraph second = painter.layout('hello', roboto.atSize(16));
      expect(identical(first, second), isTrue);
      expect(painter.paragraphs.hitCount, 1);
    });
  });

  group('paragraph measurement', () {
    test('measureParagraph reports the longest line, not the width asked for',
        () {
      final TextPainter painter = TextPainter();
      final Size size =
          painter.measureParagraph('aa bb', ahem.atSize(10), maxWidth: 35);
      expect(size.width, 20.0);
      expect(size.height, 20.0);
    });

    test('the measured box is the box the ink fits in', () async {
      final TextPainter painter = TextPainter();
      final Paragraph paragraph =
          painter.layout('aa bb', ahem.atSize(10), maxWidth: 35);
      final Size size = paragraph.size;

      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      painter.paintParagraph(list, paragraph, Offset.zero, paint);
      final Framebuffer frame = await _render(list, const Size(64, 64));

      int rightmost = -1;
      int lowest = -1;
      for (int y = 0; y < frame.height; y++) {
        for (int x = 0; x < frame.width; x++) {
          if (frame.pixels[frame.offsetOf(x, y)] < 128) {
            if (x > rightmost) rightmost = x;
            if (y > lowest) lowest = y;
          }
        }
      }
      expect(rightmost, lessThan(size.width));
      expect(lowest, lessThan(size.height));
      expect(rightmost, greaterThan(size.width - 2));
    });
  });
}
