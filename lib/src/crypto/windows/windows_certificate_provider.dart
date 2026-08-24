import 'dart:async';
import 'dart:typed_data';

import '../certificate_provider.dart';
import '../x509/x509_certificate.dart';
import 'windows_certificate_store_platform_stub.dart'
    if (dart.library.io) 'windows_certificate_store_platform_io.dart';
import 'windows_certificate_store_types.dart';

/// Provedor generico sobre CurrentUser\\MY, CNG/KSP e CryptoAPI/CSP.
final class WindowsCertificateProvider implements CertificateProvider {
  WindowsCertificateProvider({WindowsCertificateStoreApi? store})
      : _store = store ?? WindowsCertificateStore(),
        id = 'windows-system-${_nextId++}';

  static int _nextId = 1;

  final WindowsCertificateStoreApi _store;
  final Map<String, WindowsCertificate> _certificates =
      <String, WindowsCertificate>{};
  bool _closed = false;

  @override
  final String id;

  @override
  String get name => 'Certificados do Windows';

  @override
  CertificateProviderKind get kind => CertificateProviderKind.windowsSystem;

  @override
  CertificateAuthenticationMode get authenticationMode =>
      CertificateAuthenticationMode.providerUi;

  @override
  bool get isAvailable => !_closed;

  @override
  Future<List<CryptoIdentity>> listIdentities({
    CertificateOperationContext context = const CertificateOperationContext(),
  }) =>
      Future<List<CryptoIdentity>>.sync(() {
        _checkOpen('listIdentities');
        final certificates = _store.listCertificates();
        _certificates.clear();
        final identities = <CryptoIdentity>[];
        for (final certificate in certificates) {
          final reference = certificate.thumbprintHex;
          final x509 = X509Certificate.parse(certificate.derBytes);
          _certificates[reference] = certificate;
          identities.add(
            CryptoIdentity(
              providerId: id,
              id: reference,
              label: x509.commonName,
              certificate: x509,
              metadata: <String, String>{
                'provider': certificate.providerName,
                'container': certificate.containerName,
                'technology': certificate.providerKind.name,
                'thumbprint': reference,
              },
            ),
          );
        }
        return List<CryptoIdentity>.unmodifiable(identities);
      });

  @override
  Future<Uint8List> signSha256({
    required CryptoIdentity identity,
    required Uint8List data,
    CertificateOperationContext context = const CertificateOperationContext(),
  }) =>
      Future<Uint8List>.sync(() {
        _checkIdentity(identity, 'signSha256');
        final certificate = _certificates[identity.id];
        if (certificate == null) {
          throw CertificateProviderException(
            provider: name,
            operation: 'signSha256',
            message: 'identity is stale; enumerate certificates again',
          );
        }
        return _store.signSha256(
          certificate: certificate,
          data: data,
          parentWindowHandle: context.nativeWindowHandle,
        );
      });

  void _checkIdentity(CryptoIdentity identity, String operation) {
    _checkOpen(operation);
    if (identity.providerId != id) {
      throw CertificateProviderException(
        provider: name,
        operation: operation,
        message: 'identity belongs to another provider',
      );
    }
  }

  void _checkOpen(String operation) {
    if (_closed) {
      throw CertificateProviderException(
        provider: name,
        operation: operation,
        message: 'provider is closed',
      );
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _certificates.clear();
  }
}
