/// The pieces of the rich clipboard that are the same on every backend.
///
/// Every backend that implements `RichClipboard` has to answer the same three
/// small questions at its edge - is this really a PNG, what does this HTML
/// say as plain text, and which encoding did another application put these
/// HTML bytes in - and three copies of each answer would drift apart the way
/// copies always do. They live here, beside the port, because none of them
/// needs anything but the bytes: no codec, no window, no platform.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'clipboard.dart';

/// The eight bytes every PNG file starts with.
const List<int> _pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

/// Whether [bytes] begins with the PNG signature.
///
/// A sniff, not validation: the rest of the file may still be rubbish. It is
/// what `RichClipboard.writeImage` checks before it hands the bytes to another
/// application, because a caller that passed a JPEG or raw pixels made a
/// mistake the receiving application would report far less clearly.
bool isPngData(Uint8List bytes) {
  if (bytes.length < _pngSignature.length) return false;
  for (int i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return false;
  }
  return true;
}

/// Throws [ArgumentError] unless [png] starts with the PNG signature.
void requirePngData(Uint8List png) {
  if (!isPngData(png)) {
    throw ArgumentError.value(
      '${png.length} bytes',
      'png',
      'is not a PNG file (the PNG signature is missing); '
          'RichClipboard.writeImage takes encoded PNG bytes, not raw pixels',
    );
  }
}

/// The MIME type X11 and Wayland negotiate an image under.
const String clipboardPngMime = 'image/png';

/// The MIME type X11 and Wayland negotiate HTML under.
const String clipboardHtmlMime = 'text/html';

/// The portable formats a list of MIME types (Wayland offers, X11 target
/// names) can be read as.
///
/// [textMimes] is the backend's own list of text spellings, because the two
/// Linux backends accept slightly different ones (`UTF8_STRING` and `STRING`
/// are X atoms, not MIME types). Only `image/png` counts as an image: it is
/// the one encoding `readImage` asks for, and reporting an image the read
/// would then refuse is the lie `availableFormats` exists to avoid.
Set<ClipboardFormat> clipboardFormatsForMimes(
  Iterable<String> mimes, {
  required Iterable<String> textMimes,
}) {
  final Set<String> text = textMimes.toSet();
  final Set<ClipboardFormat> formats = <ClipboardFormat>{};
  for (final String mime in mimes) {
    if (text.contains(mime)) {
      formats.add(ClipboardFormat.text);
    } else if (isHtmlMime(mime)) {
      formats.add(ClipboardFormat.html);
    } else if (mime == clipboardPngMime) {
      formats.add(ClipboardFormat.image);
    }
  }
  return formats;
}

/// Whether [mime] names HTML, with or without a charset parameter.
bool isHtmlMime(String mime) {
  final String lower = mime.toLowerCase();
  return lower == clipboardHtmlMime || lower.startsWith('$clipboardHtmlMime;');
}

/// HTML bytes another application put on the clipboard, as a string.
///
/// UTF-8 unless a byte-order mark says otherwise, and the mark is not a
/// formality: Firefox has historically written `text/html` on X11 as
/// **UTF-16 with a BOM**, and decoding that as UTF-8 yields every other
/// character as a NUL. A trailing NUL, which Windows-minded writers append,
/// is dropped.
String decodeClipboardHtml(Uint8List bytes) {
  String text;
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    text = _utf16(bytes, 2, littleEndian: true);
  } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    text = _utf16(bytes, 2, littleEndian: false);
  } else if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    text = utf8.decode(Uint8List.sublistView(bytes, 3), allowMalformed: true);
  } else {
    text = utf8.decode(bytes, allowMalformed: true);
  }
  final int nul = text.indexOf('\u0000');
  return nul < 0 ? text : text.substring(0, nul);
}

String _utf16(Uint8List bytes, int start, {required bool littleEndian}) {
  final int count = (bytes.length - start) ~/ 2;
  final Uint16List units = Uint16List(count);
  for (int i = 0; i < count; i++) {
    final int a = bytes[start + i * 2];
    final int b = bytes[start + i * 2 + 1];
    units[i] = littleEndian ? a | b << 8 : a << 8 | b;
  }
  return String.fromCharCodes(units);
}

