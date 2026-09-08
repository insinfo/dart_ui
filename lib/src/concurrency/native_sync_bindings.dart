/// The operating system's own mutex and condition variable, bound once.
///
/// Everything above this file - [NativeMutex], [NativeConditionVariable], the
/// mailboxes - is portable Dart over the two operations every platform has:
/// "block this thread until somebody wakes it" and "wake it". This file is the
/// only place that knows which pair of native functions provides them.
///
/// ## Why not `package:native_synchronization`
///
/// It is the reference design for this problem and it was read. It cannot be
/// used: this repository takes no dependency it does not already have, so the
/// primitives are re-implemented here, in this repository's idiom - a bound
/// API object with a [provenance] string, exactly like [NativeAllocator].
///
/// ## Why `DynamicLibrary.lookupFunction` and not `@Native` + `external`
///
/// Both work. `@Native` was measured on this SDK (3.6.2, windows_x64) and does
/// resolve `GetCurrentThreadId` and `InitializeSRWLock` against the process
/// without any native-assets configuration, so it was a real option. It was
/// not taken for two reasons:
///
///   * **A missing symbol under `@Native` fails at the call site, not at bind
///     time.** There is no `providesSymbol` to ask first, and no way to report
///     "this platform has no pthread" as a diagnostic instead of as a stack
///     trace from inside a video decoder. [tryBind] returns null instead, and
///     names the symbol that was missing in [missingSymbol].
///   * **`@Native` fixes one lookup strategy.** The pthread symbols are in
///     `libc.so.6` on glibc 2.34 and later, in `libpthread.so.0` before that,
///     and in `libSystem` on macOS. A fallback chain is expressible with
///     `DynamicLibrary` and is not expressible with an annotation.
///
/// The cost is one closure call per native call. That is irrelevant here: the
/// calls this file makes either block for milliseconds or run a handful of
/// instructions a few times a frame.
///
/// ## Struct sizes are claims about an ABI, and this file over-reserves
///
/// See [nativeMutexReservedBytes].
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Which native pair is behind the abstraction.
enum NativeSyncFlavor {
  /// `SRWLOCK` and `CONDITION_VARIABLE`, from the Windows API.
  ///
  /// Chosen over `CRITICAL_SECTION` for the same reason the audio control
  /// block already uses it: an `SRWLOCK` is a single pointer, needs no
  /// destructor, and can therefore live inside shared memory that two isolates
  /// map at the same address without anybody owning a handle.
  slimReaderWriterLock,

  /// `pthread_mutex_t` and `pthread_cond_t`.
  pthread,
}

/// Bytes reserved in shared memory for one native mutex.
///
/// **This is an over-reservation, not a `sizeof`.** There is no portable way
/// to ask a running libc how big its `pthread_mutex_t` is - the size lives in
/// a header, not in an exported symbol - so a Dart binding either hard-codes a
/// number per platform or reserves more than any of them needs. Hard-coding is
/// the option that corrupts memory silently the first time a platform this
/// table does not list runs the code, so this file reserves.
///
/// The sizes this number has to cover, all on 64-bit:
///
/// | Platform                  | `pthread_mutex_t` | `pthread_cond_t` |
/// |---------------------------|-------------------|------------------|
/// | Windows (`SRWLOCK`)       | 8                 | 8                |
/// | Linux glibc x86_64        | 40                | 48               |
/// | Linux glibc aarch64       | 48                | 48               |
/// | Linux musl                | 40                | 48               |
/// | macOS (arm64 and x86_64)  | 64                | 48               |
/// | Android bionic            | 40                | 48               |
///
/// The largest is 64. Reserving 128 leaves a factor of two for a platform that
/// is not in the table.
///
/// **And the reservation is checked rather than trusted.** Every reserved
/// region is followed by [nativeSyncGuardBytes] of a known pattern, written
/// before the primitive is initialised and verified afterwards - see
/// [NativeMutex.checkGuard]. A platform whose mutex does not fit therefore
/// fails by name at construction, which is the whole point: a wrong size is
/// not an error anywhere, it is a neighbouring field changing value hours
/// later.
const int nativeMutexReservedBytes = 128;

