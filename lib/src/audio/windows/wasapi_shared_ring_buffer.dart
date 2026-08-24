/// Native-memory SPSC ring buffer for a WASAPI realtime isolate.
library;

import 'dart:ffi';

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import 'wasapi_bindings.dart';

const int _ringMagic = 0x44554152; // "DUAR"
const int _ringVersion = 1;
const int _headerBytes = 64;
const int _magicOffset = 0;
const int _versionOffset = 4;
const int _capacityOffset = 8;
const int _bytesPerFrameOffset = 12;
const int _readOffset = 16;
const int _writeOffset = 24;
const int _lockOffset = 32;

/// A native, process-local ring buffer that can be attached by another Dart
/// isolate using [address].
///
/// The producer takes an exclusive SRW lock while copying. The realtime
/// consumer only *tries* the lock: contention produces zero frames instead of
/// blocking the audio thread. All cursors and sample bytes are protected by
/// the same native primitive, so this does not rely on undocumented Dart or
/// CPU memory-order behaviour.
///
/// Exactly one owner may call [dispose]. Attachments must be disposed or stop
/// using the address before the owner releases it.
final class WasapiSharedRingBuffer with DisposableMixin {
  WasapiSharedRingBuffer._(
    this._memory,
    this._api,
    this._ownsMemory,
  );

  factory WasapiSharedRingBuffer.allocate({
    required int capacityFrames,
    required int bytesPerFrame,
  }) {
    if (capacityFrames <= 1) {
      throw RangeError.value(
          capacityFrames, 'capacityFrames', 'must be greater than one');
    }
    if (bytesPerFrame <= 0) {
      throw RangeError.value(
          bytesPerFrame, 'bytesPerFrame', 'must be positive');
    }
    final int byteLength = _headerBytes + capacityFrames * bytesPerFrame;
    final Pointer<Uint8> memory =
        NativeAllocator.instance.allocate<Uint8>(byteLength);
    final WasapiNativeApi nativeApi = WasapiNativeApi.load();
    memory.cast<Uint32>()[_magicOffset ~/ 4] = _ringMagic;
    memory.cast<Uint32>()[_versionOffset ~/ 4] = _ringVersion;
    memory.cast<Uint32>()[_capacityOffset ~/ 4] = capacityFrames;
    memory.cast<Uint32>()[_bytesPerFrameOffset ~/ 4] = bytesPerFrame;
    memory.cast<Uint64>()[_readOffset ~/ 8] = 0;
    memory.cast<Uint64>()[_writeOffset ~/ 8] = 0;
    nativeApi.initializeLock(
      Pointer<Void>.fromAddress(memory.address + _lockOffset),
    );
    return WasapiSharedRingBuffer._(memory, nativeApi, true);
  }

  /// Attaches to storage created by [WasapiSharedRingBuffer.allocate] in the
  /// same process. The returned object does not own the allocation.
  factory WasapiSharedRingBuffer.attach(int address) {
    if (address == 0) {
      throw ArgumentError.value(address, 'address', 'must not be zero');
    }
    final Pointer<Uint8> memory = Pointer<Uint8>.fromAddress(address);
    if (memory.cast<Uint32>()[_magicOffset ~/ 4] != _ringMagic ||
        memory.cast<Uint32>()[_versionOffset ~/ 4] != _ringVersion) {
      throw StateError('address does not contain a dart_ui audio ring buffer');
    }
    return WasapiSharedRingBuffer._(
      memory,
      WasapiNativeApi.load(),
      false,
    );
  }

  final Pointer<Uint8> _memory;
  final WasapiNativeApi _api;
  final bool _ownsMemory;

  int get address {
    throwIfDisposed();
    return _memory.address;
  }

  int get capacityFrames {
    throwIfDisposed();
    return _memory.cast<Uint32>()[_capacityOffset ~/ 4];
  }

  int get bytesPerFrame {
    throwIfDisposed();
    return _memory.cast<Uint32>()[_bytesPerFrameOffset ~/ 4];
  }

  int get byteLength => _headerBytes + capacityFrames * bytesPerFrame;

  Pointer<Void> get _lock =>
      Pointer<Void>.fromAddress(_memory.address + _lockOffset);
  Pointer<Uint8> get _samples =>
      Pointer<Uint8>.fromAddress(_memory.address + _headerBytes);

