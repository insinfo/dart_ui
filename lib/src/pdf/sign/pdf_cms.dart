import 'dart:typed_data';

import '../../crypto/asn1/der.dart';
import '../../crypto/crypto.dart';
import '../../crypto/x509/x509_certificate.dart';
import 'pdf_external_signer.dart';

/// Resultado intermediário que deve ser entregue à chave externa.
final class PdfCmsSigningRequest {
  const PdfCmsSigningRequest({
    required this.documentDigest,
    required this.authenticatedAttributesDer,
  });

  final Uint8List documentDigest;
  final Uint8List authenticatedAttributesDer;
}

/// Construtor CMS SignedData destacado compatível com PAdES B-B.
final class PdfCmsBuilder {
  const PdfCmsBuilder._();

  static const String _data = '1.2.840.113549.1.7.1';
  static const String _signedData = '1.2.840.113549.1.7.2';
  static const String _sha256 = '2.16.840.1.101.3.4.2.1';
  static const String _rsaSha256 = '1.2.840.113549.1.1.11';
  static const String _ecdsaSha256 = '1.2.840.10045.4.3.2';
  static const String _contentType = '1.2.840.113549.1.9.3';
  static const String _messageDigest = '1.2.840.113549.1.9.4';
  static const String _signingTime = '1.2.840.113549.1.9.5';
  static const String _signingCertificateV2 = '1.2.840.113549.1.9.16.2.47';

  static PdfCmsSigningRequest createSigningRequest({
    required Uint8List documentDigest,
    required Uint8List signerCertificate,
    DateTime? signingTime,
  }) {
    if (documentDigest.length != 32) {
      throw ArgumentError.value(
        documentDigest.length,
        'documentDigest',
        'SHA-256 digest must contain 32 bytes',
      );
    }
    X509Certificate.parse(signerCertificate);
    final certificateDigest = Crypto.sha256(signerCertificate);
    Uint8List attribute(String oid, Uint8List value) => Der.sequence(
          <Uint8List>[
            Der.oid(oid),
            Der.setOf(<Uint8List>[value])
          ],
        );
    final essCertIdV2 = Der.sequence(<Uint8List>[
      Der.octetString(certificateDigest),
    ]);
    final signingCertificate = Der.sequence(<Uint8List>[
      Der.sequence(<Uint8List>[essCertIdV2]),
    ]);
    final attributes = Der.setOf(<Uint8List>[
      attribute(_contentType, Der.oid(_data)),
      attribute(_messageDigest, Der.octetString(documentDigest)),
      attribute(_signingTime, Der.time(signingTime ?? DateTime.now())),
      attribute(_signingCertificateV2, signingCertificate),
    ]);
    return PdfCmsSigningRequest(
      documentDigest: Uint8List.fromList(documentDigest),
      authenticatedAttributesDer: attributes,
    );
  }

  static Uint8List buildDetachedSignedData({
    required PdfCmsSigningRequest request,
    required Uint8List signature,
    required List<Uint8List> certificateChain,
    required PdfSignatureAlgorithm algorithm,
  }) {
    if (certificateChain.isEmpty) {
      throw ArgumentError.value(certificateChain, 'certificateChain');
    }
    final signer = X509Certificate.parse(certificateChain.first);
    final digestAlgorithm = _algorithmIdentifier(_sha256, withNull: true);
    final signatureAlgorithm = switch (algorithm) {
      PdfSignatureAlgorithm.rsaSha256 =>
        _algorithmIdentifier(_rsaSha256, withNull: true),
      PdfSignatureAlgorithm.ecdsaSha256 =>
        _algorithmIdentifier(_ecdsaSha256, withNull: false),
    };
    final issuerAndSerial = Der.sequence(<Uint8List>[
      signer.issuerDer,
      Der.integerBytes(signer.serialNumber),
    ]);
    final signedAttributesImplicit = Uint8List.fromList(
      request.authenticatedAttributesDer,
    )..[0] = 0xa0;
    final signerInfo = Der.sequence(<Uint8List>[
      Der.integer(1),
      issuerAndSerial,
      digestAlgorithm,
      signedAttributesImplicit,
      signatureAlgorithm,
      Der.octetString(signature),
    ]);
    final certificates = certificateChain.map(Uint8List.fromList).toList()
      ..sort(_compareBytes);
    final certificateSet = Der.implicitConstructed(
      0,
      certificates.expand((certificate) => certificate),
    );
    final encapContentInfo = Der.sequence(<Uint8List>[
      Der.oid(_data),
    ]);
    final signedData = Der.sequence(<Uint8List>[
      Der.integer(1),
      Der.setOf(<Uint8List>[digestAlgorithm]),
      encapContentInfo,
      certificateSet,
      Der.setOf(<Uint8List>[signerInfo]),
    ]);
    return Der.sequence(<Uint8List>[
      Der.oid(_signedData),
      Der.explicit(0, signedData),
    ]);
  }

  static Uint8List _algorithmIdentifier(String oid, {required bool withNull}) =>
      Der.sequence(<Uint8List>[
        Der.oid(oid),
        if (withNull) Der.nullValue(),
      ]);

  static int _compareBytes(Uint8List a, Uint8List b) {
    final count = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < count; i++) {
      final result = a[i].compareTo(b[i]);
      if (result != 0) return result;
    }
    return a.length.compareTo(b.length);
  }
}
