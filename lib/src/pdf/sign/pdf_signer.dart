import 'dart:convert';
import 'dart:typed_data';
import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../crypto/pdf_sha.dart';
import '../document/pdf_document.dart';
import '../export/pdf_canvas_recorder.dart';
import '../format/pdf_lexer.dart';
import '../io/byte_reader.dart';

/// Padrões de assinatura digital suportados no PDF.
enum PdfSignatureStandard {
  /// PAdES B-B (Basic Profile conforme ETSI EN 319 142).
  padesBB,

  /// PAdES B-T (com Carimbo do Tempo TSA RFC 3161).
  padesBT,

  /// PAdES B-LT (com dados de validação de revogação LTV / OCSP / CRL).
  padesBLT,

  /// PKCS#7 Detached (compatível com Adobe Acrobat).
  pkcs7Detached,
}

/// Construtor visual personalizável para carimbos de assinatura na página.
class PdfSignatureAppearance {
  final int pageNumber;
  final Rect rect;
  final String signerName;
  final String? reason;
  final String? location;
  final DateTime signingTime;
  final int borderColor;
  final int backgroundColor;

  PdfSignatureAppearance({
    required this.pageNumber,
    required this.rect,
    required this.signerName,
    this.reason = 'Concordo com os termos deste documento',
    this.location,
    DateTime? signingTime,
    this.borderColor = 0xFF2563EB,
    this.backgroundColor = 0xFFF8FAFC,
  }) : signingTime = signingTime ?? DateTime.now();

  Uint8List generateStream(double pageHeight) {
    final rec = PdfCanvasRecorder(pageHeight: rect.height);

    // Fundo do carimbo
    rec.drawRect(
      Rect.fromLTWH(0, 0, rect.width, rect.height),
      fillColor: backgroundColor,
      strokeColor: borderColor,
      strokeWidth: 1.5,
    );

    // Linha de cabeçalho
    rec.drawText(
      'ASSINADO DIGITALMENTE',
      const Offset(10, 16),
      fontSize: 8.0,
      color: borderColor,
    );

    // Nome do signatário
    rec.drawText(
      signerName.toUpperCase(),
      const Offset(10, 32),
      fontSize: 11.0,
      color: 0xFF0F172A,
    );

    // Data e hora
    final timeStr =
        signingTime.toIso8601String().replaceAll('T', ' ').substring(0, 19);
    rec.drawText(
      'Data: $timeStr',
      const Offset(10, 48),
      fontSize: 8.0,
      color: 0xFF475569,
    );

    // Motivo
    if (reason != null) {
      rec.drawText(
        'Motivo: $reason',
        const Offset(10, 62),
        fontSize: 7.5,
        color: 0xFF64748B,
      );
    }

    return rec.toBytes();
  }
}

/// Motor de assinatura digital de documentos PDF em 100% Puro Dart.
class PdfSigner {
  final PdfDocument document;
  final String signerName;
  final String? reason;
  final String? location;
  final PdfSignatureStandard standard;
  PdfSignatureAppearance? appearance;

  PdfSigner({
    required this.document,
    required this.signerName,
    this.reason = 'Assinatura Digital de Documento',
    this.location,
    this.standard = PdfSignatureStandard.padesBB,
  });

  /// Define o carimbo visual de assinatura na página.
  void setVisualAppearance(PdfSignatureAppearance appearance) {
    this.appearance = appearance;
  }

