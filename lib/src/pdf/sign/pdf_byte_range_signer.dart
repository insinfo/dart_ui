import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/crypto.dart';

/// Documento preparado, mas ainda sem o contêiner CMS no `/Contents`.
final class PdfPreparedSignature {
  PdfPreparedSignature({
    required Uint8List bytes,
    required this.byteRange,
    required this.contentsHexOffset,
    required this.reservedSignatureBytes,
  }) : bytes = Uint8List.fromList(bytes) {
    if (byteRange.length != 4 || byteRange.first != 0) {
      throw ArgumentError.value(byteRange, 'byteRange');
    }
  }

  final Uint8List bytes;
  final List<int> byteRange;
  final int contentsHexOffset;
  final int reservedSignatureBytes;

  Uint8List get documentDigest =>
      const PdfByteRangeSigner().hashByteRange(bytes, byteRange);

  /// Preenche o placeholder sem alterar tamanho nem offsets do documento.
  Uint8List embed(Uint8List cmsSignedData) {
    if (cmsSignedData.length > reservedSignatureBytes) {
      throw PdfSignatureSizeException(
        actualBytes: cmsSignedData.length,
        reservedBytes: reservedSignatureBytes,
      );
    }
    final result = Uint8List.fromList(bytes);
    final hex = ascii.encode(
      cmsSignedData
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(),
    );
    result.setRange(contentsHexOffset, contentsHexOffset + hex.length, hex);
    return result;
  }
}

final class PdfSignatureSizeException implements Exception {
  const PdfSignatureSizeException({
    required this.actualBytes,
    required this.reservedBytes,
  });

  final int actualBytes;
  final int reservedBytes;

  @override
  String toString() =>
      'PdfSignatureSizeException: CMS uses $actualBytes bytes, '
      'but /Contents reserves $reservedBytes bytes';
}

/// Operações exatas de `/ByteRange`, reutilizáveis por assinadores externos.
final class PdfByteRangeSigner {
  const PdfByteRangeSigner();

  List<int> calculateByteRange(
    Uint8List documentBytes,
    int excludedStart,
    int excludedLength,
  ) {
    if (excludedStart < 0 ||
        excludedLength < 0 ||
        excludedStart + excludedLength > documentBytes.length) {
      throw RangeError('signature placeholder is outside the PDF');
    }
    final secondStart = excludedStart + excludedLength;
    return <int>[
      0,
      excludedStart,
      secondStart,
      documentBytes.length - secondStart,
    ];
  }

  Uint8List hashByteRange(Uint8List documentBytes, List<int> byteRange) {
    if (byteRange.length != 4 ||
        byteRange[0] != 0 ||
        byteRange[1] < 0 ||
        byteRange[2] < byteRange[1] ||
        byteRange[3] < 0 ||
        byteRange[2] + byteRange[3] > documentBytes.length) {
      throw ArgumentError.value(byteRange, 'byteRange');
    }
    final bytes = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(documentBytes, 0, byteRange[1]))
      ..add(Uint8List.sublistView(
        documentBytes,
        byteRange[2],
        byteRange[2] + byteRange[3],
      ));
    return Crypto.sha256(bytes.takeBytes());
  }
}
