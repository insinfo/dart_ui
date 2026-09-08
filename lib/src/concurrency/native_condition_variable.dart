/// A condition variable two isolates in one process can wait on.
library;

import 'dart:ffi';

import '../ffi/native_memory.dart';
import 'blocking_wait.dart';
import 'native_mutex.dart';
import 'native_sync_bindings.dart';

/// The platform's own condition variable: park this thread until told.
///
/// Pairs with a [NativeMutex] the way the underlying primitives require - the
/// wait atomically releases the lock, sleeps, and has the lock again when it
/// returns - so a producer can publish under the lock and wake a consumer
/// without either of them ever polling.
///
/// ## What is shared and what is not
///
/// The condition variable itself is shared: it is bytes in the process heap
/// and every isolate reaches the same bytes. The **wait scratch** is not. On
/// POSIX the wait takes an absolute `struct timespec`, and if the two isolates
/// parked on one condition variable computed their deadlines into the same
/// buffer, each would be waiting on the other's deadline. So every isolate
/// that constructs or attaches one of these allocates sixteen private bytes
/// and frees them in [detach] or [destroy]. On Windows the wait takes a
/// relative millisecond count and there is no scratch at all.
///
/// ## Every wait is bounded, and sliced
///
/// [waitFor] never waits longer than [maxNativeWaitSliceMilliseconds] in one
/// native call, and counts the slices against a [Stopwatch]. See that constant
/// for why - briefly: `pthread_cond_timedwait` measures against a clock the
/// user can set, and a Dart [Stopwatch] cannot be set.
///
/// [nativeWaitCount] is exposed because "did the consumer block or did it
/// spin?" is otherwise unanswerable from a test: both produce the same bytes
/// at the same time. A wait of a third of a second shows up here as one or two
/// native calls; a spin loop would show hundreds of thousands.
final class NativeConditionVariable {
  NativeConditionVariable._(this._api, this._memory, this.ownsMemory)
      : _scratch = _api.waitScratchBytes == 0
            ? nullptr
            : NativeAllocator.instance
                .allocate<Uint8>(_api.waitScratchBytes)
                .cast<Void>();

  /// Bytes one condition variable occupies in a shared block, guard included.
  static const int reservedBytes =
      nativeConditionReservedBytes + nativeSyncGuardBytes;

  /// Creates a condition variable in its own allocation.
  factory NativeConditionVariable.allocate() {
    final Pointer<Uint8> memory =
        NativeAllocator.instance.allocate<Uint8>(reservedBytes);
    try {
      return NativeConditionVariable.initializeAt(memory, ownsMemory: true);
    } on Object {
      NativeAllocator.instance.free(memory);
      rethrow;
    }
  }

  /// Initialises a condition variable inside memory the caller already owns.
  factory NativeConditionVariable.initializeAt(
    Pointer<Uint8> memory, {
    bool ownsMemory = false,
  }) {
    final NativeSyncApi api = NativeSyncApi.instance;
    writeSyncGuard(memory, nativeConditionReservedBytes);
    api.initializeCondition(memory.cast<Void>());
    final NativeConditionVariable condition =
        NativeConditionVariable._(api, memory, ownsMemory);
    condition.checkGuard();
    return condition;
  }

  /// Wraps a condition variable another isolate initialised, at [memory].
  factory NativeConditionVariable.attachAt(Pointer<Uint8> memory) =>
      NativeConditionVariable._(NativeSyncApi.instance, memory, false);

  /// Wraps a condition variable another isolate initialised, by address.
  factory NativeConditionVariable.attach(int address) {
    if (address == 0) {
      throw ArgumentError.value(address, 'address', 'must not be zero');
    }
    return NativeConditionVariable.attachAt(
        Pointer<Uint8>.fromAddress(address));
  }

  final NativeSyncApi _api;
  final Pointer<Uint8> _memory;

  /// Private to this isolate. See the class comment.
  final Pointer<Void> _scratch;

  final bool ownsMemory;
  bool _released = false;
  int _nativeWaitCount = 0;

