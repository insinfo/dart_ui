import 'dart:typed_data';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../format/pdf_limits.dart';
import '../format/pdf_object.dart';

final class PdfPageContentIssue {
  const PdfPageContentIssue(this.streamIndex, this.error);
  final int streamIndex;
  final Object error;
}

final class PdfPageContentResult {
  const PdfPageContentResult(this.bytes, this.issues);
  final Uint8List bytes;
  final List<PdfPageContentIssue> issues;
  bool get isComplete => issues.isEmpty;
}

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
  final PdfLimits limits;

  PdfPage({
    required this.pageNumber,
    required this.dict,
    required this.resolver,
    this.reference,
    this.limits = const PdfLimits(),
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
          mediaBox.right;
      final y2 = (array.getResolved(3, resolver) as PdfNumber?)?.asDouble ??
          mediaBox.bottom;
      return Rect.fromLTRB(x1, y1, x2, y2);
    }
    return mediaBox;
  }

  /// Ângulo de rotação da página em graus (0, 90, 180, 270).
  int get rotation {
    final value = dict.getNumber('Rotate', resolver)?.toInt() ?? 0;
    return ((value % 360) + 360) % 360;
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
  Uint8List getContentsBytes() => readContents().bytes;

  /// Reads content streams and can preserve usable streams when one is bad.
  PdfPageContentResult readContents({bool ignoreStreamErrors = false}) {
    final contentsObj = dict.getResolved('Contents', resolver);
    if (contentsObj == null) {
      return PdfPageContentResult(Uint8List(0), const <PdfPageContentIssue>[]);
    }

    final issues = <PdfPageContentIssue>[];
    final builder = BytesBuilder(copy: false);
    var decodedBytes = 0;

    void append(PdfStream stream, int index) {
      try {
        final decoded = stream.getDecodedBytes(resolver);
        decodedBytes += decoded.length;
        if (decodedBytes > limits.maxPageContentBytes) {
          throw PdfFormatException(
            'page $pageNumber content exceeds '
            '${limits.maxPageContentBytes} decoded bytes',
          );
        }
        builder
          ..add(decoded)
          ..addByte(0x20);
      } on Object catch (error) {
        if (!ignoreStreamErrors) rethrow;
        issues.add(PdfPageContentIssue(index, error));
      }
    }

    if (contentsObj is PdfStream) {
      append(contentsObj, 0);
    } else if (contentsObj is PdfArray) {
      for (var i = 0; i < contentsObj.length; i++) {
        final stream = contentsObj.getResolved(i, resolver);
        if (stream is PdfStream) {
          append(stream, i);
        }
      }
    }
    return PdfPageContentResult(
      builder.takeBytes(),
      List<PdfPageContentIssue>.unmodifiable(issues),
    );
  }

  @override
  String toString() =>
      'PdfPage(page: $pageNumber, size: ${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)})';
}
