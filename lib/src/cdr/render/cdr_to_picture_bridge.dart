import 'dart:typed_data';
import '../../pdf/export/pdf_document_builder.dart';
import '../document/cdr_document.dart';

/// Ponte de conversão e renderização de desenhos CorelDRAW para PDF vetorial e pipelines gráficos do `dart_ui`.
class CdrToPdfConverter {
  final CdrDocument document;

  CdrToPdfConverter(this.document);

  /// Converte o documento CorelDRAW completo em um arquivo PDF (ISO 32000) em Puro Dart.
  Uint8List convertToPdf() {
    final builder = PdfDocumentBuilder(
      title: 'Conversão CorelDRAW (${document.versionName})',
      creator: 'dart_ui CDR Engine',
    );

    final recorder = builder.addPage(
      width: document.bounds.width > 0 ? document.bounds.width : 612.0,
      height: document.bounds.height > 0 ? document.bounds.height : 792.0,
    );

    // Desenha todos os caminhos vetoriais extraídos do CorelDRAW
    for (final cdrPath in document.paths) {
      final path = cdrPath.toPath();
      recorder.drawPath(
        path,
        strokeColor: 0xFF000000,
        strokeWidth: 1.5,
      );
    }

    return builder.build();
  }
}

/// Extensão ergonômica em [CdrDocument] para exportação direta.
extension CdrExportExtension on CdrDocument {
  /// Exporta o desenho CorelDRAW diretamente como um arquivo PDF em 100% Puro Dart.
  Uint8List exportToPdf() {
    return CdrToPdfConverter(this).convertToPdf();
  }
}