  int get address => _memory.address;

  /// How many times this isolate has entered the platform's wait function.
  ///
  /// Isolate-local, like every Dart field: a consumer isolate has to send this
  /// back over a port for the spawning isolate to see it.
  int get nativeWaitCount => _nativeWaitCount;

  /// Parks the calling thread until woken or until [timeout] elapses.
  ///
  /// [mutex] must be held on entry and is held again on return, exactly as the
  /// underlying primitives specify. Returns true for a wake-up - **which may be
  /// spurious**, on every platform, so the caller must re-test its predicate
  /// and call again with whatever time is left - and false when the deadline
  /// passed.
  ///
  /// Refuses to run on the root isolate: parking there is a frozen window. See
  /// [BlockingWaitPolicy].
  bool waitFor(
    NativeMutex mutex,
    Duration timeout, {
    String operation = 'NativeConditionVariable.waitFor',
  }) {
    _throwIfReleased();
    BlockingWaitPolicy.check(operation);
    final int total = millisecondsCeil(timeout);
    if (total == 0) {
      // The documented "poll once" spelling. Still a real native call, because
      // a zero-length wait is the only way to release the lock and take it
      // again in one atomic step, which is what makes it a fair poll rather
      // than a peek.
      _nativeWaitCount++;
      return _api.waitOnCondition(
          _memory.cast<Void>(), mutex.pointer, 0, _scratch);
    }
    final Stopwatch elapsed = Stopwatch()..start();
    var remaining = total;
    while (true) {
      final int slice = remaining < maxNativeWaitSliceMilliseconds
          ? remaining
          : maxNativeWaitSliceMilliseconds;
      _nativeWaitCount++;
      final bool woken = _api.waitOnCondition(
          _memory.cast<Void>(), mutex.pointer, slice, _scratch);
      if (woken) return true;
      final int used = elapsed.elapsedMilliseconds;
      if (used >= total) return false;
      remaining = total - used;
    }
  }

  /// Wakes one parked waiter, if any. Cheap enough to call unconditionally.
  void wakeOne() {
    _throwIfReleased();
    _api.wakeOne(_memory.cast<Void>());
  }

  /// Wakes every parked waiter. Used at shutdown, where the point is that no
  /// waiter is left parked on something that will never arrive.
  void wakeAll() {
    _throwIfReleased();
    _api.wakeAll(_memory.cast<Void>());
  }

  /// Verifies the platform's condition variable fitted its reservation.
  /// See [nativeMutexReservedBytes].
  void checkGuard() {
    if (syncGuardIsIntact(_memory, nativeConditionReservedBytes)) return;
    throw StateError(
      'the native condition variable at $address overran its '
      '$nativeConditionReservedBytes byte reservation: ${_api.provenance} '
      'needs more room than this platform table allows for. Raise '
      'nativeConditionReservedBytes.',
    );
  }

  /// Releases this isolate's private scratch and nothing else.
  ///
  /// What an attached handle does at the end of its life. Calling it does not
  /// affect the shared primitive or any other isolate.
  void detach() {
    if (_released) return;
    _released = true;
    if (_scratch != nullptr) NativeAllocator.instance.free(_scratch);
  }

  /// Destroys the shared primitive and releases this isolate's scratch.
  ///
  /// Only the owner may call this, and only once every other isolate has
  /// stopped waiting: `pthread_cond_destroy` on a condition variable with a
  /// waiter parked on it returns `EBUSY`, and on Windows destroying is not
  /// even a thing you can ask about - the memory simply goes away underneath
  /// the sleeping thread. `BlockingSlotMailbox.dispose` is where that
  /// precondition is actually enforced.
  void destroy() {
    if (_released) return;
    _api.destroyCondition(_memory.cast<Void>());
    detach();
    if (ownsMemory) NativeAllocator.instance.free(_memory);
  }

  void _throwIfReleased() {
    if (_released) {
      throw StateError(
          'this NativeConditionVariable was detached or destroyed');
    }
  }
}
