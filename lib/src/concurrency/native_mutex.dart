/// A mutual exclusion lock two isolates in one process can share.
library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'blocking_wait.dart';
import 'native_sync_bindings.dart';

/// The platform's own mutex, living in native memory rather than in an object.
///
/// ## What makes it shareable
///
/// The lock is a few bytes at a fixed address in the process's heap, and a
/// second isolate reaches it with [attach] over the integer [address] - the
/// same handoff `WasapiPlaybackControlBlock` already uses for its control
/// block. No handle is duplicated, nothing is serialised, and the two isolates
/// are manipulating literally the same word of memory. This works because Dart
/// isolates are threads of one process: it is not, and must not be mistaken
/// for, inter-*process* synchronisation.
///
/// ## Ownership, spelled out, because [Finalizer] is not a lifetime
///
/// `package:native_synchronization` attaches a [Finalizer] to its mutex so the
/// native memory is released when the Dart wrapper is collected. That is not
/// usable here. A finalizer runs at the garbage collector's convenience and is
/// explicitly permitted never to run at all, and "the lock two isolates are
/// using is freed at an unpredictable moment, possibly while one of them is
/// inside it" is not a lifetime, it is a use-after-free with a schedule.
///
/// So ownership is explicit and asymmetric:
///
///   * The isolate that called [allocate] or [initializeAt] **owns** the
///     memory and is the only one that may [destroy] it.
///   * An isolate that called [attach] or [attachAt] owns nothing. It has no
///     teardown to run.
///   * The owner may only destroy after every other isolate has stopped using
///     the lock. Nothing here can check that for it; the mailboxes above this
///     file can, and do - see `BlockingSlotMailbox.dispose`.
///
/// ## There is no unbounded acquire
///
/// [acquire] takes a timeout and throws [BlockingWaitTimeout] when it expires.
/// The reason is the case there is no other answer to: an isolate that died
/// inside a critical section leaves the lock held forever, and
/// `AcquireSRWLockExclusive` has no timeout at all. A held lock in this layer
/// means somebody is copying four integers, so a two-second wait is not a
/// budget - it is the point at which "the holder is still running" has stopped
/// being a credible explanation.
final class NativeMutex {
  NativeMutex._(this._api, this._memory, this.ownsMemory);

  /// Bytes one mutex occupies in a shared block, guard included.
  ///
  /// A multiple of 16, so the next primitive placed after one of these is
  /// still aligned for anything the platform might need.
  static const int reservedBytes =
      nativeMutexReservedBytes + nativeSyncGuardBytes;

  /// Creates a mutex in its own allocation, owned by this isolate.
  factory NativeMutex.allocate() {
    final Pointer<Uint8> memory =
        NativeAllocator.instance.allocate<Uint8>(reservedBytes);
    try {
      return NativeMutex.initializeAt(memory, ownsMemory: true);
    } on Object {
      NativeAllocator.instance.free(memory);
      rethrow;
    }
  }

  /// Initialises a mutex inside memory the caller already owns.
  ///
  /// [ownsMemory] says whether [destroy] should free those bytes; a mutex
  /// embedded in a larger shared block says false, because the block is freed
  /// as a whole.
  factory NativeMutex.initializeAt(
    Pointer<Uint8> memory, {
    bool ownsMemory = false,
  }) {
    final NativeSyncApi api = NativeSyncApi.instance;
    // The guard goes down *before* the primitive is initialised, so that
    // `pthread_mutex_init` writing past the reservation is caught by the very
    // first check rather than blamed on whatever ran next.
    writeSyncGuard(memory, nativeMutexReservedBytes);
    api.initializeMutex(memory.cast<Void>());
    final NativeMutex mutex = NativeMutex._(api, memory, ownsMemory);
    mutex.checkGuard();
    return mutex;
  }

  /// Wraps a mutex another isolate initialised, at [memory].
  factory NativeMutex.attachAt(Pointer<Uint8> memory) =>
      NativeMutex._(NativeSyncApi.instance, memory, false);

  /// Wraps a mutex another isolate initialised, by integer address.
  factory NativeMutex.attach(int address) {
    if (address == 0) {
      throw ArgumentError.value(address, 'address', 'must not be zero');
    }
    return NativeMutex.attachAt(Pointer<Uint8>.fromAddress(address));
  }

  final NativeSyncApi _api;
  final Pointer<Uint8> _memory;

  /// Whether [destroy] releases the underlying allocation.
  final bool ownsMemory;

  bool _destroyed = false;

