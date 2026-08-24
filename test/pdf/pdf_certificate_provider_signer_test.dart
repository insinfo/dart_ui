import 'dart:typed_data';

import 'package:dart_ui/crypto.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

import 'signing_fixture.dart';

void main() {
  test('adaptador encaminha identidade, dados e contexto ao provedor',
      () async {
    final provider = _FakeCertificateProvider();
    final identity = _identity(provider.id);
    final signer = PdfCertificateProviderSigner(
      provider: provider,
      identity: identity,
      context: const CertificateOperationContext(nativeWindowHandle: 42),
    );
    final input = Uint8List.fromList(const <int>[1, 2, 3]);

    final signature = await signer.sign(input);

    expect(signature, <int>[9, 8, 7]);
    expect(provider.signedData, input);
    expect(provider.identity, same(identity));
    expect(provider.context?.nativeWindowHandle, 42);
    expect(signer.certificateChain.single, identity.certificate.derBytes);
    expect(signer.algorithm, PdfSignatureAlgorithm.rsaSha256);
  });
}

CryptoIdentity _identity(String providerId) {
  final certificate = X509Certificate.parse(signingTestCertificate());
  return CryptoIdentity(
    providerId: providerId,
    id: 'identity',
    label: 'Certificado',
    certificate: certificate,
  );
}

final class _FakeCertificateProvider implements CertificateProvider {
  Uint8List? signedData;
  CryptoIdentity? identity;
  CertificateOperationContext? context;

  @override
  String get id => 'fake';
  @override
  String get name => 'Fake';
  @override
  CertificateProviderKind get kind => CertificateProviderKind.pkcs11;
  @override
  CertificateAuthenticationMode get authenticationMode =>
      CertificateAuthenticationMode.applicationPin;
  @override
  bool get isAvailable => true;

  @override
  Future<List<CryptoIdentity>> listIdentities({
    CertificateOperationContext context = const CertificateOperationContext(),
  }) async =>
      const <CryptoIdentity>[];

  @override
  Future<Uint8List> signSha256({
    required CryptoIdentity identity,
    required Uint8List data,
    CertificateOperationContext context = const CertificateOperationContext(),
  }) async {
    this.identity = identity;
    signedData = Uint8List.fromList(data);
    this.context = context;
    return Uint8List.fromList(const <int>[9, 8, 7]);
  }

  @override
  void close() {}
}
