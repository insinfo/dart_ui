import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../../ffi/native_memory.dart';
import '../certificate_provider.dart';
import '../crypto.dart';
import '../x509/x509_certificate.dart';

const int _errSecSuccess = 0;
const int _errSecItemNotFound = -25300;

typedef _SecItemCopyMatchingNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _SecItemCopyMatchingDart = int Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _SecIdentityCopyCertificateNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _SecIdentityCopyCertificateDart = int Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _SecIdentityCopyPrivateKeyNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _SecIdentityCopyPrivateKeyDart = int Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _SecCertificateCopyDataNative = Pointer<Void> Function(Pointer<Void>);
typedef _SecCertificateCopyDataDart = Pointer<Void> Function(Pointer<Void>);
typedef _SecKeyCreateSignatureNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _SecKeyCreateSignatureDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _CfDictionaryCreateNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
  IntPtr,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _CfDictionaryCreateDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
  int,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _CfArrayGetCountNative = IntPtr Function(Pointer<Void>);
typedef _CfArrayGetCountDart = int Function(Pointer<Void>);
typedef _CfArrayGetValueAtIndexNative = Pointer<Void> Function(
  Pointer<Void>,
  IntPtr,
);
typedef _CfArrayGetValueAtIndexDart = Pointer<Void> Function(
  Pointer<Void>,
  int,
);
typedef _CfDataCreateNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
);
typedef _CfDataCreateDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
);
typedef _CfDataGetLengthNative = IntPtr Function(Pointer<Void>);
typedef _CfDataGetLengthDart = int Function(Pointer<Void>);
typedef _CfDataGetBytePtrNative = Pointer<Uint8> Function(Pointer<Void>);
typedef _CfDataGetBytePtrDart = Pointer<Uint8> Function(Pointer<Void>);
typedef _CfRetainNative = Pointer<Void> Function(Pointer<Void>);
typedef _CfRetainDart = Pointer<Void> Function(Pointer<Void>);
typedef _CfReleaseNative = Void Function(Pointer<Void>);
typedef _CfReleaseDart = void Function(Pointer<Void>);

/// Provedor de identidades do Keychain usando `Security.framework`.
///
/// Chaves de smart cards publicadas por CryptoTokenKit aparecem como
/// `SecIdentity`. A autenticacao e o PIN permanecem na UI segura do macOS.
final class MacOsCertificateProvider implements CertificateProvider {
  MacOsCertificateProvider()
      : id = 'macos-system-${_nextId++}',
        _bindings = Platform.isMacOS ? _MacOsSecurityBindings() : null;

  static int _nextId = 1;

  final _MacOsSecurityBindings? _bindings;
  final Map<String, Pointer<Void>> _identityHandles = <String, Pointer<Void>>{};
  bool _closed = false;

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
  bool get isAvailable => !_closed && _bindings != null;

  @override
  Future<List<CryptoIdentity>> listIdentities({
    CertificateOperationContext context = const CertificateOperationContext(),
  }) =>
      Future<List<CryptoIdentity>>.sync(() {
        final bindings = _requireBindings('listIdentities');
        _releaseIdentityHandles(bindings);
        final result = <CryptoIdentity>[];
        for (final record in bindings.listIdentities()) {
          try {
            final certificate = X509Certificate.parse(record.derBytes);
            final reference = _hex(Crypto.sha256(record.derBytes));
            final retained = bindings.retain(record.identity);
            _identityHandles[reference] = retained;
            result.add(
              CryptoIdentity(
                providerId: id,
                id: reference,
                label: certificate.commonName,
                certificate: certificate,
                metadata: <String, String>{
                  'store': 'Keychain',
                  'technology': 'Security.framework/CryptoTokenKit',
                  'fingerprintSha256': reference,
                },
              ),
            );
          } finally {
            bindings.release(record.identity);
          }
        }
        return List<CryptoIdentity>.unmodifiable(result);
      });

  @override
  Future<Uint8List> signSha256({
    required CryptoIdentity identity,
    required Uint8List data,
    CertificateOperationContext context = const CertificateOperationContext(),
  }) =>
      Future<Uint8List>.sync(() {
        final bindings = _requireBindings('signSha256');
        if (identity.providerId != id) {
          throw CertificateProviderException(
            provider: name,
            operation: 'signSha256',
            message: 'identity belongs to another provider',
          );
        }
        final handle = _identityHandles[identity.id];
        if (handle == null) {
          throw CertificateProviderException(
            provider: name,
            operation: 'signSha256',
            message: 'identity is stale; enumerate certificates again',
          );
        }
        return bindings.signSha256(
          identity: handle,
          algorithm: identity.publicKeyAlgorithm,
          data: data,
        );
      });

