import 'crypto_identity.dart';
import 'external_key_signer.dart';

export 'crypto_identity.dart';
export 'external_key_signer.dart';

/// Contrato comum consumido por PDF, XML, TLS ou qualquer outro protocolo.
abstract interface class CertificateProvider implements ExternalKeySigner {
  String get id;
  String get name;
  CertificateProviderKind get kind;
  CertificateAuthenticationMode get authenticationMode;
  bool get isAvailable;

  Future<List<CryptoIdentity>> listIdentities({
    CertificateOperationContext context = const CertificateOperationContext(),
  });

  void close();
}

final class CertificateProviderException implements Exception {
  const CertificateProviderException({
    required this.provider,
    required this.operation,
    required this.message,
    this.cause,
  });

  final String provider;
  final String operation;
  final String message;
  final Object? cause;

  @override
  String toString() => 'CertificateProviderException($provider): '
      '$operation: $message${cause == null ? '' : ' ($cause)'}';
}
