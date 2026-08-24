/// Shared one-shot events for realtime WASAPI processors.
library;

import 'dart:ffi';

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import 'wasapi_bindings.dart';

const int _triggerMagic = 0x54554144; // "DUAT"
const int _triggerVersion = 1;
const int _headerBytes = 64;
const int _magicOffset = 0;
const int _versionOffset = 4;
const int _countOffset = 8;
const int _lockOffset = 32;

/// Monotonic trigger counters and velocities shared by UI and audio isolates.
///
/// Unlike a boolean gate, a sequence counter preserves repeated one-shot hits.
/// The realtime reader never waits: [trySnapshot] retains its previous state
/// when the UI owns the lock for the few instructions needed by [trigger].
final class WasapiSharedTriggerBlock with DisposableMixin {
  WasapiSharedTriggerBlock._(this._memory, this._api, this._ownsMemory);

  factory WasapiSharedTriggerBlock.allocate(int count) {
    if (count <= 0) {
      throw RangeError.value(count, 'count', 'must be positive');
    }
    final Pointer<Uint8> memory = NativeAllocator.instance.allocate<Uint8>(
      _headerBytes + count * sizeOf<Uint32>() + count * sizeOf<Float>(),
    );
    final WasapiNativeApi api = WasapiNativeApi.load();
    memory.cast<Uint32>()[_magicOffset ~/ 4] = _triggerMagic;
    memory.cast<Uint32>()[_versionOffset ~/ 4] = _triggerVersion;
    memory.cast<Uint32>()[_countOffset ~/ 4] = count;
    api.initializeLock(Pointer<Void>.fromAddress(memory.address + _lockOffset));
    return WasapiSharedTriggerBlock._(memory, api, true);
  }

  factory WasapiSharedTriggerBlock.attach(int address) {
    if (address == 0) {
      throw ArgumentError.value(address, 'address', 'must not be zero');
    }
    final Pointer<Uint8> memory = Pointer<Uint8>.fromAddress(address);
    if (memory.cast<Uint32>()[_magicOffset ~/ 4] != _triggerMagic ||
        memory.cast<Uint32>()[_versionOffset ~/ 4] != _triggerVersion) {
      throw StateError('address does not contain a dart_ui trigger block');
    }
    return WasapiSharedTriggerBlock._(memory, WasapiNativeApi.load(), false);
  }

  final Pointer<Uint8> _memory;
  final WasapiNativeApi _api;
  final bool _ownsMemory;

  int get address {
    throwIfDisposed();
    return _memory.address;
  }

  int get count {
    throwIfDisposed();
    return _memory.cast<Uint32>()[_countOffset ~/ 4];
  }

  Pointer<Void> get _lock =>
      Pointer<Void>.fromAddress(_memory.address + _lockOffset);
  Pointer<Uint32> get _sequences =>
      Pointer<Uint32>.fromAddress(_memory.address + _headerBytes);
  Pointer<Float> get _velocities => Pointer<Float>.fromAddress(
        _memory.address + _headerBytes + count * sizeOf<Uint32>(),
      );

  /// Publishes a one-shot hit. Velocity is normalized to 0...1.
  void trigger(int index, {double velocity = 1}) {
    throwIfDisposed();
    RangeError.checkValidIndex(index, this, 'index', count);
    _api.acquireLock(_lock);
    try {
      _velocities[index] = velocity.clamp(0.0, 1.0);
      _sequences[index] = (_sequences[index] + 1) & 0xffffffff;
    } finally {
      _api.releaseLock(_lock);
    }
  }

  /// Copies all counters and velocities without blocking the audio thread.
  bool trySnapshot(
    Pointer<Uint32> sequences,
    Pointer<Float> velocities,
  ) {
    throwIfDisposed();
    if (sequences == nullptr || velocities == nullptr) {
      throw ArgumentError('snapshot destinations must not be null');
    }
    if (_api.tryAcquireLock(_lock) == 0) return false;
    try {
      _api.moveMemory(
        sequences.cast<Void>(),
        _sequences.cast<Void>(),
        count * sizeOf<Uint32>(),
      );
      _api.moveMemory(
        velocities.cast<Void>(),
        _velocities.cast<Void>(),
        count * sizeOf<Float>(),
      );
      return true;
    } finally {
      _api.releaseLock(_lock);
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
