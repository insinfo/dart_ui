import 'dart:async';
import 'dart:typed_data';

import '../asn1/der.dart';
import '../certificate_provider.dart';
import '../crypto.dart';
import '../x509/x509_certificate.dart';
import 'pkcs11_types.dart';

/// Provedor multiplataforma sobre um slot PKCS#11/Cryptoki.
///
/// O mesmo contrato funciona com DLL no Windows, `.dylib` no macOS e `.so` no
/// Linux. O modulo e o unico componente que conhece o middleware SafeSign,
/// OpenSC ou outro fabricante.
final class Pkcs11CertificateProvider implements CertificateProvider {
  Pkcs11CertificateProvider({
    required this.module,
    required this.slotId,
    required this.tokenLabel,
    this.rsaMechanism = Pkcs11Mechanism.sha256RsaPkcs,
    this.ownsModule = false,
  }) : id = 'pkcs11-${_nextId++}';

  factory Pkcs11CertificateProvider.forToken({
    required Pkcs11ModuleApi module,
    required Pkcs11Token token,
    Pkcs11Mechanism rsaMechanism = Pkcs11Mechanism.sha256RsaPkcs,
    bool ownsModule = false,
  }) =>
      Pkcs11CertificateProvider(
        module: module,
        slotId: token.slotId,
        tokenLabel: token.label,
        rsaMechanism: rsaMechanism,
        ownsModule: ownsModule,
      );

  static int _nextId = 1;

  final Pkcs11ModuleApi module;
  final int slotId;
  final String tokenLabel;
  final Pkcs11Mechanism rsaMechanism;
  final bool ownsModule;
  final Map<String, Pkcs11Certificate> _certificates =
      <String, Pkcs11Certificate>{};
  bool _closed = false;

  @override
  final String id;

  @override
  String get name => tokenLabel.trim().isEmpty
      ? 'Token PKCS#11 (slot $slotId)'
      : tokenLabel.trim();

  @override
  CertificateProviderKind get kind => CertificateProviderKind.pkcs11;

  @override
  CertificateAuthenticationMode get authenticationMode =>
      CertificateAuthenticationMode.applicationPin;

  @override
  bool get isAvailable => !_closed;

  @override
  Future<List<CryptoIdentity>> listIdentities({
    CertificateOperationContext context = const CertificateOperationContext(),
  }) =>
      Future<List<CryptoIdentity>>.sync(() {
        _checkOpen('listIdentities');
        final certificates = module.listCertificates(
          slotId: slotId,
          pin: context.pin,
        );
        _certificates.clear();
        final identities = <CryptoIdentity>[];
        for (final certificate in certificates) {
          final reference = certificate.idHex;
          final x509 = X509Certificate.parse(certificate.derBytes);
          _certificates[reference] = certificate;
          identities.add(
            CryptoIdentity(
              providerId: id,
              id: reference,
              label: certificate.label.trim().isEmpty
                  ? x509.commonName
                  : certificate.label.trim(),
              certificate: x509,
              metadata: <String, String>{
                'module': module.modulePath,
                'slot': '$slotId',
                'token': tokenLabel,
                'keyId': reference,
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
        final pin = context.pin;
        if (pin == null || pin.isEmpty) {
          throw CertificateProviderException(
            provider: name,
            operation: 'signSha256',
            message: 'PIN is required by this PKCS#11 provider',
          );
        }
        final certificate = _certificates[identity.id];
        if (certificate == null) {
          throw CertificateProviderException(
            provider: name,
            operation: 'signSha256',
            message: 'identity is stale; enumerate certificates again',
          );
        }
        final (input, mechanism) = switch (identity.publicKeyAlgorithm) {
          X509PublicKeyAlgorithm.rsa => (data, rsaMechanism),
          X509PublicKeyAlgorithm.ec => (
              Crypto.sha256(data),
              Pkcs11Mechanism.ecdsa
            ),
          X509PublicKeyAlgorithm.unknown => throw CertificateProviderException(
              provider: name,
              operation: 'signSha256',
              message: 'unsupported X.509 public key algorithm',
            ),
        };
        final signature = module.sign(
          slotId: slotId,
          pin: pin,
          keyId: certificate.id,
          data: input,
          mechanism: mechanism,
        );
        if (identity.publicKeyAlgorithm == X509PublicKeyAlgorithm.rsa) {
          return signature;
        }
        if (signature.length.isOdd) {
          throw CertificateProviderException(
            provider: name,
            operation: 'signSha256',
            message: 'PKCS#11 returned an invalid ECDSA signature',
          );
        }
        final componentLength = signature.length ~/ 2;
        return Der.sequence(<Uint8List>[
          Der.integerBytes(
            Uint8List.sublistView(signature, 0, componentLength),
          ),
          Der.integerBytes(
            Uint8List.sublistView(signature, componentLength),
          ),
        ]);
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
    if (ownsModule) module.close();
  }
}
