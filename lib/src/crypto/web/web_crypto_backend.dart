import 'dart:js_interop';
import 'dart:typed_data';
import '../crypto_backend.dart';
import '../dart/pure_dart_crypto_backend.dart';

@JS('window.crypto.subtle')
external JSObject? get subtleCrypto;

@JS('window.crypto.getRandomValues')
external JSObject getRandomValues(JSObject array);

/// Implementação da Web Crypto API via JS Interop.
class WebCryptoBackend implements CryptoBackend {
  final PureDartCryptoBackend _fallback = const PureDartCryptoBackend();

  WebCryptoBackend._();

  static CryptoBackend create() {
    return WebCryptoBackend._();
  }

  @override
  String get name => 'Web Crypto API';

  @override
  bool get isNativeAccelerated => true;

  // No Web, a API é assíncrona. Como a interface do dart_ui é síncrona para hashes rápidos,
  // nós caímos para o fallback puro Dart se o usuário chamar os métodos síncronos.
  // Futuramente, a interface CryptoBackend poderia ter métodos async.

  @override
  Uint8List sha256(Uint8List data) => _fallback.sha256(data);

  @override
  Uint8List sha384(Uint8List data) => _fallback.sha384(data);

  @override
  Uint8List sha512(Uint8List data) => _fallback.sha512(data);

  @override
  Uint8List sha1(Uint8List data) => _fallback.sha1(data);

  @override
  Uint8List md5(Uint8List data) => _fallback.md5(data);

  // A Web Crypto API nao expoe MD5 nem hashing incremental sincrono.
  @override
  HashSink md5Sink() => _fallback.md5Sink();

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

CryptoBackend createPlatformCryptoBackend() {
  return WebCryptoBackend.create();
}