  int get availableReadFrames {
    throwIfDisposed();
    _api.acquireLock(_lock);
    try {
      return _writeCursor - _readCursor;
    } finally {
      _api.releaseLock(_lock);
    }
  }

  int get availableWriteFrames => capacityFrames - availableReadFrames;

  int get _readCursor => _memory.cast<Uint64>()[_readOffset ~/ 8];
  set _readCursor(int value) =>
      _memory.cast<Uint64>()[_readOffset ~/ 8] = value;
  int get _writeCursor => _memory.cast<Uint64>()[_writeOffset ~/ 8];
  set _writeCursor(int value) =>
      _memory.cast<Uint64>()[_writeOffset ~/ 8] = value;

  /// Copies as many complete frames as fit. This is the producer-side method
  /// and may briefly wait for the native lock.
  int writeFrames(Pointer<Uint8> source, int frameCount) {
    throwIfDisposed();
    if (source == nullptr) {
      throw ArgumentError.value(source, 'source', 'must not be null');
    }
    if (frameCount <= 0) return 0;
    _api.acquireLock(_lock);
    try {
      final int read = _readCursor;
      final int write = _writeCursor;
      final int frames = frameCount.clamp(0, capacityFrames - (write - read));
      _copyIntoRing(source, write, frames);
      _writeCursor = write + frames;
      return frames;
    } finally {
      _api.releaseLock(_lock);
    }
  }

  /// Realtime consumer read. Returns zero immediately if the producer owns
  /// the lock; it never waits behind non-realtime work.
  int tryReadFrames(Pointer<Uint8> destination, int frameCount) {
    throwIfDisposed();
    if (destination == nullptr) {
      throw ArgumentError.value(destination, 'destination', 'must not be null');
    }
    if (frameCount <= 0) return 0;
    if (_api.tryAcquireLock(_lock) == 0) return 0;
    try {
      final int read = _readCursor;
      final int frames = frameCount.clamp(0, _writeCursor - read);
      _copyOutOfRing(destination, read, frames);
      _readCursor = read + frames;
      return frames;
    } finally {
      _api.releaseLock(_lock);
    }
  }

  void clear() {
    throwIfDisposed();
    _api.acquireLock(_lock);
    try {
      _readCursor = _writeCursor;
    } finally {
      _api.releaseLock(_lock);
    }
  }

  void _copyIntoRing(Pointer<Uint8> source, int cursor, int frames) {
    if (frames == 0) return;
    final int firstFrame = cursor % capacityFrames;
    final int firstFrames = frames.clamp(0, capacityFrames - firstFrame);
    final int firstBytes = firstFrames * bytesPerFrame;
    _api.moveMemory(
      Pointer<Void>.fromAddress(_samples.address + firstFrame * bytesPerFrame),
      source.cast<Void>(),
      firstBytes,
    );
    final int remainingBytes = (frames - firstFrames) * bytesPerFrame;
    if (remainingBytes != 0) {
      _api.moveMemory(
        _samples.cast<Void>(),
        Pointer<Void>.fromAddress(source.address + firstBytes),
        remainingBytes,
      );
    }
  }

  void _copyOutOfRing(Pointer<Uint8> destination, int cursor, int frames) {
    if (frames == 0) return;
    final int firstFrame = cursor % capacityFrames;
    final int firstFrames = frames.clamp(0, capacityFrames - firstFrame);
    final int firstBytes = firstFrames * bytesPerFrame;
    _api.moveMemory(
      destination.cast<Void>(),
      Pointer<Void>.fromAddress(_samples.address + firstFrame * bytesPerFrame),
      firstBytes,
    );
    final int remainingBytes = (frames - firstFrames) * bytesPerFrame;
    if (remainingBytes != 0) {
      _api.moveMemory(
        Pointer<Void>.fromAddress(destination.address + firstBytes),
        _samples.cast<Void>(),
        remainingBytes,
      );
    }
  }

  @override
  void onDispose() {
    if (_ownsMemory) {
      _memory.cast<Uint32>()[_magicOffset ~/ 4] = 0;
      NativeAllocator.instance.free(_memory);
    }
  }
}
