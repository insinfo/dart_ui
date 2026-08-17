import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  group('Assinador Digital PDF e Criptografia SHA-256 em Puro Dart', () {
    test('PdfSha256 calcula hash criptográfico conhecido', () {
      // Test vector padrão NIST: "abc" -> ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
      final data = Uint8List.fromList(ascii.encode('abc'));
      final digest = PdfSha256.digest(data);
      final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      expect(hex,
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    test('PdfSigner assina documento PDF com ByteRange e carimbo visual', () {
      // Cria um documento original
      final builder =
          PdfDocumentBuilder(title: 'Contrato de Prestacao de Servicos');
      final page = builder.addPage();
      page.drawText(
          'Contrato Particular de Servicos Graficos', const Offset(50, 80),
          fontSize: 16.0);
      page.drawRect(const Rect.fromLTWH(50, 100, 512, 2),
          fillColor: 0xFF000000);
      final originalPdfBytes = builder.build();

      final doc = PdfDocument.fromBytes(originalPdfBytes);

      // Prepara o assinador
      final signer = PdfSigner(
        document: doc,
        signerName: 'Dr. Roberto Magalhaes',
        reason: 'Aprovacao Formal do Contrato',
        location: 'Sao Paulo, Brasil',
        standard: PdfSignatureStandard.padesBB,
      );

      signer.setVisualAppearance(PdfSignatureAppearance(
        pageNumber: 1,
        rect: const Rect.fromLTWH(350, 650, 200, 80),
        signerName: 'Dr. Roberto Magalhaes',
        reason: 'Aprovacao Formal do Contrato',
      ));

      // Executa a assinatura digital
      final signedBytes = signer.sign(reservedSignatureBytes: 1024);

      expect(signedBytes.length, greaterThan(originalPdfBytes.length));

      // Valida que o PDF assinado contém a estrutura de assinatura
      final signedString = utf8.decode(signedBytes, allowMalformed: true);
      expect(signedString, contains('/Type /Sig'));
      expect(signedString, contains('/SubFilter /adbe.pkcs7.detached'));
      expect(signedString, contains('Dr. Roberto Magalhaes'));
      expect(signedString, contains('/ByteRange [0 '));

      // Valida que o PDF assinado ainda abre perfeitamente
      final verifiedDoc = PdfDocument.fromBytes(signedBytes);
      expect(verifiedDoc.pageCount, 1);
      expect(verifiedDoc.title, 'Contrato de Prestacao de Servicos');
    });
  });
}
