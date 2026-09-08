import 'dart:convert';
import 'dart:typed_data';
import 'pdf_canvas_recorder.dart';

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
          '   /Resources << /Font << /F1 $fontObjNum 0 R >> '
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
