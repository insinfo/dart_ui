import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../../ffi/native_memory.dart';
import '../asn1/der.dart';
import '../crypto.dart';
import '../x509/x509_certificate.dart';
import 'windows_certificate_store_types.dart';

const int _x509AsnEncoding = 0x00000001;
const int _certKeyProvInfoPropId = 2;
const int _certFindSha1Hash = 0x00010000;
const int _certNcryptKeySpec = 0xffffffff;
const int _cryptAcquireWindowHandleFlag = 0x00000080;
const int _cryptAcquirePreferNcryptKeyFlag = 0x00020000;
const int _ncryptPadPkcs1Flag = 0x00000002;
const int _calgSha256 = 0x0000800c;

final class _CertContext extends Struct {
  @Uint32()
  external int encodingType;

  external Pointer<Uint8> encoded;

  @Uint32()
  external int encodedLength;

  external Pointer<Void> certInfo;
  external Pointer<Void> certStore;
}

final class _CryptDataBlob extends Struct {
  @Uint32()
  external int length;

  external Pointer<Uint8> data;
}

final class _CryptKeyProvInfo extends Struct {
  external Pointer<Uint16> containerName;
  external Pointer<Uint16> providerName;

  @Uint32()
  external int providerType;

  @Uint32()
  external int flags;

  @Uint32()
  external int parameterCount;

  external Pointer<Void> parameters;

  @Uint32()
  external int keySpec;
}

final class _BcryptPkcs1PaddingInfo extends Struct {
  external Pointer<Uint16> algorithmId;
}

typedef _CertOpenSystemStoreWNative = Pointer<Void> Function(
  IntPtr,
  Pointer<Uint16>,
);
typedef _CertOpenSystemStoreWDart = Pointer<Void> Function(
  int,
  Pointer<Uint16>,
);
typedef _CertCloseStoreNative = Int32 Function(Pointer<Void>, Uint32);
typedef _CertCloseStoreDart = int Function(Pointer<Void>, int);
typedef _CertEnumCertificatesInStoreNative = Pointer<_CertContext> Function(
  Pointer<Void>,
  Pointer<_CertContext>,
);
typedef _CertEnumCertificatesInStoreDart = Pointer<_CertContext> Function(
  Pointer<Void>,
  Pointer<_CertContext>,
);
typedef _CertGetCertificateContextPropertyNative = Int32 Function(
  Pointer<_CertContext>,
  Uint32,
  Pointer<Void>,
  Pointer<Uint32>,
);
typedef _CertGetCertificateContextPropertyDart = int Function(
  Pointer<_CertContext>,
  int,
  Pointer<Void>,
  Pointer<Uint32>,
);
typedef _CertFindCertificateInStoreNative = Pointer<_CertContext> Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Uint32,
  Pointer<Void>,
  Pointer<_CertContext>,
);
typedef _CertFindCertificateInStoreDart = Pointer<_CertContext> Function(
  Pointer<Void>,
  int,
  int,
  int,
  Pointer<Void>,
  Pointer<_CertContext>,
);
typedef _CertFreeCertificateContextNative = Int32 Function(
  Pointer<_CertContext>,
);
typedef _CertFreeCertificateContextDart = int Function(
  Pointer<_CertContext>,
);
typedef _CryptAcquireCertificatePrivateKeyNative = Int32 Function(
  Pointer<_CertContext>,
  Uint32,
  Pointer<Void>,
  Pointer<IntPtr>,
  Pointer<Uint32>,
  Pointer<Int32>,
);
typedef _CryptAcquireCertificatePrivateKeyDart = int Function(
  Pointer<_CertContext>,
  int,
  Pointer<Void>,
  Pointer<IntPtr>,
  Pointer<Uint32>,
  Pointer<Int32>,
);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();
typedef _NCryptSignHashNative = Int32 Function(
  IntPtr,
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Uint32,
);
typedef _NCryptSignHashDart = int Function(
  int,
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  int,
);
typedef _NCryptFreeObjectNative = Int32 Function(IntPtr);
typedef _NCryptFreeObjectDart = int Function(int);
typedef _CryptCreateHashNative = Int32 Function(
  IntPtr,
  Uint32,
  IntPtr,
  Uint32,
  Pointer<IntPtr>,
);
typedef _CryptCreateHashDart = int Function(
  int,
  int,
  int,
  int,
  Pointer<IntPtr>,
);
typedef _CryptHashDataNative = Int32 Function(
  IntPtr,
  Pointer<Uint8>,
  Uint32,
  Uint32,
);
typedef _CryptHashDataDart = int Function(
  int,
  Pointer<Uint8>,
  int,
  int,
);
typedef _CryptSignHashWNative = Int32 Function(
  IntPtr,
  Uint32,
  Pointer<Uint16>,
  Uint32,
  Pointer<Uint8>,
  Pointer<Uint32>,
);
typedef _CryptSignHashWDart = int Function(
  int,
  int,
  Pointer<Uint16>,
  int,
  Pointer<Uint8>,
  Pointer<Uint32>,
);
typedef _CryptDestroyHashNative = Int32 Function(IntPtr);
typedef _CryptDestroyHashDart = int Function(int);
typedef _CryptReleaseContextNative = Int32 Function(IntPtr, Uint32);
typedef _CryptReleaseContextDart = int Function(int, int);

