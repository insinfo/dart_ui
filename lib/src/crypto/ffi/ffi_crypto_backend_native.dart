import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../../ffi/native_memory.dart';
import '../crypto_backend.dart';
import '../dart/pure_dart_crypto_backend.dart';

/// Algoritmos de digest suportados, com o tamanho do resultado e o nome que
/// cada API nativa usa para pedi-lo.
enum _Digest {
  md5('MD5', 'MD5', 16),
  sha1('SHA1', 'SHA1', 20),
  sha256('SHA256', 'SHA256', 32),
  sha384('SHA384', 'SHA384', 48),
  sha512('SHA512', 'SHA512', 64);

  const _Digest(this.cngId, this.opensslId, this.length);

  /// Identificador CNG (`BCRYPT_*_ALGORITHM`).
  final String cngId;

  /// Nome aceito por `EVP_get_digestbyname` do OpenSSL.
  final String opensslId;

  /// Tamanho do digest em bytes.
  final int length;
}

// --- macOS CommonCrypto ---
typedef _CcDigestC = Pointer<Uint8> Function(
    Pointer<Uint8> data, Uint32 len, Pointer<Uint8> md);
typedef _CcDigestDart = Pointer<Uint8> Function(
    Pointer<Uint8> data, int len, Pointer<Uint8> md);

typedef _CcInitC = Int32 Function(Pointer<Uint8> ctx);
typedef _CcInitDart = int Function(Pointer<Uint8> ctx);
typedef _CcUpdateC = Int32 Function(
    Pointer<Uint8> ctx, Pointer<Uint8> data, Uint32 len);
typedef _CcUpdateDart = int Function(
    Pointer<Uint8> ctx, Pointer<Uint8> data, int len);
typedef _CcFinalC = Int32 Function(Pointer<Uint8> md, Pointer<Uint8> ctx);
typedef _CcFinalDart = int Function(Pointer<Uint8> md, Pointer<Uint8> ctx);

// --- Windows CNG (bcrypt.dll) ---
typedef _BCryptOpenAlgC = Int32 Function(Pointer<IntPtr> phAlgorithm,
    Pointer<Uint16> pszAlgId, Pointer<Uint16> pszImplementation, Uint32 flags);
typedef _BCryptOpenAlgDart = int Function(Pointer<IntPtr> phAlgorithm,
    Pointer<Uint16> pszAlgId, Pointer<Uint16> pszImplementation, int flags);

typedef _BCryptCloseAlgC = Int32 Function(IntPtr hAlgorithm, Uint32 flags);
typedef _BCryptCloseAlgDart = int Function(int hAlgorithm, int flags);

typedef _BCryptCreateHashC = Int32 Function(
    IntPtr hAlgorithm,
    Pointer<IntPtr> phHash,
    Pointer<Uint8> pbHashObject,
    Uint32 cbHashObject,
    Pointer<Uint8> pbSecret,
    Uint32 cbSecret,
    Uint32 flags);
typedef _BCryptCreateHashDart = int Function(
    int hAlgorithm,
    Pointer<IntPtr> phHash,
    Pointer<Uint8> pbHashObject,
    int cbHashObject,
    Pointer<Uint8> pbSecret,
    int cbSecret,
    int flags);

typedef _BCryptHashDataC = Int32 Function(
    IntPtr hHash, Pointer<Uint8> pbInput, Uint32 cbInput, Uint32 flags);
typedef _BCryptHashDataDart = int Function(
    int hHash, Pointer<Uint8> pbInput, int cbInput, int flags);

typedef _BCryptFinishHashC = Int32 Function(
    IntPtr hHash, Pointer<Uint8> pbOutput, Uint32 cbOutput, Uint32 flags);
typedef _BCryptFinishHashDart = int Function(
    int hHash, Pointer<Uint8> pbOutput, int cbOutput, int flags);

typedef _BCryptDestroyHashC = Int32 Function(IntPtr hHash);
typedef _BCryptDestroyHashDart = int Function(int hHash);