/// Bytes reserved for one native condition variable. See
/// [nativeMutexReservedBytes] for why this is a reservation and not a size.
const int nativeConditionReservedBytes = 128;

/// Bytes of sentinel written after every reserved region.
///
/// Sixteen would be enough to catch an overrun by a whole pointer; thirty-two
/// is used because these regions are 16-byte aligned and keeping the total a
/// multiple of 16 means the next primitive in a shared block is aligned too,
/// without an alignment expression at every offset.
const int nativeSyncGuardBytes = 32;

/// The byte the guard region is filled with.
const int nativeSyncGuardByte = 0xA5;

/// Fills the [nativeSyncGuardBytes] that follow a [reservedBytes] region.
///
/// Written **before** the primitive is initialised, so that an initialiser
/// writing past its reservation is caught by the very first [syncGuardIsIntact]
/// rather than blamed on whatever ran afterwards.
void writeSyncGuard(Pointer<Uint8> memory, int reservedBytes) {
  memory.asTypedList(reservedBytes + nativeSyncGuardBytes).fillRange(
      reservedBytes, reservedBytes + nativeSyncGuardBytes, nativeSyncGuardByte);
}

/// Whether the sentinel after a [reservedBytes] region is still untouched.
bool syncGuardIsIntact(Pointer<Uint8> memory, int reservedBytes) {
  final Uint8List bytes =
      memory.asTypedList(reservedBytes + nativeSyncGuardBytes);
  for (var at = reservedBytes; at < bytes.length; at++) {
    if (bytes[at] != nativeSyncGuardByte) return false;
  }
  return true;
}

/// `CLOCK_REALTIME`, which is 0 on Linux, macOS and every BSD.
///
/// Not `CLOCK_MONOTONIC`: `pthread_cond_timedwait` measures against the clock
/// the condition variable was *initialised* with, and selecting a different one
/// needs `pthread_condattr_setclock`, which macOS does not have. So the native
/// deadline moves if somebody sets the system clock. That is tolerable here and
/// only here, because no caller's deadline is the native one: every wait in
/// [NativeConditionVariable.waitFor] is sliced, and the slices are counted
/// against a Dart [Stopwatch], which is monotonic. A clock jump costs an early
/// or late wake-up inside one slice, never a missed deadline.
const int _clockRealtime = 0;

/// `EBUSY`, the same value on Linux and macOS.
const int _ebusy = 16;

/// `ETIMEDOUT`, which is **not** the same value on the two POSIX platforms:
/// 110 on Linux, 60 on macOS. Getting this wrong turns every timeout into a
/// thrown "unexpected errno", which is at least loud - but it would be loud on
/// exactly the path that exists to report a stuck producer.
int get _etimedout => Platform.isMacOS ? 60 : 110;

/// `ERROR_TIMEOUT` from the Windows API.
const int _errorTimeout = 1460;

typedef _VoidPtrNative = Void Function(Pointer<Void>);
typedef _VoidPtrDart = void Function(Pointer<Void>);
typedef _BooleanPtrNative = Uint8 Function(Pointer<Void>);
typedef _Int32PtrNative = Int32 Function(Pointer<Void>);
typedef _IntPtrDart = int Function(Pointer<Void>);
typedef _SleepConditionNative = Int32 Function(
    Pointer<Void>, Pointer<Void>, Uint32, Uint32);
typedef _SleepConditionDart = int Function(
    Pointer<Void>, Pointer<Void>, int, int);
typedef _LastErrorNative = Uint32 Function();
typedef _PthreadInitNative = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _PthreadInitDart = int Function(Pointer<Void>, Pointer<Void>);
typedef _CondWaitNative = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _CondWaitDart = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _ClockGetTimeNative = Int32 Function(Int32, Pointer<Void>);
typedef _ClockGetTimeDart = int Function(int, Pointer<Void>);

