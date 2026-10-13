/// The two Windows clipboard formats that need translating, translated in pure
/// Dart: `HTML Format` (CF_HTML) and the device-independent bitmap.
///
/// Neither touches the operating system. They are bytes in and bytes out, kept
/// apart from `win32_clipboard.dart` for exactly that reason: Windows cannot
/// run on the machines most of this repository is tested on, and the parts of
/// the rich clipboard most likely to be wrong - an offset counted in UTF-16
/// units where the format wants UTF-8 bytes, a bottom-up row order, a stride
/// that forgot its padding - are all here, where
/// `test/backends/win32/win32_clipboard_formats_test.dart` reaches them on any
/// platform.
///
/// ## CF_HTML
///
/// Windows has no `text/html`. The registered format `HTML Format` is UTF-8
/// with an ASCII header in front, and the header's numbers are **byte
/// offsets from the start of the data**:
///
/// ```text
/// Version:0.9
/// StartHTML:0000000105
/// EndHTML:0000000177
/// StartFragment:0000000141
/// EndFragment:0000000149
/// <html><body><!--StartFragment--><b>x</b><!--EndFragment--></body></html>
/// ```
///
/// `StartFragment`/`EndFragment` delimit what the user copied; the document
/// around it is context. A reader that wants the paste takes the fragment.
///
/// ## The DIB
///
/// `CF_DIB` and `CF_DIBV5` are a `BITMAPINFOHEADER` (or its V4/V5 extension),
/// optional colour masks, an optional palette, and rows of pixels - bottom-up
/// unless the height is negative, each padded to four bytes. Windows
/// synthesises `CF_DIB` from a `CF_BITMAP`, so a screenshot from PrintScreen
/// arrives this way, and older applications write nothing else.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../graphics/image/decoded_image.dart';
import '../../graphics/image/png.dart';
import '../../graphics/image/png_encoder.dart';

/// `CF_DIB`: a `BITMAPINFO` followed by the bits.
const int cfDib = 8;

/// `CF_DIBV5`: a `BITMAPV5HEADER` followed by the bits. The one form whose
/// alpha channel is defined rather than conventional.
const int cfDibV5 = 17;

/// The name `RegisterClipboardFormatW` takes for CF_HTML. Exactly this
/// spelling, space included: it is how every application finds the format.
const String win32HtmlFormatName = 'HTML Format';

/// The name browsers, Office and most image editors register for PNG bytes.
/// Not a standard - Windows has no PNG clipboard format of its own - but the
/// de facto one, and the only route by which an alpha channel crosses the
/// Windows clipboard reliably.
const String win32PngFormatName = 'PNG';

const String _startFragmentMarker = '<!--StartFragment-->';
const String _endFragmentMarker = '<!--EndFragment-->';

/// [html] framed as CF_HTML, UTF-8, without a terminating NUL.
///
/// A fragment is wrapped in a minimal document with the two comment markers
/// around it. A whole document - one with a `<body>` - keeps its own
/// structure, and the markers go just inside the body, so its `<head>` (and
/// the styles in it) still reaches an application that reads the context.
///
/// The offsets are written as ten zero-padded digits, which makes the header's
/// length independent of their values and lets them be computed in one pass.
Uint8List encodeCfHtml(String html, {String? sourceUrl}) {
  final String document;
  final Match? bodyOpen =
      RegExp(r'<body\b[^>]*>', caseSensitive: false).firstMatch(html);
  final int bodyClose = html.toLowerCase().lastIndexOf('</body>');
  if (bodyOpen != null && bodyClose >= bodyOpen.end) {
    document = '${html.substring(0, bodyOpen.end)}$_startFragmentMarker'
        '${html.substring(bodyOpen.end, bodyClose)}$_endFragmentMarker'
        '${html.substring(bodyClose)}';
  } else {
    document = '<html>\r\n<body>\r\n$_startFragmentMarker$html'
        '$_endFragmentMarker\r\n</body>\r\n</html>';
  }

  String header(
          int startHtml, int endHtml, int startFragment, int endFragment) =>
      'Version:0.9\r\n'
      'StartHTML:${_offset(startHtml)}\r\n'
      'EndHTML:${_offset(endHtml)}\r\n'
      'StartFragment:${_offset(startFragment)}\r\n'
      'EndFragment:${_offset(endFragment)}\r\n'
      '${sourceUrl == null ? '' : 'SourceURL:$sourceUrl\r\n'}';

  // The header is ASCII (a URL is, once it is a valid one), so its byte length
  // is its character length; computing it with zeros gives the real length.
  final int headerBytes = utf8.encode(header(0, 0, 0, 0)).length;
  final Uint8List body = Uint8List.fromList(utf8.encode(document));
  final int fragmentStart = headerBytes +
      utf8
          .encode(document.substring(
              0,
              document.indexOf(_startFragmentMarker) +
                  _startFragmentMarker.length))
          .length;
  final int fragmentEnd = headerBytes +
      utf8
          .encode(document.substring(0, document.indexOf(_endFragmentMarker)))
          .length;
  final Uint8List prefix = Uint8List.fromList(utf8.encode(header(
    headerBytes,
    headerBytes + body.length,
    fragmentStart,
    fragmentEnd,
  )));
  return Uint8List(prefix.length + body.length)
    ..setAll(0, prefix)
    ..setAll(prefix.length, body);
}

