import 'dart:typed_data';

/// Interface unificada para serviços de criptografia e hashing no `dart_ui`.
abstract class CryptoBackend {
  /// Nome descritivo da implementação (ex: "Pure Dart", "Windows CNG (bcrypt.dll)", "macOS CommonCrypto", "Linux libcrypto").
  String get name;

  /// Retorna `true` se a implementação utiliza aceleração de hardware/SO nativa via FFI.
  bool get isNativeAccelerated;

  /// Calcula o hash SHA-256 (256 bits / 32 bytes).
  Uint8List sha256(Uint8List data);

  /// Calcula o hash SHA-384 (384 bits / 48 bytes).
  Uint8List sha384(Uint8List data);

  /// Calcula o hash SHA-512 (512 bits / 64 bytes).
  Uint8List sha512(Uint8List data);

  /// Calcula o hash SHA-1 (160 bits / 20 bytes).
  Uint8List sha1(Uint8List data);

  /// Calcula o hash MD5 (128 bits / 16 bytes).
  Uint8List md5(Uint8List data);

  /// Cifra dados usando AES em modo CBC com chave de 128, 192 ou 256 bits e IV de 16 bytes.
  Uint8List aesEncryptCbc(Uint8List key, Uint8List iv, Uint8List plaintext,
      {bool padding = true});

  /// Decifra dados usando AES em modo CBC com chave de 128, 192 ou 256 bits e IV de 16 bytes.
  Uint8List aesDecryptCbc(Uint8List key, Uint8List iv, Uint8List ciphertext,
      {bool padding = true});

  /// Cifra ou decifra dados usando o algoritmo de fluxo RC4 (ARC4) com chave arbitrária.
  Uint8List rc4(Uint8List key, Uint8List data);
}