/// The two blocking primitives, bound lazily and once per process.
///
/// Importing this file is harmless on a platform that has neither: [tryBind]
/// answers null and [isAvailable] is false, which is the rule section 6.6 of
/// the roadmap sets for every native binding in this repository.
abstract base class NativeSyncApi {
  NativeSyncApi(this.provenance);

  /// Which libraries the symbols came from, for a bug report. The failure this
  /// layer is most likely to be blamed for - a lock that never unblocks - is
  /// diagnosed very differently depending on whether the pthread symbols came
  /// out of `libc` or out of `libpthread`.
  final String provenance;

  NativeSyncFlavor get flavor;

  /// Bytes of scratch space a waiting isolate must hand [waitOnCondition].
  ///
  /// Sixteen on POSIX, for the `struct timespec` the absolute deadline goes in;
  /// zero on Windows, whose wait takes a relative millisecond count.
  ///
  /// The scratch is **per waiting isolate and never shared**. Two isolates
  /// parked on the same condition variable each compute their own deadline, and
  /// a single buffer in the shared block would have them writing over each
  /// other's `timespec` between the `clock_gettime` and the wait.
  int get waitScratchBytes;

  void initializeMutex(Pointer<Void> mutex);
  void destroyMutex(Pointer<Void> mutex);

  /// Takes the lock if it is free. Never blocks.
  ///
  /// The only acquisition primitive this class exposes. There is deliberately
  /// no blocking acquire: `AcquireSRWLockExclusive` and `pthread_mutex_lock`
  /// have no timeout, so a holder that died mid-critical-section turns them
  /// into a permanent hang with no message - the worst outcome this framework
  /// can produce. [NativeMutex.acquire] builds a bounded acquire out of this.
  bool tryAcquireMutex(Pointer<Void> mutex);

  void releaseMutex(Pointer<Void> mutex);

  void initializeCondition(Pointer<Void> condition);
  void destroyCondition(Pointer<Void> condition);

  /// Atomically releases [mutex], waits up to [milliseconds], reacquires it.
  ///
  /// Returns true if the wait ended in a wake-up (which may be spurious, so
  /// every caller re-tests its predicate), false if the slice elapsed.
  ///
  /// **Never bound with `isLeaf: true`.** A leaf call promises the VM it will
  /// return promptly and does not transition out of the Dart execution state,
  /// so a leaf call that blocks for 250 ms stops garbage collection for the
  /// whole isolate group for 250 ms. Blocking is this function's entire job.
  bool waitOnCondition(
    Pointer<Void> condition,
    Pointer<Void> mutex,
    int milliseconds,
    Pointer<Void> scratch,
  );

  void wakeOne(Pointer<Void> condition);
  void wakeAll(Pointer<Void> condition);

  static NativeSyncApi? _instance;
  static bool _attempted = false;

  /// The symbol that could not be resolved, when [tryBind] returned null.
  static String? missingSymbol;

  /// The bound API, or null when this platform exports neither pair.
  static NativeSyncApi? tryBind() {
    if (_attempted) return _instance;
    _attempted = true;
    try {
      return _instance =
          Platform.isWindows ? _WindowsSyncApi.bind() : _PthreadSyncApi.bind();
    } on ArgumentError catch (error) {
      // `lookupFunction` throws ArgumentError naming the symbol it could not
      // find. Recording it is the difference between "synchronisation is
      // unavailable" and a bug report somebody can act on.
      missingSymbol = '$error';
      return null;
    } on Object catch (error) {
      missingSymbol = '$error';
      return null;
    }
  }

  static NativeSyncApi get instance {
    final NativeSyncApi? bound = tryBind();
    if (bound == null) {
      throw StateError(
        'no native synchronisation primitives on this platform: '
        '${missingSymbol ?? 'nothing was bound'}',
      );
    }
    return bound;
  }

  static bool get isAvailable => tryBind() != null;

  /// Drops the binding. Only for a test that wants to observe a fresh bind.
  static void debugReset() {
    _attempted = false;
    _instance = null;
    missingSymbol = null;
  }
}

/// `SRWLOCK` and `CONDITION_VARIABLE`.
final class _WindowsSyncApi extends NativeSyncApi {
  _WindowsSyncApi._(
    this._initializeLock,
    this._tryAcquireLock,
    this._releaseLock,
    this._initializeCondition,
    this._sleepCondition,
    this._wakeOne,
    this._wakeAll,
    this._lastError,
    super.provenance,
  );

