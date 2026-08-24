import 'dart:typed_data';

import 'package:dart_ui/crypto.dart';
import 'package:test/test.dart';

import '../pdf/signing_fixture.dart';

void main() {
  test('DER e X.509 são consumíveis sem importar o subsistema PDF', () {
    final encoded = Der.sequence(<Uint8List>[
      Der.integer(42),
      Der.oid('1.2.840.113549.1.1.1'),
    ]);
    final sequence = DerReader(encoded).read();
    expect(sequence.tag, 0x30);

    final certificate = X509Certificate.parse(signingTestCertificate());
    expect(certificate.commonName, contains('Autoridade Certificadora'));
    expect(certificate.publicKeyAlgorithm, X509PublicKeyAlgorithm.rsa);
  });

  test('DER rejeita comprimento longo com zero inicial', () {
    expect(
      () => DerReader(
        Uint8List.fromList(<int>[0x04, 0x82, 0x00, 0x80, ...Uint8List(128)]),
      ).read(),
      throwsFormatException,
    );
  });
}
