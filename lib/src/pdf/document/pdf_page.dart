import 'dart:typed_data';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../format/pdf_object.dart';

/// Representação de uma página de documento PDF (ISO 32000).
class PdfPage {
  final int pageNumber;
  final PdfDict dict;
  final PdfResolver resolver;

  /// Referência indireta do dicionário original da página.
  ///
  /// Escritores incrementais (assinaturas e anotações) precisam redefinir o
  /// objeto sem reescrever o arquivo inteiro. PDFs sintéticos podem não ter
  /// uma referência, por isso o valor é anulável.
  final PdfRef? reference;

  PdfPage({
    required this.pageNumber,
    required this.dict,
    required this.resolver,
    this.reference,
  });

  /// Dimensões da caixa de corte (/MediaBox) da página.
  Rect get mediaBox {
    final array = dict.getArray('MediaBox', resolver);
    if (array != null && array.length >= 4) {
      final x1 =
          (array.getResolved(0, resolver) as PdfNumber?)?.asDouble ?? 0.0;
      final y1 =
          (array.getResolved(1, resolver) as PdfNumber?)?.asDouble ?? 0.0;
      final x2 = (array.getResolved(2, resolver) as PdfNumber?)?.asDouble ??
          612.0; // Padrão Carta (8.5 x 11 in)
      final y2 =
          (array.getResolved(3, resolver) as PdfNumber?)?.asDouble ?? 792.0;
      return Rect.fromLTRB(x1, y1, x2, y2);
    }
    return const Rect.fromLTWH(0, 0, 612, 792);
  }

  /// Caixa de corte visível (/CropBox), padrão igual a MediaBox.
  Rect get cropBox {
    final array = dict.getArray('CropBox', resolver);
    if (array != null && array.length >= 4) {
      final x1 =
          (array.getResolved(0, resolver) as PdfNumber?)?.asDouble ?? 0.0;
      final y1 =
          (array.getResolved(1, resolver) as PdfNumber?)?.asDouble ?? 0.0;
      final x2 = (array.getResolved(2, resolver) as PdfNumber?)?.asDouble ??
          mediaBox.width;
      final y2 = (array.getResolved(3, resolver) as PdfNumber?)?.asDouble ??
          mediaBox.height;
      return Rect.fromLTRB(x1, y1, x2, y2);
    }
    return mediaBox;
  }

  /// Ângulo de rotação da página em graus (0, 90, 180, 270).
  int get rotation {
    return dict.getNumber('Rotate', resolver)?.toInt() ?? 0;
  }

  /// Largura da página em pontos tipográficos (1/72 de polegada).
  double get width =>
      (rotation == 90 || rotation == 270) ? cropBox.height : cropBox.width;

  /// Altura da página em pontos tipográficos.
  double get height =>
      (rotation == 90 || rotation == 270) ? cropBox.width : cropBox.height;

  /// Tamanho da página como [Size].
  Size get size => Size(width, height);

  /// Dicionário de recursos (`/Resources`) associado à página.
  PdfDict? get resources => dict.getDict('Resources', resolver);

  /// Obtém o fluxo de comandos de conteúdo (`/Contents`) concatenado como [Uint8List].
  Uint8List getContentsBytes() {
    final contentsObj = dict.getResolved('Contents', resolver);
    if (contentsObj == null) return Uint8List(0);

    if (contentsObj is PdfStream) {
      return contentsObj.getDecodedBytes(resolver);
    }

    if (contentsObj is PdfArray) {
      final builder = BytesBuilder();
      for (var i = 0; i < contentsObj.length; i++) {
        final stream = contentsObj.getResolved(i, resolver);
        if (stream is PdfStream) {
          builder.add(stream.getDecodedBytes(resolver));
          builder.addByte(0x20); // Espaço separador
        }
      }
      return builder.takeBytes();
    }

    return Uint8List(0);
  }

  @override
  String toString() =>
      'PdfPage(page: $pageNumber, size: ${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)})';
}
