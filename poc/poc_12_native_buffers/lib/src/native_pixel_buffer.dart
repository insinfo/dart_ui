import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// A manually managed BGRA8888 buffer allocated outside the Dart heap.
///
/// The [words] view aliases the native allocation and becomes invalid after
/// [dispose]. Consumers must not retain it beyond the buffer lifetime.
final class NativePixelBuffer {
  NativePixelBuffer(this.width, this.height)
      : length = _checkedLength(width, height),
        byteLength = _checkedLength(width, height) * sizeOf<Uint32>(),
        _pointer = calloc<Uint32>(_checkedLength(width, height)) {
    _words = _pointer.asTypedList(length);
  }

  final int width;
  final int height;
  final int length;
  final int byteLength;

  Pointer<Uint32> _pointer;
  late final Uint32List _words;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  int get address {
    _ensureAlive();
    return _pointer.address;
  }

  Pointer<Uint32> get pointer {
    _ensureAlive();
    return _pointer;
  }

  Uint32List get words {
    _ensureAlive();
    return _words;
  }

  Uint8List get bytes => Uint8List.view(
        words.buffer,
        words.offsetInBytes,
        byteLength,
      );

  /// C-style indexed stores through `Pointer<Uint32>`.
  void fillWithPointer(int bgra) {
    _ensureAlive();
    final target = _pointer;
    for (var index = 0; index < length; index++) {
      target[index] = bgra;
    }
  }

  /// Bulk fill through a typed view over the same native allocation.
  void fillWithView(int bgra) {
    _ensureAlive();
    _words.fillRange(0, length, bgra);
  }

  /// Copies packed BGRA words from Dart-managed memory into native memory.
  void copyFrom(Uint32List source) {
    _ensureAlive();
    if (source.length != length) {
      throw ArgumentError.value(
        source.length,
        'source',
        'Expected exactly $length BGRA words.',
      );
    }
    _words.setAll(0, source);
  }

  /// Reads three distant words so benchmark writes remain observable.
  int sampleChecksum() {
    _ensureAlive();
    return _words.first ^ _words[length ~/ 2] ^ _words.last;
  }

  void dispose() {
    if (_disposed) return;
    calloc.free(_pointer);
    _pointer = nullptr;
    _disposed = true;
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('NativePixelBuffer has been disposed.');
  }

  static int _checkedLength(int width, int height) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Buffer dimensions must be positive.');
    }
    return width * height;
  }
}
