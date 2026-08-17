import 'dart:typed_data';
import 'crypto_backend.dart';
import 'ffi/ffi_crypto_backend_stub.dart'
    if (dart.library.ffi) 'ffi/ffi_crypto_backend_native.dart'
    if (dart.library.js_interop) 'web/web_crypto_backend.dart';

/// Ponto central de serviços criptográficos e hashing do `dart_ui`.
///
/// Utiliza aceleração de hardware e APIs nativas do sistema operacional (Windows CNG, macOS CommonCrypto, Linux OpenSSL)
/// via FFI sempre que disponíveis, com chaveamento e fallback automático para a implementação de alta performance em 100% Puro Dart.
class Crypto {
  static final CryptoBackend _instance = createPlatformCryptoBackend();

  /// Retorna o backend atualmente ativo em tempo de execução.
  static CryptoBackend get backend => _instance;

  /// Nome do backend em execução.
  static String get backendName => _instance.name;

  /// Indica se a aceleração nativa por FFI está ativa.
  static bool get isNativeAccelerated => _instance.isNativeAccelerated;

  /// Calcula o hash SHA-256 (32 bytes / 256 bits).
  static Uint8List sha256(Uint8List data) => _instance.sha256(data);

  /// Calcula o hash SHA-384 (48 bytes / 384 bits).
  static Uint8List sha384(Uint8List data) => _instance.sha384(data);

  /// Calcula o hash SHA-512 (64 bytes / 512 bits).
  static Uint8List sha512(Uint8List data) => _instance.sha512(data);

  /// Calcula o hash SHA-1 (20 bytes / 160 bits).
  static Uint8List sha1(Uint8List data) => _instance.sha1(data);

  /// Calcula o hash MD5 (16 bytes / 128 bits).
  static Uint8List md5(Uint8List data) => _instance.md5(data);

  /// Cifra [plaintext] usando AES no modo CBC com chave de 128, 192 ou 256 bits e IV de 16 bytes.
  static Uint8List aesEncryptCbc(
      Uint8List key, Uint8List iv, Uint8List plaintext,
      {bool padding = true}) {
    return _instance.aesEncryptCbc(key, iv, plaintext, padding: padding);
  }

  /// Decifra [ciphertext] usando AES no modo CBC com chave de 128, 192 ou 256 bits e IV de 16 bytes.
  static Uint8List aesDecryptCbc(
      Uint8List key, Uint8List iv, Uint8List ciphertext,
      {bool padding = true}) {
    return _instance.aesDecryptCbc(key, iv, ciphertext, padding: padding);
  }

  /// Cifra ou decifra dados com o algoritmo de fluxo RC4 (ARC4).
  static Uint8List rc4(Uint8List key, Uint8List data) {
    return _instance.rc4(key, data);
  }
}
