/// Controls and readings shared between an application and its audio isolate.
library;

import 'dart:ffi';

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';

const int _magic = 0x44554342; // "DUCB"
const int _headerBytes = 16;

/// Floats and counters in native memory that the isolate running the
/// interface and the isolate rendering audio both see, without a lock.
///
/// Three regions, each with one writer:
///
/// * **parameters** - volume, filter gains, a seek target. The application
///   writes them with [setParameter]; the processor reads them each block.
/// * **triggers** - counters the application bumps with [trigger] ("seek
///   now", "hit the snare"); the processor compares [triggerSequence] with
///   the last value it acted on.
/// * **telemetry** - position, peak, spectrum. The processor writes them with
///   [publish]; the interface reads them when it paints.
///
/// Every value is an aligned 32-bit word, which every CPU dart_ui runs on
/// loads and stores whole, so a reader sees an old value or a new one, never
/// half of each. Nothing waits: the audio side cannot be blocked by a busy
/// interface, which is the one thing a render callback must never be. What
/// it does not give is consistency *between* values - a reader can see the
/// new volume and the old balance in the same block, which for controls a
/// person moves by hand is inaudible.
///
/// Created with [AudioControlBlock.allocate] by the application, handed to
/// the audio isolate by [address], and opened there with
/// [AudioControlBlock.attach]. Only the allocating side frees the memory, and
/// it must outlive the audio isolate.
final class AudioControlBlock with DisposableMixin {
  AudioControlBlock._(this._memory, this._owns)
      : parameterCount = _memory.cast<Uint32>()[1],
        triggerCount = _memory.cast<Uint32>()[2],
        telemetryCount = _memory.cast<Uint32>()[3];

  factory AudioControlBlock.allocate({
    int parameters = 0,
    int triggers = 0,
    int telemetry = 0,
  }) {
    if (parameters < 0 || triggers < 0 || telemetry < 0) {
      throw ArgumentError('counts must not be negative');
    }
    final int bytes = _headerBytes + 4 * (parameters + triggers + telemetry);
    final Pointer<Uint8> memory =
        NativeAllocator.instance.allocate<Uint8>(bytes);
    memory.asTypedList(bytes).fillRange(0, bytes, 0);
    memory.cast<Uint32>()
      ..[0] = _magic
      ..[1] = parameters
      ..[2] = triggers
      ..[3] = telemetry;
    return AudioControlBlock._(memory, true);
  }

  /// Opens a block another isolate allocated.
  factory AudioControlBlock.attach(int address) {
    if (address == 0) {
      throw ArgumentError.value(address, 'address', 'must not be zero');
    }
    final Pointer<Uint8> memory = Pointer<Uint8>.fromAddress(address);
    if (memory.cast<Uint32>()[0] != _magic) {
      throw StateError('address does not hold a dart_ui audio control block');
    }
    return AudioControlBlock._(memory, false);
  }

  final Pointer<Uint8> _memory;
  final bool _owns;
  final int parameterCount;
  final int triggerCount;
  final int telemetryCount;

  /// Where the block lives, for [AudioControlBlock.attach] on another isolate.
  int get address {
    throwIfDisposed();
    return _memory.address;
  }

  Pointer<Float> get _parameters =>
      Pointer<Float>.fromAddress(_memory.address + _headerBytes);
  Pointer<Uint32> get _triggers => Pointer<Uint32>.fromAddress(
      _memory.address + _headerBytes + 4 * parameterCount);
  Pointer<Float> get _telemetry => Pointer<Float>.fromAddress(
      _memory.address + _headerBytes + 4 * (parameterCount + triggerCount));

  double parameter(int index) {
    RangeError.checkValidIndex(index, this, 'index', parameterCount);
    return _parameters[index];
  }

  void setParameter(int index, double value) {
    RangeError.checkValidIndex(index, this, 'index', parameterCount);
    _parameters[index] = value;
  }

  /// Asks the processor to act once more on trigger [index].
  void trigger(int index) {
    RangeError.checkValidIndex(index, this, 'index', triggerCount);
    _triggers[index] = (_triggers[index] + 1) & 0xFFFFFFFF;
  }

  /// How many times trigger [index] has fired; the processor acts when this
  /// differs from the value it saw last.
  int triggerSequence(int index) {
    RangeError.checkValidIndex(index, this, 'index', triggerCount);
    return _triggers[index];
  }

  double telemetry(int index) {
    RangeError.checkValidIndex(index, this, 'index', telemetryCount);
    return _telemetry[index];
  }

  void publish(int index, double value) {
    RangeError.checkValidIndex(index, this, 'index', telemetryCount);
    _telemetry[index] = value;
  }

  @override
  void onDispose() {
    if (_owns) NativeAllocator.instance.free(_memory);
  }
}