  /// The system library is opened by name rather than through
  /// `DynamicLibrary.process()`. Process lookup was measured to work on this
  /// SDK for these symbols, but it searches every loaded module in load order,
  /// and this repository already loads four other DLLs; naming the one library
  /// that defines these functions removes the question of which module a
  /// symbol came from.
  factory _WindowsSyncApi.bind() {
    final DynamicLibrary system = DynamicLibrary.open('kernel32.dll');
    return _WindowsSyncApi._(
      system.lookupFunction<_VoidPtrNative, _VoidPtrDart>('InitializeSRWLock'),
      system.lookupFunction<_BooleanPtrNative, _IntPtrDart>(
        'TryAcquireSRWLockExclusive',
        isLeaf: true,
      ),
      system.lookupFunction<_VoidPtrNative, _VoidPtrDart>(
        'ReleaseSRWLockExclusive',
        isLeaf: true,
      ),
      system.lookupFunction<_VoidPtrNative, _VoidPtrDart>(
        'InitializeConditionVariable',
      ),
      // Deliberately not a leaf call: it blocks. See [waitOnCondition].
      system.lookupFunction<_SleepConditionNative, _SleepConditionDart>(
        'SleepConditionVariableSRW',
      ),
      system.lookupFunction<_VoidPtrNative, _VoidPtrDart>(
        'WakeConditionVariable',
        isLeaf: true,
      ),
      system.lookupFunction<_VoidPtrNative, _VoidPtrDart>(
        'WakeAllConditionVariable',
        isLeaf: true,
      ),
      system.lookupFunction<_LastErrorNative, int Function()>(
        'GetLastError',
        isLeaf: true,
      ),
      'SRWLOCK + CONDITION_VARIABLE (kernel32.dll)',
    );
  }

  final _VoidPtrDart _initializeLock;
  final _IntPtrDart _tryAcquireLock;
  final _VoidPtrDart _releaseLock;
  final _VoidPtrDart _initializeCondition;
  final _SleepConditionDart _sleepCondition;
  final _VoidPtrDart _wakeOne;
  final _VoidPtrDart _wakeAll;
  final int Function() _lastError;

  @override
  NativeSyncFlavor get flavor => NativeSyncFlavor.slimReaderWriterLock;

  @override
  int get waitScratchBytes => 0;

  @override
  void initializeMutex(Pointer<Void> mutex) => _initializeLock(mutex);

  /// Nothing to do: an `SRWLOCK` has no destructor, which is exactly why it is
  /// safe to place in memory that outlives the isolate that initialised it.
  @override
  void destroyMutex(Pointer<Void> mutex) {}

  @override
  bool tryAcquireMutex(Pointer<Void> mutex) => _tryAcquireLock(mutex) != 0;

  @override
  void releaseMutex(Pointer<Void> mutex) => _releaseLock(mutex);

  @override
  void initializeCondition(Pointer<Void> condition) =>
      _initializeCondition(condition);

  @override
  void destroyCondition(Pointer<Void> condition) {}

  @override
  bool waitOnCondition(
    Pointer<Void> condition,
    Pointer<Void> mutex,
    int milliseconds,
    Pointer<Void> scratch,
  ) {
    final int woken = _sleepCondition(condition, mutex, milliseconds, 0);
    if (woken != 0) return true;
    // The documented failure here is `ERROR_TIMEOUT`, and everything else is a
    // parameter error that cannot happen with a pair this file initialised.
    // Zero is accepted as well: `GetLastError` is thread-local and this read
    // happens after the VM has transitioned back out of the native state, so
    // it is read defensively rather than trusted. Anything *else* is a real
    // failure and must not become a hot loop of instant false returns.
    final int code = _lastError();
    if (code == _errorTimeout || code == 0) return false;
    throw StateError('SleepConditionVariableSRW failed with error $code');
  }

  @override
  void wakeOne(Pointer<Void> condition) => _wakeOne(condition);

  @override
  void wakeAll(Pointer<Void> condition) => _wakeAll(condition);
}

/// `pthread_mutex_t` and `pthread_cond_t`.
final class _PthreadSyncApi extends NativeSyncApi {
  _PthreadSyncApi._(
    this._mutexInit,
    this._mutexDestroy,
    this._mutexTryLock,
    this._mutexUnlock,
    this._condInit,
    this._condDestroy,
    this._condTimedWait,
    this._condSignal,
    this._condBroadcast,
    this._clockGetTime,
    super.provenance,
  );

