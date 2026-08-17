import 'dart:typed_data';

/// Implementação do algoritmo AES (Rijndael - FIPS PUB 197) em 100% Puro Dart para cifragem/decifragem de streams e documentos PDF.
class PureDartAes {
  static const List<int> _sBox = [
    0x63,
    0x7c,
    0x77,
    0x7b,
    0xf2,
    0x6b,
    0x6f,
    0xc5,
    0x30,
    0x01,
    0x67,
    0x2b,
    0xfe,
    0xd7,
    0xab,
    0x76,
    0xca,
    0x82,
    0xc9,
    0x7d,
    0xfa,
    0x59,
    0x47,
    0xf0,
    0xad,
    0xd4,
    0xa2,
    0xaf,
    0x9c,
    0xa4,
    0x72,
    0xc0,
    0xb7,
    0xfd,
    0x93,
    0x26,
    0x36,
    0x3f,
    0xf7,
    0xcc,
    0x34,
    0xa5,
    0xe5,
    0xf1,
    0x71,
    0xd8,
    0x31,
    0x15,
    0x04,
    0xc7,
    0x23,
    0xc3,
    0x18,
    0x96,
    0x05,
    0x9a,
    0x07,
    0x12,
    0x80,
    0xe2,
    0xeb,
    0x27,
    0xb2,
    0x75,
    0x09,
    0x83,
    0x2c,
    0x1a,
    0x1b,
    0x6e,
    0x5a,
    0xa0,
    0x52,
    0x3b,
    0xd6,
    0xb3,
    0x29,
    0xe3,
    0x2f,
    0x84,
    0x53,
    0xd1,
    0x00,
    0xed,
    0x20,
    0xfc,
    0xb1,
    0x5b,
    0x6a,
    0xcb,
    0xbe,
    0x39,
    0x4a,
    0x4c,
    0x58,
    0xcf,
    0xd0,
    0xef,
    0xaa,
    0xfb,
    0x43,
    0x4d,
    0x33,
    0x85,
    0x45,
    0xf9,
    0x02,
    0x7f,
    0x50,
    0x3c,
    0x9f,
    0xa8,
    0x51,
    0xa3,
    0x40,
    0x8f,
    0x92,
    0x9d,
    0x38,
    0xf5,
    0xbc,
    0xb6,
    0xda,
    0x21,
    0x10,
    0xff,
    0xf3,
    0xd2,
    0xcd,
    0x0c,
    0x13,
    0xec,
    0x5f,
    0x97,
    0x44,
    0x17,
    0xc4,
    0xa7,
    0x7e,
    0x3d,
    0x64,
    0x5d,
    0x19,
    0x73,
    0x60,
    0x81,
    0x4f,
    0xdc,
    0x22,
    0x2a,
    0x90,
    0x88,
    0x46,
    0xee,
    0xb8,
    0x14,
    0xde,
    0x5e,
    0x0b,
    0xdb,
    0xe0,
    0x32,
    0x3a,
    0x0a,
    0x49,
    0x06,
    0x24,
    0x5c,
    0xc2,
    0xd3,
    0xac,
    0x62,
    0x91,
    0x95,
    0xe4,
    0x79,
    0xe7,
    0xc8,
    0x37,
    0x6d,
    0x8d,
    0xd5,
    0x4e,
    0xa9,
    0x6c,
    0x56,
    0xf4,
    0xea,
    0x65,
    0x7a,
    0xae,
    0x08,
    0xba,
    0x78,
    0x25,
    0x2e,
    0x1c,
    0xa6,
    0xb4,
    0xc6,
    0xe8,
    0xdd,
    0x74,
    0x1f,
    0x4b,
    0xbd,
    0x8b,
    0x8a,
    0x70,
    0x3e,
    0xb5,
    0x66,
    0x48,
    0x03,
    0xf6,
    0x0e,
    0x61,
    0x35,
    0x57,
    0xb9,
    0x86,
    0xc1,
    0x1d,
    0x9e,
    0xe1,
    0xf8,
    0x98,
    0x11,
    0x69,
    0xd9,
    0x8e,
    0x94,
    0x9b,
    0x1e,
    0x87,
    0xe9,
    0xce,
    0x55,
    0x28,
    0xdf,
    0x8c,
    0xa1,
    0x89,
    0x0d,
    0xbf,
    0xe6,
    0x42,
    0x68,
    0x41,
    0x99,
    0x2d,
    0x0f,
    0xb0,
    0x54,
    0xbb,
    0x16
  ];

