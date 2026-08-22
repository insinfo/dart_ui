import 'dart:typed_data';
import '../../crypto/crypto.dart';

/// Implementa os Handlers de Segurança do PDF (Standard Security Handler v1 a v6).
/// Deriva chaves a partir de senhas de Owner/User para criptografia RC4 ou AES.
class PdfSecurityHandler {
  final int
      revision; // 2 (RC4-40), 3 (RC4-128), 4 (AES-128/RC4-128), 5 (AES-256), 6 (AES-256 PDF 2.0)
  final Uint8List ownerKey; // /O
  final Uint8List userKey; // /U
  final int permissions; // /P
  final Uint8List fileId; // ID[0] from trailer
  final bool isAes;
  final int keyLength; // em bytes

  late final Uint8List encryptionKey;

  PdfSecurityHandler({
    required this.revision,
    required this.ownerKey,
    required this.userKey,
    required this.permissions,
    required this.fileId,
    this.isAes = false,
    this.keyLength = 16, // 128 bits default
    String password = '',
  }) {
    encryptionKey = _authenticate(password);
  }

  Uint8List _authenticate(String password) {
    // PDF authentication algorithm (ISO 32000-1 / 7.6.3)
    // Simplified for this phase. In a complete implementation, this performs MD5/SHA256
    // padding of the password and matching against the /O and /U hashes.
    // For now, we return a mock key or perform basic hashing.
    final passBytes = Uint8List.fromList(password.codeUnits);
    if (revision >= 5) {
      return Crypto.sha256(passBytes);
    }
    return Crypto.md5(passBytes);
  }

  /// Cifra o conteúdo de um objeto baseando-se no número do objeto e geração.
  Uint8List encryptContent(int objNum, int objGen, Uint8List data) {
    final objKey = _computeObjectKey(objNum, objGen);
    if (isAes) {
      // AES requires IV. No PDF, o IV vai colado no começo do ciphertext (16 bytes).
      final iv = Crypto.sha256(Uint8List.fromList([objNum, objGen]))
          .sublist(0, 16); // mock random
      final ciphertext = Crypto.aesEncryptCbc(objKey, iv, data, padding: true);
      final result = Uint8List(iv.length + ciphertext.length);
      result.setAll(0, iv);
      result.setAll(iv.length, ciphertext);
      return result;
    } else {
      // RC4
      return Crypto.rc4(objKey, data);
    }
  }

  /// Decifra o conteúdo de um objeto.
  Uint8List decryptContent(int objNum, int objGen, Uint8List data) {
    final objKey = _computeObjectKey(objNum, objGen);
    if (isAes) {
      if (data.length <= 16) return data; // Erro, sem IV
      final iv = data.sublist(0, 16);
      final ciphertext = data.sublist(16);
      return Crypto.aesDecryptCbc(objKey, iv, ciphertext, padding: true);
    } else {
      return Crypto.rc4(objKey, data);
    }
  }

  Uint8List _computeObjectKey(int objNum, int objGen) {
    if (revision >= 5) {
      return encryptionKey; // PDF 2.0 / AES-256 usa a chave direta
    }

    // Para algoritmos mais antigos, a chave do objeto é um MD5 da encryptionKey + objNum + objGen
    final data = Uint8List(encryptionKey.length + 5);
    data.setAll(0, encryptionKey);
    data[encryptionKey.length] = objNum & 0xFF;
    data[encryptionKey.length + 1] = (objNum >> 8) & 0xFF;
    data[encryptionKey.length + 2] = (objNum >> 16) & 0xFF;
    data[encryptionKey.length + 3] = objGen & 0xFF;
    data[encryptionKey.length + 4] = (objGen >> 8) & 0xFF;

    final hash = Crypto.md5(data);
    final finalLen =
        (encryptionKey.length + 5 > 16) ? 16 : encryptionKey.length + 5;
    return hash.sublist(0, finalLen);
  }
}
