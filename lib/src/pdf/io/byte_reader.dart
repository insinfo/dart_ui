import 'dart:typed_data';

/// Leitor sequencial e de acesso aleatório a bytes em memória ou buffers contíguos.
class ByteReader {
  final Uint8List _buffer;
  final ByteData _byteData;
  int _offset;

  ByteReader(Uint8List buffer, [int offset = 0])
      : _buffer = buffer,
        _byteData = ByteData.sublistView(buffer),
        _offset = offset;

  /// Tamanho total do buffer em bytes.
  int get length => _buffer.length;

  /// Posição atual de leitura no buffer.
  int get offset => _offset;
  set offset(int value) {
    if (value < 0 || value > _buffer.length) {
      throw RangeError.range(value, 0, _buffer.length, 'offset');
    }
    _offset = value;
  }

  /// Quantidade de bytes restantes a partir do offset atual.
  int get remaining => _buffer.length - _offset;

  /// Retorna `true` se todos os bytes já foram lidos.
  bool get isEOF => _offset >= _buffer.length;

  /// Buffer bruto subjacente.
  Uint8List get buffer => _buffer;

  /// Lê 1 byte (8 bits sem sinal) e avança o cursor.
  int readUint8() {
    if (_offset >= _buffer.length) {
      throw StateError('Tentativa de ler além do fim do buffer (EOF).');
    }
    return _buffer[_offset++];
  }

  /// Espia 1 byte sem avançar o cursor. Retorna -1 se EOF.
  int peekUint8() {
    if (_offset >= _buffer.length) return -1;
    return _buffer[_offset];
  }

  /// Lê 2 bytes (16 bits sem sinal) em Big-Endian (padrão de redes e formatos gráficos).
  int readUint16BE() {
    final val = _byteData.getUint16(_offset, Endian.big);
    _offset += 2;
    return val;
  }

  /// Lê 2 bytes (16 bits sem sinal) em Little-Endian (padrão RIFF / CorelDRAW).
  int readUint16LE() {
    final val = _byteData.getUint16(_offset, Endian.little);
    _offset += 2;
    return val;
  }

  /// Lê 4 bytes (32 bits sem sinal) em Big-Endian.
  int readUint32BE() {
    final val = _byteData.getUint32(_offset, Endian.big);
    _offset += 4;
    return val;
  }

  /// Lê 4 bytes (32 bits sem sinal) em Little-Endian.
  int readUint32LE() {
    final val = _byteData.getUint32(_offset, Endian.little);
    _offset += 4;
    return val;
  }

  /// Lê 4 bytes em ponto flutuante (Float32) Big-Endian.
  double readFloat32BE() {
    final val = _byteData.getFloat32(_offset, Endian.big);
    _offset += 4;
    return val;
  }

  /// Lê 8 bytes em ponto flutuante (Float64) Little-Endian.
  double readFloat64LE() {
    final val = _byteData.getFloat64(_offset, Endian.little);
    _offset += 8;
    return val;
  }

  /// Lê uma fatia contígua de [count] bytes como um novo [Uint8List] sem cópia redundante.
  Uint8List readBytes(int count) {
    if (_offset + count > _buffer.length) {
      throw StateError(
          'Tentativa de ler $count bytes, mas restam apenas $remaining.');
    }
    final slice = Uint8List.view(
      _buffer.buffer,
      _buffer.offsetInBytes + _offset,
      count,
    );
    _offset += count;
    return slice;
  }

  /// Returns a zero-copy view up to [pattern], advancing past the pattern.
  /// Returns all remaining bytes when the pattern is absent.
  Uint8List readUntil(List<int> pattern) {
    if (pattern.isEmpty) return Uint8List(0);
    final start = _offset;
    final lastStart = _buffer.length - pattern.length;
    for (var candidate = _offset; candidate <= lastStart; candidate++) {
      if (_buffer[candidate] != pattern[0]) continue;
      var matches = true;
      for (var index = 1; index < pattern.length; index++) {
        if (_buffer[candidate + index] != pattern[index]) {
          matches = false;
          break;
        }
      }
      if (!matches) continue;
      _offset = candidate + pattern.length;
      return Uint8List.view(
        _buffer.buffer,
        _buffer.offsetInBytes + start,
        candidate - start,
      );
    }
    _offset = _buffer.length;
    return Uint8List.view(
      _buffer.buffer,
      _buffer.offsetInBytes + start,
      _buffer.length - start,
    );
  }

  /// Like [readUntil], but only accepts a PDF keyword delimited by whitespace
  /// or delimiter characters. This prevents binary stream data containing the
  /// same byte sequence from terminating a damaged/indirect-length stream.
  Uint8List readUntilKeyword(List<int> keyword) {
    if (keyword.isEmpty) return Uint8List(0);
    final start = _offset;
    final lastStart = _buffer.length - keyword.length;
    for (var candidate = _offset; candidate <= lastStart; candidate++) {
      if (_buffer[candidate] != keyword[0]) continue;
      final before = candidate == start ? -1 : _buffer[candidate - 1];
      if (before >= 0 && !_isPdfBoundary(before)) continue;
      var matches = true;
      for (var index = 1; index < keyword.length; index++) {
        if (_buffer[candidate + index] != keyword[index]) {
          matches = false;
          break;
        }
      }
      if (!matches) continue;
      final afterOffset = candidate + keyword.length;
      final after = afterOffset >= _buffer.length ? -1 : _buffer[afterOffset];
      if (after >= 0 && !_isPdfBoundary(after)) continue;
      _offset = afterOffset;
      return Uint8List.view(
        _buffer.buffer,
        _buffer.offsetInBytes + start,
        candidate - start,
      );
    }
    _offset = _buffer.length;
    return Uint8List.view(
      _buffer.buffer,
      _buffer.offsetInBytes + start,
      _buffer.length - start,
    );
  }

  static bool _isPdfBoundary(int byte) =>
      byte == 0 ||
      byte == 9 ||
      byte == 10 ||
      byte == 12 ||
      byte == 13 ||
      byte == 32 ||
      const <int>[
        0x28,
        0x29,
        0x3c,
        0x3e,
        0x5b,
        0x5d,
        0x7b,
        0x7d,
        0x2f,
        0x25,
      ].contains(byte);

  /// Avança o cursor em [count] posições.
  void skip(int count) {
    offset = _offset + count;
  }

  /// Retorna uma sub-visão [ByteReader] começando na posição atual até [count] bytes.
  ByteReader subReader(int count) {
    final bytes = readBytes(count);
    return ByteReader(bytes);
  }
}