  static const List<int> _invSBox = [
    0x52,
    0x09,
    0x6a,
    0xd5,
    0x30,
    0x36,
    0xa5,
    0x38,
    0xbf,
    0x40,
    0xa3,
    0x9e,
    0x81,
    0xf3,
    0xd7,
    0xfb,
    0x7c,
    0xe3,
    0x39,
    0x82,
    0x9b,
    0x2f,
    0xff,
    0x87,
    0x34,
    0x8e,
    0x43,
    0x44,
    0xc4,
    0xde,
    0xe9,
    0xcb,
    0x54,
    0x7b,
    0x94,
    0x32,
    0xa6,
    0xc2,
    0x23,
    0x3d,
    0xee,
    0x4c,
    0x95,
    0x0b,
    0x42,
    0xfa,
    0xc3,
    0x4e,
    0x08,
    0x2e,
    0xa1,
    0x66,
    0x28,
    0xd9,
    0x24,
    0xb2,
    0x76,
    0x5b,
    0xa2,
    0x49,
    0x6d,
    0x8b,
    0xd1,
    0x25,
    0x72,
    0xf8,
    0xf6,
    0x64,
    0x86,
    0x68,
    0x98,
    0x16,
    0xd4,
    0xa4,
    0x5c,
    0xcc,
    0x5d,
    0x65,
    0xb6,
    0x92,
    0x6c,
    0x70,
    0x48,
    0x50,
    0xfd,
    0xed,
    0xb9,
    0xda,
    0x5e,
    0x15,
    0x46,
    0x57,
    0xa7,
    0x8d,
    0x9d,
    0x84,
    0x90,
    0xd8,
    0xab,
    0x00,
    0x8c,
    0xbc,
    0xd3,
    0x0a,
    0xf7,
    0xe4,
    0x58,
    0x05,
    0xb8,
    0xb3,
    0x45,
    0x06,
    0xd0,
    0x2c,
    0x1e,
    0x8f,
    0xca,
    0x3f,
    0x0f,
    0x02,
    0xc1,
    0xaf,
    0xbd,
    0x03,
    0x01,
    0x13,
    0x8a,
    0x6b,
    0x3a,
    0x91,
    0x11,
    0x41,
    0x4f,
    0x67,
    0xdc,
    0xea,
    0x97,
    0xf2,
    0xcf,
    0xce,
    0xf0,
    0xb4,
    0xe6,
    0x73,
    0x96,
    0xac,
    0x74,
    0x22,
    0xe7,
    0xad,
    0x35,
    0x85,
    0xe2,
    0xf9,
    0x37,
    0xe8,
    0x1c,
    0x75,
    0xdf,
    0x6e,
    0x47,
    0xf1,
    0x1a,
    0x71,
    0x1d,
    0x29,
    0xc5,
    0x89,
    0x6f,
    0xb7,
    0x62,
    0x0e,
    0xaa,
    0x18,
    0xbe,
    0x1b,
    0xfc,
    0x56,
    0x3e,
    0x4b,
    0xc6,
    0xd2,
    0x79,
    0x20,
    0x9a,
    0xdb,
    0xc0,
    0xfe,
    0x78,
    0xcd,
    0x5a,
    0xf4,
    0x1f,
    0xdd,
    0xa8,
    0x33,
    0x88,
    0x07,
    0xc7,
    0x31,
    0xb1,
    0x12,
    0x10,
    0x59,
    0x27,
    0x80,
    0xec,
    0x5f,
    0x60,
    0x51,
    0x7f,
    0xa9,
    0x19,
    0xb5,
    0x4a,
    0x0d,
    0x2d,
    0xe5,
    0x7a,
    0x9f,
    0x93,
    0xc9,
    0x9c,
    0xef,
    0xa0,
    0xe0,
    0x3b,
    0x4d,
    0xae,
    0x2a,
    0xf5,
    0xb0,
    0xc8,
    0xeb,
    0xbb,
    0x3c,
    0x83,
    0x53,
    0x99,
    0x61,
    0x17,
    0x2b,
    0x04,
    0x7e,
    0xba,
    0x77,
    0xd6,
    0x26,
    0xe1,
    0x69,
    0x14,
    0x63,
    0x55,
    0x21,
    0x0c,
    0x7d
  ];

