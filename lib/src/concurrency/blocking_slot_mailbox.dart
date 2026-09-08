/// The frame handoff: a slot index crosses, the pixels never move.
library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'blocking_wait.dart';
import 'native_condition_variable.dart';
import 'native_mutex.dart';
import 'native_sync_bindings.dart';

const int _magic = 0x4d534c54; // "MSLT"
const int _version = 1;

const int _magicOffset = 0;
const int _versionOffset = 4;
const int _capacityOffset = 8;
const int _closedOffset = 12;
const int _headOffset = 16;
const int _tailOffset = 20;
const int _countOffset = 24;
const int _waiterOffset = 28;
const int _putTotalOffset = 32; // 64-bit
const int _takeTotalOffset = 40; // 64-bit

/// Padded to 64 so the first native primitive starts 16-byte aligned without
/// an alignment expression, and so a future field does not have to move one.
const int _headerBytes = 64;

const int _mutexOffset = _headerBytes;
const int _notEmptyOffset = _mutexOffset + NativeMutex.reservedBytes;
const int _notFullOffset =
    _notEmptyOffset + NativeConditionVariable.reservedBytes;
const int _entriesOffset =
    _notFullOffset + NativeConditionVariable.reservedBytes;

/// A published entry: two 32-bit fields, and that is the whole message.
const int _entryBytes = 8;

/// One frame's worth of message: which slot, and which generation of it.
///
/// Eight bytes. That is the entire point of this type - see
/// [BlockingSlotMailbox].
final class MailboxSlot {
  const MailboxSlot(this.slot, this.generation);

  /// Index into the ring the producer and consumer both attached to.
  final int slot;

  /// The ring's generation counter for that slot when it was published.
  ///
  /// Carried so the consumer can call `NativeVideoFrameLease.validate()` and
  /// find out that the ring wrapped while the message was in flight, instead
  /// of rendering whatever the producer has since overwritten the slot with.
  final int generation;

  @override
  String toString() => 'MailboxSlot(slot: $slot, generation: $generation)';
}

/// The mailbox is closed and no further message will arrive.
///
/// An [Exception] rather than an [Error]: a consumer loop ending because the
/// producer shut down is the normal way this ends, not a bug.
final class MailboxClosedException implements Exception {
  const MailboxClosedException(this.operation);

  final String operation;

  @override
  String toString() => 'MailboxClosedException: $operation on a closed mailbox';
}

/// A bounded queue of slot references that a consumer isolate can block on.
///
/// ## Why this exists at all
///
/// `NativeVideoFrameRing` already solved the memory question: one native
/// allocation, one view per slot, and a decoder writes the pixels where the
/// renderer will read them. Measured on this project, the shared ring costs
/// 1.10x a single-isolate baseline where copying through a `SendPort` costs
/// 3.47x and `TransferableTypedData` costs 4.82x.
///
/// What the ring cannot do is **tell anybody**. Publishing a frame went
/// through a `SendPort`, which means the consumer learns about it when its
/// event loop next runs a microtask drain and a message turn - work that is
/// scheduled behind every timer, every I/O completion and every widget rebuild
/// already queued. This type is the missing half: the consumer parks in the
/// operating system's own wait, and the producer's `WakeConditionVariable` /
/// `pthread_cond_signal` moves it back to runnable directly, with no Dart
/// event loop between the two.
///
/// ## The design correction that matters
///
/// `package:native_synchronization`'s `Mailbox.put` mallocs and **copies** the
/// payload, and `take` copies or wraps it. For an eight-megabyte frame that
/// reintroduces exactly the 3.47x copy the ring exists to avoid, one memcpy at
/// a time, twenty-five times a second.
///
/// So nothing here carries pixels. A message is [MailboxSlot]: a slot index
/// and a generation, eight bytes. The frame stays where the decoder wrote it
/// and the consumer reads it out of the same ring at the same address. If you
/// need to send bytes rather than a reference, that is what
/// [BlockingByteMailbox] is for - and it must never be used for a frame.
///
/// ## Ownership and teardown
///
/// One isolate calls [allocate] and owns the block. Others [attach] over the
/// integer [address] and own nothing. Teardown is a sequence, not a garbage
/// collection:
///
/// ```dart
/// mailbox.close();                 // wakes every parked waiter, from anywhere
/// await consumerExited;            // or mailbox.waitUntilQuiet(...)
/// mailbox.dispose();               // owner only, and only once nobody waits
/// ```
///
/// [dispose] refuses while a waiter is parked, by name, rather than freeing
/// memory a sleeping thread is about to touch. There is no [Finalizer]: a
/// finalizer runs when the collector feels like it and is allowed never to run,
/// which is not a lifetime for something another thread is inside.
final class BlockingSlotMailbox {
  BlockingSlotMailbox._(
    this._memory,
    this._mutex,
    this._notEmpty,
    this._notFull,
    this.ownsMemory,
  );

