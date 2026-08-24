import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/crypto.dart';
import 'package:test/test.dart';

import '../pdf/signing_fixture.dart';

void main() {
  group('CertificateProvider multiplataforma', () {
    test('Windows normaliza store, identidade, HWND e assinatura', () async {
      final store = _FakeWindowsStore();
      final provider = WindowsCertificateProvider(store: store);

      final identities = await provider.listIdentities();
      final signature = await provider.signSha256(
        identity: identities.single,
        data: Uint8List.fromList(const <int>[1, 2, 3]),
        context: const CertificateOperationContext(nativeWindowHandle: 42),
      );

      expect(provider.kind, CertificateProviderKind.windowsSystem);
      expect(provider.authenticationMode,
          CertificateAuthenticationMode.providerUi);
      expect(identities.single.providerId, provider.id);
      expect(identities.single.certificate.commonName, isNotEmpty);
      expect(signature, <int>[7, 8, 9]);
      expect(store.parentWindowHandle, 42);
    });

    test('PKCS#11 normaliza slot, certificado, PIN e assinatura', () async {
      final module = _FakePkcs11Module();
      final provider = Pkcs11CertificateProvider(
        module: module,
        slotId: 7,
        tokenLabel: 'SafeSign',
      );
      const context = CertificateOperationContext(pin: '1234');

      final identities = await provider.listIdentities(context: context);
      final signature = await provider.signSha256(
        identity: identities.single,
        data: Uint8List.fromList(const <int>[4, 5, 6]),
        context: context,
      );

      expect(provider.kind, CertificateProviderKind.pkcs11);
      expect(provider.authenticationMode,
          CertificateAuthenticationMode.applicationPin);
      expect(identities.single.metadata['slot'], '7');
      expect(module.lastPin, '1234');
      expect(module.lastSlot, 7);
      expect(signature, <int>[6, 5, 4]);
    });

    test('PKCS#11 converte ECDSA P1363 para DER', () async {
      final module = _FakePkcs11Module(
        certificateDer: ecdsaSigningTestCertificate(),
        signature: Uint8List.fromList(List<int>.generate(64, (i) => i + 1)),
      );
      final provider = Pkcs11CertificateProvider(
        module: module,
        slotId: 9,
        tokenLabel: 'SafeSign EC',
      );
      const context = CertificateOperationContext(pin: '1234');
      final identity = (await provider.listIdentities(context: context)).single;

      final signature = await provider.signSha256(
        identity: identity,
        data: Uint8List.fromList(const <int>[1, 2, 3]),
        context: context,
      );

      expect(identity.publicKeyAlgorithm, X509PublicKeyAlgorithm.ec);
      expect(module.lastMechanism, Pkcs11Mechanism.ecdsa);
      expect(module.lastData, hasLength(32), reason: 'CKM_ECDSA receives hash');
      expect(signature.first, 0x30, reason: 'CMS receives DER (r, s)');
    });

    test('um provedor recusa identidade criada por outro', () async {
      final first = WindowsCertificateProvider(store: _FakeWindowsStore());
      final second = WindowsCertificateProvider(store: _FakeWindowsStore());
      final identity = (await first.listIdentities()).single;

      expect(
        second.signSha256(
          identity: identity,
          data: Uint8List(1),
        ),
        throwsA(isA<CertificateProviderException>()),
      );
    });

    test('providers nativos informam disponibilidade sem abrir UI', () {
      final macos = MacOsCertificateProvider();
      addTearDown(macos.close);
      expect(macos.isAvailable, Platform.isMacOS);

      if (!Platform.isLinux) {
        final result = LinuxCertificateProviderDiscovery.discover();
        expect(result.providers, isEmpty);
        expect(result.failures, isEmpty);
      }
    });
  });
}

final class _FakeWindowsStore implements WindowsCertificateStoreApi {
  int? parentWindowHandle;

  @override
  List<WindowsCertificate> listCertificates({bool requirePrivateKey = true}) {
    final der = signingTestCertificate();
    return <WindowsCertificate>[
      WindowsCertificate(
        derBytes: der,
        sha1Thumbprint: Uint8List(20)..[0] = 1,
        providerName: 'Microsoft Smart Card Key Storage Provider',
        containerName: 'container',
        providerType: 0,
        keySpec: 0xffffffff,
        providerKind: WindowsKeyProviderKind.cng,
        publicKeyAlgorithm: X509PublicKeyAlgorithm.rsa,
      ),
    ];
  }

  @override
  Uint8List signSha256({
    required WindowsCertificate certificate,
    required Uint8List data,
    int parentWindowHandle = 0,
  }) {
    this.parentWindowHandle = parentWindowHandle;
    return Uint8List.fromList(const <int>[7, 8, 9]);
  }
}

final class _FakePkcs11Module implements Pkcs11ModuleApi {
  _FakePkcs11Module({Uint8List? certificateDer, this.signature})
      : certificateDer = certificateDer ?? signingTestCertificate(),
        assert(signature == null || signature.isNotEmpty);

  final Uint8List certificateDer;
  final Uint8List? signature;
  String? lastPin;
  int? lastSlot;
  Uint8List? lastData;
  Pkcs11Mechanism? lastMechanism;

  @override
  String get modulePath => '/usr/lib/libaetpkss.so';

  @override
  List<Pkcs11Token> listTokens() => const <Pkcs11Token>[];

  @override
  List<Pkcs11Certificate> listCertificates({
    required int slotId,
    String? pin,
  }) {
    lastPin = pin;
    lastSlot = slotId;
    return <Pkcs11Certificate>[
      Pkcs11Certificate(
        id: Uint8List.fromList(const <int>[1, 2]),
        label: 'A3',
        derBytes: certificateDer,
      ),
    ];
  }

  @override
  Uint8List sign({
    required int slotId,
    required String pin,
    required Uint8List keyId,
    required Uint8List data,
    Pkcs11Mechanism mechanism = Pkcs11Mechanism.sha256RsaPkcs,
  }) {
    lastPin = pin;
    lastSlot = slotId;
    lastData = Uint8List.fromList(data);
    lastMechanism = mechanism;
    return signature == null
        ? Uint8List.fromList(data.reversed.toList())
        : Uint8List.fromList(signature!);
  }

  @override
  void close() {}
}
