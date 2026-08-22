/// Marshalling and unmarshalling of the Wayland wire format, in pure Dart.
///
/// A Wayland message is two 32-bit header words followed by the arguments:
///
/// ```text
/// word 0: sender/target object id
/// word 1: (size in bytes, header included) << 16 | opcode
/// ```
///
/// Arguments are 32-bit aligned. `int`/`uint`/`object`/`new_id` are one word;
/// `fixed` is signed 24.8; `string` is a length word (NUL included) followed by
/// NUL-terminated UTF-8 padded to a word; `array` is a length word followed by
/// bytes padded to a word; `fd` occupies **no bytes at all** - the descriptor
/// travels as `SCM_RIGHTS` ancillary data on the socket and is consumed in
/// argument order by the receiver.
///
/// The wire is in the *host's* byte order. Everything this backend runs on is
/// little-endian, and the code says so once here instead of assuming it
/// silently in every reader - the same posture `x11_libc.dart` takes.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Wayland speaks host byte order; this backend supports the little-endian
/// hosts Linux desktops actually run on. A big-endian port would only need to
/// change this constant's derivation.
final Endian waylandWireEndian = Endian.host;

/// Bytes of a message header: object id word plus size/opcode word.
const int waylandHeaderBytes = 8;

/// The size field is 16 bits, so no single message can exceed this.
const int waylandMaximumMessageBytes = 0xffff;

/// Converts a signed 24.8 fixed-point wire value to a double.
double waylandFixedToDouble(int fixed) {
  final signed = fixed >= 0x80000000 ? fixed - 0x100000000 : fixed;
  return signed / 256.0;
}

/// Converts a double to the signed 24.8 fixed-point wire encoding.
int waylandDoubleToFixed(double value) {
  final scaled = (value * 256.0).round();
  return scaled & 0xffffffff;
}

/// Rounds [length] up to the 32-bit alignment every argument obeys.
int waylandWordAlign(int length) => (length + 3) & ~3;

/// Builds one outgoing message, then hands back its exact bytes.
///
/// One instance per connection, reused for every request: `reset` rewinds it,
/// `take` copies out only the bytes written. The scratch grows to the largest
/// message ever sent and stays there, which honours section 6.5's rule against
/// per-event allocation without a fixed ceiling guess.
final class WaylandMessageWriter {
  WaylandMessageWriter([int initialCapacity = 256])
      : _bytes = Uint8List(initialCapacity < 64 ? 64 : initialCapacity) {
    _data = ByteData.sublistView(_bytes);
  }

  Uint8List _bytes;
  late ByteData _data;
  int _length = 0;
  int _objectId = 0;
  int _opcode = 0;

  /// The file descriptors queued by [putFd], in argument order. The transport
  /// must send them with the same `sendmsg` that carries the bytes.
  final List<int> fds = <int>[];

  /// Starts a message for [objectId]/[opcode]. Arguments follow.
  void begin(int objectId, int opcode) {
    if (objectId <= 0) {
      throw ArgumentError.value(objectId, 'objectId', 'must be positive');
    }
    if (opcode < 0 || opcode > 0xffff) {
      throw ArgumentError.value(opcode, 'opcode', 'must fit in 16 bits');
    }
    _objectId = objectId;
    _opcode = opcode;
    _length = waylandHeaderBytes;
    fds.clear();
  }

  void putInt(int value) => _putWord(value & 0xffffffff);

  void putUint(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw ArgumentError.value(value, 'value', 'must fit in 32 bits');
    }
    _putWord(value);
  }

  void putFixed(double value) => _putWord(waylandDoubleToFixed(value));

  void putObject(int objectId) => putUint(objectId);

  void putNewId(int objectId) => putUint(objectId);

  /// A non-null protocol string: length word (NUL included), UTF-8 bytes, NUL,
  /// padding to a word boundary.
  void putString(String value) {
    final encoded = utf8.encode(value);
    final lengthWithNul = encoded.length + 1;
    putUint(lengthWithNul);
    _ensure(waylandWordAlign(lengthWithNul));
    _bytes.setAll(_length, encoded);
    var cursor = _length + encoded.length;
    final padded = _length + waylandWordAlign(lengthWithNul);
    while (cursor < padded) {
      _bytes[cursor++] = 0;
    }
    _length = padded;
  }

  /// A protocol array: length word (bytes, padding excluded), raw bytes,
  /// padding to a word boundary.
  void putArray(Uint8List value) {
    putUint(value.length);
    _ensure(waylandWordAlign(value.length));
    _bytes.setAll(_length, value);
    var cursor = _length + value.length;
    final padded = _length + waylandWordAlign(value.length);
    while (cursor < padded) {
      _bytes[cursor++] = 0;
    }
    _length = padded;
  }

  /// Queues [fd] as ancillary data. Writes nothing into the byte stream.
  void putFd(int fd) {
    if (fd < 0) throw ArgumentError.value(fd, 'fd', 'must be a valid fd');
    fds.add(fd);
  }

  /// Finishes the message and returns a copy of exactly its bytes.
  Uint8List take() {
    if (_length < waylandHeaderBytes) {
      throw StateError('WaylandMessageWriter.take before begin');
    }
    if (_length > waylandMaximumMessageBytes) {
      throw StateError('Wayland message of $_length bytes exceeds the 16-bit '
          'size field');
    }
    _data.setUint32(0, _objectId, waylandWireEndian);
    _data.setUint32(4, (_length << 16) | _opcode, waylandWireEndian);
    final result = Uint8List.fromList(
      Uint8List.sublistView(_bytes, 0, _length),
    );
    _length = 0;
    return result;
  }

  void _putWord(int value) {
    _ensure(4);
    _data.setUint32(_length, value, waylandWireEndian);
    _length += 4;
  }

  void _ensure(int extra) {
    if (_length + extra <= _bytes.length) return;
    var capacity = _bytes.length * 2;
    while (capacity < _length + extra) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity);
    grown.setAll(0, _bytes);
    _bytes = grown;
    _data = ByteData.sublistView(_bytes);
  }
}

