import 'dart:typed_data';

import 'package:dart_ui/crypto.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

import 'signing_fixture.dart';

void main() {
  group('DER, X.509 e CMS/PAdES', () {
    test('parser X.509 preserva emissor, serial e nome comum', () {
      final certificate = X509Certificate.parse(signingTestCertificate());
      expect(certificate.serialNumber, isNotEmpty);
      expect(certificate.issuerDer.first, 0x30);
      expect(certificate.commonName, contains('Autoridade Certificadora'));
      expect(certificate.publicKeyAlgorithm, X509PublicKeyAlgorithm.rsa);
      expect(certificate.isValidAt(DateTime.utc(2005)), isTrue);
      expect(certificate.isValidAt(DateTime.utc(2026)), isFalse);
    });

    test('atributos autenticados contêm digest e SigningCertificateV2', () {
      final request = const PdfPadesEngine().createSigningRequest(
        documentDigest: Uint8List(32),
        signerCertificate: signingTestCertificate(),
        signingTime: DateTime.utc(2005, 1, 2, 3, 4, 5),
      );
      expect(request.authenticatedAttributesDer.first, 0x31);
      expect(request.documentDigest, Uint8List(32));

      final cms = const PdfPadesEngine().complete(
        request: request,
        signature: Uint8List(256),
        certificateChain: <Uint8List>[signingTestCertificate()],
      );
      expect(cms.first, 0x30);
      expect(cms.length, greaterThan(signingTestCertificate().length));
    });

    test('ByteRange rejeita intervalos fora do documento', () {
      const signer = PdfByteRangeSigner();
      final bytes = Uint8List(100);
      expect(signer.calculateByteRange(bytes, 20, 10), <int>[0, 20, 30, 70]);
      expect(signer.hashByteRange(bytes, <int>[0, 20, 30, 70]).length, 32);
      expect(
        () => signer.calculateByteRange(bytes, 95, 10),
        throwsRangeError,
      );
    });
  });
}