/// The plain text a reader sees in [html]: the words, the line breaks, and
/// none of the markup.
///
/// Used by `RichClipboard.writeHtml` when the caller gives no plain-text
/// alternative. Deliberately a small converter rather than an HTML parser,
/// because what it must get right is narrow: a terminal pasting the result
/// should get the paragraphs on separate lines, entities decoded, and no
/// script or style text. It does not lay out tables beyond a tab between
/// cells, number list items, or honour CSS - a caller who needs those has the
/// text already and should pass it.
String plainTextFromHtml(String html) {
  final StringBuffer out = StringBuffer();
  int preDepth = 0;
  int index = 0;
  final int length = html.length;
  // How many newlines the output currently ends with, so a block boundary can
  // ask for "a line break" or "a blank line" without stacking up one per tag.
  int trailingNewlines = 1;

  void write(String text) {
    if (text.isEmpty) return;
    out.write(text);
    int count = 0;
    for (int i = text.length - 1; i >= 0 && text[i] == '\n'; i--) {
      count++;
    }
    trailingNewlines = count == text.length ? trailingNewlines + count : count;
  }

  void breakTo(int newlines) {
    while (trailingNewlines < newlines) {
      write('\n');
    }
  }

  while (index < length) {
    final int lt = html.indexOf('<', index);
    final int textEnd = lt < 0 ? length : lt;
    if (textEnd > index) {
      String text = _decodeEntities(html.substring(index, textEnd));
      if (preDepth == 0) {
        text = text.replaceAll(_whitespaceRun, ' ');
        // Source indentation between blocks is not a space the reader sees.
        if (trailingNewlines > 0 && text.startsWith(' ')) {
          text = text.substring(1);
        }
      }
      write(text);
    }
    if (lt < 0) break;

    if (html.startsWith('<!--', lt)) {
      final int end = html.indexOf('-->', lt + 4);
      index = end < 0 ? length : end + 3;
      continue;
    }
    final int gt = html.indexOf('>', lt + 1);
    if (gt < 0) {
      // An unterminated tag is text: the source did not mean it as markup,
      // or it was truncated, and either way dropping it loses words.
      write(html.substring(lt));
      break;
    }
    final String inside = html.substring(lt + 1, gt);
    index = gt + 1;
    final Match? name = _tagName.matchAsPrefix(inside);
    if (name == null) continue; // <!DOCTYPE>, <?xml?> and other declarations.
    final bool closing = name.group(1) == '/';
    final String tag = name.group(2)!.toLowerCase();

    if (!closing && _rawTextTags.contains(tag)) {
      // Script and style bodies are not text a reader sees.
      final int close = html.toLowerCase().indexOf('</$tag', index);
      if (close < 0) break;
      final int closeEnd = html.indexOf('>', close);
      index = closeEnd < 0 ? length : closeEnd + 1;
      continue;
    }
    switch (tag) {
      case 'br':
        write('\n');
      case 'pre':
        if (closing) {
          if (preDepth > 0) preDepth--;
        } else {
          preDepth++;
        }
        breakTo(2);
      case 'td':
      case 'th':
        // Between cells, not before the first one.
        if (!closing && trailingNewlines == 0) write('\t');
      default:
        if (_paragraphTags.contains(tag)) {
          breakTo(2);
        } else if (_blockTags.contains(tag)) {
          breakTo(1);
        }
    }
  }
  return _tidyLines(out.toString());
}

final RegExp _whitespaceRun = RegExp(r'[ \t\r\n\f]+');
final RegExp _tagName = RegExp(r'(/?)\s*([A-Za-z][A-Za-z0-9-]*)');

const Set<String> _rawTextTags = <String>{
  'script',
  'style',
  'head',
  'title',
  'template',
};

/// Tags that end a paragraph: a blank line before and after, as a browser's
/// `innerText` puts one.
const Set<String> _paragraphTags = <String>{
  'blockquote',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'p',
};

/// Tags that start a new line and nothing more.
const Set<String> _blockTags = <String>{
  'address',
  'article',
  'aside',
  'dd',
  'div',
  'dl',
  'dt',
  'figcaption',
  'figure',
  'footer',
  'form',
  'header',
  'hr',
  'li',
  'main',
  'nav',
  'ol',
  'section',
  'table',
  'tr',
  'ul',
};

/// Trims the spaces the collapsing left at line ends and the newlines the
/// first and last block asked for, which belong to no line.
String _tidyLines(String text) => text
    .split('\n')
    .map((String line) => line.replaceAll(_trailingSpaces, ''))
    .join('\n')
    .replaceAll(_leadingOrTrailingNewlines, '');

final RegExp _trailingSpaces = RegExp(r' +$');
final RegExp _leadingOrTrailingNewlines = RegExp(r'^\n+|\n+$');

const Map<String, String> _namedEntities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
  'bull': '•',
  'middot': '·',
  'euro': '€',
};

final RegExp _entity = RegExp(r'&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z]+);');

String _decodeEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(_entity, (Match match) {
    final String body = match.group(1)!;
    if (body.startsWith('#')) {
      final bool hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
      final int? code = int.tryParse(
        hex ? body.substring(2) : body.substring(1),
        radix: hex ? 16 : 10,
      );
      if (code == null || code <= 0 || code > 0x10FFFF) return match.group(0)!;
      if (code >= 0xD800 && code <= 0xDFFF) return '�';
      return String.fromCharCode(code);
    }
    return _namedEntities[body] ?? match.group(0)!;
  });
}
