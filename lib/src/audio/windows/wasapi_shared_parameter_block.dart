/// Shared native float parameters for a realtime WASAPI processor.
library;

import 'dart:ffi';

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import 'wasapi_bindings.dart';

const int _parameterMagic = 0x44554150; // "DUAP"
const int _parameterVersion = 1;
const int _headerBytes = 64;
const int _magicOffset = 0;
const int _versionOffset = 4;
const int _countOffset = 8;
const int _lockOffset = 32;

/// Float controls in native memory, shared between the UI and audio isolates.
///
/// UI writes may wait briefly. The realtime side uses [trySnapshot] and keeps
/// its previous snapshot on contention, so parameter automation cannot block
/// the WASAPI period.
final class WasapiSharedParameterBlock with DisposableMixin {
  WasapiSharedParameterBlock._(
    this._memory,
    this._api,
    this._ownsMemory,
  );

  factory WasapiSharedParameterBlock.allocate(int count) {
    if (count <= 0) {
      throw RangeError.value(count, 'count', 'must be positive');
    }
    final Pointer<Uint8> memory = NativeAllocator.instance.allocate<Uint8>(
      _headerBytes + count * sizeOf<Float>(),
    );
    final WasapiNativeApi api = WasapiNativeApi.load();
    memory.cast<Uint32>()[_magicOffset ~/ 4] = _parameterMagic;
    memory.cast<Uint32>()[_versionOffset ~/ 4] = _parameterVersion;
    memory.cast<Uint32>()[_countOffset ~/ 4] = count;
    api.initializeLock(Pointer<Void>.fromAddress(memory.address + _lockOffset));
    final Pointer<Float> values =
        Pointer<Float>.fromAddress(memory.address + _headerBytes);
    for (int index = 0; index < count; index++) {
      values[index] = 0;
    }
    return WasapiSharedParameterBlock._(memory, api, true);
  }

  factory WasapiSharedParameterBlock.attach(int address) {
    if (address == 0) {
      throw ArgumentError.value(address, 'address', 'must not be zero');
    }
    final Pointer<Uint8> memory = Pointer<Uint8>.fromAddress(address);
    if (memory.cast<Uint32>()[_magicOffset ~/ 4] != _parameterMagic ||
        memory.cast<Uint32>()[_versionOffset ~/ 4] != _parameterVersion) {
      throw StateError('address does not contain a dart_ui parameter block');
    }
    return WasapiSharedParameterBlock._(
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

  int get count {
    throwIfDisposed();
    return _memory.cast<Uint32>()[_countOffset ~/ 4];
  }

  Pointer<Void> get _lock =>
      Pointer<Void>.fromAddress(_memory.address + _lockOffset);
  Pointer<Float> get _values =>
      Pointer<Float>.fromAddress(_memory.address + _headerBytes);

  void setValue(int index, double value) {
    throwIfDisposed();
    RangeError.checkValidIndex(index, this, 'index', count);
    _api.acquireLock(_lock);
    try {
      _values[index] = value;
    } finally {
      _api.releaseLock(_lock);
    }
  }

  double valueAt(int index) {
    throwIfDisposed();
    RangeError.checkValidIndex(index, this, 'index', count);
    _api.acquireLock(_lock);
    try {
      return _values[index];
    } finally {
      _api.releaseLock(_lock);
    }
  }

  /// Copies all values into caller-owned native memory without waiting.
  bool trySnapshot(Pointer<Float> destination) {
    throwIfDisposed();
    if (destination == nullptr) {
      throw ArgumentError.value(destination, 'destination', 'must not be null');
    }
    if (_api.tryAcquireLock(_lock) == 0) return false;
    try {
      _api.moveMemory(
        destination.cast<Void>(),
        _values.cast<Void>(),
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