  /// Bytes a mailbox of [capacity] entries occupies.
  static int bytesFor(int capacity) => _entriesOffset + capacity * _entryBytes;

  /// Creates a mailbox owned by the calling isolate.
  ///
  /// [capacity] should match the ring's slot count: a producer that is allowed
  /// to publish more references than the ring has slots is a producer that
  /// will overwrite a frame the consumer has not read yet, and the generation
  /// check would then turn every such frame into a thrown `StateError` on the
  /// consumer side.
  factory BlockingSlotMailbox.allocate({required int capacity}) {
    if (capacity <= 0) {
      throw RangeError.value(capacity, 'capacity', 'must be positive');
    }
    final Pointer<Uint8> memory =
        NativeAllocator.instance.allocate<Uint8>(bytesFor(capacity));
    try {
      memory.cast<Uint32>()[_magicOffset ~/ 4] = _magic;
      memory.cast<Uint32>()[_versionOffset ~/ 4] = _version;
      memory.cast<Uint32>()[_capacityOffset ~/ 4] = capacity;
      return BlockingSlotMailbox._(
        memory,
        NativeMutex.initializeAt(
            Pointer<Uint8>.fromAddress(memory.address + _mutexOffset)),
        NativeConditionVariable.initializeAt(
            Pointer<Uint8>.fromAddress(memory.address + _notEmptyOffset)),
        NativeConditionVariable.initializeAt(
            Pointer<Uint8>.fromAddress(memory.address + _notFullOffset)),
        true,
      );
    } on Object {
      NativeAllocator.instance.free(memory);
      rethrow;
    }
  }

  /// Attaches to a mailbox another isolate in this process allocated.
  ///
  /// The magic and version are checked because the alternative - treating an
  /// arbitrary integer as a mailbox - means calling `pthread_mutex_trylock` on
  /// whatever happened to be at that address, and that does not fail, it
  /// corrupts.
  factory BlockingSlotMailbox.attach(int address) {
    if (address == 0) {
      throw ArgumentError.value(address, 'address', 'must not be zero');
    }
    final Pointer<Uint8> memory = Pointer<Uint8>.fromAddress(address);
    if (memory.cast<Uint32>()[_magicOffset ~/ 4] != _magic ||
        memory.cast<Uint32>()[_versionOffset ~/ 4] != _version) {
      throw StateError('address does not contain a dart_ui slot mailbox');
    }
    return BlockingSlotMailbox._(
      memory,
      NativeMutex.attachAt(Pointer<Uint8>.fromAddress(address + _mutexOffset)),
      NativeConditionVariable.attachAt(
          Pointer<Uint8>.fromAddress(address + _notEmptyOffset)),
      NativeConditionVariable.attachAt(
          Pointer<Uint8>.fromAddress(address + _notFullOffset)),
      false,
    );
  }

  final Pointer<Uint8> _memory;
  final NativeMutex _mutex;
  final NativeConditionVariable _notEmpty;
  final NativeConditionVariable _notFull;

