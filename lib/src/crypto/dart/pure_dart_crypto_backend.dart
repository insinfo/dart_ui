import 'dart:typed_data';
import '../crypto_backend.dart';
import 'pure_dart_aes.dart';
import 'pure_dart_md5.dart';
import 'pure_dart_rc4.dart';
import 'pure_dart_sha.dart';

/// Implementação padrão em 100% Puro Dart de todos os serviços de criptografia.
class PureDartCryptoBackend implements CryptoBackend {
  const PureDartCryptoBackend();

  @override
  String get name => 'Pure Dart Crypto Engine';

  @override
  bool get isNativeAccelerated => false;

  @override
  Uint8List sha256(Uint8List data) => PureDartSha.sha256(data);

  @override
  Uint8List sha384(Uint8List data) => PureDartSha.sha512(data, is384: true);

  @override
  Uint8List sha512(Uint8List data) => PureDartSha.sha512(data, is384: false);

  @override
  Uint8List sha1(Uint8List data) => PureDartSha.sha1(data);

  @override
  Uint8List md5(Uint8List data) => PureDartMd5.digest(data);

  @override
  Uint8List aesEncryptCbc(Uint8List key, Uint8List iv, Uint8List plaintext,
      {bool padding = true}) {
    return PureDartAes.encryptCbc(key, iv, plaintext, padding: padding);
  }

  @override
  Uint8List aesDecryptCbc(Uint8List key, Uint8List iv, Uint8List ciphertext,
      {bool padding = true}) {
    return PureDartAes.decryptCbc(key, iv, ciphertext, padding: padding);
  }

  @override
  Uint8List rc4(Uint8List key, Uint8List data) {
    return PureDartRc4.process(key, data);
  }
}
