import 'dart:typed_data';

/// Implementação do algoritmo de fluxo RC4 (ARC4) em 100% Puro Dart para descriptografia de PDF padrão (V1 e V2 / 40-128 bits).
class PureDartRc4 {
  /// Cifra ou decifra dados com RC4 (a operação é simétrica e idêntica em ambos os sentidos).
  static Uint8List process(Uint8List key, Uint8List data) {
    if (key.isEmpty || data.isEmpty) return Uint8List.fromList(data);

    // KSA (Key-Scheduling Algorithm)
    final s = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      s[i] = i;
    }

    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % key.length]) & 0xFF;
      final temp = s[i];
      s[i] = s[j];
      s[j] = temp;
    }

    // PRGA (Pseudo-Random Generation Algorithm)
    final output = Uint8List(data.length);
    var i = 0;
    j = 0;

    for (var k = 0; k < data.length; k++) {
      i = (i + 1) & 0xFF;
      j = (j + s[i]) & 0xFF;
      final temp = s[i];
      s[i] = s[j];
      s[j] = temp;

      final t = (s[i] + s[j]) & 0xFF;
      final kByte = s[t];
      output[k] = data[k] ^ kByte;
    }

    return output;
  }
}
