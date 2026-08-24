import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/crypto.dart';
import 'package:test/test.dart';

void main() {
  test(
    'enumera CurrentUser/MY sem depender de PKCS#11',
    () {
      final certificates = WindowsCertificateStore().listCertificates();
      for (final certificate in certificates) {
        expect(certificate.derBytes, isNotEmpty);
        expect(certificate.sha1Thumbprint, hasLength(20));
        expect(
          certificate.providerKind,
          isIn(<WindowsKeyProviderKind>[
            WindowsKeyProviderKind.cng,
            WindowsKeyProviderKind.legacyCsp,
          ]),
        );
        expect(certificate.publicKeyAlgorithm,
            isNot(X509PublicKeyAlgorithm.unknown));
      }
    },
    skip: !Platform.isWindows,
  );

  test('WindowsCertificate protege suas cópias de bytes', () {
    final der = Uint8List.fromList(const <int>[0x30, 0]);
    final thumbprint = Uint8List(20)..[0] = 1;
    final certificate = WindowsCertificate(
      derBytes: der,
      sha1Thumbprint: thumbprint,
      providerName: 'Microsoft Smart Card Key Storage Provider',
      containerName: 'container',
      providerType: 0,
      keySpec: 0xffffffff,
      providerKind: WindowsKeyProviderKind.cng,
      publicKeyAlgorithm: X509PublicKeyAlgorithm.rsa,
    );
    der[0] = 0;
    thumbprint[0] = 0;

    expect(certificate.derBytes, <int>[0x30, 0]);
    expect(certificate.sha1Thumbprint.first, 1);
    expect(certificate.thumbprintHex, startsWith('01'));
  });
}
