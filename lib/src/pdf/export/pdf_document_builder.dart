import 'dart:convert';
import 'dart:typed_data';
import 'pdf_canvas_recorder.dart';

class _PdfPageEntry {
  final double width;
  final double height;
  final PdfCanvasRecorder recorder;

  _PdfPageEntry(this.width, this.height, this.recorder);
}

/// Construtor de documentos PDF em 100% Puro Dart para exportação e impressão de alta fidelidade.
class PdfDocumentBuilder {
  final String title;
  final String author;
  final String creator;
  final List<_PdfPageEntry> _pages = [];

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
          '   /Resources << /Font << /F1 $fontObjNum 0 R >> >>\n'
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
        '<< /Title ($title) /Author ($author) /Creator ($creator) /Producer (dart_ui PDF Engine) >>\n'
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
