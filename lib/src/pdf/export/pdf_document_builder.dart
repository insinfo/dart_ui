import 'dart:convert';
import 'dart:typed_data';
import '../../text/typeface.dart';
import 'pdf_canvas_recorder.dart';
import 'pdf_embedded_font.dart';

export 'pdf_embedded_font.dart';

class _PdfPageEntry {
  final double width;
  final double height;
  final PdfCanvasRecorder recorder;

  _PdfPageEntry(this.width, this.height, this.recorder);
}

final class _PdfJpegEntry {
  const _PdfJpegEntry(
      this.name, this.bytes, this.width, this.height, this.components);
  final String name;
  final Uint8List bytes;
  final int width;
  final int height;
  final int components;
}

/// Construtor de documentos PDF em 100% Puro Dart para exportação e impressão de alta fidelidade.
class PdfDocumentBuilder {
  final String title;
  final String author;
  final String creator;
  final List<_PdfPageEntry> _pages = [];
  final List<_PdfJpegEntry> _jpegImages = [];
  final List<PdfEmbeddedFont> _fonts = [];

  PdfDocumentBuilder({
    this.title = 'Documento Dart UI',
    this.author = 'dart_ui Engine',
    this.creator = 'dart_ui PDF Exporter',
  });

  /// Adiciona uma nova página ao documento e retorna um [PdfCanvasRecorder] para desenhar nela.
  PdfCanvasRecorder addPage({double width = 612.0, double height = 792.0}) {
    final recorder = PdfCanvasRecorder(pageHeight: height);
    _pages.add(_PdfPageEntry(width, height, recorder));
    return recorder;
  }