  /// Whether this handle is the one that allocated the block.
  final bool ownsMemory;

  bool _released = false;

  /// The integer another isolate needs to [attach].
  int get address => _memory.address;

  int get capacity => _u32(_capacityOffset);

  /// True once [close] ran, from any isolate.
  bool get isClosed => _u32(_closedOffset) != 0;

  /// How many references are published and not yet taken.
  int get pendingCount => _u32(_countOffset);

  /// How many threads are parked inside this mailbox right now.
  ///
  /// The precondition [dispose] checks, and the reason it can refuse instead of
  /// freeing memory out from under a sleeping thread.
  int get parkedWaiters => _u32(_waiterOffset);

  int get putTotal => _i64(_putTotalOffset);
  int get takeTotal => _i64(_takeTotalOffset);

  /// How many times *this isolate* entered the platform's wait function.
  ///
  /// Exposed so a test can distinguish blocking from spinning, which is
  /// otherwise impossible: both deliver the same bytes at the same moment. A
  /// consumer that waited a third of a second shows one or two here; a spin
  /// loop would show six figures.
  int get nativeWaitCount =>
      _notEmpty.nativeWaitCount + _notFull.nativeWaitCount;

  /// Which native pair is underneath, for a bug report.
  String get provenance => NativeSyncApi.instance.provenance;

  /// Publishes a reference without ever parking. False when the queue is full.
  ///
  /// The form to use on an isolate that services a UI: it cannot block, so it
  /// is not guarded, and a producer that finds the queue full can drop the
  /// frame - which for video is usually the right answer anyway.
  bool tryPut(int slot, int generation) {
    _throwIfReleased();
    return _mutex.runLocked(() {
      if (isClosed) throw const MailboxClosedException('tryPut');
      if (_u32(_countOffset) >= capacity) return false;
      _push(slot, generation);
      _notEmpty.wakeOne();
      return true;
    });
  }

  /// Publishes a reference, parking while the queue is full.
  ///
  /// Refuses on the root isolate: see [BlockingWaitPolicy]. Throws
  /// [BlockingWaitTimeout] if room never appears, and [MailboxClosedException]
  /// if the mailbox closes while waiting.
  void put(
    int slot,
    int generation, {
    Duration timeout = defaultBlockingWaitTimeout,
  }) {
    _throwIfReleased();
    BlockingWaitPolicy.check('BlockingSlotMailbox.put');
    final Stopwatch elapsed = Stopwatch()..start();
    _mutex.runLocked(() {
      while (true) {
        if (isClosed) throw const MailboxClosedException('put');
        if (_u32(_countOffset) < capacity) {
          _push(slot, generation);
          _notEmpty.wakeOne();
          return;
        }
        _park(_notFull, elapsed, timeout, 'BlockingSlotMailbox.put');
      }
    }, timeout: timeout < defaultLockTimeout ? defaultLockTimeout : timeout);
  }

  /// Takes a reference if one is published. Never parks, never guarded.
  MailboxSlot? tryTake() {
    _throwIfReleased();
    return _mutex.runLocked(() {
      if (_u32(_countOffset) == 0) return null;
      return _pop();
    });
  }

