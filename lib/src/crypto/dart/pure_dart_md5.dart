import 'dart:typed_data';

/// Implementação do algoritmo MD5 (RFC 1321) em 100% Puro Dart para compatibilidade legada e PDF security handlers.
class PureDartMd5 {
  static const List<int> _s = [
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
  ];

  static const List<int> _k = [
    0xd76aa478,
    0xe8c7b756,
    0x242070db,
    0xc1bdceee,
    0xf57c0faf,
    0x4787c62a,
    0xa8304613,
    0xfd469501,
    0x698098d8,
    0x8b44f7af,
    0xffff5bb1,
    0x895cd7be,
    0x6b901122,
    0xfd987193,
    0xa679438e,
    0x49b40821,
    0xf61e2562,
    0xc040b340,
    0x265e5a51,
    0xe9b6c7aa,
    0xd62f105d,
    0x02441453,
    0xd8a1e681,
    0xe7d3fbc8,
    0x21e1cde6,
    0xc33707d6,
    0xf4d50d87,
    0x455a14ed,
    0xa9e3e905,
    0xfcefa3f8,
    0x676f02d9,
    0x8d2a4c8a,
    0xfffa3942,
    0x8771f681,
    0x6d9d6122,
    0xfde5380c,
    0xa4beea44,
    0x4bdecfa9,
    0xf6bb4b60,
    0xbebfbc70,
    0x289b7ec6,
    0xeaa127fa,
    0xd4ef3085,
    0x04881d05,
    0xd9d4d039,
    0xe6db99e5,
    0x1fa27cf8,
    0xc4ac5665,
    0xf4292244,
    0x432aff97,
    0xab9423a7,
    0xfc93a039,
    0x655b59c3,
    0x8f0ccc92,
    0xffeff47d,
    0x85845dd1,
    0x6fa87e4f,
    0xfe2ce6e0,
    0xa3014314,
    0x4e0811a1,
    0xf7537e82,
    0xbd3af235,
    0x2ad7d2bb,
    0xeb86d391,
  ];

  /// Calcula o hash MD5 (16 bytes / 128 bits) de [data].
  static Uint8List digest(Uint8List data) {
    var a0 = 0x67452301;
    var b0 = 0xefcdab89;
    var c0 = 0x98badcfe;
    var d0 = 0x10325476;

    final lengthInBits = data.length * 8;
    final paddingLength = (data.length % 64 < 56)
        ? (56 - (data.length % 64))
        : (120 - (data.length % 64));

    final padded = Uint8List(data.length + paddingLength + 8);
    padded.setAll(0, data);
    padded[data.length] = 0x80;

    final bd = ByteData.sublistView(padded);
    bd.setUint64(padded.length - 8, lengthInBits, Endian.little);

    for (var chunk = 0; chunk < padded.length; chunk += 64) {
      final m = Uint32List(16);
      for (var i = 0; i < 16; i++) {
        m[i] = bd.getUint32(chunk + i * 4, Endian.little);
      }

      var a = a0;
      var b = b0;
      var c = c0;
      var d = d0;

      for (var i = 0; i < 64; i++) {
        int f, g;
        if (i < 16) {
          f = (b & c) | ((~b) & d);
          g = i;
        } else if (i < 32) {
          f = (d & b) | ((~d) & c);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | (~d));
          g = (7 * i) % 16;
        }

        final temp = d;
        d = c;
        c = b;
        final sum = (a + f + _k[i] + m[g]) & 0xFFFFFFFF;
        b = (b + _rotl32(sum, _s[i])) & 0xFFFFFFFF;
        a = temp;
      }

      a0 = (a0 + a) & 0xFFFFFFFF;
      b0 = (b0 + b) & 0xFFFFFFFF;
      c0 = (c0 + c) & 0xFFFFFFFF;
      d0 = (d0 + d) & 0xFFFFFFFF;
    }

    final result = Uint8List(16);
    final rbd = ByteData.sublistView(result);
    rbd.setUint32(0, a0, Endian.little);
    rbd.setUint32(4, b0, Endian.little);
    rbd.setUint32(8, c0, Endian.little);
    rbd.setUint32(12, d0, Endian.little);

    return result;
  }

  static int _rotl32(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;
}