/// One decoded message: who it is for, which event, and its argument bytes.
///
/// Reused by [WaylandWireDecoder]; never retained across `nextMessage` calls.
/// The payload view is only valid until the next decode, which is the same
/// borrow rule `X11RawEvent` lives by.
final class WaylandWireMessage {
  int objectId = 0;
  int opcode = 0;
  Uint8List payload = _emptyPayload;

  static final Uint8List _emptyPayload = Uint8List(0);
}

/// Reads arguments out of one message payload, in declaration order.
final class WaylandMessageReader {
  WaylandMessageReader(this._payload, [List<int>? fdQueue])
      : _data = ByteData.sublistView(_payload),
        _fdQueue = fdQueue;

  final Uint8List _payload;
  final ByteData _data;

  /// Received descriptors, shared with the connection: an `fd` argument
  /// consumes the head of this queue, in the order `recvmsg` delivered them.
  final List<int>? _fdQueue;

  int _offset = 0;

  bool get isAtEnd => _offset >= _payload.length;

  int readUint() {
    final value = _data.getUint32(_require(4), waylandWireEndian);
    _offset += 4;
    return value;
  }

  int readInt() {
    final value = _data.getInt32(_require(4), waylandWireEndian);
    _offset += 4;
    return value;
  }

  double readFixed() {
    final value = _data.getInt32(_require(4), waylandWireEndian);
    _offset += 4;
    return value / 256.0;
  }

  int readObject() => readUint();

  int readNewId() => readUint();

  /// A protocol string. Empty length means a null string, returned as ''.
  String readString() {
    final lengthWithNul = readUint();
    if (lengthWithNul == 0) return '';
    final start = _require(waylandWordAlign(lengthWithNul));
    final textLength = lengthWithNul - 1;
    final value = utf8.decode(
      Uint8List.sublistView(_payload, start, start + textLength),
      allowMalformed: true,
    );
    _offset += waylandWordAlign(lengthWithNul);
    return value;
  }

  /// A protocol array, copied out so the caller may keep it.
  Uint8List readArray() {
    final length = readUint();
    final start = _require(waylandWordAlign(length));
    final value = Uint8List.fromList(
      Uint8List.sublistView(_payload, start, start + length),
    );
    _offset += waylandWordAlign(length);
    return value;
  }

  /// The next ancillary file descriptor, or -1 when none arrived - which is a
  /// protocol violation by the peer, reported by the caller rather than
  /// guessed around here.
  int readFd() {
    final queue = _fdQueue;
    if (queue == null || queue.isEmpty) return -1;
    return queue.removeAt(0);
  }

  int _require(int bytes) {
    if (_offset + bytes > _payload.length) {
      throw StateError(
        'Wayland message payload of ${_payload.length} bytes ended while '
        'reading $bytes byte(s) at offset $_offset',
      );
    }
    return _offset;
  }
}

/// Reassembles complete messages out of an arbitrary chunking of the stream.
///
/// A unix socket delivers bytes, not messages: one read can contain half a
/// header, three whole events and the first word of a fourth. The decoder
/// buffers what arrived and yields a message only when all of it is present.
final class WaylandWireDecoder {
  Uint8List _buffer = Uint8List(4096);
  int _start = 0;
  int _end = 0;

  int get bufferedBytes => _end - _start;

  /// Appends [bytes] (the first [length] entries, or all of them) to the
  /// stream.
  void addBytes(Uint8List bytes, [int? length]) {
    final count = length ?? bytes.length;
    if (count <= 0) return;
    _reserve(count);
    _buffer.setRange(_end, _end + count, bytes);
    _end += count;
  }

  /// Decodes the next complete message into [into]. Returns false when the
  /// buffered bytes do not yet contain one.
  bool nextMessage(WaylandWireMessage into) {
    if (bufferedBytes < waylandHeaderBytes) return false;
    final data = ByteData.sublistView(_buffer, _start, _end);
    final objectId = data.getUint32(0, waylandWireEndian);
    final sizeOpcode = data.getUint32(4, waylandWireEndian);
    final size = sizeOpcode >> 16;
    if (size < waylandHeaderBytes) {
      throw StateError(
        'Wayland message header declares $size bytes; the minimum is '
        '$waylandHeaderBytes',
      );
    }
    if (bufferedBytes < size) return false;
    into
      ..objectId = objectId
      ..opcode = sizeOpcode & 0xffff
      ..payload = Uint8List.sublistView(
        _buffer,
        _start + waylandHeaderBytes,
        _start + size,
      );
    _start += size;
    if (_start == _end) {
      _start = 0;
      _end = 0;
    }
    return true;
  }

  void _reserve(int extra) {
    if (_end + extra <= _buffer.length) return;
    // Compact before growing: the live bytes usually fit once the consumed
    // prefix is dropped.
    if (_start > 0) {
      _buffer.setRange(0, _end - _start, _buffer, _start);
      _end -= _start;
      _start = 0;
      if (_end + extra <= _buffer.length) return;
    }
    var capacity = _buffer.length * 2;
    while (capacity < _end + extra) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, _end, _buffer);
    _buffer = grown;
  }
}
