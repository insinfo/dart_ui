// Laying the same text out at another width must not shape it again.
//
// Shaping (GSUB, GPOS) is the expensive half of a paragraph and does not
// depend on the width; line breaking and the ellipsis do. A column of names
// being resized re-laid every name out on every pointer event, and each one
// re-shaped the whole string - 51% of a column drag's CPU in the file
// explorer. These tests pin that the shaped runs are reused, and that reusing
// them changes nothing about the result.
import 'dart:io';

import 'package:dart_ui/src/text/paragraph.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

/// Counts the calls that reach the real shaper.
final class _CountingShaper implements Shaper {
  final Shaper inner = OpenTypeShaper();
  int calls = 0;

  @override
  GlyphRun shape(
    String text,
    ScaledTypeface font, {
    Script? script,
    String? language,
    TextDirection direction = TextDirection.leftToRight,
  }) {
    calls++;
    return inner.shape(text, font,
        script: script, language: language, direction: direction);
  }
}

void main() {
  late TextStyle style;

  setUp(() {
    style = TextStyle(
      font: Typeface.parse(File('test/fonts/DejaVuSans.ttf').readAsBytesSync())
          .atSize(13),
    );
  });

  const String name =
      'Documento de exemplo número 12 com um nome razoavelmente longo.pdf';
  const ParagraphStyle oneLine = ParagraphStyle(maxLines: 1, ellipsis: '…');

  test('a new width re-breaks lines without shaping again', () {
    final _CountingShaper shaper = _CountingShaper();
    Paragraph.layout(
      spans: <TextSpan>[TextSpan(name, style)],
      style: oneLine,
      maxWidth: 300,
      shaper: shaper,
    );
    final int first = shaper.calls;
    expect(first, greaterThan(0));
    for (double width = 120; width < 400; width += 7) {
      Paragraph.layout(
        spans: <TextSpan>[TextSpan(name, style)],
        style: oneLine,
        maxWidth: width,
        shaper: shaper,
      );
    }
    expect(shaper.calls, first,
        reason: 'the text and the ellipsis were shaped again for a new width');
  });

  test('the cached runs lay out exactly as fresh shaping does', () {
    for (double width = 80; width < 520; width += 37) {
      final Paragraph cached = Paragraph.layout(
        spans: <TextSpan>[TextSpan(name, style)],
        style: oneLine,
        maxWidth: width,
      );
      // A shaper no paragraph has used yet: a cold cache.
      final Paragraph fresh = Paragraph.layout(
        spans: <TextSpan>[TextSpan(name, style)],
        style: oneLine,
        maxWidth: width,
        shaper: OpenTypeShaper(),
      );
      expect(cached.size, fresh.size, reason: 'at width $width');
      expect(cached.lines.length, fresh.lines.length);
      for (int i = 0; i < cached.lines.length; i++) {
        expect(cached.lines[i].width, fresh.lines[i].width);
        expect(cached.lines[i].end, fresh.lines[i].end);
      }
    }
  });
}
