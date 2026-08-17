import 'dart:typed_data';
import '../../crypto/crypto.dart';

/// Algoritmo SHA-256 (FIPS PUB 180-4) com aceleração nativa via FFI e fallback automático para Puro Dart.
class PdfSha256 {
  /// Calcula o hash SHA-256 de um buffer de bytes [data].
  static Uint8List digest(Uint8List data) {
    return Crypto.sha256(data);
  }
}