  /// Parks this thread until a reference is published.
  ///
  /// **This stops the calling thread dead.** Not "yields", not "awaits": the
  /// operating system takes the thread off the run queue and nothing else on
  /// this isolate happens - no timers, no ports, no microtasks - until a
  /// producer wakes it or [timeout] runs out. That is the whole value of the
  /// method and the whole danger of it, so it refuses to run on the root
  /// isolate, where the failure would be a window that stops repainting and
  /// stops accepting input. Use [tryTake] there.
  ///
  /// Throws [BlockingWaitTimeout] when nothing arrives in time, and
  /// [MailboxClosedException] when the producer shuts the mailbox down - which
  /// is how a consumer loop is meant to end.
  MailboxSlot takeBlocking({
    Duration timeout = defaultBlockingWaitTimeout,
  }) {
    _throwIfReleased();
    BlockingWaitPolicy.check('BlockingSlotMailbox.takeBlocking');
    final Stopwatch elapsed = Stopwatch()..start();
    return _mutex.runLocked(() {
      while (true) {
        if (_u32(_countOffset) > 0) {
          final MailboxSlot taken = _pop();
          _notFull.wakeOne();
          return taken;
        }
        // Closed is tested *after* the queue, so a consumer drains what was
        // already published instead of dropping the last frames on shutdown.
        if (isClosed) throw const MailboxClosedException('takeBlocking');
        _park(_notEmpty, elapsed, timeout, 'BlockingSlotMailbox.takeBlocking');
      }
    }, timeout: timeout < defaultLockTimeout ? defaultLockTimeout : timeout);
  }

  /// Marks the mailbox closed and wakes every parked thread on both sides.
  ///
  /// Callable from any isolate and idempotent. This is the first half of
  /// shutdown, and the half that makes the second half possible: a waiter that
  /// is never woken is a waiter [dispose] can never get past.
  void close() {
    _throwIfReleased();
    _closeAndCountWaiters();
  }

  /// Closes, and reports how many threads were still parked, in one critical
  /// section.
  ///
  /// The two have to be atomic. A waiter decrements the count only while
  /// holding the lock - the condition wait reacquires it before returning - so
  /// a count read *inside* the same critical section that closed the mailbox
  /// is exact. Reading it afterwards is a race that [dispose] would lose about
  /// as often as it won, and losing it means handing the allocator memory that
  /// a just-woken thread is about to write to.
  int _closeAndCountWaiters() {
    return _mutex.runLocked(() {
      _setU32(_closedOffset, 1);
      // Both, and `wakeAll` rather than `wakeOne`: at shutdown the point is
      // that nobody is left parked, and a producer blocked on a full queue is
      // just as stuck as a consumer blocked on an empty one.
      _notEmpty.wakeAll();
      _notFull.wakeAll();
      return _u32(_waiterOffset);
    });
  }

  /// Blocks until no thread is parked in this mailbox, or [timeout] elapses.
  ///
  /// Returns whether the mailbox went quiet. For a shutdown where the owner
  /// has no other way to know the consumer has left - if it does have one (an
  /// `Isolate.exit` future, a port message), waiting on that is better, and
  /// this method is the fallback rather than the recommendation.
  ///
  /// Polls, deliberately: the thing being waited for is *the absence of
  /// waiters*, so there is nobody left to signal a condition variable, and a
  /// millisecond poll on a path that runs once per shutdown costs nothing.
  ///
  /// It parks, so it refuses on the root isolate like everything else here
  /// that does. That is not an inconvenience to route around: an application
  /// whose owner is the UI isolate shuts down by awaiting the consumer's
  /// `onExit` port, which is asynchronous and freezes nothing.
  bool waitUntilQuiet({Duration timeout = defaultBlockingWaitTimeout}) {
    _throwIfReleased();
    BlockingWaitPolicy.check('BlockingSlotMailbox.waitUntilQuiet');
    final Stopwatch elapsed = Stopwatch()..start();
    while (elapsed.elapsed < timeout) {
      if (parkedWaiters == 0) return true;
      sleep(const Duration(milliseconds: 1));
    }
    return parkedWaiters == 0;
  }

  /// Releases an attached handle's private per-isolate scratch.
  ///
  /// What a consumer isolate calls before it exits. It touches nothing shared,
  /// so calling it while the owner is still running is correct.
  ///
  /// Refused for the owner, and refused rather than quietly accepted: for the
  /// owner this would release sixteen bytes of scratch and leak the whole
  /// block, the mutex and both condition variables - a leak that looks exactly
  /// like a correct teardown from the outside.
  void detach() {
    if (_released) return;
    if (ownsMemory) {
      throw StateError(
        'the isolate that allocated this mailbox releases it with dispose(); '
        'detach() would leak the block',
      );
    }
    _released = true;
    _notEmpty.detach();
    _notFull.detach();
  }