// --- Linux/Android OpenSSL (libcrypto) ---
typedef _EvpMdCtxNewC = Pointer<Void> Function();
typedef _EvpMdCtxFreeC = Void Function(Pointer<Void> ctx);
typedef _EvpMdCtxFreeDart = void Function(Pointer<Void> ctx);

typedef _EvpGetDigestByNameC = Pointer<Void> Function(Pointer<Uint8> name);
typedef _EvpGetDigestByNameDart = Pointer<Void> Function(Pointer<Uint8> name);

typedef _EvpDigestInitExC = Int32 Function(
    Pointer<Void> ctx, Pointer<Void> type, Pointer<Void> engine);
typedef _EvpDigestInitExDart = int Function(
    Pointer<Void> ctx, Pointer<Void> type, Pointer<Void> engine);

typedef _EvpDigestUpdateC = Int32 Function(
    Pointer<Void> ctx, Pointer<Uint8> data, IntPtr count);
typedef _EvpDigestUpdateDart = int Function(
    Pointer<Void> ctx, Pointer<Uint8> data, int count);

typedef _EvpDigestFinalExC = Int32 Function(
    Pointer<Void> ctx, Pointer<Uint8> md, Pointer<Uint32> size);
typedef _EvpDigestFinalExDart = int Function(
    Pointer<Void> ctx, Pointer<Uint8> md, Pointer<Uint32> size);

/// Backend de aceleração de criptografia via FFI utilizando as APIs nativas do SO (Windows CNG, macOS CommonCrypto, Linux OpenSSL).
///
/// Cada operação verifica se o símbolo nativo correspondente foi resolvido e,
/// se não foi, delega para [PureDartCryptoBackend]. Assim uma plataforma que
/// exporta só parte das funções continua acelerada no que dá, sem quebrar o
/// resto.
class NativeCryptoBackend implements CryptoBackend {
  final PureDartCryptoBackend _fallback = const PureDartCryptoBackend();

  DynamicLibrary? _nativeLib;
  String _platformName = 'Native OS Engine';

  _MacCommonCrypto? _mac;
  _WindowsCng? _cng;
  _OpenSslEvp? _evp;

  NativeCryptoBackend._() {
    _initBindings();
  }

  static CryptoBackend create() {
    try {
      final backend = NativeCryptoBackend._();
      if (backend._hasAnyDigestEngine) {
        return backend;
      }
    } catch (_) {
      // Fallback gracioso para puro Dart
    }
    return const PureDartCryptoBackend();
  }

  bool get _hasAnyDigestEngine => _mac != null || _cng != null || _evp != null;

  void _initBindings() {
    try {
      if (Platform.isMacOS || Platform.isIOS) {
        _nativeLib = DynamicLibrary.process();
        _platformName = 'macOS CommonCrypto (libSystem)';
        _mac = _MacCommonCrypto.bind(_nativeLib!);
      } else if (Platform.isLinux || Platform.isAndroid) {
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
        final lib = _nativeLib;
        if (lib != null) {
          _evp = _OpenSslEvp.bind(lib);
        }
      } else if (Platform.isWindows) {
        try {
          _nativeLib = DynamicLibrary.open('bcrypt.dll');
          _platformName = 'Windows CNG (bcrypt.dll)';
          _cng = _WindowsCng.bind(_nativeLib!);
        } catch (_) {}
      }
    } catch (_) {
      _nativeLib = null;
      _mac = null;
      _cng = null;
      _evp = null;
    }

    // Biblioteca abriu mas nenhum simbolo util saiu dela: nao ha aceleracao.
    if (!_hasAnyDigestEngine) {
      _nativeLib = null;
    }
  }

  @override
  String get name => _hasAnyDigestEngine ? _platformName : _fallback.name;

  @override
  bool get isNativeAccelerated => _hasAnyDigestEngine;

  @override
  Uint8List sha256(Uint8List data) =>
      _digest(_Digest.sha256, data) ?? _fallback.sha256(data);

  @override
  Uint8List sha384(Uint8List data) =>
      _digest(_Digest.sha384, data) ?? _fallback.sha384(data);

  @override
  Uint8List sha512(Uint8List data) =>
      _digest(_Digest.sha512, data) ?? _fallback.sha512(data);

