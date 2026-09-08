/// A general-purpose byte handoff. **Never for a video frame.**
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../ffi/native_memory.dart';
import 'blocking_slot_mailbox.dart';
import 'blocking_wait.dart';
import 'native_condition_variable.dart';
import 'native_mutex.dart';

const int _magic = 0x4d425954; // "MBYT"
const int _version = 1;

const int _magicOffset = 0;
const int _versionOffset = 4;
const int _closedOffset = 8;
const int _hasValueOffset = 12;
const int _waiterOffset = 16;
const int _payloadAddressOffset = 24; // 64-bit
const int _payloadLengthOffset = 32; // 64-bit

const int _headerBytes = 64;
const int _mutexOffset = _headerBytes;
const int _notEmptyOffset = _mutexOffset + NativeMutex.reservedBytes;
const int _notFullOffset =
    _notEmptyOffset + NativeConditionVariable.reservedBytes;
const int _blockBytes = _notFullOffset + NativeConditionVariable.reservedBytes;

/// A one-slot mailbox that carries **copied** bytes between isolates.
///
/// This is the shape `package:native_synchronization` gives its `Mailbox`, and
/// it is here because it is genuinely the right answer for small, variable
/// messages that have no home of their own: a decoder's error string, a
/// container header, a seek acknowledgement. [put] allocates and copies, [take]
/// copies out and frees.
///
/// ## It must never carry a frame
///
/// Two copies per message is exactly the cost `NativeVideoFrameRing` was built
/// to remove. At 1920x1080 BGRA that is 7.91 MiB in and 7.91 MiB out, twenty-
/// five times a second, and it is the measured 3.47x regression the port path
/// already showed. Frames travel as a reference through
/// [BlockingSlotMailbox]; the pixels stay in the ring and are never moved by
/// anybody.
///
/// [maximumPayloadBytes] enforces that rather than leaving it to a comment: a
/// payload larger than a quarter of a megabyte is refused, because at that size
/// the caller is no longer sending a message, it is moving a buffer, and moving
/// a buffer through here is the mistake this whole layer exists to prevent.
///
/// ## Which heap the payload lives on
///
/// The producer allocates through [NativeAllocator] and the consumer frees
/// through it. That is safe here and would not be in general: allocating on one
/// heap and freeing on another is the corruption `native_memory.dart` documents
/// at length. It holds because both isolates are threads of one process and
/// [NativeAllocator] binds the same pair in every one of them - the COM task
/// allocator on Windows, the process's `malloc`/`free` elsewhere. Nothing here
/// would survive being turned into inter-process communication.
final class BlockingByteMailbox {
  BlockingByteMailbox._(
    this._memory,
    this._mutex,
    this._notEmpty,
    this._notFull,
    this.ownsMemory,
  );

  /// The largest message this mailbox accepts. See the class comment.
  static const int maximumPayloadBytes = 256 * 1024;

  /// Bytes one mailbox occupies. Fixed: the payload lives elsewhere.
  static int get blockBytes => _blockBytes;