  /// The lookup order, and why it is a chain rather than one library name.
  ///
  ///   1. **`DynamicLibrary.process()`.** On macOS the pthread implementation
  ///      is in `libSystem`, which is loaded into every process that exists.
  ///      On glibc 2.34 and later the pthread symbols were folded into
  ///      `libc.so.6` proper, and the Dart VM has libc loaded by definition.
  ///      So on both current CI images this succeeds and nothing else runs.
  ///   2. **`libpthread.so.0`.** glibc before 2.34 keeps the real
  ///      implementations here; `libc.so.6` has only weak stubs, and a stub
  ///      `pthread_cond_timedwait` returns immediately, which would look like
  ///      a wait that never blocks.
  ///   3. **`libc.so.6` / `libSystem.B.dylib` by name**, for a process where
  ///      process-wide lookup is restricted.
  ///
  /// `clock_gettime` is chased separately because glibc before 2.17 had it in
  /// `librt.so.1` rather than in libc.
  factory _PthreadSyncApi.bind() {
    final List<String> tried = <String>[];
    final List<DynamicLibrary> candidates = <DynamicLibrary>[];
    void add(String name, DynamicLibrary Function() open) {
      try {
        candidates.add(open());
        tried.add(name);
      } on Object {
        // A library that is not present on this machine is expected, not
        // exceptional: the chain exists precisely because no single name is
        // right on every image.
      }
    }

    add('process', DynamicLibrary.process);
    if (Platform.isMacOS) {
      add('libSystem.B.dylib', () => DynamicLibrary.open('libSystem.B.dylib'));
    } else {
      add('libpthread.so.0', () => DynamicLibrary.open('libpthread.so.0'));
      add('libc.so.6', () => DynamicLibrary.open('libc.so.6'));
      add('librt.so.1', () => DynamicLibrary.open('librt.so.1'));
    }

    // The library is chosen first and the signature spelled out at each call
    // site, rather than a generic `lookup<Native, Dart>` helper: `dart:ffi`
    // rejects a type *variable* where a native signature is expected, so a
    // helper that took the two signatures as type arguments would not compile.
    DynamicLibrary provider(String symbol) {
      for (final DynamicLibrary library in candidates) {
        if (library.providesSymbol(symbol)) return library;
      }
      throw ArgumentError('none of ${tried.join(', ')} exports $symbol');
    }

    return _PthreadSyncApi._(
      provider('pthread_mutex_init')
          .lookupFunction<_PthreadInitNative, _PthreadInitDart>(
              'pthread_mutex_init'),
      provider('pthread_mutex_destroy')
          .lookupFunction<_Int32PtrNative, _IntPtrDart>(
              'pthread_mutex_destroy'),
      provider('pthread_mutex_trylock')
          .lookupFunction<_Int32PtrNative, _IntPtrDart>('pthread_mutex_trylock',
              isLeaf: true),
      provider('pthread_mutex_unlock')
          .lookupFunction<_Int32PtrNative, _IntPtrDart>('pthread_mutex_unlock',
              isLeaf: true),
      provider('pthread_cond_init')
          .lookupFunction<_PthreadInitNative, _PthreadInitDart>(
              'pthread_cond_init'),
      provider('pthread_cond_destroy')
          .lookupFunction<_Int32PtrNative, _IntPtrDart>('pthread_cond_destroy'),
      // Deliberately not a leaf call: it blocks. See [waitOnCondition].
      provider('pthread_cond_timedwait')
          .lookupFunction<_CondWaitNative, _CondWaitDart>(
              'pthread_cond_timedwait'),
      provider('pthread_cond_signal')
          .lookupFunction<_Int32PtrNative, _IntPtrDart>('pthread_cond_signal',
              isLeaf: true),
      provider('pthread_cond_broadcast')
          .lookupFunction<_Int32PtrNative, _IntPtrDart>(
              'pthread_cond_broadcast',
              isLeaf: true),
      provider('clock_gettime')
          .lookupFunction<_ClockGetTimeNative, _ClockGetTimeDart>(
              'clock_gettime',
              isLeaf: true),
      'pthread_mutex_t + pthread_cond_t (${tried.join(' -> ')})',
    );
  }

