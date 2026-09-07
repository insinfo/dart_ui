@TestOn('browser')

/// The claim this backend exists to make: the text on the page is *text*.
///
/// Every assertion here is one a canvas backend could not pass. Not "a span was
/// emitted with the right style" - a canvas emits nothing at all - but "the
/// browser's own selection API can anchor in it", "find-in-page has something
/// to find", and "the string survives a redraw with the selection intact".
///
/// Two paths are exercised and both have to keep working. A display list that
/// recorded its text - see `graphics/glyph_text.dart` - hands over the exact
/// characters, ligature or not. A list that did not is still a legal input, and
/// this backend then inverts the font's `cmap`, which cannot name a glyph a
/// substitution produced; the count of those is asserted rather than hidden,
/// because a backend that dropped them silently would produce text that reads
/// correctly and copies wrong.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/backends/web/dom/dom_scene.dart';
import 'package:dart_ui/src/backends/web/dom/dom_text.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/text/text_painter.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import 'dom_session.dart';

void main() {
  late DomTestHost host;
  late DomScene scene;
  late DomTestFont font;

  setUpAll(() async {
    font = await DomTestFont.load();
    if (font.skipReason != null) {
      // Printed once, loudly. A suite whose text tests all skipped must not be
      // mistaken for a suite whose text tests all passed.
      // ignore: avoid_print
      print('DOM text tests will skip: ${font.skipReason}');
    }
  });

  setUp(() {
    host = DomTestHost.open();
    scene = DomScene(host.element);
    DomFontRegistry.instance.resetForTesting();
  });

  tearDown(() => host.close());

  /// One line of text, drawn through the same painter every widget uses.
  ///
  /// [recordText] off by default, so every test that does not name it is still
  /// exercising the `cmap` fallback - which stays the behaviour for any list
  /// built by something that never asked for capture.
  DisplayList listWith(String text,
      {double size = 16, int color = 0xFF000000, bool recordText = false}) {
    final DisplayList list = DisplayList()..capturesGlyphText = recordText;
    final int paint = list.addPaint(colorArgb: color);
    TextPainter().paint(
      list,
      text,
      ScaledTypeface(font.typeface!, size),
      const Offset(20, 40),
      paint,
    );
    return list;
  }

  web.Element? firstSpan(web.Element root) => root.querySelector('span');

  test('a glyph run becomes a span holding the characters', () {
    if (skipIfMissing(font.skipReason)) return;

    scene.update(listWith('Hello, world'));

    final web.Element? span = firstSpan(host.element);
    expect(span, isNotNull);
    expect(span!.textContent, 'Hello, world');
    // Not a paragraph and not a heading: this backend has no way to know which
    // it is - see the semantics layer for the vocabulary that does.
    expect(span.tagName.toLowerCase(), 'span');
    final String style = span.getAttribute('style')!;
    // The private family, not the name table's. Matching by family name is how
    // a page ends up rendering in a face that merely shares a name with the one
    // the framework shaped against.
    expect(style, contains('dartui-'));
    expect(style, contains('16px'));
    expect(style, contains('color:rgb(0,0,0)'));
    // Leading and trailing spaces are part of the shaped run and would collapse
    // without this.
    expect(style, contains('white-space:pre'));
  });

  test('the text is really in the document, not just in an attribute', () {
    if (skipIfMissing(font.skipReason)) return;

    scene.update(listWith('findable'));

    // `textContent` of the whole host, which is what find-in-page and a screen
    // reader walk. A canvas backend answers the empty string here.
    expect(host.element.textContent, contains('findable'));
  });

  test('the browser can put a selection inside it', () {
    if (skipIfMissing(font.skipReason)) return;

    scene.update(listWith('selectable text'));
    final web.Element span = firstSpan(host.element)!;

    final web.Range range = web.document.createRange()
      ..selectNodeContents(span);
    final web.Selection selection = web.window.getSelection()!;
    selection
      ..removeAllRanges()
      ..addRange(range);

    expect(selection.toString(), 'selectable text');
    selection.removeAllRanges();
  });

  test('a redraw with the same string leaves the selection anchored', () {
    if (skipIfMissing(font.skipReason)) return;

    scene.update(listWith('keep me selected'));
    final web.Element span = firstSpan(host.element)!;
    final web.Selection selection = web.window.getSelection()!
      ..removeAllRanges()
      ..addRange(web.document.createRange()..selectNodeContents(span));
    expect(selection.toString(), 'keep me selected');

    // A different colour, the same characters. Assigning `textContent` would
    // destroy and recreate the text node and collapse the selection, which is
    // exactly what the cached-string compare in `_DomSlot.setText` prevents.
    scene.update(listWith('keep me selected', color: 0xFFFF0000));

    expect(scene.lastCreated, 0);
    expect(
      selection.toString(),
      'keep me selected',
      reason: 'the text node must survive a frame that only changed a style',
    );
    selection.removeAllRanges();
  });

  test('the span is positioned by its baseline, not by its top', () {
    if (skipIfMissing(font.skipReason)) return;

    // The run origin below is the baseline at y = 40. The element's top must
    // therefore be *above* it by the browser's own ascent, and its line-height
    // must be exactly ascent + descent so the half-leading is zero. Getting
    // this wrong puts every label a few pixels off its box in a way that reads
    // as a layout bug in the framework.
    scene.update(listWith('baseline', size: 20));
    final web.Element span = firstSpan(host.element)!;
    final String style = span.getAttribute('style')!;

    final RegExp top = RegExp(r'top:(-?[\d.]+)px');
    final RegExp lineHeight = RegExp(r'line-height:([\d.]+)px');
    final double topPx = double.parse(top.firstMatch(style)!.group(1)!);
    final double linePx = double.parse(lineHeight.firstMatch(style)!.group(1)!);

    expect(topPx, lessThan(40), reason: 'the top is above the baseline');
    expect(40 - topPx, greaterThan(0.5 * 20),
        reason: 'the ascent of a 20px face is more than half its size');
    expect(linePx, greaterThan(40 - topPx),
        reason: 'the line box is the ascent plus a descent below it');
  });

  test('a ligature comes back as the letters it stands for', () {
    if (skipIfMissing(font.skipReason)) return;

    // This is the test that found the bug. Roboto forms the `fi` ligature and
    // maps that glyph from U+FB01, so inverting the cmap first produced
    // `<ligature>ndable` - visually perfect and unsearchable, because Ctrl+F for
    // "find" does not match a presentation form. The fix is NFKC applied to the
    // presentation-form blocks only; see `dom_text.dart`.
    scene.update(listWith('findable office'));
    final web.Element span = firstSpan(host.element)!;

    expect(span.textContent, 'findable office');
    expect(
      span.textContent!.codeUnits.any((int u) => u >= 0xFB00 && u <= 0xFB4F),
      isFalse,
      reason: 'no presentation form may survive into the document: a user '
          'searching the page types the letters, not the ligature',
    );
    expect(scene.unresolvedGlyphs, 0);
    expect(span.getAttribute('data-dartui-unresolved'), isNull);
  });

  test('a glyph with no code point at all is counted, never dropped quietly',
      () {
    if (skipIfMissing(font.skipReason)) return;

    // Hand-built rather than shaped, because the failure being asserted is one
    // no string can reliably produce: a glyph id the font's cmap does not map
    // from anything. `0xFFFF` is past the end of any real face, which is
    // exactly the shape of a substitution output this backend cannot name.
    final DisplayList list = DisplayList();
    final int paint = list.addPaint(colorArgb: 0xFF000000);
    final int fontId = list.addFont(ScaledTypeface(font.typeface!, 16));
    list.drawGlyphRun(
      fontId,
      paint,
      0,
      20,
      Int32List.fromList(<int>[0xFFFF, 0xFFFE]),
      Float32List.fromList(<double>[0, 0, 8, 0]),
      2,
    );

    scene.update(list);

    expect(scene.unresolvedGlyphs, 2);
    expect(
      scene.refusals.keys,
      contains('glyph without a code point'),
      reason: 'and it must be in the refusal list, which is what a human reads '
          'to find out what this backend cannot do',
    );
  });

  test('recorded text is used, and the cmap is never consulted', () {
    if (skipIfMissing(font.skipReason)) return;

    scene.update(listWith('findable office', recordText: true));
    final web.Element span = firstSpan(host.element)!;

    expect(span.textContent, 'findable office');
    expect(scene.unresolvedGlyphs, 0);
    expect(scene.lastRunsFromText, 1);
    expect(scene.lastRunsFromCmap, 0);
    expect(span.getAttribute('data-dartui-text-source'), isNull,
        reason: 'the attribute marks the fallback, so its absence is the '
            'assertion that the fallback was not taken');
  });

  test('recorded text names glyphs the cmap cannot name at all', () {
    if (skipIfMissing(font.skipReason)) return;

    // The same unmappable glyph ids as the confession test below, with the
    // text recorded beside them. This is the whole point of the side table:
    // there is no glyph a substitution can produce that makes the characters
    // unrecoverable, because the characters never had to be recovered.
    final DisplayList list = DisplayList()..capturesGlyphText = true;
    final int paint = list.addPaint(colorArgb: 0xFF000000);
    final int fontId = list.addFont(ScaledTypeface(font.typeface!, 16));
    list
      ..recordGlyphText('في', 0, 2)
      ..drawGlyphRun(
        fontId,
        paint,
        0,
        20,
        Int32List.fromList(<int>[0xFFFF, 0xFFFE]),
        Float32List.fromList(<double>[0, 0, 8, 0]),
        2,
      );

    scene.update(list);

    expect(firstSpan(host.element)!.textContent, 'في');
    expect(scene.unresolvedGlyphs, 0);
    expect(scene.refusals.keys, isNot(contains('glyph without a code point')));
  });

  test('a run with no recorded text still falls back, and says so', () {
    if (skipIfMissing(font.skipReason)) return;

    scene.update(listWith('plain'));
    expect(firstSpan(host.element)!.textContent, 'plain');
    expect(scene.lastRunsFromText, 0);
    expect(scene.lastRunsFromCmap, 1);
    expect(firstSpan(host.element)!.getAttribute('data-dartui-text-source'),
        'cmap');
  });

  test('one face is registered with the browser once, however often it draws',
      () {
    if (skipIfMissing(font.skipReason)) return;

    scene
      ..update(listWith('a'))
      ..update(listWith('b'))
      ..update(listWith('c'));

    expect(DomFontRegistry.instance.registeredFaceCount, 1);
  });

  test('a face at two sizes is one browser face and two CSS font strings', () {
    if (skipIfMissing(font.skipReason)) return;

    final DisplayList list = DisplayList();
    final int paint = list.addPaint(colorArgb: 0xFF000000);
    final TextPainter painter = TextPainter();
    painter.paint(list, 'small', ScaledTypeface(font.typeface!, 12),
        const Offset(0, 20), paint);
    painter.paint(list, 'large', ScaledTypeface(font.typeface!, 32),
        const Offset(0, 80), paint);

    scene.update(list);

    // `addFont` interns a face *at a size*, so these are two font ids and one
    // file. The browser only ever needs the file once; the size lives in the
    // CSS `font` shorthand.
    expect(DomFontRegistry.instance.registeredFaceCount, 1);
    final List<web.Element> spans = <web.Element>[
      for (int i = 0; i < host.element.querySelectorAll('span').length; i++)
        host.element.querySelectorAll('span').item(i)! as web.Element,
    ];
    expect(spans, hasLength(2));
    expect(spans[0].getAttribute('style'), contains('12px'));
    expect(spans[1].getAttribute('style'), contains('32px'));
  });
}