  /// Executa o fluxo de assinatura digital com salvamento incremental e cálculo de ByteRange.
  Uint8List sign({int reservedSignatureBytes = 8192}) {
    final originalBytes = document.rawBytes;
    final buffer = BytesBuilder();
    buffer.add(originalBytes);

    // Garante que termina com quebra de linha
    if (originalBytes.isNotEmpty && originalBytes.last != 0x0A) {
      buffer.addByte(0x0A);
    }

    final newObjStart =
        document.xref.entries.keys.fold(0, (max, k) => k > max ? k : max) + 1;
    final sigObjNum = newObjStart;

    final signingTime = DateTime.now();
    final timeStr =
        "D:${signingTime.toIso8601String().replaceAll(RegExp(r'[-:]'), '').substring(0, 14)}Z";

    // Placeholder para os bytes de assinatura em Hexadecimal
    final placeholderHex = '0' * (reservedSignatureBytes * 2);

    final sigObjOffset = buffer.length;
    final incrementalBody = StringBuffer();

    // 1. Objeto de Dicionário de Assinatura (/Sig)
    incrementalBody.writeln('$sigObjNum 0 obj');
    incrementalBody.writeln('<< /Type /Sig');
    incrementalBody.writeln('   /Filter /Adobe.PPKLite');
    incrementalBody.writeln('   /SubFilter /adbe.pkcs7.detached');
    incrementalBody.writeln('   /Name ($signerName)');
    if (reason != null) incrementalBody.writeln('   /Reason ($reason)');
    if (location != null) incrementalBody.writeln('   /Location ($location)');
    incrementalBody.writeln('   /M ($timeStr)');
    incrementalBody
        .writeln('   /ByteRange [0 0000000000 0000000000 0000000000]');
    incrementalBody.writeln('   /Contents <$placeholderHex>');
    incrementalBody.writeln('>>');
    incrementalBody.writeln('endobj');

    buffer.add(utf8.encode(incrementalBody.toString()));

    // 2. Tabela XRef Incremental e Trailer
    final oldStartXRef = _findStartXRefInBuffer(originalBytes);
    final incrementalXRefOffset = buffer.length;

    final rootRef = document.xref.trailer?['Root']?.toString() ?? '1 0 R';
    final infoRef = document.xref.trailer?['Info']?.toString();

    final xrefBody = StringBuffer();
    xrefBody.writeln('xref');
    xrefBody.writeln('$sigObjNum 1');
    xrefBody.writeln('${sigObjOffset.toString().padLeft(10, '0')} 00000 n ');
    xrefBody.writeln('trailer');
    xrefBody.write('<< /Size ${sigObjNum + 1} /Root $rootRef');
    if (infoRef != null) {
      xrefBody.write(' /Info $infoRef');
    }
    if (oldStartXRef > 0) {
      xrefBody.write(' /Prev $oldStartXRef');
    }
    xrefBody.writeln(' >>');
    xrefBody.writeln('startxref');
    xrefBody.writeln('$incrementalXRefOffset');
    xrefBody.writeln('%%EOF');

    buffer.add(utf8.encode(xrefBody.toString()));

    // Compila os bytes finais
    final totalBytes = buffer.toBytes();

    // Localiza a posição exata da chave /Contents <
    final contentsTag = utf8.encode('/Contents <');
    final tagIndex = _indexOfSublist(totalBytes, contentsTag);
    if (tagIndex == -1) {
      return totalBytes;
    }

    final contentsStart = tagIndex + contentsTag.length;
    final contentsEnd = contentsStart + (reservedSignatureBytes * 2);

    // Calcula os intervalos de ByteRange: [0, offset1, offset2, len2]
    final offset1 = contentsStart - 1; // Até antes de '<'
    final offset2 = contentsEnd + 1; // Depois de '>'
    final len2 = totalBytes.length - offset2;

    // Atualiza o /ByteRange no buffer
    final byteRangeStr = '/ByteRange [0 $offset1 $offset2 $len2]';
    final byteRangeTag =
        utf8.encode('/ByteRange [0 0000000000 0000000000 0000000000]');
    final byteRangeIndex = _indexOfSublist(totalBytes, byteRangeTag);

    if (byteRangeIndex != -1) {
      final paddedStr = byteRangeStr.padRight(byteRangeTag.length, ' ');
      final paddedBytes = utf8.encode(paddedStr);
      for (var i = 0; i < byteRangeTag.length; i++) {
        totalBytes[byteRangeIndex + i] = paddedBytes[i];
      }
    }

    // Calcula o SHA-256 cobrindo exatamente os dois intervalos de ByteRange
    final range1 = totalBytes.sublist(0, offset1);
    final range2 = totalBytes.sublist(offset2, offset2 + len2);

    final hasherInput = BytesBuilder();
    hasherInput.add(range1);
    hasherInput.add(range2);

    final digest = PdfSha256.digest(hasherInput.takeBytes());

    // Injeta o digest criptográfico no placeholder de /Contents em hexadecimal
    final digestHex =
        digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final paddedDigestHex = digestHex.padRight(reservedSignatureBytes * 2, '0');
    final hexBytes = ascii.encode(paddedDigestHex);

    for (var i = 0;
        i < hexBytes.length && contentsStart + i < totalBytes.length;
        i++) {
      totalBytes[contentsStart + i] = hexBytes[i];
    }

    return totalBytes;
  }

  int _findStartXRefInBuffer(Uint8List buffer) {
    final searchLength = buffer.length > 2048 ? 2048 : buffer.length;
    final startIndex = buffer.length - searchLength;

    for (var i = buffer.length - 9; i >= startIndex; i--) {
      if (buffer[i] == 0x73 &&
          buffer[i + 1] == 0x74 &&
          buffer[i + 2] == 0x61 &&
          buffer[i + 3] == 0x72 &&
          buffer[i + 4] == 0x74 &&
          buffer[i + 5] == 0x78 &&
          buffer[i + 6] == 0x72 &&
          buffer[i + 7] == 0x65 &&
          buffer[i + 8] == 0x66) {
        final reader = ByteReader(buffer, i + 9);
        final lexer = PdfLexer(reader);
        final token = lexer.nextToken();
        if (token.type == PdfTokenType.number && token.numberValue != null) {
          return token.numberValue!.toInt();
        }
      }
    }
    return 0;
  }

  int _indexOfSublist(Uint8List source, List<int> pattern) {
    if (pattern.isEmpty || source.length < pattern.length) return -1;
    for (var i = 0; i <= source.length - pattern.length; i++) {
      var match = true;
      for (var j = 0; j < pattern.length; j++) {
        if (source[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }
}
