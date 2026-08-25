import 'dart:convert';
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

  test('lê nome e CPF de SubjectAlternativeName ICP-Brasil', () {
    final certificate = X509Certificate.parse(_icpBrasilCertificate());

    expect(certificate.icpBrasilDisplayName, 'MARIA DA SILVA');
    expect(certificate.icpBrasilCpf, '12345678909');
    expect(certificate.maskedIcpBrasilCpf, '***.456.789-**');
    expect(maskBrazilianCpf('123.456.789-09'), '***.456.789-**');
    expect(maskBrazilianCpf('invalido'), isNull);
  });

  test('lê CPF do serialNumber do DN antes dos formatos legados', () {
    final certificate = X509Certificate.parse(
      _icpBrasilCertificate(includeSan: false, includeSerialNumber: true),
    );

    expect(certificate.icpBrasilCpf, '98765432100');
    expect(certificate.maskedIcpBrasilCpf, '***.654.321-**');
  });

  test('usa o sufixo CPF do CN como último recurso', () {
    final certificate = X509Certificate.parse(
      _icpBrasilCertificate(includeSan: false),
    );

    expect(certificate.icpBrasilCpf, '12345678909');
  });
}

Uint8List _icpBrasilCertificate({
  bool includeSan = true,
  bool includeSerialNumber = false,
}) {
  final name = Der.sequence(<Uint8List>[
    Der.setOf(<Uint8List>[
      Der.sequence(<Uint8List>[
        Der.oid('2.5.4.3'),
        Der.tlv(0x0c, utf8.encode('MARIA DA SILVA:12345678909')),
      ]),
    ]),
    if (includeSerialNumber)
      Der.setOf(<Uint8List>[
        Der.sequence(<Uint8List>[
          Der.oid('2.5.4.5'),
          Der.tlv(0x13, ascii.encode('98765432100')),
        ]),
      ]),
  ]);
  final personalData = ascii.encode(
    '0101199012345678909'.padRight(51),
  );
  final otherName = Der.tlv(
    0xa0,
    Der.sequence(<Uint8List>[
      Der.oid('2.16.76.1.3.1'),
      Der.explicit(0, Der.explicit(0, Der.octetString(personalData))),
    ]),
  );
  final san = Der.sequence(<Uint8List>[otherName]);
  final extensions = Der.explicit(
    3,
    Der.sequence(<Uint8List>[
      Der.sequence(<Uint8List>[
        Der.oid('2.5.29.17'),
        Der.octetString(san),
      ]),
    ]),
  );
  final algorithm = Der.sequence(<Uint8List>[
    Der.oid('1.2.840.113549.1.1.1'),
    Der.nullValue(),
  ]);
  final tbs = Der.sequence(<Uint8List>[
    Der.explicit(0, Der.integer(2)),
    Der.integer(1),
    algorithm,
    name,
    Der.sequence(<Uint8List>[
      Der.time(DateTime.utc(2020)),
      Der.time(DateTime.utc(2030)),
    ]),
    name,
    Der.sequence(<Uint8List>[
      algorithm,
      Der.tlv(0x03, const <int>[0, 0]),
    ]),
    if (includeSan) extensions,
  ]);
  return Der.sequence(<Uint8List>[
    tbs,
    algorithm,
    Der.tlv(0x03, const <int>[0, 0]),
  ]);
}