  @override
  Uint8List sha1(Uint8List data) =>
      _digest(_Digest.sha1, data) ?? _fallback.sha1(data);

  @override
  Uint8List md5(Uint8List data) =>
      _digest(_Digest.md5, data) ?? _fallback.md5(data);

  @override
  HashSink md5Sink() =>
      _mac?.sink(_Digest.md5) ??
      _cng?.sink(_Digest.md5) ??
      _evp?.sink(_Digest.md5) ??
      _fallback.md5Sink();

  /// Devolve `null` quando a plataforma nao tem o simbolo, para o chamador cair
  /// no fallback.
  Uint8List? _digest(_Digest algorithm, Uint8List data) {
    return _mac?.oneShot(algorithm, data) ??
        _cng?.oneShot(algorithm, data) ??
        _evp?.oneShot(algorithm, data);
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
}

// ---------------------------------------------------------------------------
// Helpers de memoria nativa
// ---------------------------------------------------------------------------

Pointer<Uint8> _allocBytes(int byteCount) =>
    NativeAllocator.instance.allocate<Uint8>(byteCount > 0 ? byteCount : 1);

void _freePtr(Pointer<NativeType> ptr) {
  if (ptr.address != 0) {
    NativeAllocator.instance.free(ptr);
  }
}

/// Copia [data] para memoria nativa. O chamador libera.
Pointer<Uint8> _copyToNative(List<int> data) {
  final ptr = _allocBytes(data.length);
  if (data.isNotEmpty) {
    ptr.asTypedList(data.length).setAll(0, data);
  }
  return ptr;
}

/// String C terminada em NUL (ASCII), para `EVP_get_digestbyname`.
Pointer<Uint8> _toAscii(String value) {
  final units = value.codeUnits;
  final ptr = NativeAllocator.instance.allocate<Uint8>(units.length + 1);
  final view = ptr.asTypedList(units.length + 1);
  view.setAll(0, units);
  view[units.length] = 0;
  return ptr;
}

/// String UTF-16 terminada em NUL, para os `pszAlgId` do CNG.
Pointer<Uint16> _toUtf16(String value) {
  final units = value.codeUnits;
  final ptr = NativeAllocator.instance.allocate<Uint16>((units.length + 1) * 2);
  final view = ptr.asTypedList(units.length + 1);
  view.setAll(0, units);
  view[units.length] = 0;
  return ptr;
}

// ---------------------------------------------------------------------------
// macOS / iOS - CommonCrypto
// ---------------------------------------------------------------------------

/// `CC_MD5_CTX` tem 92 bytes e `CC_SHA512_CTX` 208; 256 cobre todos com folga.
const int _ccContextBytes = 256;

class _MacCommonCrypto {
  _MacCommonCrypto._(
      this._oneShotFns, this._md5Init, this._md5Update, this._md5Final);

  final Map<_Digest, _CcDigestDart> _oneShotFns;
  final _CcInitDart? _md5Init;
  final _CcUpdateDart? _md5Update;
  final _CcFinalDart? _md5Final;

  static _MacCommonCrypto? bind(DynamicLibrary lib) {
    final oneShot = <_Digest, _CcDigestDart>{};
    for (final entry in const {
      _Digest.md5: 'CC_MD5',
      _Digest.sha1: 'CC_SHA1',
      _Digest.sha256: 'CC_SHA256',
      _Digest.sha384: 'CC_SHA384',
      _Digest.sha512: 'CC_SHA512',
    }.entries) {
      try {
        oneShot[entry.key] =
            lib.lookupFunction<_CcDigestC, _CcDigestDart>(entry.value);
      } catch (_) {}
    }

    _CcInitDart? init;
    _CcUpdateDart? update;
    _CcFinalDart? finalize;
    try {
      init = lib.lookupFunction<_CcInitC, _CcInitDart>('CC_MD5_Init');
      update = lib.lookupFunction<_CcUpdateC, _CcUpdateDart>('CC_MD5_Update');
      finalize = lib.lookupFunction<_CcFinalC, _CcFinalDart>('CC_MD5_Final');
    } catch (_) {
      init = null;
      update = null;
      finalize = null;
    }

    if (oneShot.isEmpty && init == null) return null;
    return _MacCommonCrypto._(oneShot, init, update, finalize);
  }

