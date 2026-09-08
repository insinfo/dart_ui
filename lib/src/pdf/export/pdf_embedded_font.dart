import 'dart:typed_data';

import '../../text/typeface.dart';

/// A TrueType font registered with [PdfDocumentBuilder].
///
/// Text drawn with this resource is encoded as two-byte glyph identifiers.
/// The builder embeds the original sfnt program and writes a `/ToUnicode`
/// CMap for every glyph used by the document, keeping the result searchable
/// and selectable without painting duplicate invisible text.
final class PdfEmbeddedFont {
  PdfEmbeddedFont.internal(this.resourceName, this.typeface)
      : bytes = Uint8List.fromList(typeface.sfnt.data.bytes);

  final String resourceName;
  final Typeface typeface;
  final Uint8List bytes;
  final Map<int, int> _unicodeByGlyph = <int, int>{};

  /// Encodes [text] as an Identity-H hexadecimal string and records its
  /// Unicode mapping for the font's `/ToUnicode` CMap.
  String encodeText(String text) {
    final buffer = StringBuffer('<');
    for (final codePoint in text.runes) {
      final glyph = typeface.glyphForCodePoint(codePoint);
      if (glyph < 0 || glyph > 0xffff) {
        throw StateError('glyph $glyph cannot be represented by Identity-H');
      }
      _unicodeByGlyph.putIfAbsent(glyph, () => codePoint);
      buffer.write(glyph.toRadixString(16).padLeft(4, '0'));
    }
    return '${buffer.toString()}>';
  }

  Iterable<int> get usedGlyphs => _unicodeByGlyph.keys;

  int unicodeForGlyph(int glyph) => _unicodeByGlyph[glyph]!;
}