String _offset(int value) => value.toString().padLeft(10, '0');

/// The fragment a CF_HTML block marks, or the markup it carries when it marks
/// none.
///
/// Writers in the wild disagree with the specification, and this survives
/// them in this order:
///
///  * **the comment markers win over the offsets.** Every writer that puts
///    `<!--StartFragment-->` and `<!--EndFragment-->` in the markup also means
///    its offsets to point at them, and the writers that get the offsets wrong
///    - counting characters where the format counts UTF-8 bytes, so a
///    document with one accented letter before the fragment is off by one -
///    still get the markers right, because the markers are text;
///  * **offsets are used when there are no markers**, and only if they fall
///    on UTF-8 boundaries inside the data;
///  * **no header at all** - a writer that registered the name and put plain
///    markup under it - is returned as it is.
///
/// A trailing NUL, which every writer appends, is not part of the HTML.
String decodeCfHtml(Uint8List data) {
  int length = data.indexOf(0);
  if (length < 0) length = data.length;
  final Uint8List bytes = Uint8List.sublistView(data, 0, length);

  final Map<String, int> fields = <String, int>{};
  int cursor = 0;
  // Header lines are `Name:value`, ASCII, each ended by CR, LF or CRLF. The
  // first line that is not one is where the markup begins.
  while (cursor < bytes.length) {
    int end = cursor;
    while (end < bytes.length && bytes[end] != 0x0A && bytes[end] != 0x0D) {
      end++;
    }
    final String line =
        latin1.decode(Uint8List.sublistView(bytes, cursor, end));
    final Match? field = _headerField.matchAsPrefix(line);
    if (field == null) break;
    final int? value = int.tryParse(field.group(2)!.trim());
    if (value != null) fields[field.group(1)!] = value;
    cursor = end;
    while (cursor < bytes.length &&
        (bytes[cursor] == 0x0A || bytes[cursor] == 0x0D)) {
      cursor++;
    }
  }

  bool usable(int? start, int? end) =>
      start != null &&
      end != null &&
      start >= 0 &&
      start <= end &&
      end <= bytes.length &&
      _isUtf8Boundary(bytes, start) &&
      _isUtf8Boundary(bytes, end);

  String decode(int start, int end) => utf8
      .decode(Uint8List.sublistView(bytes, start, end), allowMalformed: true);

  final String text = decode(cursor, bytes.length);
  final int markerStart = text.indexOf(_startFragmentMarker);
  final int markerEnd = markerStart < 0
      ? -1
      : text.indexOf(
          _endFragmentMarker, markerStart + _startFragmentMarker.length);
  if (markerStart >= 0 && markerEnd >= 0) {
    return text.substring(markerStart + _startFragmentMarker.length, markerEnd);
  }
  final int? startFragment = fields['StartFragment'];
  final int? endFragment = fields['EndFragment'];
  if (usable(startFragment, endFragment)) {
    return decode(startFragment!, endFragment!);
  }
  final int? startHtml = fields['StartHTML'];
  final int? endHtml = fields['EndHTML'];
  if (usable(startHtml, endHtml)) return decode(startHtml!, endHtml!);
  return text;
}