  Uint8List? oneShot(_Digest algorithm, Uint8List data) {
    final fn = _oneShotFns[algorithm];
    if (fn == null) return null;

    final inPtr = _copyToNative(data);
    final outPtr = _allocBytes(algorithm.length);
    try {
      fn(inPtr, data.length, outPtr);
      return Uint8List.fromList(outPtr.asTypedList(algorithm.length));
    } finally {
      _freePtr(inPtr);
      _freePtr(outPtr);
    }
  }

  HashSink? sink(_Digest algorithm) {
    if (algorithm != _Digest.md5) return null;

    final init = _md5Init;
    final update = _md5Update;
    final finalize = _md5Final;
    if (init == null || update == null || finalize == null) return null;

    final ctx = _allocBytes(_ccContextBytes);
    ctx.asTypedList(_ccContextBytes).fillRange(0, _ccContextBytes, 0);
    if (init(ctx) != 1) {
      _freePtr(ctx);
      return null;
    }
    return _CcHashSink(ctx, update, finalize, algorithm.length);
  }
}

class _CcHashSink extends _NativeHashSink {
  _CcHashSink(this._ctx, this._update, this._finalize, this._length);

  final Pointer<Uint8> _ctx;
  final _CcUpdateDart _update;
  final _CcFinalDart _finalize;
  final int _length;

  @override
  void addChunk(Pointer<Uint8> data, int length) => _update(_ctx, data, length);

  @override
  Uint8List finish() {
    final outPtr = _allocBytes(_length);
    try {
      _finalize(outPtr, _ctx);
      return Uint8List.fromList(outPtr.asTypedList(_length));
    } finally {
      _freePtr(outPtr);
      _freePtr(_ctx);
    }
  }
}

// ---------------------------------------------------------------------------
// Windows - CNG (bcrypt.dll)
// ---------------------------------------------------------------------------

class _WindowsCng {
  _WindowsCng._(this._openAlg, this._closeAlg, this._createHash, this._hashData,
      this._finishHash, this._destroyHash);

  final _BCryptOpenAlgDart _openAlg;
  final _BCryptCloseAlgDart _closeAlg;
  final _BCryptCreateHashDart _createHash;
  final _BCryptHashDataDart _hashData;
  final _BCryptFinishHashDart _finishHash;
  final _BCryptDestroyHashDart _destroyHash;

  static _WindowsCng? bind(DynamicLibrary lib) {
    try {
      return _WindowsCng._(
        lib.lookupFunction<_BCryptOpenAlgC, _BCryptOpenAlgDart>(
            'BCryptOpenAlgorithmProvider'),
        lib.lookupFunction<_BCryptCloseAlgC, _BCryptCloseAlgDart>(
            'BCryptCloseAlgorithmProvider'),
        lib.lookupFunction<_BCryptCreateHashC, _BCryptCreateHashDart>(
            'BCryptCreateHash'),
        lib.lookupFunction<_BCryptHashDataC, _BCryptHashDataDart>(
            'BCryptHashData'),
        lib.lookupFunction<_BCryptFinishHashC, _BCryptFinishHashDart>(
            'BCryptFinishHash'),
        lib.lookupFunction<_BCryptDestroyHashC, _BCryptDestroyHashDart>(
            'BCryptDestroyHash'),
      );
    } catch (_) {
      return null;
    }
  }

