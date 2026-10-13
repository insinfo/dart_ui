/// CF_HTML and the DIB, translated in pure Dart and checked on any platform.
///
/// Windows cannot run where most of this suite does, so the part of the rich
/// Win32 clipboard most likely to be wrong - byte offsets, row order, stride
/// padding, alpha conventions - is tested here, against bytes built by hand
/// the way Windows and the applications on it lay them out. What this cannot
/// prove is that the FFI calls in `win32_clipboard.dart` move those bytes in
/// and out of a real clipboard; see that file.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_clipboard_formats.dart';
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/image/image_errors.dart';
import 'package:dart_ui/src/graphics/image/png.dart';
import 'package:dart_ui/src/graphics/image/png_encoder.dart';
import 'package:test/test.dart';

/// The header fields of a CF_HTML block, parsed independently of the decoder
/// under test.
Map<String, int> _fields(Uint8List block) {
  final Map<String, int> fields = <String, int>{};
  for (final String line in latin1.decode(block).split('\r\n')) {
    final int colon = line.indexOf(':');
    if (colon <= 0) break;
    final int? value = int.tryParse(line.substring(colon + 1));
    if (value == null) {
      if (line.startsWith('Version:') || line.startsWith('SourceURL:')) {
        continue;
      }
      break;
    }
    fields[line.substring(0, colon)] = value;
  }
  return fields;
}

String _slice(Uint8List block, int start, int end) =>
    utf8.decode(block.sublist(start, end));