final RegExp _headerField = RegExp(r'([A-Za-z]+):(.*)$');

/// Whether [offset] starts a UTF-8 sequence (or is the end of the data):
/// a continuation byte there means the offset was counted in something other
/// than bytes.
bool _isUtf8Boundary(Uint8List bytes, int offset) =>
    offset == bytes.length || (bytes[offset] & 0xC0) != 0x80;

// ---------------------------------------------------------------------------
// The device-independent bitmap
// ---------------------------------------------------------------------------

const int _biRgb = 0;
const int _biBitfields = 3;
const int _biPng = 5;
const int _biAlphaBitfields = 6;

/// The largest bitmap converted, in pixels. A clipboard is filled by another
/// process, and a header claiming 100 000 by 100 000 pixels must be refused
/// before it is allocated, not after.
const int win32MaximumClipboardPixels = 1 << 27;

/// The bitmap in a `CF_DIB` or `CF_DIBV5` block, as a PNG file.
///
/// Reads 1-, 4- and 8-bit palettes, 16-bit 5-5-5 and bit fields, 24-bit, and
/// 32-bit with or without masks; a block whose compression is `BI_PNG`
/// already holds a PNG and is returned as it is. Run-length and JPEG
/// compression are refused with a [FormatException] that names them -
/// nothing on a clipboard produces them in practice, and an implementation
/// that has never seen one is better off saying so.
///
/// Alpha follows what the header promises. A V4/V5 header with an alpha mask
/// has a real alpha channel. A plain 32-bit `BI_RGB` block's fourth byte is
/// officially "reserved": it is used when some pixel sets it, and the image is
/// treated as opaque when every pixel leaves it zero - which is what an
/// application that never heard of alpha writes, and reading those zeros as
/// "fully transparent" would paste an invisible picture.
Uint8List win32DibToPng(Uint8List dib) {
  final ByteData data = ByteData.sublistView(dib);
  if (dib.length < 40) {
    throw FormatException(
        'a DIB starts with a 40-byte BITMAPINFOHEADER; got ${dib.length} '
        'bytes');
  }
  final int headerSize = data.getUint32(0, Endian.little);
  if (headerSize < 40 || headerSize > dib.length) {
    throw FormatException(headerSize == 12
        ? 'OS/2 BITMAPCOREHEADER bitmaps are not supported'
        : 'a DIB header of $headerSize bytes is not one Windows defines');
  }
  final int width = data.getInt32(4, Endian.little);
  final int rawHeight = data.getInt32(8, Endian.little);
  final int bitCount = data.getUint16(14, Endian.little);
  final int compression = data.getUint32(16, Endian.little);
  final int sizeImage = data.getUint32(20, Endian.little);
  final int colorsUsed = data.getUint32(32, Endian.little);
  final bool topDown = rawHeight < 0;
  final int height = rawHeight.abs();

  // Masks live inside a V2+ header, and right after a plain one.
  int masksAfterHeader = 0;
  int redMask = 0;
  int greenMask = 0;
  int blueMask = 0;
  int alphaMask = 0;
  if (compression == _biBitfields || compression == _biAlphaBitfields) {
    int maskOffset = 40;
    if (headerSize == 40) {
      masksAfterHeader = compression == _biAlphaBitfields ? 16 : 12;
    }
    if (maskOffset + (compression == _biAlphaBitfields ? 16 : 12) >
        dib.length) {
      throw const FormatException('the DIB ends inside its colour masks');
    }
    redMask = data.getUint32(maskOffset, Endian.little);
    greenMask = data.getUint32(maskOffset += 4, Endian.little);
    blueMask = data.getUint32(maskOffset += 4, Endian.little);
    if (compression == _biAlphaBitfields || headerSize >= 56) {
      alphaMask = data.getUint32(maskOffset += 4, Endian.little);
    }
  } else if (headerSize >= 56) {
    // A V3+ header carries an alpha mask even for BI_RGB, and an application
    // that bothered to fill it in means it.
    alphaMask = data.getUint32(52, Endian.little);
  }

  // A bit count of zero is how BI_PNG and BI_JPEG say "the encoded image
  // decides": no palette then.
  final int paletteEntries = bitCount > 0 && bitCount <= 8
      ? (colorsUsed != 0 ? colorsUsed : 1 << bitCount)
      : 0;
  final int paletteOffset = headerSize + masksAfterHeader;
  final int bitsOffset = paletteOffset + paletteEntries * 4;

  if (compression == _biPng) {
    final int end = sizeImage == 0 ? dib.length : bitsOffset + sizeImage;
    if (end > dib.length) {
      throw const FormatException('the DIB ends inside its embedded PNG');
    }
    final Uint8List png = Uint8List.fromList(dib.sublist(bitsOffset, end));
    if (!isPng(png)) {
      throw const FormatException('a BI_PNG DIB that holds no PNG');
    }
    return png;
  }
  if (compression != _biRgb &&
      compression != _biBitfields &&
      compression != _biAlphaBitfields) {
    throw FormatException('DIB compression ${_compressionName(compression)} '
        'is not supported');
  }
  if (width <= 0 || height == 0) {
    throw FormatException('a ${width}x$rawHeight DIB has no pixels');
  }
  if (width * height > win32MaximumClipboardPixels) {
    throw FormatException('a ${width}x$height DIB exceeds the '
        '$win32MaximumClipboardPixels-pixel limit');
  }
  if (!const <int>[1, 4, 8, 16, 24, 32].contains(bitCount)) {
    throw FormatException('a $bitCount-bit DIB is not one Windows defines');
  }
  if ((compression == _biBitfields || compression == _biAlphaBitfields) &&
      bitCount != 16 &&
      bitCount != 32) {
    throw FormatException('bit-field masks on a $bitCount-bit DIB');
  }
  final int stride = (width * bitCount + 31) ~/ 32 * 4;
  if (bitsOffset + stride * height > dib.length) {
    throw FormatException('a ${width}x$height $bitCount-bit DIB needs '
        '${bitsOffset + stride * height} bytes; the block has ${dib.length}');
  }

  if (bitCount == 16 && compression == _biRgb) {
    redMask = 0x7C00;
    greenMask = 0x03E0;
    blueMask = 0x001F;
  }
  final _Channel red = _Channel(redMask);
  final _Channel green = _Channel(greenMask);
  final _Channel blue = _Channel(blueMask);
  final _Channel alpha = _Channel(alphaMask);
  final bool rgb32 = bitCount == 32 && compression == _biRgb;

  final Uint8List rgba = Uint8List(width * height * 4);
  bool anyAlpha = false;
  for (int y = 0; y < height; y++) {
    final int row = bitsOffset + (topDown ? y : height - 1 - y) * stride;
    int out = y * width * 4;
    for (int x = 0; x < width; x++, out += 4) {
      switch (bitCount) {
        case 1 || 4 || 8:
          final int bit = x * bitCount;
          final int byte = dib[row + (bit >> 3)];
          final int index =
              byte >> (8 - bitCount - (bit & 7)) & ((1 << bitCount) - 1);
          if (index >= paletteEntries) {
            throw FormatException('palette index $index past the '
                '$paletteEntries entries the DIB declares');
          }
          final int entry = paletteOffset + index * 4;
          rgba[out] = dib[entry + 2];
          rgba[out + 1] = dib[entry + 1];
          rgba[out + 2] = dib[entry];
          rgba[out + 3] = 0xFF;
        case 16:
          final int value = data.getUint16(row + x * 2, Endian.little);
          rgba[out] = red.read(value);
          rgba[out + 1] = green.read(value);
          rgba[out + 2] = blue.read(value);
          rgba[out + 3] = alpha.isPresent ? alpha.read(value) : 0xFF;
        case 24:
          final int pixel = row + x * 3;
          rgba[out] = dib[pixel + 2];
          rgba[out + 1] = dib[pixel + 1];
          rgba[out + 2] = dib[pixel];
          rgba[out + 3] = 0xFF;
        case 32:
          if (rgb32) {
            final int pixel = row + x * 4;
            rgba[out] = dib[pixel + 2];
            rgba[out + 1] = dib[pixel + 1];
            rgba[out + 2] = dib[pixel];
            final int a = dib[pixel + 3];
            rgba[out + 3] = a;
            if (a != 0) anyAlpha = true;
          } else {
            final int value = data.getUint32(row + x * 4, Endian.little);
            rgba[out] = red.read(value);
            rgba[out + 1] = green.read(value);
            rgba[out + 2] = blue.read(value);
            rgba[out + 3] = alpha.isPresent ? alpha.read(value) : 0xFF;
          }
      }
    }
  }
  if (rgb32 && !anyAlpha && alphaMask == 0) {
    for (int i = 3; i < rgba.length; i += 4) {
      rgba[i] = 0xFF;
    }
  }
  return encodePng(width: width, height: height, pixels: rgba);
}