  /// Abre provider + hash. Devolve `null` se qualquer NTSTATUS falhar, sempre
  /// desfazendo o que ja tinha sido aberto.
  ({int algorithm, int hash})? openHash(_Digest algorithm) {
    final algIdPtr = _toUtf16(algorithm.cngId);
    final algHandlePtr =
        NativeAllocator.instance.allocate<IntPtr>(sizeOf<IntPtr>());
    final hashHandlePtr =
        NativeAllocator.instance.allocate<IntPtr>(sizeOf<IntPtr>());
    try {
      algHandlePtr.value = 0;
      hashHandlePtr.value = 0;

      if (_openAlg(algHandlePtr, algIdPtr, nullptr, 0) != 0) return null;
      final algHandle = algHandlePtr.value;

      // pbHashObject nulo faz o CNG alocar o objeto internamente (Win8+).
      final status =
          _createHash(algHandle, hashHandlePtr, nullptr, 0, nullptr, 0, 0);
      if (status != 0) {
        _closeAlg(algHandle, 0);
        return null;
      }
      return (algorithm: algHandle, hash: hashHandlePtr.value);
    } finally {
      _freePtr(algIdPtr);
      _freePtr(algHandlePtr);
      _freePtr(hashHandlePtr);
    }
  }

  void closeHash(int hashHandle, int algHandle) {
    _destroyHash(hashHandle);
    _closeAlg(algHandle, 0);
  }

  int hashData(int hashHandle, Pointer<Uint8> data, int length) =>
      _hashData(hashHandle, data, length, 0);

  int finishHash(int hashHandle, Pointer<Uint8> out, int length) =>
      _finishHash(hashHandle, out, length, 0);

  Uint8List? oneShot(_Digest algorithm, Uint8List data) {
    final handles = openHash(algorithm);
    if (handles == null) return null;

    final inPtr = _copyToNative(data);
    final outPtr = _allocBytes(algorithm.length);
    try {
      if (hashData(handles.hash, inPtr, data.length) != 0) return null;
      if (finishHash(handles.hash, outPtr, algorithm.length) != 0) return null;
      return Uint8List.fromList(outPtr.asTypedList(algorithm.length));
    } finally {
      _freePtr(inPtr);
      _freePtr(outPtr);
      closeHash(handles.hash, handles.algorithm);
    }
  }

  HashSink? sink(_Digest algorithm) {
    final handles = openHash(algorithm);
    if (handles == null) return null;
    return _CngHashSink(
        this, handles.hash, handles.algorithm, algorithm.length);
  }
}

class _CngHashSink extends _NativeHashSink {
  _CngHashSink(this._cng, this._hash, this._alg, this._length);

  final _WindowsCng _cng;
  final int _hash;
  final int _alg;
  final int _length;

  @override
  void addChunk(Pointer<Uint8> data, int length) =>
      _cng.hashData(_hash, data, length);

  @override
  Uint8List finish() {
    final outPtr = _allocBytes(_length);
    try {
      _cng.finishHash(_hash, outPtr, _length);
      return Uint8List.fromList(outPtr.asTypedList(_length));
    } finally {
      _freePtr(outPtr);
      _cng.closeHash(_hash, _alg);
    }
  }
}

// ---------------------------------------------------------------------------
// Linux / Android - OpenSSL EVP
// ---------------------------------------------------------------------------

class _OpenSslEvp {
  _OpenSslEvp._(this._ctxNew, this._ctxFree, this._byName, this._initEx,
      this._update, this._finalEx);

  final _EvpMdCtxNewC _ctxNew;
  final _EvpMdCtxFreeDart _ctxFree;
  final _EvpGetDigestByNameDart _byName;
  final _EvpDigestInitExDart _initEx;
  final _EvpDigestUpdateDart _update;
  final _EvpDigestFinalExDart _finalEx;

  static _OpenSslEvp? bind(DynamicLibrary lib) {
    try {
      return _OpenSslEvp._(
        lib.lookupFunction<_EvpMdCtxNewC, _EvpMdCtxNewC>('EVP_MD_CTX_new'),
        lib.lookupFunction<_EvpMdCtxFreeC, _EvpMdCtxFreeDart>(
            'EVP_MD_CTX_free'),
        lib.lookupFunction<_EvpGetDigestByNameC, _EvpGetDigestByNameDart>(
            'EVP_get_digestbyname'),
        lib.lookupFunction<_EvpDigestInitExC, _EvpDigestInitExDart>(
            'EVP_DigestInit_ex'),
        lib.lookupFunction<_EvpDigestUpdateC, _EvpDigestUpdateDart>(
            'EVP_DigestUpdate'),
        lib.lookupFunction<_EvpDigestFinalExC, _EvpDigestFinalExDart>(
            'EVP_DigestFinal_ex'),
      );
    } catch (_) {
      return null;
    }
  }

