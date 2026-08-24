import 'dart:typed_data';

import '../../crypto/certificate_provider.dart';
import '../../crypto/x509/x509_certificate.dart';
import 'pdf_external_signer.dart';

/// Adaptador unico entre qualquer [CertificateProvider] e CMS/PAdES.
///
/// PDF nao conhece store do Windows, CryptoTokenKit, PC/SC ou PKCS#11. O
/// provedor entrega uma assinatura normalizada e mantem a chave privada.
final class PdfCertificateProviderSigner implements PdfExternalSigner {
  PdfCertificateProviderSigner({
    required this.provider,
    required this.identity,
    this.context = const CertificateOperationContext(),
    List<Uint8List> additionalCertificates = const <Uint8List>[],
  }) : certificateChain = <Uint8List>[
          ...identity.certificateChain.map(
            (certificate) => Uint8List.fromList(certificate.derBytes),
          ),
          ...additionalCertificates.map(Uint8List.fromList),
        ];

  final CertificateProvider provider;
  final CryptoIdentity identity;
  final CertificateOperationContext context;

  @override
  final List<Uint8List> certificateChain;

  @override
  PdfSignatureAlgorithm get algorithm => switch (identity.publicKeyAlgorithm) {
        X509PublicKeyAlgorithm.rsa => PdfSignatureAlgorithm.rsaSha256,
        X509PublicKeyAlgorithm.ec => PdfSignatureAlgorithm.ecdsaSha256,
        X509PublicKeyAlgorithm.unknown => throw UnsupportedError(
            'Unsupported X.509 public key algorithm',
          ),
      };

  @override
  Future<Uint8List> sign(Uint8List authenticatedAttributesDer) =>
      provider.signSha256(
        identity: identity,
        data: authenticatedAttributesDer,
        context: context,
      );
}
