import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('PKCS#11 é consumível sem importar o subsistema PDF', () {
    final id = Uint8List.fromList(const <int>[1, 2]);
    final der = Uint8List.fromList(const <int>[0x30, 0]);
    final certificate = Pkcs11Certificate(
      id: id,
      label: 'Certificado',
      derBytes: der,
    );
    id[0] = 9;
    der[0] = 9;

    expect(certificate.id, <int>[1, 2]);
    expect(certificate.derBytes, <int>[0x30, 0]);
    expect(certificate.idHex, '0102');
    expect(Pkcs11Mechanism.sha256RsaPkcs.value, 0x40);
  });

  test('ABI Cryptoki usa pack(1), inclusive no Windows x64', () {
    final layout = Pkcs11Module.nativeAbiLayout;

    if (Platform.isWindows) {
      expect(layout.attribute, 16);
      expect(layout.mechanism, 16);
      expect(layout.tokenInfo, 160);
    } else {
      expect(layout.attribute, 24);
      expect(layout.mechanism, 24);
      expect(layout.tokenInfo, 204);
    }
  });
}
