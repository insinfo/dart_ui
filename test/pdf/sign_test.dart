import 'package:test/test.dart';
import 'dart:typed_data';
import 'package:dart_ui/src/pdf/sign/pdf_pades_engine.dart';
import 'package:dart_ui/src/pdf/sign/pdf_byte_range_signer.dart';
import 'package:dart_ui/src/pdf/crypto/pdf_security_handler.dart';

void main() {
  group('PAdES & Security Tests', () {
    test('PdfByteRangeSigner calculates and hashes byte ranges', () {
      final signer = PdfByteRangeSigner();
      final dummyDoc =
          Uint8List.fromList(List.generate(100, (i) => i)); // 0..99

      final byteRange = signer.calculateByteRange(dummyDoc, 20, 10);
      expect(byteRange, equals([0, 20, 30, 70]));

      final hash = signer.hashByteRange(dummyDoc, byteRange);
      expect(hash.length, equals(32)); // SHA-256
    });

    test('PdfPadesEngine generates signed data', () {
      final engine = PdfPadesEngine(
        Uint8List.fromList([1, 2, 3]), // privateKey mock
        Uint8List.fromList([4, 5, 6]), // cert mock
      );

      final hash = Uint8List(32);
      final signedData = engine.sign(hash);

      expect(signedData.length, greaterThan(32));
      expect(signedData[0], equals(0x30)); // ASN.1 SEQUENCE
    });

    test('PdfSecurityHandler encrypts and decrypts with RC4', () {
      final handler = PdfSecurityHandler(
        revision: 3,
        ownerKey: Uint8List(32),
        userKey: Uint8List(32),
        permissions: 0,
        fileId: Uint8List(16),
        isAes: false,
        password: 'test',
      );

      final data = Uint8List.fromList([10, 20, 30, 40]);
      final encrypted = handler.encryptContent(1, 0, data);
      final decrypted = handler.decryptContent(1, 0, encrypted);

      expect(decrypted, equals(data));
    });
  });
}