/// [png] as a `CF_DIB` block: a 40-byte `BITMAPINFOHEADER` and 32-bit
/// bottom-up `BI_RGB` rows with **straight** alpha in the fourth byte.
///
/// Thirty-two bits rather than twenty-four so the alpha is there for the
/// applications that read the reserved byte, and straight rather than
/// premultiplied so the colours are right for the many that ignore it. The
/// PNG written beside it carries the alpha for everything modern.
///
/// Throws [ImageDecodeException] when [png] does not decode.
Uint8List win32PngToDib(Uint8List png) {
  final DecodedImage image = decodePng(png, order: ImageChannelOrder.bgra);
  final int width = image.width;
  final int height = image.height;
  final int stride = width * 4;
  final Uint8List dib = Uint8List(40 + stride * height);
  ByteData.sublistView(dib)
    ..setUint32(0, 40, Endian.little)
    ..setInt32(4, width, Endian.little)
    ..setInt32(8, height, Endian.little) // positive: bottom-up
    ..setUint16(12, 1, Endian.little) // planes
    ..setUint16(14, 32, Endian.little)
    ..setUint32(16, _biRgb, Endian.little)
    ..setUint32(20, stride * height, Endian.little)
    ..setInt32(24, 2835, Endian.little) // 72 DPI, in pixels per metre
    ..setInt32(28, 2835, Endian.little);
  final Uint8List pixels = image.pixels;
  for (int y = 0; y < height; y++) {
    final int source = y * stride;
    final int target = 40 + (height - 1 - y) * stride;
    for (int x = 0; x < stride; x += 4) {
      final int a = pixels[source + x + 3];
      dib[target + x + 3] = a;
      for (int c = 0; c < 3; c++) {
        dib[target + x + c] = _unpremultiply(pixels[source + x + c], a);
      }
    }
  }
  return dib;
}

