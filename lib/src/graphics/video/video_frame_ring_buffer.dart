/// Reusable native frame storage for decoder hot paths.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../ffi/native_memory.dart';
import 'video_frame.dart';

/// A fixed-size ring of equally sized native-memory frame slots.
///
/// One native allocation and one external [Uint8List] view per slot are made
/// up front. [acquire] only advances a cursor and generation counter: a native
/// decoder can write into [NativeVideoFrameLease.pointer] directly, then hand
/// [NativeVideoFrameLease.bytes] to a video plane without a Dart-side copy.
///
/// ## Lifetime
///
/// A lease stays valid until its slot is acquired again, [invalidateAll] is
/// called, or the ring is disposed. With three slots this normally means a
/// frame may be retained across the next two acquisitions. Consumers that
/// keep frames longer must copy their bytes. Always use [isValid] or
/// [validate] before accessing a retained lease.
///
/// The external typed-list view itself cannot intercept indexing after native
/// memory is released. Therefore a view obtained from [bytes] must never be
/// used after its lease becomes invalid. Decoder implementations must dispose
/// the ring only after native writes have stopped.
final class NativeVideoFrameRing {
  NativeVideoFrameRing({
    required this.slotCount,
    required this.bytesPerSlot,
    Allocator? allocator,
  }) : _allocator = allocator ?? NativeAllocator.instance {
    if (slotCount <= 0) {
      throw RangeError.value(slotCount, 'slotCount', 'must be positive');
    }
    if (bytesPerSlot <= 0) {
      throw RangeError.value(
        bytesPerSlot,
        'bytesPerSlot',
        'must be positive',
      );
    }
    _memory = _allocator.allocate<Uint8>(slotCount * bytesPerSlot);
    // Both the pointer and the view per slot are made here and never again.
    // `Pointer.fromAddress` and `asTypedList` each allocate, and a decoder
    // that reached for `lease.pointer` per frame paid for one of them 25
    // times a second for a value fixed for the ring's whole life.
    _pointers = List<Pointer<Uint8>>.generate(slotCount, (int index) {
      return Pointer<Uint8>.fromAddress(_memory.address + index * bytesPerSlot);
    }, growable: false);
    _views = List<Uint8List>.generate(slotCount, (int index) {
      return _pointers[index].asTypedList(bytesPerSlot);
    }, growable: false);
    _generations = List<int>.filled(slotCount, 0, growable: false);
  }

  final int slotCount;
  final int bytesPerSlot;
  final Allocator _allocator;
  late final Pointer<Uint8> _memory;
  late final List<Pointer<Uint8>> _pointers;
  late final List<Uint8List> _views;
  late final List<int> _generations;
  int _nextSlot = 0;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  /// Acquires the next slot and invalidates its previous lease, if any.
  ///
  /// The bytes are intentionally not cleared. A decoder overwrites the full
  /// slot and avoiding that extra memory pass is the point of this type.
  NativeVideoFrameLease acquire() {
    _throwIfDisposed();
    final int slot = _nextSlot;
    _nextSlot = (_nextSlot + 1) % slotCount;
    final int generation = ++_generations[slot];
    return NativeVideoFrameLease._(this, slot, generation);
  }

  /// Invalidates every outstanding lease without freeing or reallocating.
  ///
  /// Decoders use this after a seek so a frame from the old timeline cannot be
  /// mistaken for storage belonging to the new sequence.
  void invalidateAll() {
    _throwIfDisposed();
    for (var index = 0; index < _generations.length; index++) {
      _generations[index]++;
    }
    _nextSlot = 0;
  }

  /// Releases the native allocation exactly once and invalidates all leases.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _allocator.free(_memory);
  }

  Pointer<Uint8> _pointerAt(int slot) => _pointers[slot];

  bool _isValid(int slot, int generation) =>
      !_disposed && _generations[slot] == generation;

  void _validate(int slot, int generation) {
    if (!_isValid(slot, generation)) {
      throw StateError(
        'native video frame slot $slot generation $generation is no longer '
        'valid',
      );
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('the native video frame ring is disposed');
  }
}

/// One generational lease over a slot in [NativeVideoFrameRing].
///
/// Do not retain [pointer] or [bytes] independently of this object: those
/// values cannot perform a generation check on their own.
final class NativeVideoFrameLease implements VideoFrameStorageLifetime {
  const NativeVideoFrameLease._(this._owner, this.slot, this.generation);

  final NativeVideoFrameRing _owner;
  final int slot;
  final int generation;

  @override
  bool get isValid => _owner._isValid(slot, generation);

  /// Throws if this slot has wrapped, was invalidated, or was freed.
  @override
  void validate() => _owner._validate(slot, generation);

  /// Destination pointer for a native decoder write.
  Pointer<Uint8> get pointer {
    validate();
    return _owner._pointerAt(slot);
  }

  /// Cached external view over [pointer], with no per-acquisition allocation.
  Uint8List get bytes {
    validate();
    return _owner._views[slot];
  }

  int get length {
    validate();
    return _owner.bytesPerSlot;
  }
}