  /// Destroys the primitives and frees the block. Owner only.
  ///
  /// Refuses, by name, while any thread is parked. Freeing here would hand the
  /// allocator memory that a sleeping thread is going to write to the moment
  /// it wakes, and that corruption surfaces somewhere else entirely - which is
  /// the failure mode this whole file is written to avoid.
  void dispose() {
    if (_released) return;
    if (!ownsMemory) {
      throw StateError(
        'only the isolate that allocated this mailbox may dispose it; an '
        'attached handle calls detach()',
      );
    }
    final int waiters = _closeAndCountWaiters();
    if (waiters != 0) {
      throw StateError(
        'refusing to free a mailbox with $waiters thread(s) parked in it. '
        'close() has already woken them; wait for them to leave - '
        'waitUntilQuiet(), or the consumer isolate\'s exit - and dispose '
        'then.',
      );
    }
    _released = true;
    _notEmpty.destroy();
    _notFull.destroy();
    _mutex.destroy();
    _setU32(_magicOffset, 0);
    NativeAllocator.instance.free(_memory);
  }

  // --- internals, all called with the lock held ----------------------------

  /// Parks on [condition] for whatever is left of [timeout].
  ///
  /// The waiter count is incremented before parking and decremented after, and
  /// both happen under the lock - the wait reacquires it before returning - so
  /// [parkedWaiters] is exact rather than approximate, which is what lets
  /// [dispose] treat it as a precondition.
  void _park(
    NativeConditionVariable condition,
    Stopwatch elapsed,
    Duration timeout,
    String operation,
  ) {
    final Duration remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      throw BlockingWaitTimeout(operation, elapsed.elapsed);
    }
    _setU32(_waiterOffset, _u32(_waiterOffset) + 1);
    try {
      condition.waitFor(_mutex, remaining, operation: operation);
    } finally {
      _setU32(_waiterOffset, _u32(_waiterOffset) - 1);
    }
    if (elapsed.elapsed >= timeout) {
      // Re-tested by the caller's loop as well, but reporting it here keeps
      // the message pointing at what was actually being waited for.
      throw BlockingWaitTimeout(operation, elapsed.elapsed);
    }
  }

  void _push(int slot, int generation) {
    final int tail = _u32(_tailOffset);
    final Pointer<Int32> words = _memory.cast<Int32>();
    final int at = (_entriesOffset + tail * _entryBytes) ~/ 4;
    words[at] = slot;
    words[at + 1] = generation;
    _setU32(_tailOffset, (tail + 1) % capacity);
    _setU32(_countOffset, _u32(_countOffset) + 1);
    _setI64(_putTotalOffset, _i64(_putTotalOffset) + 1);
  }

  MailboxSlot _pop() {
    final int head = _u32(_headOffset);
    final Pointer<Int32> words = _memory.cast<Int32>();
    final int at = (_entriesOffset + head * _entryBytes) ~/ 4;
    final MailboxSlot taken = MailboxSlot(words[at], words[at + 1]);
    _setU32(_headOffset, (head + 1) % capacity);
    _setU32(_countOffset, _u32(_countOffset) - 1);
    _setI64(_takeTotalOffset, _i64(_takeTotalOffset) + 1);
    return taken;
  }

  int _u32(int offset) => _memory.cast<Uint32>()[offset ~/ 4];
  void _setU32(int offset, int value) =>
      _memory.cast<Uint32>()[offset ~/ 4] = value;
  int _i64(int offset) => _memory.cast<Int64>()[offset ~/ 8];
  void _setI64(int offset, int value) =>
      _memory.cast<Int64>()[offset ~/ 8] = value;

  void _throwIfReleased() {
    if (_released) {
      throw StateError('this BlockingSlotMailbox handle was detached');
    }
  }
}
