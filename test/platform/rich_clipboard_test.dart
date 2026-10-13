/// HTML and images on the clipboard, as the port and the headless clipboard
/// promise them.
///
/// The per-backend tests prove each platform's transport; this file proves the
/// contract they share - one write replaces everything, an HTML copy carries
/// a plain-text alternative, null is "not there" and an exception is "could
/// not ask" - against [FakeClipboard], which is what every widget test pastes
/// from, and the helpers in `clipboard_formats.dart` that every backend uses
/// at its edge.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/platform/clipboard_formats.dart';
import 'package:test/test.dart';

void main() {
  final Uint8List png = encodePng(
    width: 2,
    height: 1,
    pixels: Uint8List.fromList(<int>[255, 0, 0, 255, 0, 0, 255, 128]),
  );

  group('FakeClipboard as a RichClipboard', () {
    late FakeClipboard clipboard;

    setUp(() => clipboard = FakeClipboard());

    test('is one, so a widget can ask for it by type', () {
      expect(clipboard, isA<RichClipboard>());
    });

    test('an image round-trips, and leaves no text behind', () async {
      await clipboard.writeText('antes');
      await clipboard.writeImage(png);

      expect(await clipboard.readImage(), png);
      expect(await clipboard.readText(), isNull);
      expect(await clipboard.readHtml(), isNull);
      expect(await clipboard.availableFormats(),
          <ClipboardFormat>{ClipboardFormat.image});
    });

    test('a pasted image is a copy, not the clipboard itself', () async {
      await clipboard.writeImage(png);
      final Uint8List pasted = (await clipboard.readImage())!;
      pasted[0] = 0;
      expect((await clipboard.readImage())![0], 137);
    });

    test('HTML round-trips with the plain text it was given', () async {
      await clipboard.writeHtml('<p>olá</p>', plainText: 'olá!');
      expect(await clipboard.readHtml(), '<p>olá</p>');
      expect(await clipboard.readText(), 'olá!');
      expect(await clipboard.availableFormats(),
          <ClipboardFormat>{ClipboardFormat.text, ClipboardFormat.html});
    });

    test('HTML without plain text gets one derived from it', () async {
      await clipboard.writeHtml('<h1>Título</h1><p>um &amp; dois</p>');
      expect(clipboard.text, 'Título\n\num & dois');
    });

    test('text replaces an image and HTML', () async {
      await clipboard.writeHtml('<b>x</b>');
      await clipboard.writeImage(png);
      await clipboard.writeText('só');
      expect(await clipboard.readImage(), isNull);
      expect(await clipboard.readHtml(), isNull);
      expect(await clipboard.availableFormats(),
          <ClipboardFormat>{ClipboardFormat.text});
    });

    test('an empty clipboard has no formats', () async {
      expect(await clipboard.availableFormats(), isEmpty);
      await clipboard.writeImage(png);
      await clipboard.clear();
      expect(await clipboard.availableFormats(), isEmpty);
    });

    test('seeding builds a clipboard holding several formats at once',
        () async {
      clipboard
        ..seedText('t')
        ..seedHtml('<i>t</i>')
        ..seedImage(png);
      expect(
          await clipboard.availableFormats(), ClipboardFormat.values.toSet());
      expect(clipboard.writes, 0);
    });

    test('a write that is not a PNG is the caller\'s error, never counted',
        () async {
      await expectLater(
          clipboard.writeImage(Uint8List.fromList(utf8.encode('GIF89a'))),
          throwsArgumentError);
      expect(clipboard.writes, 0);
      expect(clipboard.image, isNull);
    });

    test('a busy clipboard fails rich operations the way it fails text',
        () async {
      clipboard.failWith();
      for (final Future<Object?> Function() operation
          in <Future<Object?> Function()>[
        clipboard.readImage,
        clipboard.readHtml,
        clipboard.availableFormats,
        () => clipboard.writeImage(png),
        () => clipboard.writeHtml('<b>x</b>'),
      ]) {
        await expectLater(operation(), throwsA(isA<ClipboardException>()));
      }
      expect(clipboard.reads, 3);
      expect(clipboard.writes, 2);
    });

    test('a failed rich write leaves the previous contents alone', () async {
      await clipboard.writeText('guardado');
      clipboard.failWritesWith(const ClipboardException(
          operation: 'writeImage', reason: 'teste', backend: 'fake'));
      await expectLater(
          clipboard.writeImage(png), throwsA(isA<ClipboardException>()));
      expect(await clipboard.readText(), 'guardado');
    });
  });

  group('UnavailableClipboard', () {
    test('is a RichClipboard whose every operation is the named failure',
        () async {
      const UnavailableClipboard clipboard = UnavailableClipboard('sem host');
      expect(clipboard, isA<RichClipboard>());
      for (final (String name, Future<Object?> Function() operation)
          in <(String, Future<Object?> Function())>[
        ('readImage', clipboard.readImage),
        ('writeImage', () => clipboard.writeImage(png)),
        ('readHtml', clipboard.readHtml),
        ('writeHtml', () => clipboard.writeHtml('<b>x</b>')),
        ('availableFormats', clipboard.availableFormats),
      ]) {
        await expectLater(
          operation(),
          throwsA(isA<ClipboardException>()
              .having((e) => e.operation, 'operation', name)
              .having((e) => e.reason, 'reason', 'sem host')),
        );
      }
    });
  });

  group('plainTextFromHtml', () {
    test('drops the markup and keeps the words', () {
      expect(plainTextFromHtml('<b>negrito</b> e <i>itálico</i>'),
          'negrito e itálico');
    });

    test('paragraphs are separated by a blank line, <br> by a line break', () {
      expect(plainTextFromHtml('<p>um</p><p>dois<br>três</p>'),
          'um\n\ndois\ntrês');
    });

    test('source whitespace collapses; <pre> keeps it', () {
      expect(plainTextFromHtml('<div>\n   a\n   b  </div>'), 'a b');
      expect(plainTextFromHtml('<pre>a\n  b</pre>'), 'a\n  b');
    });

    test('entities are decoded, numeric and named', () {
      expect(plainTextFromHtml('a &amp; b &lt;c&gt; &#233; &#x1F30D; &nbsp;!'),
          'a & b <c> é 🌍  !');
      expect(plainTextFromHtml('&unknown; &#xD800;'), '&unknown; �');
    });

    test('script, style, head and comments are not text', () {
      expect(
        plainTextFromHtml('<html><head><title>T</title><style>p{}</style>'
            '</head><body><!-- nota --><script>x()</script>visível</body>'
            '</html>'),
        'visível',
      );
    });

    test('table cells are tab-separated, rows on their own lines', () {
      expect(
        plainTextFromHtml('<table><tr><td>a</td><td>b</td></tr>'
            '<tr><td>c</td><td>d</td></tr></table>'),
        'a\tb\nc\td',
      );
    });

    test('list items each start a line', () {
      expect(
          plainTextFromHtml('<ul><li>um</li><li>dois</li></ul>'), 'um\ndois');
    });

    test('an unterminated tag is kept as text', () {
      expect(plainTextFromHtml('a < b'), 'a < b');
    });
  });

  group('decodeClipboardHtml', () {
    Uint8List utf16(String text, {required bool little}) {
      final List<int> out = little ? <int>[0xFF, 0xFE] : <int>[0xFE, 0xFF];
      for (final int unit in text.codeUnits) {
        out.addAll(little
            ? <int>[unit & 0xFF, unit >> 8]
            : <int>[unit >> 8, unit & 0xFF]);
      }
      return Uint8List.fromList(out);
    }

    test('UTF-8 by default, a BOM stripped, a trailing NUL dropped', () {
      expect(decodeClipboardHtml(Uint8List.fromList(utf8.encode('<b>ç</b>'))),
          '<b>ç</b>');
      expect(
          decodeClipboardHtml(Uint8List.fromList(
              <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('<i>x</i>'), 0])),
          '<i>x</i>');
    });

    test('UTF-16 in either byte order, by its mark', () {
      expect(
          decodeClipboardHtml(utf16('<p>ü🌍</p>', little: true)), '<p>ü🌍</p>');
      expect(decodeClipboardHtml(utf16('<p>ü🌍</p>', little: false)),
          '<p>ü🌍</p>');
    });
  });

  group('clipboardFormatsForMimes', () {
    test('maps text spellings, any HTML spelling and image/png only', () {
      expect(
        clipboardFormatsForMimes(
          <String>['UTF8_STRING', 'text/html;charset=utf-8', 'image/jpeg'],
          textMimes: <String>['UTF8_STRING'],
        ),
        <ClipboardFormat>{ClipboardFormat.text, ClipboardFormat.html},
        reason: 'image/jpeg is not an image readImage could return',
      );
      expect(
        clipboardFormatsForMimes(<String>['image/png'],
            textMimes: const <String>[]),
        <ClipboardFormat>{ClipboardFormat.image},
      );
    });
  });

  test('isPngData sniffs the signature', () {
    expect(isPngData(png), isTrue);
    expect(isPngData(Uint8List.fromList(<int>[137, 80, 78])), isFalse);
    expect(() => requirePngData(Uint8List(0)), throwsArgumentError);
  });
}