  _MacOsSecurityBindings _requireBindings(String operation) {
    if (_closed) {
      throw CertificateProviderException(
        provider: name,
        operation: operation,
        message: 'provider is closed',
      );
    }
    final bindings = _bindings;
    if (bindings == null) {
      throw CertificateProviderException(
        provider: name,
        operation: operation,
        message: 'Security.framework is available only on macOS',
      );
    }
    return bindings;
  }

  void _releaseIdentityHandles(_MacOsSecurityBindings bindings) {
    for (final handle in _identityHandles.values) {
      bindings.release(handle);
    }
    _identityHandles.clear();
  }

  @override
  void close() {
    if (_closed) return;
    final bindings = _bindings;
    if (bindings != null) _releaseIdentityHandles(bindings);
    _closed = true;
  }
}

final class _MacOsIdentityRecord {
  const _MacOsIdentityRecord(this.identity, this.derBytes);

  /// Referencia retida uma vez; o consumidor deve libera-la.
  final Pointer<Void> identity;
  final Uint8List derBytes;
}

final class _MacOsSecurityBindings {
  _MacOsSecurityBindings()
      : _security = DynamicLibrary.open(
          '/System/Library/Frameworks/Security.framework/Security',
        ),
        _coreFoundation = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
        ) {
    _secItemCopyMatching = _security.lookupFunction<_SecItemCopyMatchingNative,
        _SecItemCopyMatchingDart>('SecItemCopyMatching');
    _secIdentityCopyCertificate = _security.lookupFunction<
        _SecIdentityCopyCertificateNative,
        _SecIdentityCopyCertificateDart>('SecIdentityCopyCertificate');
    _secIdentityCopyPrivateKey = _security.lookupFunction<
        _SecIdentityCopyPrivateKeyNative,
        _SecIdentityCopyPrivateKeyDart>('SecIdentityCopyPrivateKey');
    _secCertificateCopyData = _security.lookupFunction<
        _SecCertificateCopyDataNative,
        _SecCertificateCopyDataDart>('SecCertificateCopyData');
    _secKeyCreateSignature = _security.lookupFunction<
        _SecKeyCreateSignatureNative,
        _SecKeyCreateSignatureDart>('SecKeyCreateSignature');
    _cfDictionaryCreate = _coreFoundation.lookupFunction<
        _CfDictionaryCreateNative,
        _CfDictionaryCreateDart>('CFDictionaryCreate');
    _cfArrayGetCount = _coreFoundation.lookupFunction<_CfArrayGetCountNative,
        _CfArrayGetCountDart>('CFArrayGetCount');
    _cfArrayGetValueAtIndex = _coreFoundation.lookupFunction<
        _CfArrayGetValueAtIndexNative,
        _CfArrayGetValueAtIndexDart>('CFArrayGetValueAtIndex');
    _cfDataCreate = _coreFoundation
        .lookupFunction<_CfDataCreateNative, _CfDataCreateDart>('CFDataCreate');
    _cfDataGetLength = _coreFoundation.lookupFunction<_CfDataGetLengthNative,
        _CfDataGetLengthDart>('CFDataGetLength');
    _cfDataGetBytePtr = _coreFoundation.lookupFunction<_CfDataGetBytePtrNative,
        _CfDataGetBytePtrDart>('CFDataGetBytePtr');
    _cfRetain = _coreFoundation
        .lookupFunction<_CfRetainNative, _CfRetainDart>('CFRetain');
    _cfRelease = _coreFoundation
        .lookupFunction<_CfReleaseNative, _CfReleaseDart>('CFRelease');
  }

  final DynamicLibrary _security;
  final DynamicLibrary _coreFoundation;
  late final _SecItemCopyMatchingDart _secItemCopyMatching;
  late final _SecIdentityCopyCertificateDart _secIdentityCopyCertificate;
  late final _SecIdentityCopyPrivateKeyDart _secIdentityCopyPrivateKey;
  late final _SecCertificateCopyDataDart _secCertificateCopyData;
  late final _SecKeyCreateSignatureDart _secKeyCreateSignature;
  late final _CfDictionaryCreateDart _cfDictionaryCreate;
  late final _CfArrayGetCountDart _cfArrayGetCount;
  late final _CfArrayGetValueAtIndexDart _cfArrayGetValueAtIndex;
  late final _CfDataCreateDart _cfDataCreate;
  late final _CfDataGetLengthDart _cfDataGetLength;
  late final _CfDataGetBytePtrDart _cfDataGetBytePtr;
  late final _CfRetainDart _cfRetain;
  late final _CfReleaseDart _cfRelease;

  Pointer<Void> _constant(String name) =>
      _security.lookup<Pointer<Void>>(name).value;

  Pointer<Void> _cfConstant(String name) =>
      _coreFoundation.lookup<Pointer<Void>>(name).value;

  List<_MacOsIdentityRecord> listIdentities() => using((arena) {
        final keys = arena.allocate<Pointer<Void>>(
          sizeOf<Pointer<Void>>() * 3,
        );
        final values = arena.allocate<Pointer<Void>>(
          sizeOf<Pointer<Void>>() * 3,
        );
        keys[0] = _constant('kSecClass');
        values[0] = _constant('kSecClassIdentity');
        keys[1] = _constant('kSecReturnRef');
        values[1] = _cfConstant('kCFBooleanTrue');
        keys[2] = _constant('kSecMatchLimit');
        values[2] = _constant('kSecMatchLimitAll');
        final query = _cfDictionaryCreate(
          nullptr,
          keys,
          values,
          3,
          nullptr,
          nullptr,
        );
        if (query == nullptr) {
          throw StateError('CFDictionaryCreate returned null');
        }
        final output = arena.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
        try {
          final status = _secItemCopyMatching(query, output);
          if (status == _errSecItemNotFound) return <_MacOsIdentityRecord>[];
          _checkStatus(status, 'SecItemCopyMatching');
          final array = output.value;
          if (array == nullptr) return <_MacOsIdentityRecord>[];
          try {
            final count = _cfArrayGetCount(array);
            final result = <_MacOsIdentityRecord>[];
            for (var index = 0; index < count; index++) {
              final borrowedIdentity = _cfArrayGetValueAtIndex(array, index);
              final identity = retain(borrowedIdentity);
              try {
                result.add(
                  _MacOsIdentityRecord(identity, _certificateBytes(identity)),
                );
              } on Object {
                release(identity);
                rethrow;
              }
            }
            return result;
          } finally {
            release(array);
          }
        } finally {
          release(query);
        }
      });

  Uint8List _certificateBytes(Pointer<Void> identity) => using((arena) {
        final output = arena.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
        _checkStatus(
          _secIdentityCopyCertificate(identity, output),
          'SecIdentityCopyCertificate',
        );
        final certificate = output.value;
        if (certificate == nullptr) {
          throw StateError('SecIdentityCopyCertificate returned null');
        }
        try {
          final data = _secCertificateCopyData(certificate);
          if (data == nullptr) {
            throw StateError('SecCertificateCopyData returned null');
          }
          try {
            return _copyData(data);
          } finally {
            release(data);
          }
        } finally {
          release(certificate);
        }
      });

  Uint8List signSha256({
    required Pointer<Void> identity,
    required X509PublicKeyAlgorithm algorithm,
    required Uint8List data,
  }) =>
      using((arena) {
        final keyOutput =
            arena.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
        _checkStatus(
          _secIdentityCopyPrivateKey(identity, keyOutput),
          'SecIdentityCopyPrivateKey',
        );
        final key = keyOutput.value;
        if (key == nullptr) {
          throw StateError('SecIdentityCopyPrivateKey returned null');
        }
        try {
          final input = arena.allocate<Uint8>(data.length);
          input.asTypedList(data.length).setAll(0, data);
          final inputData = _cfDataCreate(nullptr, input, data.length);
          if (inputData == nullptr) {
            throw StateError('CFDataCreate returned null');
          }
          try {
            final securityAlgorithm = switch (algorithm) {
              X509PublicKeyAlgorithm.rsa => _constant(
                  'kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256',
                ),
              X509PublicKeyAlgorithm.ec => _constant(
                  'kSecKeyAlgorithmECDSASignatureMessageX962SHA256',
                ),
              X509PublicKeyAlgorithm.unknown => throw UnsupportedError(
                  'Unsupported X.509 public key algorithm',
                ),
            };
            final error =
                arena.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
            final signature = _secKeyCreateSignature(
              key,
              securityAlgorithm,
              inputData,
              error,
            );
            if (signature == nullptr) {
              if (error.value != nullptr) release(error.value);
              throw StateError('SecKeyCreateSignature failed');
            }
            try {
              return _copyData(signature);
            } finally {
              release(signature);
              if (error.value != nullptr) release(error.value);
            }
          } finally {
            release(inputData);
          }
        } finally {
          release(key);
        }
      });

  Uint8List _copyData(Pointer<Void> data) {
    final length = _cfDataGetLength(data);
    if (length < 0) throw StateError('CFData has a negative length');
    final bytes = _cfDataGetBytePtr(data);
    return Uint8List.fromList(bytes.asTypedList(length));
  }

  Pointer<Void> retain(Pointer<Void> value) => _cfRetain(value);

  void release(Pointer<Void> value) {
    if (value != nullptr) _cfRelease(value);
  }

  void _checkStatus(int status, String operation) {
    if (status != _errSecSuccess) {
      throw StateError('$operation failed with OSStatus $status');
    }
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
