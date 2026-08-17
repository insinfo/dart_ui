import 'dart:typed_data';

/// Implementações de SHA-1, SHA-256, SHA-384 e SHA-512 (FIPS PUB 180-4) em 100% Puro Dart.
class PureDartSha {
  static const List<int> _k256 = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2
  ];

  /// SHA-256 (32 bytes / 256 bits).
  static Uint8List sha256(Uint8List data) {
    var h0 = 0x6a09e667;
    var h1 = 0xbb67ae85;
    var h2 = 0x3c6ef372;
    var h3 = 0xa54ff53a;
    var h4 = 0x510e527f;
    var h5 = 0x9b05688c;
    var h6 = 0x1f83d9ab;
    var h7 = 0x5be0cd19;

    final lengthInBits = data.length * 8;
    final paddingLength = (data.length % 64 < 56)
        ? (56 - (data.length % 64))
        : (120 - (data.length % 64));

    final padded = Uint8List(data.length + paddingLength + 8);
    padded.setAll(0, data);
    padded[data.length] = 0x80;

    final bd = ByteData.sublistView(padded);
    bd.setUint64(padded.length - 8, lengthInBits, Endian.big);

    final w = Uint32List(64);

    for (var chunk = 0; chunk < padded.length; chunk += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = bd.getUint32(chunk + i * 4, Endian.big);
      }
      for (var i = 16; i < 64; i++) {
        final s0 =
            _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        final s1 =
            _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
      }

      var a = h0;
      var b = h1;
      var c = h2;
      var d = h3;
      var e = h4;
      var f = h5;
      var g = h6;
      var h = h7;

      for (var i = 0; i < 64; i++) {
        final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
        final ch = (e & f) ^ ((~e) & g);
        final temp1 = (h + s1 + ch + _k256[i] + w[i]) & 0xFFFFFFFF;
        final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + maj) & 0xFFFFFFFF;

        h = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xFFFFFFFF;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xFFFFFFFF;
      }

      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
      h4 = (h4 + e) & 0xFFFFFFFF;
      h5 = (h5 + f) & 0xFFFFFFFF;
      h6 = (h6 + g) & 0xFFFFFFFF;
      h7 = (h7 + h) & 0xFFFFFFFF;
    }

    final result = Uint8List(32);
    final rbd = ByteData.sublistView(result);
    rbd.setUint32(0, h0, Endian.big);
    rbd.setUint32(4, h1, Endian.big);
    rbd.setUint32(8, h2, Endian.big);
    rbd.setUint32(12, h3, Endian.big);
    rbd.setUint32(16, h4, Endian.big);
    rbd.setUint32(20, h5, Endian.big);
    rbd.setUint32(24, h6, Endian.big);
    rbd.setUint32(28, h7, Endian.big);

    return result;
  }

  /// SHA-1 (20 bytes / 160 bits).
  static Uint8List sha1(Uint8List data) {
    var h0 = 0x67452301;
    var h1 = 0xEFCDAB89;
    var h2 = 0x98BADCFE;
    var h3 = 0x10325476;
    var h4 = 0xC3D2E1F0;

    final lengthInBits = data.length * 8;
    final paddingLength = (data.length % 64 < 56)
        ? (56 - (data.length % 64))
        : (120 - (data.length % 64));

    final padded = Uint8List(data.length + paddingLength + 8);
    padded.setAll(0, data);
    padded[data.length] = 0x80;

    final bd = ByteData.sublistView(padded);
    bd.setUint64(padded.length - 8, lengthInBits, Endian.big);

    final w = Uint32List(80);

    for (var chunk = 0; chunk < padded.length; chunk += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = bd.getUint32(chunk + i * 4, Endian.big);
      }
      for (var i = 16; i < 80; i++) {
        w[i] = _rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      }

      var a = h0;
      var b = h1;
      var c = h2;
      var d = h3;
      var e = h4;

      for (var i = 0; i < 80; i++) {
        int f, k;
        if (i < 20) {
          f = (b & c) | ((~b) & d);
          k = 0x5A827999;
        } else if (i < 40) {
          f = b ^ c ^ d;
          k = 0x6ED9EBA1;
        } else if (i < 60) {
          f = (b & c) | (b & d) | (c & d);
          k = 0x8F1BBCDC;
        } else {
          f = b ^ c ^ d;
          k = 0xCA62C1D6;
        }

        final temp = (_rotl32(a, 5) + f + e + k + w[i]) & 0xFFFFFFFF;
        e = d;
        d = c;
        c = _rotl32(b, 30);
        b = a;
        a = temp;
      }

      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
      h4 = (h4 + e) & 0xFFFFFFFF;
    }

    final result = Uint8List(20);
    final rbd = ByteData.sublistView(result);
    rbd.setUint32(0, h0, Endian.big);
    rbd.setUint32(4, h1, Endian.big);
    rbd.setUint32(8, h2, Endian.big);
    rbd.setUint32(12, h3, Endian.big);
    rbd.setUint32(16, h4, Endian.big);

    return result;
  }

  /// SHA-512 (64 bytes / 512 bits) e SHA-384 (48 bytes / 384 bits).
  ///
  /// Implementação usando pares de Uint32 (hi, lo) para representar palavras de 64 bits,
  /// evitando os problemas de precisão e performance do BigInt do Dart.
  static Uint8List sha512(Uint8List data, {bool is384 = false}) {
    // Constantes K (80 palavras de 64 bits, armazenadas como hi,lo)
    final k = Uint32List.fromList([
      0x428a2f98,
      0xd728ae22,
      0x71374491,
      0x23ef65cd,
      0xb5c0fbcf,
      0xec4d3b2f,
      0xe9b5dba5,
      0x8189dbbc,
      0x3956c25b,
      0xf348b538,
      0x59f111f1,
      0xb605d019,
      0x923f82a4,
      0xaf194f9b,
      0xab1c5ed5,
      0xda6d8118,
      0xd807aa98,
      0xa3030242,
      0x12835b01,
      0x45706fbe,
      0x243185be,
      0x4ee4b28c,
      0x550c7dc3,
      0xd5ffb4e2,
      0x72be5d74,
      0xf27b896f,
      0x80deb1fe,
      0x3b1696b1,
      0x9bdc06a7,
      0x25c71235,
      0xc19bf174,
      0xcf692694,
      0xe49b69c1,
      0x9ef14ad2,
      0xefbe4786,
      0x384f25e3,
      0x0fc19dc6,
      0x8b8cd5b5,
      0x240ca1cc,
      0x77ac9c65,
      0x2de92c6f,
      0x592b0275,
      0x4a7484aa,
      0x6ea6e483,
      0x5cb0a9dc,
      0xbd41fbd4,
      0x76f988da,
      0x831153b5,
      0x983e5152,
      0xee66dfab,
      0xa831c66d,
      0x2db43210,
      0xb00327c8,
      0x98fb213f,
      0xbf597fc7,
      0xbeef0ee4,
      0xc6e00bf3,
      0x3da88fc2,
      0xd5a79147,
      0x930aa725,
      0x06ca6351,
      0xe003826f,
      0x14292967,
      0x0a0e6e70,
      0x27b70a85,
      0x46d22ffc,
      0x2e1b2138,
      0x5c26c926,
      0x4d2c6dfc,
      0x5ac42aed,
      0x53380d13,
      0x9d95b3df,
      0x650a7354,
      0x8baf63de,
      0x766a0abb,
      0x3c77b2a8,
      0x81c2c92e,
      0x47edaee6,
      0x92722c85,
      0x1482353b,
      0xa2bfe8a1,
      0x4cf10364,
      0xa81a664b,
      0xbc423001,
      0xc24b8b70,
      0xd0f89791,
      0xc76c51a3,
      0x0654be30,
      0xd192e819,
      0xd6ef5218,
      0xd6990624,
      0x5565a910,
      0xf40e3585,
      0x5771202a,
      0x106aa070,
      0x32bbd1b8,
      0x19a4c116,
      0xb8d2d0c8,
      0x1e376c08,
      0x5141ab53,
      0x2748774c,
      0xdf8eeb99,
      0x34b0bcb5,
      0xe19b48a8,
      0x391c0cb3,
      0xc5c95a63,
      0x4ed8aa4a,
      0xe3418acb,
      0x5b9cca4f,
      0x7763e373,
      0x682e6ff3,
      0xd6b2b8a3,
      0x748f82ee,
      0x5defb2fc,
      0x78a5636f,
      0x43172f60,
      0x84c87814,
      0xa1f0ab72,
      0x8cc70208,
      0x1a6439ec,
      0x90befffa,
      0x23631e28,
      0xa4506ceb,
      0xde82bde9,
      0xbef9a3f7,
      0xb2c67915,
      0xc67178f2,
      0xe372532b,
      0xca273ece,
      0xea26619c,
      0xd186b8c7,
      0x21c0c207,
      0xeada7dd6,
      0xcde0eb1e,
      0xf57d4f7f,
      0xee6ed178,
      0x06f067aa,
      0x72176fba,
      0x0a637dc5,
      0xa2c898a6,
      0x113f9804,
      0xbef90dae,
      0x1b710b35,
      0x131c471b,
      0x28db77f5,
      0x23047d84,
      0x32caab7b,
      0x40c72493,
      0x3c9ebe0a,
      0x15c9bebc,
      0x431d67c4,
      0x9c100d4c,
      0x4cc5d4be,
      0xcb3e42b6,
      0x597f299c,
      0xfc657e2a,
      0x5fcb6fab,
      0x3ad6faec,
      0x6c44198c,
      0x4a475817,
    ]);

    // Valores iniciais H (8 palavras de 64 bits, armazenadas como hi,lo)
    final h = Uint32List(16);
    if (is384) {
      h[0] = 0xcbbb9d5d;
      h[1] = 0xc1059ed8;
      h[2] = 0x629a292a;
      h[3] = 0x367cd507;
      h[4] = 0x9159015a;
      h[5] = 0x3070dd17;
      h[6] = 0x152fecd8;
      h[7] = 0xf70e5939;
      h[8] = 0x67332667;
      h[9] = 0xffc00b31;
      h[10] = 0x8eb44a87;
      h[11] = 0x68581511;
      h[12] = 0xdb0c2e0d;
      h[13] = 0x64f98fa7;
      h[14] = 0x47b5481d;
      h[15] = 0xbefa4fa4;
    } else {
      h[0] = 0x6a09e667;
      h[1] = 0xf3bcc908;
      h[2] = 0xbb67ae85;
      h[3] = 0x84caa73b;
      h[4] = 0x3c6ef372;
      h[5] = 0xfe94f82b;
      h[6] = 0xa54ff53a;
      h[7] = 0x5f1d36f1;
      h[8] = 0x510e527f;
      h[9] = 0xade682d1;
      h[10] = 0x9b05688c;
      h[11] = 0x2b3e6c1f;
      h[12] = 0x1f83d9ab;
      h[13] = 0xfb41bd6b;
      h[14] = 0x5be0cd19;
      h[15] = 0x137e2179;
    }

    // Padding
    final lengthInBits = data.length * 8;
    final paddingLength = (data.length % 128 < 112)
        ? (112 - (data.length % 128))
        : (240 - (data.length % 128));

    final padded = Uint8List(data.length + paddingLength + 16);
    padded.setAll(0, data);
    padded[data.length] = 0x80;

    // Comprimento em bits como big-endian 128-bit (apenas os últimos 64 bits são usados)
    final bdPad = ByteData.sublistView(padded);
    bdPad.setUint32(padded.length - 4, lengthInBits & 0xFFFFFFFF, Endian.big);

    // Message schedule W (80 palavras de 64 bits = 160 Uint32)
    final w = Uint32List(160);

    for (var chunk = 0; chunk < padded.length; chunk += 128) {
      // Carregar 16 palavras de 64 bits do bloco
      for (var i = 0; i < 16; i++) {
        w[i * 2] = bdPad.getUint32(chunk + i * 8, Endian.big);
        w[i * 2 + 1] = bdPad.getUint32(chunk + i * 8 + 4, Endian.big);
      }

      // Expandir para 80 palavras
      for (var i = 16; i < 80; i++) {
        // sigma_0(w[i-15]) = ROTR(1) ^ ROTR(8) ^ SHR(7)
        _sigma0_64(w, (i - 15) * 2, _t1);
        // sigma_1(w[i-2]) = ROTR(19) ^ ROTR(61) ^ SHR(6)
        _sigma1_64(w, (i - 2) * 2, _t2);
        // w[i] = w[i-16] + sigma_0 + w[i-7] + sigma_1
        _add64(w, (i - 16) * 2, _t1, 0, _t3);
        _add64(_t3, 0, w, (i - 7) * 2, _t4);
        _add64(_t4, 0, _t2, 0, w, i * 2);
      }

      // Variáveis de trabalho
      final v = Uint32List(16);
      for (var i = 0; i < 16; i++) v[i] = h[i];

      for (var i = 0; i < 80; i++) {
        // Sigma_1(e) = ROTR(14) ^ ROTR(18) ^ ROTR(41)
        _bigSigma1_64(v, 8, _t1);
        // Ch(e,f,g) = (e & f) ^ (~e & g)
        _ch64(v, 8, v, 10, v, 12, _t2);
        // T1 = h + Sigma_1(e) + Ch(e,f,g) + K[i] + W[i]
        _add64(v, 14, _t1, 0, _t3);
        _add64(_t3, 0, _t2, 0, _t4);
        _add64(_t4, 0, k, i * 2, _t5);
        _add64(_t5, 0, w, i * 2, _t1); // _t1 = T1

        // Sigma_0(a) = ROTR(28) ^ ROTR(34) ^ ROTR(39)
        _bigSigma0_64(v, 0, _t2);
        // Maj(a,b,c) = (a & b) ^ (a & c) ^ (b & c)
        _maj64(v, 0, v, 2, v, 4, _t3);
        // T2 = Sigma_0(a) + Maj(a,b,c)
        _add64(_t2, 0, _t3, 0, _t2); // _t2 = T2

        // Atualizar variáveis
        v[14] = v[12];
        v[15] = v[13]; // h = g
        v[12] = v[10];
        v[13] = v[11]; // g = f
        v[10] = v[8];
        v[11] = v[9]; // f = e
        _add64(v, 6, _t1, 0, v, 8); // e = d + T1
        v[6] = v[4];
        v[7] = v[5]; // d = c
        v[4] = v[2];
        v[5] = v[3]; // c = b
        v[2] = v[0];
        v[3] = v[1]; // b = a
        _add64(_t1, 0, _t2, 0, v, 0); // a = T1 + T2
      }

      // Somar ao hash
      for (var i = 0; i < 8; i++) {
        _add64(h, i * 2, v, i * 2, h, i * 2);
      }
    }

    // Resultado
    final outLen = is384 ? 48 : 64;
    final result = Uint8List(outLen);
    final rbd = ByteData.sublistView(result);
    final wordsCount = is384 ? 6 : 8;
    for (var i = 0; i < wordsCount; i++) {
      rbd.setUint32(i * 8, h[i * 2], Endian.big);
      rbd.setUint32(i * 8 + 4, h[i * 2 + 1], Endian.big);
    }
    return result;
  }

  // Buffers temporários para evitar alocações no loop
  static final _t1 = Uint32List(2);
  static final _t2 = Uint32List(2);
  static final _t3 = Uint32List(2);
  static final _t4 = Uint32List(2);
  static final _t5 = Uint32List(2);

  /// Soma dois Uint64 representados como (hi, lo) em Uint32List.
  static void _add64(Uint32List a, int ai, Uint32List b, int bi,
      [Uint32List? out, int oi = 0]) {
    out ??= a;
    final lo = (a[ai + 1] + b[bi + 1]) & 0xFFFFFFFF;
    final carry =
        ((a[ai + 1] & 0xFFFFFFFF) + (b[bi + 1] & 0xFFFFFFFF)) > 0xFFFFFFFF
            ? 1
            : 0;
    out[oi] = (a[ai] + b[bi] + carry) & 0xFFFFFFFF;
    out[oi + 1] = lo;
  }

  /// sigma_0(x) = ROTR(x,1) ^ ROTR(x,8) ^ SHR(x,7) (minúscula, para message schedule)
  static void _sigma0_64(Uint32List src, int si, Uint32List out) {
    final hi = src[si], lo = src[si + 1];
    // ROTR(1)
    final r1h = ((hi >>> 1) | (lo << 31)) & 0xFFFFFFFF;
    final r1l = ((lo >>> 1) | (hi << 31)) & 0xFFFFFFFF;
    // ROTR(8)
    final r8h = ((hi >>> 8) | (lo << 24)) & 0xFFFFFFFF;
    final r8l = ((lo >>> 8) | (hi << 24)) & 0xFFFFFFFF;
    // SHR(7)
    final s7h = (hi >>> 7) & 0xFFFFFFFF;
    final s7l = ((lo >>> 7) | (hi << 25)) & 0xFFFFFFFF;
    out[0] = (r1h ^ r8h ^ s7h) & 0xFFFFFFFF;
    out[1] = (r1l ^ r8l ^ s7l) & 0xFFFFFFFF;
  }

  /// sigma_1(x) = ROTR(x,19) ^ ROTR(x,61) ^ SHR(x,6) (minúscula, para message schedule)
  static void _sigma1_64(Uint32List src, int si, Uint32List out) {
    final hi = src[si], lo = src[si + 1];
    // ROTR(19)
    final r19h = ((hi >>> 19) | (lo << 13)) & 0xFFFFFFFF;
    final r19l = ((lo >>> 19) | (hi << 13)) & 0xFFFFFFFF;
    // ROTR(61) = ROTR(64-3) -> efetivamente rot left 3
    final r61h = ((lo >>> 29) | (hi << 3)) & 0xFFFFFFFF;
    final r61l = ((hi >>> 29) | (lo << 3)) & 0xFFFFFFFF;
    // SHR(6)
    final s6h = (hi >>> 6) & 0xFFFFFFFF;
    final s6l = ((lo >>> 6) | (hi << 26)) & 0xFFFFFFFF;
    out[0] = (r19h ^ r61h ^ s6h) & 0xFFFFFFFF;
    out[1] = (r19l ^ r61l ^ s6l) & 0xFFFFFFFF;
  }

  /// Sigma_1(x) = ROTR(x,14) ^ ROTR(x,18) ^ ROTR(x,41) (maiúscula, para compression)
  static void _bigSigma1_64(Uint32List src, int si, Uint32List out) {
    final hi = src[si], lo = src[si + 1];
    // ROTR(14)
    final r14h = ((hi >>> 14) | (lo << 18)) & 0xFFFFFFFF;
    final r14l = ((lo >>> 14) | (hi << 18)) & 0xFFFFFFFF;
    // ROTR(18)
    final r18h = ((hi >>> 18) | (lo << 14)) & 0xFFFFFFFF;
    final r18l = ((lo >>> 18) | (hi << 14)) & 0xFFFFFFFF;
    // ROTR(41) = ROTR(64-23) -> swap then ROTR(41-32=9)
    final r41h = ((lo >>> 9) | (hi << 23)) & 0xFFFFFFFF;
    final r41l = ((hi >>> 9) | (lo << 23)) & 0xFFFFFFFF;
    out[0] = (r14h ^ r18h ^ r41h) & 0xFFFFFFFF;
    out[1] = (r14l ^ r18l ^ r41l) & 0xFFFFFFFF;
  }

  /// Sigma_0(x) = ROTR(x,28) ^ ROTR(x,34) ^ ROTR(x,39) (maiúscula, para compression)
  static void _bigSigma0_64(Uint32List src, int si, Uint32List out) {
    final hi = src[si], lo = src[si + 1];
    // ROTR(28)
    final r28h = ((hi >>> 28) | (lo << 4)) & 0xFFFFFFFF;
    final r28l = ((lo >>> 28) | (hi << 4)) & 0xFFFFFFFF;
    // ROTR(34) = swap then ROTR(2)
    final r34h = ((lo >>> 2) | (hi << 30)) & 0xFFFFFFFF;
    final r34l = ((hi >>> 2) | (lo << 30)) & 0xFFFFFFFF;
    // ROTR(39) = swap then ROTR(7)
    final r39h = ((lo >>> 7) | (hi << 25)) & 0xFFFFFFFF;
    final r39l = ((hi >>> 7) | (lo << 25)) & 0xFFFFFFFF;
    out[0] = (r28h ^ r34h ^ r39h) & 0xFFFFFFFF;
    out[1] = (r28l ^ r34l ^ r39l) & 0xFFFFFFFF;
  }

  /// Ch(e,f,g) = (e & f) ^ (~e & g)
  static void _ch64(Uint32List e, int ei, Uint32List f, int fi, Uint32List g,
      int gi, Uint32List out) {
    out[0] = ((e[ei] & f[fi]) ^ (~e[ei] & g[gi])) & 0xFFFFFFFF;
    out[1] = ((e[ei + 1] & f[fi + 1]) ^ (~e[ei + 1] & g[gi + 1])) & 0xFFFFFFFF;
  }

  /// Maj(a,b,c) = (a & b) ^ (a & c) ^ (b & c)
  static void _maj64(Uint32List a, int ai, Uint32List b, int bi, Uint32List c,
      int ci, Uint32List out) {
    out[0] = ((a[ai] & b[bi]) ^ (a[ai] & c[ci]) ^ (b[bi] & c[ci])) & 0xFFFFFFFF;
    out[1] = ((a[ai + 1] & b[bi + 1]) ^
            (a[ai + 1] & c[ci + 1]) ^
            (b[bi + 1] & c[ci + 1])) &
        0xFFFFFFFF;
  }

  static int _rotr32(int x, int n) =>
      ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;
  static int _rotl32(int x, int n) =>
      ((x << n) | (x >>> (32 - n))) & 0xFFFFFFFF;
}
