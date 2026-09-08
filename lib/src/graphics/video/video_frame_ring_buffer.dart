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
/// ## Lifetime: a slot is borrowed, not merely dated
///
/// [acquire] hands out a **borrow** and never returns a slot whose lease is
/// still outstanding. A consumer keeps its frame until it calls
/// [NativeVideoFrameLease.release]; until then the ring will hand out any
/// other free slot, and when there is none it refuses - it returns null and
/// counts the refusal in [droppedFrames].
///
/// This replaces a generational grace period that only *detected* the hazard
/// after the fact. Under it a lease stayed valid until its slot came round
/// again, so a renderer that validated in nanoseconds and then converted for
/// tens of milliseconds was performing a check-then-use over a window it did
/// not own. It failed in production as
/// `native video frame slot 0 generation 85 is no longer valid`, thrown from
/// `_convertPackedRgb` in the middle of a conversion. Making the conversion
/// faster (70 ms to 27 ms per frame, §68) made that window narrower and the
/// crash rarer, which is the worst thing that can be done to a race short of
/// fixing it. A borrow closes the window instead of narrowing it: the slot
/// cannot be reissued while anybody holds it, so there is nothing left to
/// detect.
///
/// Refusing rather than waiting is deliberate. A decoder fed by a real-time
/// clock that blocked on a slow consumer would turn a rendering problem into
/// audio/video desynchronisation; dropping the frame is the correct answer,
/// and [droppedFrames] is there so a drop is never silent - a ring quietly
/// dropping half the frames is indistinguishable from a slow decoder.
///
/// A borrow that is never returned is a different failure: it starves the ring
/// permanently, which is a hang rather than a glitch. After [starvationLimit]
/// consecutive refusals [acquire] therefore stops returning null and throws,
/// naming the leak, because a ring that has produced nothing for seconds is a
/// bug in a consumer and must not look like a slow file.
///
/// **Do not replace the release with a `Finalizer` or a `WeakReference`.** It
/// is the obvious idea and it was measured on the player's own retention
/// pattern - one frame on screen, one decoded ahead, the previous dropped by
/// reference: of 1000 frames the ring could serve **15**. A frame that
/// survives one scavenge is promoted, and from there it waits for a major
/// collection that a loop with no old-space pressure does not run for seconds.
///
/// The rule this borrow replaced - *"consumers that keep frames longer must
/// copy their bytes"* - was not merely risky, it was unfollowable: when the
/// borrow was made strict, the in-tree Media Foundation test suite went red
/// because it had been retaining every frame it decoded, and so had the demo
/// player. A contract that the repository's own consumers all break is not a
/// contract.
///
/// ## Threading
///
/// Every field here is a plain Dart field, deliberately: all three decoders
/// that own a ring - Media Foundation, GStreamer and AVFoundation - call
/// [acquire] and fill the slot from **one isolate on one thread**. The
/// platform decoders do their own work on their own threads, but what reaches
/// this ring is a synchronous FFI copy (`IMF2DBuffer::ContiguousCopyTo`,
/// `gst_buffer_extract`, `memcpy` out of a locked `CVPixelBuffer`) made by the
/// thread that called [acquire], and the consumer runs on that same thread. A
/// mutex here would guard nothing. Should a decoder ever move its production
/// to another thread or isolate - the `BlockingSlotMailbox` in
/// `lib/src/concurrency/` exists for exactly that shape, sharing this ring's
/// pixels while only a slot index travels - then this bookkeeping, not just
/// the pixels, has to move into native memory with proper ordering.
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
    this.starvationLimit = 60,
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
    if (starvationLimit <= 0) {
      throw RangeError.value(
        starvationLimit,
        'starvationLimit',
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
    // One byte per slot rather than a `List<bool>`: this is read on every
    // acquisition and allocated once, like everything else in this
    // constructor.
    _borrowed = Uint8List(slotCount);
  }

  final int slotCount;
  final int bytesPerSlot;

  /// Consecutive refusals that mean a consumer has stopped releasing.
  ///
  /// A busy consumer holding every slot for a few frames is legitimate and
  /// only costs those frames. One holding every slot for [starvationLimit]
  /// acquisitions in a row - at a 60 Hz decode pump, a second of frozen
  /// picture - is not busy, it has leaked, and [acquire] says so by name
  /// instead of letting the ring look like a stalled file.
  final int starvationLimit;

  final Allocator _allocator;
  late final Pointer<Uint8> _memory;
  late final List<Pointer<Uint8>> _pointers;
  late final List<Uint8List> _views;
  late final List<int> _generations;
  late final Uint8List _borrowed;
  int _borrowedCount = 0;
  int _nextSlot = 0;
  int _droppedFrames = 0;
  int _consecutiveDrops = 0;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  /// Slots whose lease is outstanding right now.
  int get borrowedSlots => _borrowedCount;

  /// Slots [acquire] could hand out right now.
  int get freeSlots => slotCount - _borrowedCount;

  /// Frames this ring refused to store because every slot was borrowed.
  ///
  /// Exposed rather than logged so whichever layer reports playback health -
  /// a decoder, a synchroniser, a demo's statistics line - can read it. A drop
  /// nobody can count is a drop nobody can tell from a slow decoder.
  int get droppedFrames => _droppedFrames;

  /// How many acquisitions in a row have been refused, zeroed by a success.
  int get consecutiveDrops => _consecutiveDrops;

  /// Acquires a free slot, or null when every slot is still borrowed.
  ///
  /// The bytes are intentionally not cleared. A decoder overwrites the full
  /// slot and avoiding that extra memory pass is the point of this type.
  ///
  /// Throws once [starvationLimit] consecutive acquisitions have been refused;
  /// see [starvationLimit] for why a leak is not reported as a drop.
  NativeVideoFrameLease? acquire() {
    _throwIfDisposed();
    // Linear from the cursor, at most one pass: with three slots this is the
    // first probe in the healthy case and there is no allocation on the path.
    for (var probe = 0; probe < slotCount; probe++) {
      var slot = _nextSlot + probe;
      if (slot >= slotCount) slot -= slotCount;
      if (_borrowed[slot] != 0) continue;
      var next = slot + 1;
      if (next >= slotCount) next = 0;
      _nextSlot = next;
      _borrowed[slot] = 1;
      _borrowedCount++;
      _consecutiveDrops = 0;
      final int generation = ++_generations[slot];
      return NativeVideoFrameLease._(this, slot, generation);
    }
    _droppedFrames++;
    _consecutiveDrops++;
    if (_consecutiveDrops >= starvationLimit) {
      throw StateError(
        'all $slotCount native video frame slots have been borrowed for '
        '$_consecutiveDrops consecutive acquisitions: a consumer is holding '
        'video frames without calling release()',
      );
    }
    return null;
  }

  /// Invalidates every outstanding lease and returns every borrow.
  ///
  /// Decoders use this after a seek so a frame from the old timeline cannot be
  /// mistaken for storage belonging to the new sequence. It is also the only
  /// way a slot leaks back: a consumer that kept a frame across the seek finds
  /// its lease invalid - a named error on the next access, never a torn
  /// picture - which is the same contract seek always had.
  void invalidateAll() {
    _throwIfDisposed();
    for (var index = 0; index < _generations.length; index++) {
      _generations[index]++;
      _borrowed[index] = 0;
    }
    _borrowedCount = 0;
    _consecutiveDrops = 0;
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
      !_disposed && _borrowed[slot] != 0 && _generations[slot] == generation;

  void _validate(int slot, int generation) {
    if (_isValid(slot, generation)) return;
    if (_disposed) {
      throw StateError('the native video frame ring is disposed');
    }
    // The two remaining causes are told apart on purpose: a released lease is
    // a use-after-release in one consumer, while a superseded generation
    // means a seek or a dispose invalidated it underneath.
    if (_generations[slot] == generation) {
      throw StateError(
        'native video frame slot $slot generation $generation has already '
        'been released',
      );
    }
    throw StateError(
      'native video frame slot $slot generation $generation is no longer '
      'valid',
    );
  }

  /// Returns a borrow. Releasing twice, or releasing a lease a seek already
  /// invalidated, is a no-op rather than an error: a consumer must be able to
  /// release unconditionally in a `finally`.
  void _release(int slot, int generation) {
    if (_disposed) return;
    if (_generations[slot] != generation) return;
    if (_borrowed[slot] == 0) return;
    _borrowed[slot] = 0;
    _borrowedCount--;
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('the native video frame ring is disposed');
  }
}

/// One generational lease over a slot in [NativeVideoFrameRing].
///
/// The slot is held until [release]. Do not retain [pointer] or [bytes]
/// independently of this object: those values cannot perform a lifetime check
/// on their own, and after [release] the ring may hand the same memory to the
/// next frame.
final class NativeVideoFrameLease implements VideoFrameStorageLifetime {
  const NativeVideoFrameLease._(this._owner, this.slot, this.generation);

  final NativeVideoFrameRing _owner;
  final int slot;
  final int generation;

  @override
  bool get isValid => _owner._isValid(slot, generation);

  /// Throws if this slot was released, invalidated by a seek, or freed.
  @override
  void validate() => _owner._validate(slot, generation);

  /// Gives the slot back to the ring. Idempotent.
  ///
  /// Consumers reach this through [VideoFrame.release] rather than by holding
  /// a lease directly; both are the same call.
  @override
  void release() => _owner._release(slot, generation);

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