  final _PthreadInitDart _mutexInit;
  final _IntPtrDart _mutexDestroy;
  final _IntPtrDart _mutexTryLock;
  final _IntPtrDart _mutexUnlock;
  final _PthreadInitDart _condInit;
  final _IntPtrDart _condDestroy;
  final _CondWaitDart _condTimedWait;
  final _IntPtrDart _condSignal;
  final _IntPtrDart _condBroadcast;
  final _ClockGetTimeDart _clockGetTime;

  @override
  NativeSyncFlavor get flavor => NativeSyncFlavor.pthread;

  /// One `struct timespec`: `time_t` plus `long`, both 64-bit on every
  /// platform this runs on. [NativeConditionVariable] refuses a 32-bit process
  /// rather than silently packing the fields wrong.
  @override
  int get waitScratchBytes => 16;

  @override
  void initializeMutex(Pointer<Void> mutex) {
    // A null attribute pointer means the default mutex: not recursive, not
    // robust, not error-checking. Robust mutexes would survive a holder dying,
    // which sounds like the answer to the dead-holder problem - but they are a
    // Linux-only glibc extension with no macOS equivalent, and the bounded
    // acquire in [NativeMutex.acquire] gives the same "fail by name instead of
    // hanging" behaviour on all three platforms.
    _check('pthread_mutex_init', _mutexInit(mutex, nullptr));
  }

  @override
  void destroyMutex(Pointer<Void> mutex) =>
      _check('pthread_mutex_destroy', _mutexDestroy(mutex));

  @override
  bool tryAcquireMutex(Pointer<Void> mutex) {
    final int status = _mutexTryLock(mutex);
    if (status == 0) return true;
    if (status == _ebusy) return false;
    throw StateError('pthread_mutex_trylock failed with errno $status');
  }

  @override
  void releaseMutex(Pointer<Void> mutex) =>
      _check('pthread_mutex_unlock', _mutexUnlock(mutex));

  @override
  void initializeCondition(Pointer<Void> condition) =>
      _check('pthread_cond_init', _condInit(condition, nullptr));

  @override
  void destroyCondition(Pointer<Void> condition) =>
      _check('pthread_cond_destroy', _condDestroy(condition));

  @override
  bool waitOnCondition(
    Pointer<Void> condition,
    Pointer<Void> mutex,
    int milliseconds,
    Pointer<Void> scratch,
  ) {
    // `pthread_cond_timedwait` takes an *absolute* deadline, so the relative
    // slice has to be turned into one against the same clock the condition
    // variable uses - and recomputed every slice, because the previous slice's
    // deadline is in the past.
    // `clock_gettime` is the one call here that does not follow the pthread
    // convention: it returns -1 and sets `errno` rather than returning the
    // error code, so running it through `_check` would report an errno of -1
    // and send whoever reads the log looking for a code that does not exist.
    if (_clockGetTime(_clockRealtime, scratch) != 0) {
      throw StateError('clock_gettime(CLOCK_REALTIME) failed');
    }
    final Pointer<Int64> deadline = scratch.cast<Int64>();
    var seconds = deadline[0] + milliseconds ~/ 1000;
    var nanoseconds = deadline[1] + (milliseconds % 1000) * 1000000;
    if (nanoseconds >= 1000000000) {
      seconds += 1;
      nanoseconds -= 1000000000;
    }
    deadline[0] = seconds;
    deadline[1] = nanoseconds;
    final int status = _condTimedWait(condition, mutex, scratch);
    if (status == 0) return true;
    if (status == _etimedout) return false;
    throw StateError('pthread_cond_timedwait failed with errno $status');
  }

  @override
  void wakeOne(Pointer<Void> condition) =>
      _check('pthread_cond_signal', _condSignal(condition));

  @override
  void wakeAll(Pointer<Void> condition) =>
      _check('pthread_cond_broadcast', _condBroadcast(condition));

  static void _check(String call, int status) {
    if (status == 0) return;
    throw StateError('$call failed with errno $status');
  }
}