  static const List<int> _rCon = [
    0x00,
    0x01,
    0x02,
    0x04,
    0x08,
    0x10,
    0x20,
    0x40,
    0x80,
    0x1b,
    0x36
  ];

  /// Cifra dados em modo CBC com PKCS#7 padding opcional.
  static Uint8List encryptCbc(Uint8List key, Uint8List iv, Uint8List plaintext,
      {bool padding = true}) {
    final expandedKey = _expandKey(key);
    final numRounds = key.length == 16 ? 10 : (key.length == 24 ? 12 : 14);

    final padLen = padding ? (16 - (plaintext.length % 16)) : 0;
    final padded = Uint8List(plaintext.length + padLen);
    padded.setAll(0, plaintext);
    if (padding) {
      for (var i = plaintext.length; i < padded.length; i++) {
        padded[i] = padLen;
      }
    }

    final output = Uint8List(padded.length);
    final block = Uint8List(16);
    final currentIv = Uint8List.fromList(iv);

    for (var i = 0; i < padded.length; i += 16) {
      for (var j = 0; j < 16; j++) {
        block[j] = padded[i + j] ^ currentIv[j];
      }

      _cipher(block, expandedKey, numRounds);

      output.setRange(i, i + 16, block);
      currentIv.setAll(0, block);
    }

    return output;
  }

  /// Decifra dados em modo CBC com remoção de PKCS#7 padding.
  static Uint8List decryptCbc(Uint8List key, Uint8List iv, Uint8List ciphertext,
      {bool padding = true}) {
    final expandedKey = _expandKey(key);
    final numRounds = key.length == 16 ? 10 : (key.length == 24 ? 12 : 14);

    final output = Uint8List(ciphertext.length);
    final block = Uint8List(16);
    final currentIv = Uint8List.fromList(iv);
    final nextIv = Uint8List(16);

    for (var i = 0; i < ciphertext.length; i += 16) {
      nextIv.setRange(0, 16, ciphertext.sublist(i, i + 16));
      block.setRange(0, 16, nextIv);

      _invCipher(block, expandedKey, numRounds);

      for (var j = 0; j < 16; j++) {
        output[i + j] = block[j] ^ currentIv[j];
      }

      currentIv.setAll(0, nextIv);
    }

    if (padding && output.isNotEmpty) {
      final padLen = output.last;
      if (padLen > 0 && padLen <= 16 && padLen <= output.length) {
        var valid = true;
        for (var i = output.length - padLen; i < output.length; i++) {
          if (output[i] != padLen) {
            valid = false;
            break;
          }
        }
        if (valid) {
          return output.sublist(0, output.length - padLen);
        }
      }
    }

    return output;
  }

  static Uint32List _expandKey(Uint8List key) {
    final nk = key.length ~/ 4;
    final nr = nk + 6;
    final w = Uint32List(4 * (nr + 1));
    final bd = ByteData.sublistView(key);

    for (var i = 0; i < nk; i++) {
      w[i] = bd.getUint32(i * 4, Endian.big);
    }

    for (var i = nk; i < 4 * (nr + 1); i++) {
      var temp = w[i - 1];
      if (i % nk == 0) {
        temp = _subWord(_rotWord(temp)) ^ (_rCon[i ~/ nk] << 24);
      } else if (nk > 6 && (i % nk == 4)) {
        temp = _subWord(temp);
      }
      w[i] = w[i - nk] ^ temp;
    }

    return w;
  }

  static int _rotWord(int w) => ((w << 8) | (w >> 24)) & 0xFFFFFFFF;

  static int _subWord(int w) {
    final b0 = _sBox[(w >> 24) & 0xFF];
    final b1 = _sBox[(w >> 16) & 0xFF];
    final b2 = _sBox[(w >> 8) & 0xFF];
    final b3 = _sBox[w & 0xFF];
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
  }