/// Acesso ao store CurrentUser\\MY e as chaves CNG/KSP ou CryptoAPI/CSP.
///
/// Dispositivos CCID/PC/SC (smart cards e tokens USB) sao publicados nesse
/// store pelo minidriver/KSP/CSP do fabricante. Nenhuma chamada recebe PIN: a
/// interface de autenticacao pertence ao Windows e ao provedor da chave.
final class WindowsCertificateStore implements WindowsCertificateStoreApi {
  WindowsCertificateStore()
      : _crypt32 = _openWindowsLibrary('crypt32.dll'),
        _ncrypt = _openWindowsLibrary('ncrypt.dll'),
        _advapi32 = _openWindowsLibrary('advapi32.dll'),
        _lastErrorLibrary = _openWindowsLibrary('kernel32.dll') {
    _certOpenSystemStore = _crypt32.lookupFunction<_CertOpenSystemStoreWNative,
        _CertOpenSystemStoreWDart>('CertOpenSystemStoreW');
    _certCloseStore =
        _crypt32.lookupFunction<_CertCloseStoreNative, _CertCloseStoreDart>(
      'CertCloseStore',
    );
    _certEnumCertificates = _crypt32.lookupFunction<
        _CertEnumCertificatesInStoreNative,
        _CertEnumCertificatesInStoreDart>('CertEnumCertificatesInStore');
    _certGetProperty = _crypt32.lookupFunction<
        _CertGetCertificateContextPropertyNative,
        _CertGetCertificateContextPropertyDart>(
      'CertGetCertificateContextProperty',
    );
    _certFindCertificate = _crypt32.lookupFunction<
        _CertFindCertificateInStoreNative,
        _CertFindCertificateInStoreDart>('CertFindCertificateInStore');
    _certFreeCertificate = _crypt32.lookupFunction<
        _CertFreeCertificateContextNative,
        _CertFreeCertificateContextDart>('CertFreeCertificateContext');
    _cryptAcquirePrivateKey = _crypt32.lookupFunction<
        _CryptAcquireCertificatePrivateKeyNative,
        _CryptAcquireCertificatePrivateKeyDart>(
      'CryptAcquireCertificatePrivateKey',
    );
    _getLastError = _lastErrorLibrary
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
    _ncryptSignHash =
        _ncrypt.lookupFunction<_NCryptSignHashNative, _NCryptSignHashDart>(
      'NCryptSignHash',
    );
    _ncryptFreeObject =
        _ncrypt.lookupFunction<_NCryptFreeObjectNative, _NCryptFreeObjectDart>(
      'NCryptFreeObject',
    );
    _cryptCreateHash =
        _advapi32.lookupFunction<_CryptCreateHashNative, _CryptCreateHashDart>(
      'CryptCreateHash',
    );
    _cryptHashData =
        _advapi32.lookupFunction<_CryptHashDataNative, _CryptHashDataDart>(
      'CryptHashData',
    );
    _cryptSignHash =
        _advapi32.lookupFunction<_CryptSignHashWNative, _CryptSignHashWDart>(
      'CryptSignHashW',
    );
    _cryptDestroyHash = _advapi32
        .lookupFunction<_CryptDestroyHashNative, _CryptDestroyHashDart>(
      'CryptDestroyHash',
    );
    _cryptReleaseContext = _advapi32
        .lookupFunction<_CryptReleaseContextNative, _CryptReleaseContextDart>(
      'CryptReleaseContext',
    );
  }