  int update(Pointer<Void> ctx, Pointer<Uint8> data, int length) =>
      _update(ctx, data, length);

  int finalEx(Pointer<Void> ctx, Pointer<Uint8> out, Pointer<Uint32> size) =>
      _finalEx(ctx, out, size);

  void freeContext(Pointer<Void> ctx) => _ctxFree(ctx);

  /// Cria e inicializa um `EVP_MD_CTX`. Devolve `nullptr` se o algoritmo nao
  /// estiver disponivel no provider ativo - em OpenSSL 3 o MD5 fica de fora em
  /// builds FIPS.
  Pointer<Void> newContext(_Digest algorithm) {
    final namePtr = _toAscii(algorithm.opensslId);
    try {
      final md = _byName(namePtr);
      if (md == nullptr) return nullptr;

      final ctx = _ctxNew();
      if (ctx == nullptr) return nullptr;

      if (_initEx(ctx, md, nullptr) != 1) {
        _ctxFree(ctx);
        return nullptr;
      }
      return ctx;
    } finally {
      _freePtr(namePtr);
    }
  }

  Uint8List? oneShot(_Digest algorithm, Uint8List data) {
    final ctx = newContext(algorithm);
    if (ctx == nullptr) return null;

    final inPtr = _copyToNative(data);
    final outPtr = _allocBytes(algorithm.length);
    final sizePtr = NativeAllocator.instance.allocate<Uint32>(4);
    try {
      if (_update(ctx, inPtr, data.length) != 1) return null;
      if (_finalEx(ctx, outPtr, sizePtr) != 1) return null;
      return Uint8List.fromList(outPtr.asTypedList(algorithm.length));
    } finally {
      _freePtr(inPtr);
      _freePtr(outPtr);
      _freePtr(sizePtr);
      _ctxFree(ctx);
    }
  }

  HashSink? sink(_Digest algorithm) {
    final ctx = newContext(algorithm);
    if (ctx == nullptr) return null;
    return _EvpHashSink(this, ctx, algorithm.length);
  }
}

class _EvpHashSink extends _NativeHashSink {
  _EvpHashSink(this._ssl, this._ctx, this._length);

  final _OpenSslEvp _ssl;
  final Pointer<Void> _ctx;
  final int _length;

  @override
  void addChunk(Pointer<Uint8> data, int length) =>
      _ssl.update(_ctx, data, length);

  @override
  Uint8List finish() {
    final outPtr = _allocBytes(_length);
    final sizePtr = NativeAllocator.instance.allocate<Uint32>(4);
    try {
      _ssl.finalEx(_ctx, outPtr, sizePtr);
      return Uint8List.fromList(outPtr.asTypedList(_length));
    } finally {
      _freePtr(outPtr);
      _freePtr(sizePtr);
      _ssl.freeContext(_ctx);
    }
  }
}

// ---------------------------------------------------------------------------
// Base comum dos sinks nativos
// ---------------------------------------------------------------------------

/// Cuida do que os tres backends fazem igual: levar cada pedaco para memoria
/// nativa, garantir que o contexto seja liberado uma vez so, e tornar [close]
/// idempotente.
abstract class _NativeHashSink implements HashSink {
  Uint8List? _digest;

  /// Repassa [length] bytes ja em memoria nativa para a API do SO.
  void addChunk(Pointer<Uint8> data, int length);

  /// Finaliza o contexto nativo e o libera. Chamado no maximo uma vez.
  Uint8List finish();

  @override
  void add(List<int> data) {
    if (_digest != null) {
      throw StateError('HashSink.add() apos close()');
    }
    if (data.isEmpty) return;

    final ptr = _copyToNative(data);
    try {
      addChunk(ptr, data.length);
    } finally {
      _freePtr(ptr);
    }
  }

  @override
  Uint8List close() => _digest ??= finish();
}

/// Cria o backend nativo quando em plataforma com suporte a FFI.
CryptoBackend createPlatformCryptoBackend() {
  return NativeCryptoBackend.create();
}