void main() {
  group('CF_HTML encoding', () {
    test('the offsets are UTF-8 byte offsets, not characters', () {
      // Every character here is more than one UTF-8 byte - an encoder that
      // counted Dart string units would land mid-sequence.
      const String fragment = '<b>olá — 🌍 ação</b>';
      final Uint8List block = encodeCfHtml(fragment);
      final Map<String, int> fields = _fields(block);

      expect(fields.keys,
          containsAll(<String>['StartHTML', 'EndHTML', 'StartFragment']));
      expect(_slice(block, fields['StartFragment']!, fields['EndFragment']!),
          fragment);
      expect(fields['EndHTML'], block.length);
      expect(_slice(block, fields['StartHTML']!, fields['EndHTML']!),
          startsWith('<html>'));
      expect(latin1.decode(block.sublist(0, 12)), 'Version:0.9\r');
    });

    test('the header is fixed-width, so StartHTML is its own length', () {
      final Uint8List short = encodeCfHtml('x');
      final Uint8List long = encodeCfHtml('x' * 100000);
      expect(_fields(short)['StartHTML'], _fields(long)['StartHTML']);
      expect(utf8.decode(short.sublist(0, _fields(short)['StartHTML']!)),
          endsWith('\r\n'));
    });

    test('the fragment sits between the comment markers', () {
      final Uint8List block = encodeCfHtml('<i>x</i>');
      final String text = utf8.decode(block);
      final int start = _fields(block)['StartFragment']!;
      expect(utf8.decode(block.sublist(start - 20, start)),
          '<!--StartFragment-->');
      expect(text, contains('<i>x</i><!--EndFragment-->'));
    });

    test('a whole document keeps its head, with the markers inside the body',
        () {
      const String document = '<html><head><style>b{color:red}</style></head>'
          '<body class="c"><b>tudo</b></body></html>';
      final Uint8List block = encodeCfHtml(document);
      final Map<String, int> fields = _fields(block);
      expect(_slice(block, fields['StartFragment']!, fields['EndFragment']!),
          '<b>tudo</b>');
      expect(
          _slice(block, fields['StartHTML']!, fields['EndHTML']!),
          '<html><head><style>b{color:red}</style></head><body class="c">'
          '<!--StartFragment--><b>tudo</b><!--EndFragment--></body></html>');
    });

    test('a source URL is a header line and moves every offset', () {
      final Uint8List block =
          encodeCfHtml('<p>a</p>', sourceUrl: 'https://example.com/');
      final Map<String, int> fields = _fields(block);
      expect(latin1.decode(block), contains('SourceURL:https://example.com/'));
      expect(_slice(block, fields['StartFragment']!, fields['EndFragment']!),
          '<p>a</p>');
    });

    test('decoding what was encoded gives the fragment back', () {
      const String fragment = '<table><tr><td>ç</td></tr></table>\r\n<p>2</p>';
      expect(decodeCfHtml(encodeCfHtml(fragment)), fragment);
    });
  });

  group('CF_HTML decoding', () {
    Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

    test('reads the block a browser writes, NUL and all', () {
      // Shaped like Chromium's: Version 0.9, CRLF lines, a terminating NUL.
      final Uint8List framed = encodeCfHtml('<span>copiado</span>');
      final Uint8List withNul = Uint8List(framed.length + 1)..setAll(0, framed);
      expect(decodeCfHtml(withNul), '<span>copiado</span>');
    });

    test('reads Word\'s header, with selection fields and -1 offsets', () {
      const String body = '<html><body>\r\n<!--StartFragment--><p>Word</p>'
          '<!--EndFragment-->\r\n</body></html>';
      String pad(int value) => value.toString().padLeft(10, '0');
      String header(int html, int endHtml, int start, int end) =>
          'Version:1.0\r\n'
          'StartHTML:${pad(html)}\r\n'
          'EndHTML:${pad(endHtml)}\r\n'
          'StartFragment:${pad(start)}\r\n'
          'EndFragment:${pad(end)}\r\n'
          'StartSelection:-1\r\n'
          'EndSelection:-1\r\n';
      // Fixed-width numbers, so the header's length does not depend on them.
      final int base = header(0, 0, 0, 0).length;
      final String block = header(
            base,
            base + body.length,
            base + body.indexOf('<p>'),
            base + body.indexOf('<!--EndFragment-->'),
          ) +
          body;
      expect(decodeCfHtml(bytes(block)), '<p>Word</p>');
    });

    test('offsets counted in characters fall back to the markers', () {
      // A writer that counted UTF-16 units: with 'ã' before the fragment, the
      // byte offset is one more than the character offset, and the character
      // offset lands inside the two-byte sequence... or before the fragment.
      const String body =
          '<html><body>ã<!--StartFragment-->ção<!--EndFragment--></body></html>';
      const String headerTemplate = 'Version:0.9\r\n'
          'StartHTML:0000000097\r\n'
          'EndHTML:0000000999\r\n'
          'StartFragment:SSSSSSSSSS\r\n'
          'EndFragment:EEEEEEEEEE\r\n';
      const int base = headerTemplate.length;
      // Character offsets, wrong on purpose.
      final int start = base + body.indexOf('ção');
      final int end = base + body.indexOf('<!--EndFragment-->');
      final String header = headerTemplate
          .replaceFirst('SSSSSSSSSS', start.toString().padLeft(10, '0'))
          .replaceFirst('EEEEEEEEEE', end.toString().padLeft(10, '0'));
      expect(decodeCfHtml(bytes('$header$body')), 'ção');
    });

    test('offsets past the end fall back to the markers', () {
      const String block = 'Version:0.9\r\nStartHTML:0000000010\r\n'
          'EndHTML:0000099999\r\nStartFragment:0000090000\r\n'
          'EndFragment:0000099999\r\n'
          '<!--StartFragment-->ok<!--EndFragment-->';
      expect(decodeCfHtml(bytes(block)), 'ok');
    });

    test('no header at all is markup, returned as it is', () {
      expect(
          decodeCfHtml(bytes('<b>sem cabeçalho</b>')), '<b>sem cabeçalho</b>');
    });

    test('a header without fragment fields gives the HTML range', () {
      const String body = '<p>só html</p>';
      String header(int start, int end) => 'Version:0.9\r\n'
          'StartHTML:${start.toString().padLeft(10, '0')}\r\n'
          'EndHTML:${end.toString().padLeft(10, '0')}\r\n';
      final int base = header(0, 0).length;
      final int end = base + utf8.encode(body).length;
      expect(decodeCfHtml(bytes('${header(base, end)}$body<junk>')), body);
    });

    test('offsets alone are trusted when there are no markers', () {
      const String body = '<html><body>antes<b>meio</b>depois</body></html>';
      String header(int start, int end) => 'Version:0.9\r\n'
          'StartFragment:${start.toString().padLeft(10, '0')}\r\n'
          'EndFragment:${end.toString().padLeft(10, '0')}\r\n';
      final int base = header(0, 0).length;
      expect(
          decodeCfHtml(bytes(header(
                  base + body.indexOf('<b>'), base + body.indexOf('depois')) +
              body)),
          '<b>meio</b>');
    });

    test('offsets inside a UTF-8 sequence are not trusted', () {
      const String body = 'çç';
      String header(int start, int end) => 'Version:0.9\r\n'
          'StartFragment:${start.toString().padLeft(10, '0')}\r\n'
          'EndFragment:${end.toString().padLeft(10, '0')}\r\n';
      final int base = header(0, 0).length;
      // One byte into the first 'ç': a continuation byte.
      expect(decodeCfHtml(bytes(header(base + 1, base + 4) + body)), body);
    });
  });

  group('DIB to PNG', () {
    /// A BITMAPINFOHEADER-family header of [size] bytes.
    ByteData header(
      int size, {
      required int width,
      required int height,
      required int bitCount,
      int compression = 0,
      int colorsUsed = 0,
    }) =>
        ByteData(size)
          ..setUint32(0, size, Endian.little)
          ..setInt32(4, width, Endian.little)
          ..setInt32(8, height, Endian.little)
          ..setUint16(12, 1, Endian.little)
          ..setUint16(14, bitCount, Endian.little)
          ..setUint32(16, compression, Endian.little)
          ..setUint32(32, colorsUsed, Endian.little);

    Uint8List join(List<List<int>> parts) => Uint8List.fromList(<int>[
          for (final List<int> part in parts) ...part,
        ]);

    DecodedImage png(Uint8List bytes) {
      expect(isPng(bytes), isTrue);
      return decodePng(bytes, order: ImageChannelOrder.rgba);
    }

    test('24-bit rows are bottom-up and padded to four bytes', () {
      // 3x2: stride is 9 bytes of pixels + 3 of padding. The bottom row comes
      // first in the block.
      final Uint8List dib = join(<List<int>>[
        header(40, width: 3, height: 2, bitCount: 24).buffer.asUint8List(),
        // bottom row (y = 1): blue, green, red - stored B,G,R
        <int>[255, 0, 0, 0, 255, 0, 0, 0, 255, 0xEE, 0xEE, 0xEE],
        // top row (y = 0): white, black, grey
        <int>[255, 255, 255, 0, 0, 0, 128, 128, 128, 0xEE, 0xEE, 0xEE],
      ]);
      final DecodedImage image = png(win32DibToPng(dib));
      expect(image.width, 3);
      expect(image.height, 2);
      expect(image.argbAt(0, 0), 0xFFFFFFFF);
      expect(image.argbAt(1, 0), 0xFF000000);
      expect(image.argbAt(2, 0), 0xFF808080);
      expect(image.argbAt(0, 1), 0xFF0000FF);
      expect(image.argbAt(1, 1), 0xFF00FF00);
      expect(image.argbAt(2, 1), 0xFFFF0000);
    });

    test('a negative height is top-down', () {
      final Uint8List dib = join(<List<int>>[
        header(40, width: 1, height: -2, bitCount: 24).buffer.asUint8List(),
        <int>[0, 0, 255, 0], // y = 0: red
        <int>[255, 0, 0, 0], // y = 1: blue
      ]);
      final DecodedImage image = png(win32DibToPng(dib));
      expect(image.argbAt(0, 0), 0xFFFF0000);
      expect(image.argbAt(0, 1), 0xFF0000FF);
    });

    test('32-bit BI_RGB with every reserved byte zero is opaque', () {
      // What an application that never heard of alpha writes - and what
      // reading the zeros literally would paste as an invisible picture.
      final Uint8List dib = join(<List<int>>[
        header(40, width: 2, height: 1, bitCount: 32).buffer.asUint8List(),
        <int>[10, 20, 30, 0, 40, 50, 60, 0],
      ]);
      final DecodedImage image = png(win32DibToPng(dib));
      expect(image.argbAt(0, 0), 0xFF1E140A);
      expect(image.argbAt(1, 0), 0xFF3C3228);
    });

    test('32-bit BI_RGB that uses the fourth byte keeps it as alpha', () {
      final Uint8List dib = join(<List<int>>[
        header(40, width: 2, height: 1, bitCount: 32).buffer.asUint8List(),
        <int>[0, 0, 255, 255, 0, 0, 255, 0],
      ]);
      final DecodedImage image = png(win32DibToPng(dib));
      expect(image.argbAt(0, 0), 0xFFFF0000);
      expect(image.argbAt(1, 0) >> 24, 0, reason: 'transparent stays so');
    });

    test('a V5 header with bit-field masks carries real alpha', () {
      // CF_DIBV5 as Windows synthesises it for a 32-bit alpha bitmap: masks
      // inside the header, alpha mask at offset 52.
      final ByteData v5 =
          header(124, width: 1, height: 1, bitCount: 32, compression: 3)
            ..setUint32(40, 0x00FF0000, Endian.little)
            ..setUint32(44, 0x0000FF00, Endian.little)
            ..setUint32(48, 0x000000FF, Endian.little)
            ..setUint32(52, 0xFF000000, Endian.little);
      final Uint8List dib = join(<List<int>>[
        v5.buffer.asUint8List(),
        <int>[0x30, 0x20, 0x10, 0x80], // B G R A
      ]);
      final DecodedImage image = png(win32DibToPng(dib));
      final int argb = image.argbAt(0, 0);
      expect(argb >> 24, 0x80);
      // Premultiplied inside the decoder and undone by argbAt: allow the
      // rounding that costs at half alpha.
      expect((argb >> 16 & 0xFF) - 0x10, inInclusiveRange(-1, 1));
      expect((argb >> 8 & 0xFF) - 0x20, inInclusiveRange(-1, 1));
      expect((argb & 0xFF) - 0x30, inInclusiveRange(-1, 1));
    });

    test('BI_BITFIELDS after a plain header: masks follow it, 16-bit 5-6-5',
        () {
      final Uint8List dib = join(<List<int>>[
        header(40, width: 2, height: 1, bitCount: 16, compression: 3)
            .buffer
            .asUint8List(),
        (ByteData(12)
              ..setUint32(0, 0xF800, Endian.little)
              ..setUint32(4, 0x07E0, Endian.little)
              ..setUint32(8, 0x001F, Endian.little))
            .buffer
            .asUint8List(),
        (ByteData(4)
              ..setUint16(0, 0xF800, Endian.little) // pure red
              ..setUint16(2, 0x07E0, Endian.little)) // pure green
            .buffer
            .asUint8List(),
      ]);
      final DecodedImage image = png(win32DibToPng(dib));
      expect(image.argbAt(0, 0), 0xFFFF0000);
      expect(image.argbAt(1, 0), 0xFF00FF00);
    });

    test('16-bit BI_RGB is 5-5-5', () {
      final Uint8List dib = join(<List<int>>[
        header(40, width: 1, height: 1, bitCount: 16).buffer.asUint8List(),
        (ByteData(4)..setUint16(0, 0x7C00 | 0x001F, Endian.little))
            .buffer
            .asUint8List(),
      ]);
      expect(png(win32DibToPng(dib)).argbAt(0, 0), 0xFFFF00FF);
    });

    test('8-bit and 1-bit palettes, indices packed most significant first', () {
      final Uint8List eight = join(<List<int>>[
        header(40, width: 2, height: 1, bitCount: 8, colorsUsed: 2)
            .buffer
            .asUint8List(),
        <int>[0, 0, 255, 0, 255, 0, 0, 0], // palette: red, blue
        <int>[1, 0, 0, 0], // pixels: blue, red; padded
      ]);
      final DecodedImage image8 = png(win32DibToPng(eight));
      expect(image8.argbAt(0, 0), 0xFF0000FF);
      expect(image8.argbAt(1, 0), 0xFFFF0000);

      final Uint8List one = join(<List<int>>[
        header(40, width: 3, height: 1, bitCount: 1).buffer.asUint8List(),
        <int>[0, 0, 0, 0, 255, 255, 255, 0], // black, white
        <int>[0xA0, 0, 0, 0], // 1 0 1
      ]);
      final DecodedImage image1 = png(win32DibToPng(one));
      expect(image1.argbAt(0, 0), 0xFFFFFFFF);
      expect(image1.argbAt(1, 0), 0xFF000000);
      expect(image1.argbAt(2, 0), 0xFFFFFFFF);
    });

    test('a 4-bit palette reads both nibbles', () {
      final Uint8List dib = join(<List<int>>[
        header(40, width: 2, height: 1, bitCount: 4, colorsUsed: 3)
            .buffer
            .asUint8List(),
        <int>[0, 0, 0, 0, 0, 255, 0, 0, 255, 0, 0, 0], // black, green, blue
        <int>[0x21, 0, 0, 0],
      ]);
      final DecodedImage image = png(win32DibToPng(dib));
      expect(image.argbAt(0, 0), 0xFF0000FF);
      expect(image.argbAt(1, 0), 0xFF00FF00);
    });

    test('BI_PNG returns the PNG it carries', () {
      final Uint8List inner = encodePng(
          width: 1, height: 1, pixels: Uint8List.fromList(<int>[1, 2, 3, 4]));
      final ByteData h =
          header(40, width: 1, height: 1, bitCount: 0, compression: 5)
            ..setUint32(20, inner.length, Endian.little);
      expect(win32DibToPng(join(<List<int>>[h.buffer.asUint8List(), inner])),
          inner);
    });

    test('what it cannot read it refuses by name', () {
      Uint8List withCompression(int compression) => join(<List<int>>[
            header(40,
                    width: 1, height: 1, bitCount: 8, compression: compression)
                .buffer
                .asUint8List(),
            List<int>.filled(1024 + 4, 0),
          ]);
      expect(
          () => win32DibToPng(withCompression(1)),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('BI_RLE8'))));
      expect(() => win32DibToPng(Uint8List(10)), throwsFormatException);
      // Rows promised and not delivered.
      expect(
          () => win32DibToPng(header(40, width: 10, height: 10, bitCount: 24)
              .buffer
              .asUint8List()),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('needs'))));
      // A header claiming far more pixels than it could carry, refused
      // before anything is allocated.
      expect(
          () => win32DibToPng(
              header(40, width: 100000, height: 100000, bitCount: 24)
                  .buffer
                  .asUint8List()),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('limit'))));
    });
  });

  group('PNG to DIB', () {
    test('writes a bottom-up 32-bit BI_RGB block that reads back the same', () {
      // Opaque, so the premultiplied round trip inside the decoder is exact.
      final Uint8List rgba = Uint8List.fromList(<int>[
        255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, //
        10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255,
      ]);
      final Uint8List source = encodePng(width: 3, height: 2, pixels: rgba);
      final Uint8List dib = win32PngToDib(source);
      final ByteData data = ByteData.sublistView(dib);
      expect(data.getUint32(0, Endian.little), 40);
      expect(data.getInt32(4, Endian.little), 3);
      expect(data.getInt32(8, Endian.little), 2, reason: 'bottom-up');
      expect(data.getUint16(14, Endian.little), 32);
      expect(dib.length, 40 + 3 * 4 * 2);
      // The first stored row is the bottom one, in B,G,R,A.
      expect(dib.sublist(40, 44), <int>[30, 20, 10, 255]);

      final DecodedImage back = decodePng(win32DibToPng(dib));
      final DecodedImage original = decodePng(source);
      for (int y = 0; y < 2; y++) {
        for (int x = 0; x < 3; x++) {
          expect(back.argbAt(x, y), original.argbAt(x, y), reason: '($x,$y)');
        }
      }
    });

    test('alpha is written straight, not premultiplied', () {
      final Uint8List source = encodePng(
          width: 1,
          height: 1,
          pixels: Uint8List.fromList(<int>[200, 100, 50, 128]));
      final Uint8List dib = win32PngToDib(source);
      expect(dib[43], 128);
      expect(dib[42] - 200, inInclusiveRange(-1, 1));
      expect(dib[41] - 100, inInclusiveRange(-1, 1));
      expect(dib[40] - 50, inInclusiveRange(-1, 1));
    });

    test('bytes that are not a PNG are an ImageDecodeException', () {
      expect(() => win32PngToDib(Uint8List.fromList(<int>[1, 2, 3])),
          throwsA(isA<ImageDecodeException>()));
    });
  });
}
