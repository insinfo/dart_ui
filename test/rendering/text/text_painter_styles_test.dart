/// Styled paragraphs reach the display list: per-span colours, backgrounds,
/// decorations and the synthesized italic.
///
/// Most of this asserts on the commands the painter emits rather than on
/// pixels, because the question is "which paint, which rectangle, in which
/// order", and the commands answer it exactly. Roboto is used where the
/// decoration geometry matters - its `post` table puts the underline 150
/// units below the baseline, 100 thick, at 2048 units per em - and Ahem where
/// only the arithmetic does.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/color.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/display_list_reader.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/rendering/text/color_glyph_cache.dart';
import 'package:dart_ui/src/rendering/text/text_painter.dart';
import 'package:dart_ui/src/text/paragraph.dart';
import 'package:dart_ui/src/text/text_decoration.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

import '../../text/color_font_fixtures.dart';

Typeface _face(String name) =>
    Typeface.parse(File('test/fonts/$name').readAsBytesSync());

const Color _red = Color(0xFFFF0000);
const Color _blue = Color(0xFF0000FF);
const Color _yellow = Color(0xFFFFFF00);

/// One command, flattened to what the assertions need.
typedef _Op = ({int opcode, int paint, List<double> rect, int glyphs});

List<_Op> _ops(DisplayList list) {
  final List<_Op> ops = <_Op>[];
  final DisplayListReader reader = DisplayListReader(list);
  while (reader.moveNext()) {
    final int opcode = reader.opcode;
    ops.add((
      opcode: opcode,
      paint: opcode == opDrawRect || opcode == opDrawGlyphRun
          ? reader.paintId
          : -1,
      rect: opcode == opDrawRect || opcode == opTransform
          ? <double>[
              for (int i = 0; i < reader.floatOperandCount; i++)
                reader.floatAt(i),
            ]
          : const <double>[],
      glyphs: opcode == opDrawGlyphRun ? reader.glyphCount : 0,
    ));
  }
  return ops;
}

Future<Framebuffer> _render(DisplayList list, Size size) async {
  final RenderDevice device = await const CpuRendererBackend().createDevice();
  final MemoryRenderTarget target = device.createTarget(
    MemorySurfaceDescriptor(
      pixelWidth: size.width.toInt(),
      pixelHeight: size.height.toInt(),
    ),
  ) as MemoryRenderTarget;
  await target.renderDisplayList(list, clearColor: 0xFFFFFFFF);
  return target.framebuffer;
}