  factory BlockingByteMailbox.allocate() {
    final Pointer<Uint8> memory =
        NativeAllocator.instance.allocate<Uint8>(_blockBytes);
    try {
      memory.cast<Uint32>()[_magicOffset ~/ 4] = _magic;
      memory.cast<Uint32>()[_versionOffset ~/ 4] = _version;
      return BlockingByteMailbox._(
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

  factory BlockingByteMailbox.attach(int address) {
    if (address == 0) {
      throw ArgumentError.value(address, 'address', 'must not be zero');
    }
    final Pointer<Uint8> memory = Pointer<Uint8>.fromAddress(address);
    if (memory.cast<Uint32>()[_magicOffset ~/ 4] != _magic ||
        memory.cast<Uint32>()[_versionOffset ~/ 4] != _version) {
      throw StateError('address does not contain a dart_ui byte mailbox');
    }
    return BlockingByteMailbox._(
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
  final bool ownsMemory;
  bool _released = false;

  int get address => _memory.address;
  bool get isClosed => _u32(_closedOffset) != 0;
  bool get hasValue => _u32(_hasValueOffset) != 0;
  int get parkedWaiters => _u32(_waiterOffset);
  int get nativeWaitCount =>
      _notEmpty.nativeWaitCount + _notFull.nativeWaitCount;

  /// Copies [bytes] into the mailbox, parking while it is full.
  void put(Uint8List bytes, {Duration timeout = defaultBlockingWaitTimeout}) {
    _throwIfReleased();
    if (bytes.length > maximumPayloadBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'a BlockingByteMailbox copies its payload twice and refuses anything '
            'over $maximumPayloadBytes bytes. Buffers that big belong in a '
            'shared ring, referenced through a BlockingSlotMailbox.',
      );
    }
    BlockingWaitPolicy.check('BlockingByteMailbox.put');
    final Stopwatch elapsed = Stopwatch()..start();
    // Allocated and filled before the lock is taken: a memcpy is long by the
    // standards of a critical section, and the whole discipline in this layer
    // is that a lock is held for integer stores only.
    //
    // One byte more than asked for, so that an empty message is still a real
    // allocation: `malloc(0)` and `CoTaskMemAlloc(0)` are both allowed to
    // return null, which `NativeAllocator` reports as an out-of-memory failure.
    final Pointer<Uint8> payload =
        NativeAllocator.instance.allocate<Uint8>(bytes.length + 1);
    payload.asTypedList(bytes.length).setAll(0, bytes);
    try {
      _mutex.runLocked(() {
        while (true) {
          if (isClosed) throw const MailboxClosedException('put');
          if (!hasValue) {
            _setI64(_payloadAddressOffset, payload.address);
            _setI64(_payloadLengthOffset, bytes.length);
            _setU32(_hasValueOffset, 1);
            _notEmpty.wakeOne();
            return;
          }
          _park(_notFull, elapsed, timeout, 'BlockingByteMailbox.put');
        }
      }, timeout: timeout < defaultLockTimeout ? defaultLockTimeout : timeout);
    } on Object {
      // The payload never reached the mailbox, so nobody else will ever free
      // it. Leaking here would be a leak per timed-out message.
      NativeAllocator.instance.free(payload);
      rethrow;
    }
  }

  /// Parks this thread until a message arrives, then copies it out.
  ///
  /// **Stops the calling thread dead**, exactly as
  /// [BlockingSlotMailbox.takeBlocking] does, and refuses on the root isolate
  /// for the same reason.
  Uint8List takeBlocking({Duration timeout = defaultBlockingWaitTimeout}) {
    _throwIfReleased();
    BlockingWaitPolicy.check('BlockingByteMailbox.takeBlocking');
    final Stopwatch elapsed = Stopwatch()..start();
    return _mutex.runLocked(() {
      while (true) {
        if (hasValue) return _drain();
        if (isClosed) throw const MailboxClosedException('takeBlocking');
        _park(_notEmpty, elapsed, timeout, 'BlockingByteMailbox.takeBlocking');
      }
    }, timeout: timeout < defaultLockTimeout ? defaultLockTimeout : timeout);
  }

  /// Takes a message if one is waiting. Never parks, so it is safe anywhere.
  Uint8List? tryTake() {
    _throwIfReleased();
    return _mutex.runLocked(() => hasValue ? _drain() : null);
  }

  void close() {
    _throwIfReleased();
    _closeAndCountWaiters();
  }

  /// Closes and counts parked waiters in one critical section. See
  /// `BlockingSlotMailbox` for why those two cannot be separate operations.
  int _closeAndCountWaiters() {
    return _mutex.runLocked(() {
      _setU32(_closedOffset, 1);
      _notEmpty.wakeAll();
      _notFull.wakeAll();
      return _u32(_waiterOffset);
    });
  }

  /// Releases an attached handle's per-isolate scratch. Refused for the owner,
  /// which would leak the block - see `BlockingSlotMailbox.detach`.
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

  /// Destroys the primitives and frees the block. Owner only, and only once
  /// nobody is parked - the same rule and the same reason as
  /// [BlockingSlotMailbox.dispose].
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
        'refusing to free a mailbox with $waiters thread(s) parked in it',
      );
    }
    // An undelivered message would otherwise leak: its buffer is owned by
    // whoever takes it, and after this nobody can.
    if (hasValue) {
      NativeAllocator.instance
          .free(Pointer<Uint8>.fromAddress(_i64(_payloadAddressOffset)));
      _setU32(_hasValueOffset, 0);
    }
    _released = true;
    _notEmpty.destroy();
    _notFull.destroy();
    _mutex.destroy();
    _setU32(_magicOffset, 0);
    NativeAllocator.instance.free(_memory);
  }

  Uint8List _drain() {
    final Pointer<Uint8> payload =
        Pointer<Uint8>.fromAddress(_i64(_payloadAddressOffset));
    final int length = _i64(_payloadLengthOffset);
    // Copied out rather than returned as a view: the native block is freed on
    // the next line, and an external typed list cannot notice that its memory
    // is gone - it just reads whatever the allocator put there next.
    final Uint8List copy = Uint8List.fromList(payload.asTypedList(length));
    NativeAllocator.instance.free(payload);
    _setU32(_hasValueOffset, 0);
    _setI64(_payloadAddressOffset, 0);
    _setI64(_payloadLengthOffset, 0);
    _notFull.wakeOne();
    return copy;
  }

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
      throw BlockingWaitTimeout(operation, elapsed.elapsed);
    }
  }

  int _u32(int offset) => _memory.cast<Uint32>()[offset ~/ 4];
  void _setU32(int offset, int value) =>
      _memory.cast<Uint32>()[offset ~/ 4] = value;
  int _i64(int offset) => _memory.cast<Int64>()[offset ~/ 8];
  void _setI64(int offset, int value) =>
      _memory.cast<Int64>()[offset ~/ 8] = value;

  void _throwIfReleased() {
    if (_released) {
      throw StateError('this BlockingByteMailbox handle was detached');
    }
  }
}
