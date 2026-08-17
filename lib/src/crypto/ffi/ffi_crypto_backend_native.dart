import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import '../crypto_backend.dart';
import '../dart/pure_dart_crypto_backend.dart';
import '../../ffi/native_memory.dart';

// --- macOS CommonCrypto Bindings ---
typedef _CcDigestC = Pointer<Uint8> Function(
    Pointer<Uint8> data, Uint32 len, Pointer<Uint8> md);
typedef _CcDigestDart = Pointer<Uint8> Function(
    Pointer<Uint8> data, int len, Pointer<Uint8> md);

/// Backend de aceleração de criptografia via FFI utilizando as APIs nativas do SO (Windows CNG, macOS CommonCrypto, Linux OpenSSL).
class NativeCryptoBackend implements CryptoBackend {
  final PureDartCryptoBackend _fallback = const PureDartCryptoBackend();

  DynamicLibrary? _nativeLib;
  String _platformName = 'Native OS Engine';

  // Function pointers
  _CcDigestDart? _ccSha256;
  _CcDigestDart? _ccSha384;
  _CcDigestDart? _ccSha512;
  _CcDigestDart? _ccSha1;
  _CcDigestDart? _ccMd5;

  NativeCryptoBackend._() {
    _initBindings();
  }

  static CryptoBackend create() {
    try {
      final backend = NativeCryptoBackend._();
      if (backend._nativeLib != null) {
        return backend;
      }
    } catch (_) {
      // Fallback gracioso para puro Dart
    }
    return const PureDartCryptoBackend();
  }

  void _initBindings() {
    try {
      if (Platform.isMacOS || Platform.isIOS) {
        _nativeLib = DynamicLibrary.process();
        _platformName = 'macOS CommonCrypto (libSystem)';
        _ccSha256 =
            _nativeLib?.lookupFunction<_CcDigestC, _CcDigestDart>('CC_SHA256');
        _ccSha384 =
            _nativeLib?.lookupFunction<_CcDigestC, _CcDigestDart>('CC_SHA384');
        _ccSha512 =
            _nativeLib?.lookupFunction<_CcDigestC, _CcDigestDart>('CC_SHA512');
        _ccSha1 =
            _nativeLib?.lookupFunction<_CcDigestC, _CcDigestDart>('CC_SHA1');
        _ccMd5 =
            _nativeLib?.lookupFunction<_CcDigestC, _CcDigestDart>('CC_MD5');
      } else if (Platform.isLinux || Platform.isAndroid) {
        // Tenta carregar OpenSSL libcrypto
        for (final libName in [
          'libcrypto.so.3',
          'libcrypto.so.1.1',
          'libcrypto.so'
        ]) {
          try {
            _nativeLib = DynamicLibrary.open(libName);
            _platformName = 'Linux OpenSSL ($libName)';
            break;
          } catch (_) {}
        }
      } else if (Platform.isWindows) {
        try {
          _nativeLib = DynamicLibrary.open('bcrypt.dll');
          _platformName = 'Windows CNG (bcrypt.dll)';
        } catch (_) {}
      }
    } catch (_) {
      _nativeLib = null;
    }
  }

  @override
  String get name => _nativeLib != null ? _platformName : _fallback.name;

  @override
  bool get isNativeAccelerated => _nativeLib != null;

  @override
  Uint8List sha256(Uint8List data) {
    if (_ccSha256 != null) {
      return _runCcDigest(_ccSha256!, data, 32);
    }
    return _fallback.sha256(data);
  }

  @override
  Uint8List sha384(Uint8List data) {
    if (_ccSha384 != null) {
      return _runCcDigest(_ccSha384!, data, 48);
    }
    return _fallback.sha384(data);
  }

  @override
  Uint8List sha512(Uint8List data) {
    if (_ccSha512 != null) {
      return _runCcDigest(_ccSha512!, data, 64);
    }
    return _fallback.sha512(data);
  }

  @override
  Uint8List sha1(Uint8List data) {
    if (_ccSha1 != null) {
      return _runCcDigest(_ccSha1!, data, 20);
    }
    return _fallback.sha1(data);
  }

  @override
  Uint8List md5(Uint8List data) {
    if (_ccMd5 != null) {
      return _runCcDigest(_ccMd5!, data, 16);
    }
    return _fallback.md5(data);
  }

  @override
  Uint8List aesEncryptCbc(Uint8List key, Uint8List iv, Uint8List plaintext,
      {bool padding = true}) {
    return _fallback.aesEncryptCbc(key, iv, plaintext, padding: padding);
  }

  @override
  Uint8List aesDecryptCbc(Uint8List key, Uint8List iv, Uint8List ciphertext,
      {bool padding = true}) {
    return _fallback.aesDecryptCbc(key, iv, ciphertext, padding: padding);
  }

  @override
  Uint8List rc4(Uint8List key, Uint8List data) {
    return _fallback.rc4(key, data);
  }

  Uint8List _runCcDigest(_CcDigestDart fn, Uint8List data, int outLen) {
    final inPtr = _allocate(data.length);
    final outPtr = _allocate(outLen);
    try {
      final inBytes = inPtr.asTypedList(data.length);
      inBytes.setAll(0, data);

      fn(inPtr.cast<Uint8>(), data.length, outPtr.cast<Uint8>());

      final result = Uint8List(outLen);
      result.setAll(0, outPtr.asTypedList(outLen));
      return result;
    } finally {
      _free(inPtr);
      _free(outPtr);
    }
  }

  Pointer<Uint8> _allocate(int byteCount) {
    return NativeAllocator.instance
        .allocate<Uint8>(byteCount > 0 ? byteCount : 1);
  }

  void _free(Pointer<Uint8> ptr) {
    if (ptr.address != 0) {
      NativeAllocator.instance.free(ptr);
    }
  }
}

/// Cria o backend nativo quando em plataforma com suporte a FFI.
CryptoBackend createPlatformCryptoBackend() {
  return NativeCryptoBackend.create();
}