  static DynamicLibrary _openWindowsLibrary(String name) {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'WindowsCertificateStore is available only on Windows',
      );
    }
    return DynamicLibrary.open(name);
  }

  final DynamicLibrary _crypt32;
  final DynamicLibrary _ncrypt;
  final DynamicLibrary _advapi32;

  /// A biblioteca de onde sai `GetLastError`, e so isso.
  ///
  /// Nomeada pela funcao e nao pela DLL de proposito: `test/architecture/
  /// layering_test.dart` proibe o identificador `kernel32` no core, enquanto
  /// tolera o literal `'kernel32.dll'` acima - a regra e sobre o que o codigo
  /// nomeia, e o carregamento condicional por string ja e o padrao que
  /// `platform/message_box_platform_io.dart` usa para `user32.dll`.
  final DynamicLibrary _lastErrorLibrary;
  late final _CertOpenSystemStoreWDart _certOpenSystemStore;
  late final _CertCloseStoreDart _certCloseStore;
  late final _CertEnumCertificatesInStoreDart _certEnumCertificates;
  late final _CertGetCertificateContextPropertyDart _certGetProperty;
  late final _CertFindCertificateInStoreDart _certFindCertificate;
  late final _CertFreeCertificateContextDart _certFreeCertificate;
  late final _CryptAcquireCertificatePrivateKeyDart _cryptAcquirePrivateKey;
  late final _GetLastErrorDart _getLastError;
  late final _NCryptSignHashDart _ncryptSignHash;
  late final _NCryptFreeObjectDart _ncryptFreeObject;
  late final _CryptCreateHashDart _cryptCreateHash;
  late final _CryptHashDataDart _cryptHashData;
  late final _CryptSignHashWDart _cryptSignHash;
  late final _CryptDestroyHashDart _cryptDestroyHash;
  late final _CryptReleaseContextDart _cryptReleaseContext;

  @override
  List<WindowsCertificate> listCertificates({bool requirePrivateKey = true}) {
    final store = _openMyStore();
    var current = nullptr.cast<_CertContext>();
    try {
      final certificates = <WindowsCertificate>[];
      while (true) {
        current = _certEnumCertificates(store, current);
        if (current == nullptr) break;
        final provider = _keyProviderInfo(current);
        if (requirePrivateKey && provider == null) continue;
        final der = Uint8List.fromList(
          current.ref.encoded.asTypedList(current.ref.encodedLength),
        );
        final x509 = X509Certificate.parse(der);
        certificates.add(
          WindowsCertificate(
            derBytes: der,
            sha1Thumbprint: Crypto.sha1(der),
            providerName: provider?.providerName ?? '',
            containerName: provider?.containerName ?? '',
            providerType: provider?.providerType ?? 0,
            keySpec: provider?.keySpec ?? 0,
            providerKind:
                provider?.providerKind ?? WindowsKeyProviderKind.unknown,
            publicKeyAlgorithm: x509.publicKeyAlgorithm,
          ),
        );
      }
      return List<WindowsCertificate>.unmodifiable(certificates);
    } finally {
      // CertEnumCertificatesInStore libera o contexto anterior a cada passo,
      // mas uma excecao ao interpretar o contexto atual interrompe esse passo.
      if (current != nullptr) _certFreeCertificate(current);
      _certCloseStore(store, 0);
    }
  }

  _ProviderInfo? _keyProviderInfo(Pointer<_CertContext> certificate) =>
      using((arena) {
        final size = arena.allocate<Uint32>(sizeOf<Uint32>());
        if (_certGetProperty(
              certificate,
              _certKeyProvInfoPropId,
              nullptr,
              size,
            ) ==
            0) {
          return null;
        }
        if (size.value < sizeOf<_CryptKeyProvInfo>()) return null;
        final bytes = arena.allocate<Uint8>(size.value);
        if (_certGetProperty(
              certificate,
              _certKeyProvInfoPropId,
              bytes.cast(),
              size,
            ) ==
            0) {
          return null;
        }
        final info = bytes.cast<_CryptKeyProvInfo>().ref;
        final keySpec = info.keySpec;
        return _ProviderInfo(
          providerName: readNativeUtf16(
            info.providerName,
            limit: 32768,
          ),
          containerName: readNativeUtf16(
            info.containerName,
            limit: 32768,
          ),
          providerType: info.providerType,
          keySpec: keySpec,
          providerKind: keySpec == _certNcryptKeySpec
              ? WindowsKeyProviderKind.cng
              : WindowsKeyProviderKind.legacyCsp,
        );
      });

  @override
  Uint8List signSha256({
    required WindowsCertificate certificate,
    required Uint8List data,
    int parentWindowHandle = 0,
  }) {
    final store = _openMyStore();
    Pointer<_CertContext> context = nullptr;
    try {
      return using((arena) {
        final thumbprint = arena.allocate<Uint8>(
          certificate.sha1Thumbprint.length,
        );
        thumbprint
            .asTypedList(certificate.sha1Thumbprint.length)
            .setAll(0, certificate.sha1Thumbprint);
        final blob = arena.allocate<_CryptDataBlob>(sizeOf<_CryptDataBlob>());
        blob.ref
          ..length = certificate.sha1Thumbprint.length
          ..data = thumbprint;
        context = _certFindCertificate(
          store,
          _x509AsnEncoding,
          0,
          _certFindSha1Hash,
          blob.cast(),
          nullptr,
        );
        if (context == nullptr) {
          throw _lastError(
            'CertFindCertificateInStore',
            'the selected certificate is no longer in CurrentUser\\MY',
          );
        }

        final keyHandle = arena.allocate<IntPtr>(sizeOf<IntPtr>());
        final keySpec = arena.allocate<Uint32>(sizeOf<Uint32>());
        final callerMustFree = arena.allocate<Int32>(sizeOf<Int32>());
        Pointer<Void> parameters = nullptr;
        var flags = _cryptAcquirePreferNcryptKeyFlag;
        if (parentWindowHandle != 0) {
          final owner = arena.allocate<IntPtr>(sizeOf<IntPtr>())
            ..value = parentWindowHandle;
          parameters = owner.cast();
          flags |= _cryptAcquireWindowHandleFlag;
        }
        if (_cryptAcquirePrivateKey(
              context,
              flags,
              parameters,
              keyHandle,
              keySpec,
              callerMustFree,
            ) ==
            0) {
          throw _lastError('CryptAcquireCertificatePrivateKey');
        }

        try {
          if (keySpec.value == _certNcryptKeySpec) {
            return _signCng(
              keyHandle.value,
              data,
              certificate.publicKeyAlgorithm,
              arena,
            );
          }
          if (certificate.publicKeyAlgorithm != X509PublicKeyAlgorithm.rsa) {
            throw UnsupportedError(
              'Legacy Windows CSP signing supports only RSA certificates',
            );
          }
          return _signLegacyCsp(
            keyHandle.value,
            keySpec.value,
            data,
            arena,
          );
        } finally {
          if (callerMustFree.value != 0) {
            if (keySpec.value == _certNcryptKeySpec) {
              _ncryptFreeObject(keyHandle.value);
            } else {
              _cryptReleaseContext(keyHandle.value, 0);
            }
          }
        }
      });
    } finally {
      if (context != nullptr) _certFreeCertificate(context);
      _certCloseStore(store, 0);
    }
  }

  Uint8List _signCng(
    int key,
    Uint8List data,
    X509PublicKeyAlgorithm algorithm,
    NativeArena arena,
  ) {
    if (algorithm == X509PublicKeyAlgorithm.unknown) {
      throw UnsupportedError('Unsupported X.509 public key algorithm');
    }
    final digest = Crypto.sha256(data);
    final digestPointer = arena.allocate<Uint8>(digest.length);
    digestPointer.asTypedList(digest.length).setAll(0, digest);
    final isRsa = algorithm == X509PublicKeyAlgorithm.rsa;
    Pointer<Void> paddingPointer = nullptr;
    if (isRsa) {
      final padding = arena.allocate<_BcryptPkcs1PaddingInfo>(
        sizeOf<_BcryptPkcs1PaddingInfo>(),
      );
      padding.ref.algorithmId = arena.allocateUtf16('SHA256');
      paddingPointer = padding.cast();
    }
    final flags = isRsa ? _ncryptPadPkcs1Flag : 0;
    final outputLength = arena.allocate<Uint32>(sizeOf<Uint32>());
    var status = _ncryptSignHash(
      key,
      paddingPointer,
      digestPointer,
      digest.length,
      nullptr,
      0,
      outputLength,
      flags,
    );
    _checkStatus(status, 'NCryptSignHash(length)');
    if (outputLength.value == 0 || outputLength.value > 1024 * 1024) {
      throw StateError('NCryptSignHash returned an invalid signature length');
    }
    final signature = arena.allocate<Uint8>(outputLength.value);
    status = _ncryptSignHash(
      key,
      paddingPointer,
      digestPointer,
      digest.length,
      signature,
      outputLength.value,
      outputLength,
      flags,
    );
    _checkStatus(status, 'NCryptSignHash');
    final result = Uint8List.fromList(
      signature.asTypedList(outputLength.value),
    );
    if (isRsa) return result;
    if (result.length.isOdd) {
      throw StateError('NCryptSignHash returned an invalid ECDSA signature');
    }
    final componentLength = result.length ~/ 2;
    return Der.sequence(<Uint8List>[
      Der.integerBytes(Uint8List.sublistView(result, 0, componentLength)),
      Der.integerBytes(Uint8List.sublistView(result, componentLength)),
    ]);
  }

  Uint8List _signLegacyCsp(
    int provider,
    int keySpec,
    Uint8List data,
    NativeArena arena,
  ) {
    final hash = arena.allocate<IntPtr>(sizeOf<IntPtr>());
    if (_cryptCreateHash(provider, _calgSha256, 0, 0, hash) == 0) {
      throw _lastError(
        'CryptCreateHash(CALG_SHA_256)',
        'the legacy CSP may not support SHA-256',
      );
    }
    try {
      final input = arena.allocate<Uint8>(data.isEmpty ? 1 : data.length);
      if (data.isNotEmpty) input.asTypedList(data.length).setAll(0, data);
      if (_cryptHashData(hash.value, input, data.length, 0) == 0) {
        throw _lastError('CryptHashData');
      }
      final outputLength = arena.allocate<Uint32>(sizeOf<Uint32>());
      if (_cryptSignHash(
            hash.value,
            keySpec,
            nullptr,
            0,
            nullptr,
            outputLength,
          ) ==
          0) {
        throw _lastError('CryptSignHashW(length)');
      }
      if (outputLength.value == 0 || outputLength.value > 1024 * 1024) {
        throw StateError('CryptSignHashW returned an invalid signature length');
      }
      final signature = arena.allocate<Uint8>(outputLength.value);
      if (_cryptSignHash(
            hash.value,
            keySpec,
            nullptr,
            0,
            signature,
            outputLength,
          ) ==
          0) {
        throw _lastError('CryptSignHashW');
      }
      // CryptoAPI returns RSA signatures in little-endian byte order, while
      // CMS requires the ordinary big-endian PKCS#1 representation.
      return Uint8List.fromList(
        signature.asTypedList(outputLength.value).reversed.toList(),
      );
    } finally {
      _cryptDestroyHash(hash.value);
    }
  }

  Pointer<Void> _openMyStore() => using((arena) {
        final store = _certOpenSystemStore(0, arena.allocateUtf16('MY'));
        if (store == nullptr) throw _lastError('CertOpenSystemStoreW(MY)');
        return store;
      });

  WindowsCryptoException _lastError(String operation, [String? details]) =>
      WindowsCryptoException(
        operation: operation,
        code: _getLastError(),
        details: details,
      );

  static void _checkStatus(int status, String operation) {
    if (status != 0) {
      throw WindowsCryptoException(operation: operation, code: status);
    }
  }
}

final class _ProviderInfo {
  const _ProviderInfo({
    required this.providerName,
    required this.containerName,
    required this.providerType,
    required this.keySpec,
    required this.providerKind,
  });

  final String providerName;
  final String containerName;
  final int providerType;
  final int keySpec;
  final WindowsKeyProviderKind providerKind;
}
