/// The few C runtime and threading entry points the probes need, resolved per
/// platform with nothing but `dart:ffi`.
///
/// No `package:ffi`, no C compiler: every probe in this package must run from a
/// fresh clone with `dart run`, on Windows, Linux and macOS alike.
library;

import 'dart:ffi';
import 'dart:io';

/// The C runtime: `ucrtbase.dll` on Windows, the process image elsewhere
/// (glibc and libSystem both export `malloc`, `qsort` and `pthread_*` from it).
final DynamicLibrary libc = Platform.isWindows
    ? DynamicLibrary.open('ucrtbase.dll')
    : DynamicLibrary.process();

final DynamicLibrary? _kernel32 = Platform.isWindows
    ? DynamicLibrary.open('kernel32.dll')
    : null;

final Pointer<Void> Function(int) malloc = libc
    .lookupFunction<Pointer<Void> Function(Size), Pointer<Void> Function(int)>(
      'malloc',
    );

final void Function(Pointer<Void>) free = libc
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'free',
    );

/// `qsort(base, count, size, compare)` - the most portable C function that
/// calls back into the caller synchronously, on the caller's thread.
typedef CompareNative = Int32 Function(Pointer<Void>, Pointer<Void>);

final void Function(
  Pointer<Void>,
  int,
  int,
  Pointer<NativeFunction<CompareNative>>,
)
qsort = libc
    .lookupFunction<
      Void Function(
        Pointer<Void>,
        Size,
        Size,
        Pointer<NativeFunction<CompareNative>>,
      ),
      void Function(
        Pointer<Void>,
        int,
        int,
        Pointer<NativeFunction<CompareNative>>,
      )
    >('qsort');

/// Blocks the calling OS thread, outside Dart, for [milliseconds].
void sleepNative(int milliseconds) {
  if (Platform.isWindows) {
    _sleepWin(milliseconds);
  } else {
    _usleep(milliseconds * 1000);
  }
}

late final void Function(int) _sleepWin = _kernel32!
    .lookupFunction<Void Function(Uint32), void Function(int)>('Sleep');

late final int Function(int) _usleep = libc
    .lookupFunction<Int32 Function(Uint32), int Function(int)>('usleep');

// ---------------------------------------------------------------------------
// Threads.
// ---------------------------------------------------------------------------

/// Start routine shape for `CreateThread`.
typedef WinThreadStart = Uint32 Function(Pointer<Void>);

/// Start routine shape for `pthread_create`. The C type returns `void *`;
/// `IntPtr` is the same width and register, and a group-bound callable may
/// return it.
typedef PosixThreadStart = IntPtr Function(Pointer<Void>);

late final int Function(
  Pointer<Void>,
  int,
  Pointer<NativeFunction<WinThreadStart>>,
  Pointer<Void>,
  int,
  Pointer<Void>,
)
_createThread = _kernel32!
    .lookupFunction<
      IntPtr Function(
        Pointer<Void>,
        IntPtr,
        Pointer<NativeFunction<WinThreadStart>>,
        Pointer<Void>,
        Uint32,
        Pointer<Void>,
      ),
      int Function(
        Pointer<Void>,
        int,
        Pointer<NativeFunction<WinThreadStart>>,
        Pointer<Void>,
        int,
        Pointer<Void>,
      )
    >('CreateThread');

late final int Function(int, int) _waitForSingleObject = _kernel32!
    .lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
      'WaitForSingleObject',
    );

late final int Function(int) _closeHandle = _kernel32!
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

late final int Function(
  Pointer<IntPtr>,
  Pointer<Void>,
  Pointer<NativeFunction<PosixThreadStart>>,
  Pointer<Void>,
)
_pthreadCreate = libc
    .lookupFunction<
      Int32 Function(
        Pointer<IntPtr>,
        Pointer<Void>,
        Pointer<NativeFunction<PosixThreadStart>>,
        Pointer<Void>,
      ),
      int Function(
        Pointer<IntPtr>,
        Pointer<Void>,
        Pointer<NativeFunction<PosixThreadStart>>,
        Pointer<Void>,
      )
    >('pthread_create');

late final int Function(int, Pointer<Void>) _pthreadJoin = libc
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Void>),
      int Function(int, Pointer<Void>)
    >('pthread_join');

/// A started OS thread, joinable exactly once.
final class NativeThread {
  NativeThread._(this._handle);

  final int _handle;

  /// Starts a thread that runs [windows] on Windows or [posix] elsewhere with
  /// [argument]. Exactly one of the two start routines is used.
  static NativeThread start({
    required Pointer<NativeFunction<WinThreadStart>> Function() windows,
    required Pointer<NativeFunction<PosixThreadStart>> Function() posix,
    required Pointer<Void> argument,
  }) {
    if (Platform.isWindows) {
      final int handle = _createThread(
        nullptr,
        0,
        windows(),
        argument,
        0,
        nullptr,
      );
      if (handle == 0) throw StateError('CreateThread failed');
      return NativeThread._(handle);
    }
    final Pointer<IntPtr> id = malloc(sizeOf<IntPtr>()).cast<IntPtr>();
    try {
      final int rc = _pthreadCreate(id, nullptr, posix(), argument);
      if (rc != 0) throw StateError('pthread_create failed: $rc');
      return NativeThread._(id.value);
    } finally {
      free(id.cast());
    }
  }

  /// Blocks this OS thread, outside Dart, until the thread ends. No timeout on
  /// purpose: a probe that hangs here is reporting a deadlock, and the runner
  /// that launched it is the one holding the stopwatch.
  void join() {
    if (Platform.isWindows) {
      _waitForSingleObject(_handle, 0xFFFFFFFF /* INFINITE */);
      _closeHandle(_handle);
    } else {
      _pthreadJoin(_handle, nullptr);
    }
  }
}
