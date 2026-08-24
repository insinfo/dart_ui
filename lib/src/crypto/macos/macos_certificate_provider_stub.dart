import 'dart:typed_data';

import '../certificate_provider.dart';

/// Placeholder da API do Keychain em runtimes sem `dart:io`.
final class MacOsCertificateProvider implements CertificateProvider {
  MacOsCertificateProvider() : id = 'macos-system-unavailable';

  Never _unsupported() => throw UnsupportedError(
        'MacOsCertificateProvider requires a native macOS runtime',
      );

  @override
  final String id;

  @override
  String get name => 'Certificados do macOS';

  @override
  CertificateProviderKind get kind => CertificateProviderKind.macosSystem;

  @override
  CertificateAuthenticationMode get authenticationMode =>
      CertificateAuthenticationMode.providerUi;

  @override
  bool get isAvailable => false;

  @override
  Future<List<CryptoIdentity>> listIdentities({
    CertificateOperationContext context = const CertificateOperationContext(),
  }) =>
      _unsupported();

  @override
  Future<Uint8List> signSha256({
    required CryptoIdentity identity,
    required Uint8List data,
    CertificateOperationContext context = const CertificateOperationContext(),
  }) =>
      _unsupported();

  @override
  void close() {}
}