  /// Registers JPEG bytes without decoding or recompressing them.
  /// Returns the resource name accepted by [PdfCanvasRecorder.drawImage].
  String addJpeg(Uint8List bytes, {String? name}) {
    final info = _readJpegInfo(bytes);
    final resourceName = name ?? 'Im${_jpegImages.length + 1}';
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.-]*$').hasMatch(resourceName)) {
      throw ArgumentError.value(name, 'name', 'invalid PDF resource name');
    }
    if (_jpegImages.any((image) => image.name == resourceName)) {
      throw ArgumentError.value(name, 'name', 'duplicate image resource name');
    }
    _jpegImages.add(_PdfJpegEntry(
      resourceName,
      Uint8List.fromList(bytes),
      info.$1,
      info.$2,
      info.$3,
    ));
    return resourceName;
  }

  /// Registers a TrueType face for native, selectable PDF text.
  ///
  /// The complete sfnt program is embedded. Only widths and Unicode mappings
  /// for glyphs actually painted are emitted into the PDF dictionaries.
  PdfEmbeddedFont addTrueTypeFont(Typeface typeface, {String? name}) {
    if (typeface.isCff) {
      throw ArgumentError.value(typeface, 'typeface',
          'FontFile2 only accepts TrueType glyf outlines');
    }
    final resourceName = name ?? 'F${_fonts.length + 2}';
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.-]*$').hasMatch(resourceName)) {
      throw ArgumentError.value(name, 'name', 'invalid PDF resource name');
    }
    if (resourceName == 'F1' ||
        _fonts.any((font) => font.resourceName == resourceName)) {
      throw ArgumentError.value(name, 'name', 'duplicate font resource name');
    }
    final font = PdfEmbeddedFont.internal(resourceName, typeface);
    _fonts.add(font);
    return font;
  }

  /// Compila e gera o arquivo PDF completo (ISO 32000) como um buffer de bytes [Uint8List].
  Uint8List build() {
    final body = BytesBuilder();
    final offsets = <int>[0]; // Posição 0 é o objeto nulo livre 0

    void writeString(String str) {
      body.add(utf8.encode(str));
    }

    // Cabeçalho PDF
    writeString('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n');

    var currentObjNum = 1;

    // Objeto 1: Catálogo (/Root)
    final catalogObjNum = currentObjNum++;
    // Objeto 2: Árvore de Páginas (/Pages)
    final pagesObjNum = currentObjNum++;
    // Objeto de Fonte Padrão F1 (/Helvetica)
    final fontObjNum = currentObjNum++;

    final embeddedFontObjects = <_PdfFontObjects>[
      for (var i = 0; i < _fonts.length; i++)
        _PdfFontObjects(
          type0: currentObjNum++,
          cidFont: currentObjNum++,
          descriptor: currentObjNum++,
          fontFile: currentObjNum++,
          toUnicode: currentObjNum++,
        ),
    ];

    final imageObjectNumbers = <int>[
      for (var i = 0; i < _jpegImages.length; i++) currentObjNum++,
    ];

    final pageObjNumbers = <int>[];
    final contentObjNumbers = <int>[];

    for (var i = 0; i < _pages.length; i++) {
      pageObjNumbers.add(currentObjNum++);
      contentObjNumbers.add(currentObjNum++);
    }

    // Grava Objeto 1: Catálogo
    offsets.add(body.length);
    writeString(
        '$catalogObjNum 0 obj\n<< /Type /Catalog /Pages $pagesObjNum 0 R >>\nendobj\n');

    // Grava Objeto 2: Árvore de Páginas
    offsets.add(body.length);
    final kidsList = pageObjNumbers.map((id) => '$id 0 R').join(' ');
    writeString(
        '$pagesObjNum 0 obj\n<< /Type /Pages /Kids [$kidsList] /Count ${_pages.length} >>\nendobj\n');

    // Grava Objeto de Fonte: Helvetica
    offsets.add(body.length);
    writeString(
        '$fontObjNum 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n');

    for (var i = 0; i < _fonts.length; i++) {
      final font = _fonts[i];
      final objects = embeddedFontObjects[i];
      final face = font.typeface;
      final baseName = _pdfName(face.name?.postScriptName ??
          '${face.familyName ?? 'DartUIFont'}-${face.subfamilyName ?? 'Regular'}');
      final scale = 1000 / face.unitsPerEm;
      final glyphs = font.usedGlyphs.toList()..sort();
      final widths = glyphs
          .map((glyph) => '$glyph [${(face.advanceOf(glyph) * scale).round()}]')
          .join(' ');
      final flags = 32 | (face.isItalic ? 64 : 0);
      final capHeight = face.os2?.capHeightOrNull ?? face.hhea.ascender;

      offsets.add(body.length);
      writeString('${objects.type0} 0 obj\n'
          '<< /Type /Font /Subtype /Type0 /BaseFont /$baseName '
          '/Encoding /Identity-H /DescendantFonts [${objects.cidFont} 0 R] '
          '/ToUnicode ${objects.toUnicode} 0 R >>\nendobj\n');
      offsets.add(body.length);
      writeString('${objects.cidFont} 0 obj\n'
          '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /$baseName '
          '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> '
          '/FontDescriptor ${objects.descriptor} 0 R /CIDToGIDMap /Identity '
          '/DW 1000${widths.isEmpty ? '' : ' /W [$widths]'} >>\nendobj\n');
      offsets.add(body.length);
      writeString('${objects.descriptor} 0 obj\n'
          '<< /Type /FontDescriptor /FontName /$baseName /Flags $flags '
          '/FontBBox [${(face.head.xMin * scale).round()} '
          '${(face.head.yMin * scale).round()} '
          '${(face.head.xMax * scale).round()} '
          '${(face.head.yMax * scale).round()}] '
          '/ItalicAngle ${face.post?.italicAngle ?? 0} '
          '/Ascent ${(face.hhea.ascender * scale).round()} '
          '/Descent ${(face.hhea.descender * scale).round()} '
          '/CapHeight ${(capHeight * scale).round()} /StemV 80 '
          '/FontFile2 ${objects.fontFile} 0 R >>\nendobj\n');
      offsets.add(body.length);
      writeString('${objects.fontFile} 0 obj\n'
          '<< /Length ${font.bytes.length} /Length1 ${font.bytes.length} >>\nstream\n');
      body.add(font.bytes);
      writeString('\nendstream\nendobj\n');
      final cmap = _toUnicodeCMap(font, baseName);
      final cmapBytes = ascii.encode(cmap);
      offsets.add(body.length);
      writeString('${objects.toUnicode} 0 obj\n'
          '<< /Length ${cmapBytes.length} >>\nstream\n');
      body.add(cmapBytes);
      writeString('\nendstream\nendobj\n');
    }

    for (var i = 0; i < _jpegImages.length; i++) {
      final image = _jpegImages[i];
      final objectNumber = imageObjectNumbers[i];
      final colorSpace = image.components == 1 ? 'DeviceGray' : 'DeviceRGB';
      offsets.add(body.length);
      writeString('$objectNumber 0 obj\n'
          '<< /Type /XObject /Subtype /Image '
          '/Width ${image.width} /Height ${image.height} '
          '/ColorSpace /$colorSpace /BitsPerComponent 8 '
          '/Filter /DCTDecode /Length ${image.bytes.length} >>\nstream\n');
      body.add(image.bytes);
      writeString('\nendstream\nendobj\n');
    }

    // Grava Páginas e Content Streams
    for (var i = 0; i < _pages.length; i++) {
      final page = _pages[i];
      final pageObjNum = pageObjNumbers[i];
      final contentObjNum = contentObjNumbers[i];
      final contentBytes = page.recorder.toBytes();

      // Grava Objeto Página
      offsets.add(body.length);
      writeString('$pageObjNum 0 obj\n'
          '<< /Type /Page\n'
          '   /Parent $pagesObjNum 0 R\n'
          '   /MediaBox [0 0 ${page.width} ${page.height}]\n'
          '   /Contents $contentObjNum 0 R\n'
          '   /Resources << /Font << /F1 $fontObjNum 0 R '
          '${[
        for (var j = 0; j < _fonts.length; j++)
          '/${_fonts[j].resourceName} ${embeddedFontObjects[j].type0} 0 R'
      ].join(' ')} >> '
          '${_jpegImages.isEmpty ? '' : '/XObject << ${[
              for (var j = 0; j < _jpegImages.length; j++)
                '/${_jpegImages[j].name} ${imageObjectNumbers[j]} 0 R'
            ].join(' ')} >> '}>>\n'
          '>>\n'
          'endobj\n');

      // Grava Objeto de Content Stream
      offsets.add(body.length);
      writeString('$contentObjNum 0 obj\n'
          '<< /Length ${contentBytes.length} >>\n'
          'stream\n');
      body.add(contentBytes);
      writeString('\nendstream\nendobj\n');
    }

    // Objeto Info de Metadados
    final infoObjNum = currentObjNum++;
    offsets.add(body.length);
    writeString('$infoObjNum 0 obj\n'
        '<< /Title ${_pdfUnicodeText(title)} '
        '/Author ${_pdfUnicodeText(author)} '
        '/Creator ${_pdfUnicodeText(creator)} '
        '/Producer ${_pdfUnicodeText('dart_ui PDF Engine')} >>\n'
        'endobj\n');

    // Tabela XRef
    final startXRefOffset = body.length;
    final totalObjs = currentObjNum;

    writeString('xref\n0 $totalObjs\n');
    writeString('0000000000 65535 f \n');

    for (var i = 1; i < offsets.length; i++) {
      final offsetStr = offsets[i].toString().padLeft(10, '0');
      writeString('$offsetStr 00000 n \n');
    }

    // Trailer
    writeString('trailer\n'
        '<< /Size $totalObjs /Root $catalogObjNum 0 R /Info $infoObjNum 0 R >>\n'
        'startxref\n'
        '$startXRefOffset\n'
        '%%EOF\n');

    return body.takeBytes();
  }
}

