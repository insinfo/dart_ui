/// Lock-free single-writer telemetry shared with a UI isolate.
library;

import 'dart:ffi';

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';

const int _telemetryMagic = 0x4d554144; // "DAUM"
const int _telemetryVersion = 1;
const int _headerBytes = 32;

/// Aligned float32 telemetry written by one realtime isolate and sampled by UI.
///
/// Aligned 32-bit loads/stores are atomic on supported Windows architectures.
/// Values are independent and eventually consistent; this is for meters and
/// playheads, never for transactional control state.
final class WasapiSharedTelemetryBlock with DisposableMixin {
  WasapiSharedTelemetryBlock._(this._memory, this._ownsMemory);

  factory WasapiSharedTelemetryBlock.allocate(int count) {
    if (count <= 0) {
      throw RangeError.value(count, 'count', 'must be positive');
    }
    final Pointer<Uint8> memory = NativeAllocator.instance.allocate<Uint8>(
      _headerBytes + count * sizeOf<Float>(),
    );
    memory.cast<Uint32>()[0] = _telemetryMagic;
    memory.cast<Uint32>()[1] = _telemetryVersion;
    memory.cast<Uint32>()[2] = count;
    return WasapiSharedTelemetryBlock._(memory, true);
  }

  factory WasapiSharedTelemetryBlock.attach(int address) {
    if (address == 0) {
      throw ArgumentError.value(address, 'address', 'must not be zero');
    }
    final Pointer<Uint8> memory = Pointer<Uint8>.fromAddress(address);
    if (memory.cast<Uint32>()[0] != _telemetryMagic ||
        memory.cast<Uint32>()[1] != _telemetryVersion) {
      throw StateError('address does not contain dart_ui audio telemetry');
    }
    return WasapiSharedTelemetryBlock._(memory, false);
  }

  final Pointer<Uint8> _memory;
  final bool _ownsMemory;

  int get address {
    throwIfDisposed();
    return _memory.address;
  }

  int get count {
    throwIfDisposed();
    return _memory.cast<Uint32>()[2];
  }

  Pointer<Float> get _values =>
      Pointer<Float>.fromAddress(_memory.address + _headerBytes);

  void publish(int index, double value) {
    throwIfDisposed();
    RangeError.checkValidIndex(index, this, 'index', count);
    _values[index] = value;
  }

  double valueAt(int index) {
    throwIfDisposed();
    RangeError.checkValidIndex(index, this, 'index', count);
    return _values[index];
  }

  @override
  void onDispose() {
    if (_ownsMemory) {
      _memory.cast<Uint32>()[0] = 0;
      NativeAllocator.instance.free(_memory);
    }
  }
}