  static void _cipher(Uint8List state, Uint32List w, int nr) {
    _addRoundKey(state, w, 0);

    for (var round = 1; round < nr; round++) {
      _subBytes(state);
      _shiftRows(state);
      _mixColumns(state);
      _addRoundKey(state, w, round);
    }

    _subBytes(state);
    _shiftRows(state);
    _addRoundKey(state, w, nr);
  }

  static void _invCipher(Uint8List state, Uint32List w, int nr) {
    _addRoundKey(state, w, nr);
    _invShiftRows(state);
    _invSubBytes(state);

    for (var round = nr - 1; round > 0; round--) {
      _addRoundKey(state, w, round);
      _invMixColumns(state);
      _invShiftRows(state);
      _invSubBytes(state);
    }

    _addRoundKey(state, w, 0);
  }

  static void _addRoundKey(Uint8List state, Uint32List w, int round) {
    for (var i = 0; i < 4; i++) {
      final word = w[round * 4 + i];
      state[i * 4] ^= (word >> 24) & 0xFF;
      state[i * 4 + 1] ^= (word >> 16) & 0xFF;
      state[i * 4 + 2] ^= (word >> 8) & 0xFF;
      state[i * 4 + 3] ^= word & 0xFF;
    }
  }

  static void _subBytes(Uint8List state) {
    for (var i = 0; i < 16; i++) {
      state[i] = _sBox[state[i]];
    }
  }

  static void _invSubBytes(Uint8List state) {
    for (var i = 0; i < 16; i++) {
      state[i] = _invSBox[state[i]];
    }
  }

  static void _shiftRows(Uint8List s) {
    // Row 1
    var t = s[1];
    s[1] = s[5];
    s[5] = s[9];
    s[9] = s[13];
    s[13] = t;
    // Row 2
    t = s[2];
    s[2] = s[10];
    s[10] = t;
    t = s[6];
    s[6] = s[14];
    s[14] = t;
    // Row 3
    t = s[15];
    s[15] = s[11];
    s[11] = s[7];
    s[7] = s[3];
    s[3] = t;
  }

  static void _invShiftRows(Uint8List s) {
    // Row 1
    var t = s[13];
    s[13] = s[9];
    s[9] = s[5];
    s[5] = s[1];
    s[1] = t;
    // Row 2
    t = s[2];
    s[2] = s[10];
    s[10] = t;
    t = s[6];
    s[6] = s[14];
    s[14] = t;
    // Row 3
    t = s[3];
    s[3] = s[7];
    s[7] = s[11];
    s[11] = s[15];
    s[15] = t;
  }

  static int _xtime(int x) => ((x << 1) & 0xFF) ^ ((x & 0x80) != 0 ? 0x1b : 0);

  static void _mixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = _xtime(a0) ^ (_xtime(a1) ^ a1) ^ a2 ^ a3;
      s[i + 1] = a0 ^ _xtime(a1) ^ (_xtime(a2) ^ a2) ^ a3;
      s[i + 2] = a0 ^ a1 ^ _xtime(a2) ^ (_xtime(a3) ^ a3);
      s[i + 3] = (_xtime(a0) ^ a0) ^ a1 ^ a2 ^ _xtime(a3);
    }
  }

  static int _mul(int a, int b) {
    var p = 0;
    var aa = a;
    var bb = b;
    for (var i = 0; i < 8; i++) {
      if ((bb & 1) != 0) p ^= aa;
      final hi = aa & 0x80;
      aa = (aa << 1) & 0xFF;
      if (hi != 0) aa ^= 0x1b;
      bb >>= 1;
    }
    return p;
  }

  static void _invMixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = _mul(0x0e, a0) ^ _mul(0x0b, a1) ^ _mul(0x0d, a2) ^ _mul(0x09, a3);
      s[i + 1] =
          _mul(0x09, a0) ^ _mul(0x0e, a1) ^ _mul(0x0b, a2) ^ _mul(0x0d, a3);
      s[i + 2] =
          _mul(0x0d, a0) ^ _mul(0x09, a1) ^ _mul(0x0e, a2) ^ _mul(0x0b, a3);
      s[i + 3] =
          _mul(0x0b, a0) ^ _mul(0x0d, a1) ^ _mul(0x09, a2) ^ _mul(0x0e, a3);
    }
  }
}
