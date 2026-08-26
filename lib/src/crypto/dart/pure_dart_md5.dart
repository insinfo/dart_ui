import 'dart:typed_data';

import '../crypto_backend.dart';

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
    return (PureDartMd5Sink()..add(data)).close();
  }

  static int _rotl32(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;
}

/// Estado MD5 incremental.
///
/// Consome os dados em blocos de 64 bytes e guarda apenas o resto parcial, para
/// quem precisa do hash de um stream sem materializar o stream inteiro - o
/// verificador de assinatura do FLAC alimenta um frame decodificado por vez.
///
/// Use [PureDartMd5.digest] quando os bytes ja estiverem todos em memoria.
class PureDartMd5Sink implements HashSink {
  int _a0 = 0x67452301;
  int _b0 = 0xefcdab89;
  int _c0 = 0x98badcfe;
  int _d0 = 0x10325476;

  final Uint8List _block = Uint8List(64);
  late final ByteData _blockView = ByteData.sublistView(_block);
  final Uint32List _m = Uint32List(16);

  /// Quantos bytes de [_block] ja estao preenchidos (sempre < 64 entre chamadas).
  int _blockLength = 0;

  /// Total de bytes consumidos, para o campo de comprimento do padding.
  int _totalLength = 0;

  bool _closed = false;

  /// Acrescenta [data] ao hash. Pode ser chamado quantas vezes for preciso ate
  /// [close].
  @override
  void add(List<int> data) {
    if (_closed) {
      throw StateError('PureDartMd5Sink.add() apos close()');
    }

    _totalLength += data.length;
    var offset = 0;

    // Completa o bloco parcial que sobrou da chamada anterior.
    if (_blockLength > 0) {
      final take =
          data.length < 64 - _blockLength ? data.length : 64 - _blockLength;
      _block.setRange(_blockLength, _blockLength + take, data);
      _blockLength += take;
      offset = take;
      if (_blockLength == 64) _processBlock();
    }

    while (data.length - offset >= 64) {
      _block.setRange(0, 64, data, offset);
      _processBlock();
      offset += 64;
    }

    final rest = data.length - offset;
    if (rest > 0) {
      _block.setRange(0, rest, data, offset);
      _blockLength = rest;
    }
  }

  /// Aplica o padding e devolve o hash de 16 bytes. Chamadas seguintes devolvem
  /// o mesmo resultado; [add] passa a ser um erro.
  @override
  Uint8List close() {
    if (_closed) return _result();
    _closed = true;

    final lengthInBits = _totalLength * 8;

    _block[_blockLength++] = 0x80;

    // Sem espaco para o comprimento de 8 bytes: fecha este bloco e usa o proximo.
    if (_blockLength > 56) {
      while (_blockLength < 64) {
        _block[_blockLength++] = 0;
      }
      _processBlock();
    }

    while (_blockLength < 56) {
      _block[_blockLength++] = 0;
    }
    // Duas escritas de 32 bits e nao um `setUint64`: este arquivo e alcancavel
    // pelo backend web, e `ByteData.setUint64` lanca `UnsupportedError` sob o
    // dart2js. `~/` e `%` em vez de deslocamentos porque as operacoes bitwise
    // do dart2js sao de 32 bits.
    _blockView.setUint32(56, lengthInBits % 0x100000000, Endian.little);
    _blockView.setUint32(60, lengthInBits ~/ 0x100000000, Endian.little);
    _processBlock();

    return _result();
  }

  void _processBlock() {
    for (var i = 0; i < 16; i++) {
      _m[i] = _blockView.getUint32(i * 4, Endian.little);
    }

    var a = _a0;
    var b = _b0;
    var c = _c0;
    var d = _d0;

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
      final sum = (a + f + PureDartMd5._k[i] + _m[g]) & 0xFFFFFFFF;
      b = (b + PureDartMd5._rotl32(sum, PureDartMd5._s[i])) & 0xFFFFFFFF;
      a = temp;
    }

    _a0 = (_a0 + a) & 0xFFFFFFFF;
    _b0 = (_b0 + b) & 0xFFFFFFFF;
    _c0 = (_c0 + c) & 0xFFFFFFFF;
    _d0 = (_d0 + d) & 0xFFFFFFFF;

    _blockLength = 0;
  }

  Uint8List _result() {
    final result = Uint8List(16);
    final view = ByteData.sublistView(result);
    view.setUint32(0, _a0, Endian.little);
    view.setUint32(4, _b0, Endian.little);
    view.setUint32(8, _c0, Endian.little);
    view.setUint32(12, _d0, Endian.little);
    return result;
  }
}