final class _PdfFontObjects {
  const _PdfFontObjects({
    required this.type0,
    required this.cidFont,
    required this.descriptor,
    required this.fontFile,
    required this.toUnicode,
  });

  final int type0;
  final int cidFont;
  final int descriptor;
  final int fontFile;
  final int toUnicode;
}

String _pdfName(String value) => value
    .replaceAll(RegExp(r'[^A-Za-z0-9_.+-]'), '-')
    .replaceAll(RegExp('-+'), '-');

String _toUnicodeCMap(PdfEmbeddedFont font, String name) {
  final glyphs = font.usedGlyphs.toList()..sort();
  final mappings = <String>[
    for (final glyph in glyphs)
      '<${glyph.toRadixString(16).padLeft(4, '0')}> '
          '<${_utf16Hex(font.unicodeForGlyph(glyph))}>'
  ];
  final body = StringBuffer();
  for (var offset = 0; offset < mappings.length; offset += 100) {
    final end = (offset + 100).clamp(0, mappings.length);
    body
      ..writeln('${end - offset} beginbfchar')
      ..writeln(mappings.sublist(offset, end).join('\n'))
      ..writeln('endbfchar');
  }
  return '/CIDInit /ProcSet findresource begin\n'
      '12 dict begin\n'
      'begincmap\n'
      '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n'
      '/CMapName /${name}ToUnicode def\n'
      '/CMapType 2 def\n'
      '1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n'
      '$body'
      'endcmap\nCMapName currentdict /CMap defineresource pop\n'
      'end\nend';
}

String _utf16Hex(int codePoint) {
  if (codePoint <= 0xffff) return codePoint.toRadixString(16).padLeft(4, '0');
  final value = codePoint - 0x10000;
  final high = 0xd800 + (value >> 10);
  final low = 0xdc00 + (value & 0x3ff);
  return '${high.toRadixString(16).padLeft(4, '0')}'
      '${low.toRadixString(16).padLeft(4, '0')}';
}

(int, int, int) _readJpegInfo(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
    throw const FormatException('image is not a JPEG stream');
  }
  var offset = 2;
  while (offset + 3 < bytes.length) {
    while (offset < bytes.length && bytes[offset] != 0xff) {
      offset++;
    }
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) break;
    final marker = bytes[offset++];
    if (marker == 0xd8 || marker == 0xd9 || marker == 0x01) continue;
    if (offset + 1 >= bytes.length) break;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) break;
    final isStartOfFrame = marker >= 0xc0 &&
        marker <= 0xcf &&
        marker != 0xc4 &&
        marker != 0xc8 &&
        marker != 0xcc;
    if (isStartOfFrame && length >= 8) {
      final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
      final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      final components = bytes[offset + 7];
      if (width <= 0 || height <= 0 || (components != 1 && components != 3)) {
        throw const FormatException('unsupported JPEG dimensions or colors');
      }
      return (width, height, components);
    }
    offset += length;
  }
  throw const FormatException('JPEG has no supported start-of-frame marker');
}

String _pdfUnicodeText(String value) {
  final bytes = <int>[0xfe, 0xff];
  for (final unit in value.codeUnits) {
    bytes
      ..add(unit >> 8)
      ..add(unit & 0xff);
  }
  return '<${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}>';
}
