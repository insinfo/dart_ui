import 'dart:typed_data';

import '../x509/x509_certificate.dart';

/// Tecnologia usada pelo Windows para acessar a chave privada do certificado.
enum WindowsKeyProviderKind {
  /// Cryptography Next Generation / Key Storage Provider (CNG/KSP).
  cng,

  /// CryptoAPI / Cryptographic Service Provider (CAPI/CSP).
  legacyCsp,

  unknown,
}

/// Certificado com chave privada publicado no repositório do Windows.
final class WindowsCertificate {
  WindowsCertificate({
    required Uint8List derBytes,
    required Uint8List sha1Thumbprint,
    required this.providerName,
    required this.containerName,
    required this.providerType,
    required this.keySpec,
    required this.providerKind,
    required this.publicKeyAlgorithm,
  })  : derBytes = Uint8List.fromList(derBytes),
        sha1Thumbprint = Uint8List.fromList(sha1Thumbprint);

  /// Certificado X.509 codificado em DER.
  final Uint8List derBytes;

  /// Impressao digital usada somente para reencontrar o certificado no store.
  final Uint8List sha1Thumbprint;
  final String providerName;
  final String containerName;
  final int providerType;
  final int keySpec;
  final WindowsKeyProviderKind providerKind;
  final X509PublicKeyAlgorithm publicKeyAlgorithm;

  String get thumbprintHex => sha1Thumbprint
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

/// Falha retornada por Crypt32, NCrypt ou CryptoAPI.
final class WindowsCryptoException implements Exception {
  const WindowsCryptoException({
    required this.operation,
    required this.code,
    this.details,
  });

  final String operation;
  final int code;
  final String? details;

  @override
  String toString() {
    final suffix = details == null ? '' : ': $details';
    return 'WindowsCryptoException: $operation failed with 0x'
        '${code.toUnsigned(32).toRadixString(16).padLeft(8, '0')}$suffix';
  }
}

/// Fronteira testavel para certificados e chaves gerenciados pelo Windows.
abstract interface class WindowsCertificateStoreApi {
  /// Lista certificados do store CurrentUser\\MY.
  ///
  /// Quando [requirePrivateKey] e verdadeiro, somente certificados que
  /// publicam `CERT_KEY_PROV_INFO_PROP_ID` sao retornados.
  List<WindowsCertificate> listCertificates({bool requirePrivateKey = true});

  /// Assina [data] com SHA-256 e a chave RSA ou EC associada a [certificate].
  ///
  /// [parentWindowHandle] pode ser um HWND. O KSP/CSP continua responsavel por
  /// toda interface segura de PIN; o PIN nunca atravessa esta API.
  Uint8List signSha256({
    required WindowsCertificate certificate,
    required Uint8List data,
    int parentWindowHandle = 0,
  });
}