void main() {
  late Typeface ahem;
  late Typeface roboto;

  setUpAll(() {
    ahem = _face('ahem.ttf');
    roboto = _face('Roboto-Regular.ttf');
  });

  test('an unstyled paragraph is drawn exactly as before: one paint', () {
    final TextPainter painter = TextPainter();
    final Paragraph p = painter.layoutSpans(<TextSpan>[
      TextSpan('ab', TextStyle(font: ahem.atSize(10))),
      TextSpan('cd', TextStyle(font: ahem.atSize(20))),
    ]);
    expect(p.hasPaintStyles, isFalse);
    final DisplayList list = DisplayList();
    final int paint = list.addPaint(colorArgb: 0xFF000000);
    painter.paintParagraph(list, p, Offset.zero, paint);
    final List<_Op> ops = _ops(list);
    expect(ops.map((_Op o) => o.opcode), everyElement(opDrawGlyphRun));
    expect(ops.map((_Op o) => o.paint), everyElement(paint));
  });

  test(
      'each span is drawn in its own colour; an uncoloured one in the '
      "caller's paint", () {
    final TextPainter painter = TextPainter();
    final Paragraph p = painter.layoutSpans(<TextSpan>[
      TextSpan('ab', TextStyle(font: ahem.atSize(10), color: _red)),
      TextSpan('cd', TextStyle(font: ahem.atSize(10))),
      TextSpan('ef', TextStyle(font: ahem.atSize(10), color: _blue)),
    ]);
    expect(p.hasPaintStyles, isTrue);
    final DisplayList list = DisplayList();
    final int paint = list.addPaint(colorArgb: 0xFF000000);
    painter.paintParagraph(list, p, Offset.zero, paint);

    final List<int> colours = <int>[
      for (final _Op op in _ops(list))
        if (op.opcode == opDrawGlyphRun) list.paintColor(op.paint),
    ];
    expect(colours, <int>[_red.value, 0xFF000000, _blue.value]);
  });

  test('a background is a rectangle behind the span, from ascent to descent',
      () {
    final TextPainter painter = TextPainter();
    final Paragraph p = painter.layoutSpans(<TextSpan>[
      TextSpan('ab', TextStyle(font: ahem.atSize(10))),
      TextSpan(
          'cd', TextStyle(font: ahem.atSize(10), backgroundColor: _yellow)),
      // Same colour and box: merged with the one before it.
      TextSpan('e', TextStyle(font: ahem.atSize(10), backgroundColor: _yellow)),
    ]);
    final DisplayList list = DisplayList();
    painter.paintParagraph(
        list, p, const Offset(5, 5), list.addPaint(colorArgb: 0xFF000000));
    final List<_Op> ops = _ops(list);
    final List<_Op> rects =
        ops.where((_Op o) => o.opcode == opDrawRect).toList();
    expect(rects, hasLength(1), reason: 'adjacent equal backgrounds merge');
    expect(rects.single.rect, <double>[25, 5, 55, 15]);
    expect(list.paintColor(rects.single.paint), _yellow.value);
    expect(ops.first.opcode, opDrawRect, reason: 'behind the glyphs');
  });

  group('decorations', () {
    ({double baseline, List<double> rect}) decorated(TextDecoration kind,
        {TextDecorationStyle style = TextDecorationStyle.solid}) {
      final TextPainter painter = TextPainter();
      final Paragraph p = painter.layoutSpans(<TextSpan>[
        TextSpan(
          'Hexagon',
          TextStyle(
            font: roboto.atSize(40),
            decoration: kind,
            decorationStyle: style,
          ),
        ),
      ]);
      final DisplayList list = DisplayList();
      painter.paintParagraph(
          list, p, Offset.zero, list.addPaint(colorArgb: 0xFF000000));
      final List<_Op> rects =
          _ops(list).where((_Op o) => o.opcode == opDrawRect).toList();
      expect(rects, isNotEmpty);
      return (baseline: p.lines.single.baseline, rect: rects.first.rect);
    }

    test('an underline sits just under the baseline, where post says', () {
      final ({double baseline, List<double> rect}) u =
          decorated(TextDecoration.underline);
      // Roboto: top 150/2048 em below the baseline, 100/2048 em thick -
      // 2.9 and 1.95 px at 40 px, snapped to whole pixels.
      final double top = u.rect[1];
      final double bottom = u.rect[3];
      expect(top - u.baseline, inInclusiveRange(2.0, 4.0));
      expect(bottom - top, 2.0);
      expect(u.rect[0], 0.0);
      expect(u.rect[2], greaterThan(100), reason: 'the whole word');
    });

    test('a strike-through crosses the middle of the lowercase letters', () {
      final ({double baseline, List<double> rect}) s =
          decorated(TextDecoration.lineThrough);
      final double xHeight =
          roboto.os2!.sxHeightOrNull! * roboto.atSize(40).scale;
      final double centre = (s.rect[1] + s.rect[3]) / 2;
      expect(s.baseline - centre, closeTo(xHeight / 2, 1.0));
    });

    test('an overline sits at the ascent', () {
      final ({double baseline, List<double> rect}) o =
          decorated(TextDecoration.overline);
      expect(o.rect[1], closeTo(o.baseline - roboto.atSize(40).ascent, 0.5));
    });

    test('under and over lines go under the glyphs, strike-through over', () {
      final TextPainter painter = TextPainter();
      final Paragraph p = painter.layoutSpans(<TextSpan>[
        TextSpan(
          'ab',
          TextStyle(
            font: ahem.atSize(10),
            decoration: TextDecoration.combine(<TextDecoration>[
              TextDecoration.underline,
              TextDecoration.lineThrough,
            ]),
            decorationColor: _red,
          ),
        ),
      ]);
      final DisplayList list = DisplayList();
      painter.paintParagraph(
          list, p, Offset.zero, list.addPaint(colorArgb: 0xFF000000));
      final List<int> opcodes = <int>[for (final _Op o in _ops(list)) o.opcode];
      expect(opcodes, <int>[opDrawRect, opDrawGlyphRun, opDrawRect]);
      final List<_Op> rects =
          _ops(list).where((_Op o) => o.opcode == opDrawRect).toList();
      expect(list.paintColor(rects.first.paint), _red.value);
      expect(rects.first.rect[1], greaterThan(rects.last.rect[1]),
          reason: 'the underline is below the strike-through');
    });

    test('double, dotted and dashed are drawn as themselves', () {
      int rectsFor(TextDecorationStyle style) {
        final TextPainter painter = TextPainter();
        final Paragraph p = painter.layoutSpans(<TextSpan>[
          TextSpan(
            'aaaa',
            TextStyle(
              font: ahem.atSize(10),
              decoration: TextDecoration.underline,
              decorationStyle: style,
            ),
          ),
        ]);
        final DisplayList list = DisplayList();
        painter.paintParagraph(
            list, p, Offset.zero, list.addPaint(colorArgb: 0xFF000000));
        return _ops(list).where((_Op o) => o.opcode == opDrawRect).length;
      }

      expect(rectsFor(TextDecorationStyle.solid), 1);
      expect(rectsFor(TextDecorationStyle.double), 2);
      // A 40 px line with a 1 px stroke: dots every 2 px, dashes every 7.
      expect(rectsFor(TextDecorationStyle.dotted), 20);
      expect(rectsFor(TextDecorationStyle.dashed), 6);
    });

    test('a wavy line is a stroked path', () {
      final TextPainter painter = TextPainter();
      final Paragraph p = painter.layoutSpans(<TextSpan>[
        TextSpan(
          'aaaa',
          TextStyle(
            font: ahem.atSize(10),
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.wavy,
          ),
        ),
      ]);
      final DisplayList list = DisplayList();
      painter.paintParagraph(
          list, p, Offset.zero, list.addPaint(colorArgb: 0xFF000000));
      final List<int> opcodes = <int>[for (final _Op o in _ops(list)) o.opcode];
      expect(opcodes, contains(opDrawPath));
    });

    test('the underline reaches the framebuffer under the glyphs', () async {
      final TextPainter painter = TextPainter();
      final Paragraph p = painter.layoutSpans(<TextSpan>[
        TextSpan(
          'xx',
          TextStyle(
            font: roboto.atSize(40),
            decoration: TextDecoration.underline,
          ),
        ),
      ]);
      final DisplayList list = DisplayList();
      painter.paintParagraph(list, p, Offset.zero,
          list.addPaint(colorArgb: 0xFF000000, antiAlias: false));
      final Framebuffer frame = await _render(list, const Size(80, 64));
      final int row = (p.lines.single.baseline + 3.5).floor();
      bool ink(int x, int y) => frame.pixels[frame.offsetOf(x, y)] < 128;
      // An x has no descender, so the only ink this far under the
      // baseline is the underline - and it runs the width of the text.
      expect(ink(2, row), isTrue);
      expect(ink(30, row), isTrue);
      expect(ink(2, row + 6), isFalse);
    });
  });

  test('a synthesized italic shears the glyphs about the baseline', () {
    final TextPainter painter = TextPainter();
    final Paragraph p = painter.layoutSpans(<TextSpan>[
      TextSpan('ab', TextStyle(font: ahem.atSize(10))),
      TextSpan('cd', TextStyle(font: ahem.atSize(10), syntheticItalic: true)),
    ]);
    final DisplayList list = DisplayList();
    painter.paintParagraph(
        list, p, const Offset(0, 7), list.addPaint(colorArgb: 0xFF000000));
    final List<_Op> ops = _ops(list);
    expect(<int>[
      for (final _Op o in ops) o.opcode
    ], <int>[
      opDrawGlyphRun,
      opSave,
      opTransform,
      opDrawGlyphRun,
      opRestore,
    ]);
    final List<double> m = ops[2].rect;
    final double baseline = 7 + p.lines.single.baseline;
    expect(m[2], -0.25, reason: 'leans right going up');
    expect(m[4], closeTo(0.25 * baseline, 1e-6), reason: 'about the baseline');
    // Layout is untouched: a shear moves no advance.
    expect(p.longestLine, 40.0);
  });

  test('colour emoji still draw as pictures in a styled span', () {
    final Uint8List dejaVu = fixtureFontBytes('DejaVuSans.ttf');
    final Typeface plain = Typeface.parse(dejaVu);
    final Typeface colour =
        Typeface.parse(withTables(dejaVu, <String, Uint8List>{
      'sbix': sbixTable(glyphCount: plain.glyphCount, strikes: {
        16: <int, SbixRecord>{
          plain.glyphForCodePoint(0x1F600):
              SbixRecord('png ', solidPng(16, 16, 0xFFFF0000)),
        },
      }),
    }));
    final TextPainter painter = TextPainter(colorGlyphs: ColorGlyphCache());
    final Paragraph p = painter.layoutSpans(<TextSpan>[
      TextSpan(
        'a\u{1F600}',
        TextStyle(
          font: colour.atSize(16),
          color: _blue,
          decoration: TextDecoration.underline,
          syntheticItalic: true,
        ),
      ),
    ]);
    final DisplayList list = DisplayList();
    painter.paintParagraph(
        list, p, Offset.zero, list.addPaint(colorArgb: 0xFF000000));
    final List<int> opcodes = <int>[for (final _Op o in _ops(list)) o.opcode];
    expect(opcodes, contains(opDrawImage));
    expect(opcodes, isNot(contains(opTransform)),
        reason: 'a face with pictures is not sheared');
  });
}