/// Decoded pixels are premultiplied; a DIB's are not.
int _unpremultiply(int value, int alpha) {
  if (alpha == 255) return value;
  if (alpha == 0) return 0;
  final int straight = (value * 255 + (alpha >> 1)) ~/ alpha;
  return straight > 255 ? 255 : straight;
}

String _compressionName(int compression) => switch (compression) {
      1 => 'BI_RLE8',
      2 => 'BI_RLE4',
      4 => 'BI_JPEG',
      _ => '$compression',
    };

/// One colour mask: where its bits are and how to widen them to eight.
final class _Channel {
  _Channel(this.mask)
      : shift = mask == 0 ? 0 : _trailingZeros(mask),
        width = mask == 0 ? 0 : _bitCount(mask);

  final int mask;
  final int shift;
  final int width;

  bool get isPresent => mask != 0;

  int read(int value) {
    if (width == 0) return 0;
    final int raw = (value & mask) >> shift;
    if (width == 8) return raw;
    final int max = (1 << width) - 1;
    return (raw * 255 + (max >> 1)) ~/ max;
  }

  static int _trailingZeros(int value) {
    int count = 0;
    while (value & 1 == 0) {
      value >>= 1;
      count++;
    }
    return count;
  }

  static int _bitCount(int value) {
    int count = 0;
    while (value != 0) {
      count += value & 1;
      value >>= 1;
    }
    return count;
  }
}