  /// The value another isolate needs to [attach].
  int get address => _memory.address;

  /// The raw pointer, for [NativeConditionVariable] which must pass the same
  /// lock to the platform's wait function.
  Pointer<Void> get pointer => _memory.cast<Void>();

  /// Takes the lock if it is free. Returns false immediately otherwise.
  ///
  /// Safe to call from any isolate including the root one: it never parks.
  bool tryAcquire() {
    _throwIfDestroyed();
    return _api.tryAcquireMutex(pointer);
  }

  /// Takes the lock, giving up after [timeout] with a [BlockingWaitTimeout].
  ///
  /// The uncontended case - which is every case in this layer, because the
  /// critical sections are a few integer stores long - costs one interlocked
  /// instruction and never reaches the loop below.
  ///
  /// Deliberately **not** guarded by [BlockingWaitPolicy], unlike every wait on
  /// a condition variable. The distinction is what is being waited for: a
  /// condition wait is a wait for another isolate's *work*, which is unbounded
  /// in principle and is the thing that freezes a window. This is a wait for
  /// another isolate to finish four integer stores. Guarding it would make
  /// `tryPut` and `tryTake` - the forms a UI isolate is told to use - refuse on
  /// the UI isolate, which is the opposite of the intent.
  void acquire({Duration timeout = defaultLockTimeout}) {
    if (tryAcquire()) return;
    _acquireContended(timeout);
  }

  /// Backs off rather than spinning flat out.
  ///
  /// The first attempts are a bare retry: a lock held for the length of four
  /// integer stores is normally free again within a few hundred nanoseconds,
  /// and going to sleep for a millisecond to wait for that would cost a
  /// thousand times what the wait is worth. After that the retries sleep, and
  /// the sleeps grow, so a lock held by an isolate that is descheduled or dead
  /// does not turn one thread into a hot core until the timeout expires.
  void _acquireContended(Duration timeout) {
    final Stopwatch elapsed = Stopwatch()..start();
    const int spinAttempts = 64;
    for (var attempt = 0; attempt < spinAttempts; attempt++) {
      if (tryAcquire()) return;
    }
    var backoff = const Duration(microseconds: 50);
    const Duration maxBackoff = Duration(milliseconds: 2);
    while (elapsed.elapsed < timeout) {
      sleep(backoff);
      if (tryAcquire()) return;
      final Duration doubled = backoff * 2;
      backoff = doubled > maxBackoff ? maxBackoff : doubled;
    }
    throw BlockingWaitTimeout(
      'acquiring a NativeMutex at $address (the isolate holding it may have '
      'died inside its critical section)',
      elapsed.elapsed,
    );
  }

  void release() {
    _throwIfDestroyed();
    _api.releaseMutex(pointer);
  }

  /// Runs [body] under the lock and releases it however [body] leaves.
  ///
  /// The `finally` is the reason this exists rather than acquire/release at
  /// each call site: a critical section that grows an early return or throws
  /// on a bounds check leaves a native lock held forever, and every isolate
  /// that ever touches it afterwards is stuck.
  T runLocked<T>(T Function() body, {Duration timeout = defaultLockTimeout}) {
    acquire(timeout: timeout);
    try {
      return body();
    } finally {
      release();
    }
  }

  /// Verifies that the platform's mutex fitted the reservation.
  ///
  /// See [nativeMutexReservedBytes]. This is the difference between a wrong
  /// ABI guess being an error and it being a neighbouring field that quietly
  /// changes value: on a platform whose `pthread_mutex_t` is larger than the
  /// reservation, initialising it writes through the sentinel and this throws
  /// at construction instead of corrupting whatever was placed next.
  void checkGuard() {
    if (syncGuardIsIntact(_memory, nativeMutexReservedBytes)) return;
    throw StateError(
      'the native mutex at $address overran its $nativeMutexReservedBytes '
      'byte reservation: ${_api.provenance} needs more room than this '
      'platform table allows for. Raise nativeMutexReservedBytes.',
    );
  }

  /// Releases the platform primitive, and the memory when [ownsMemory].
  ///
  /// Idempotent, and it is the caller's job to know that nobody is inside the
  /// lock: `pthread_mutex_destroy` on a held mutex is undefined behaviour, and
  /// no API on any of these platforms can be asked whether a lock is held.
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _api.destroyMutex(pointer);
    if (ownsMemory) NativeAllocator.instance.free(_memory);
  }

  void _throwIfDestroyed() {
    if (_destroyed) throw StateError('this NativeMutex was destroyed');
  }
}
