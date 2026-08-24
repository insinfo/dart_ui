import 'dart:collection';

import 'x509/x509_certificate.dart';

/// Origem de uma identidade criptografica.
enum CertificateProviderKind {
  windowsSystem,
  macosSystem,
  pkcs11,
}

/// Como o provedor obtem autorizacao para usar a chave privada.
enum CertificateAuthenticationMode {
  /// O sistema operacional ou middleware apresenta sua propria interface.
  providerUi,

  /// O aplicativo fornece o PIN ao modulo, como no PKCS#11 classico.
  applicationPin,
}

/// Certificado e referencia opaca para uma chave que permanece no provedor.
final class CryptoIdentity {
  CryptoIdentity({
    required this.providerId,
    required this.id,
    required this.label,
    required this.certificate,
    List<X509Certificate> certificateChain = const <X509Certificate>[],
    Map<String, String> metadata = const <String, String>{},
  })  : certificateChain = List<X509Certificate>.unmodifiable(
          certificateChain.isEmpty
              ? <X509Certificate>[certificate]
              : certificateChain,
        ),
        metadata = UnmodifiableMapView<String, String>(
          Map<String, String>.from(metadata),
        );

  /// Identifica a instancia do provedor que criou esta identidade.
  final String providerId;

  /// Referencia estavel somente dentro do provedor (thumbprint, slot/id etc.).
  final String id;
  final String label;
  final X509Certificate certificate;
  final List<X509Certificate> certificateChain;
  final Map<String, String> metadata;

  X509PublicKeyAlgorithm get publicKeyAlgorithm =>
      certificate.publicKeyAlgorithm;
}
