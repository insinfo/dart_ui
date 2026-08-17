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
    final slice = _buffer.sublist(_offset, _offset + count);
    _offset += count;
    return slice;
  }

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
