/// Is `Isolate.create` reachable from pure Dart after all?
///
/// The VM guards it with `thread->isolate() != nullptr`
/// (`runtime/lib/isolate.cc`), which reads as "embedder only" - a `main` always
/// has a current isolate. But `Isolate.onEvent`'s own documentation points at
/// [NativeCallable.isolateGroupBound], whose callback runs "within the isolate
/// group" and *not* within any isolate. That is exactly the state the guard
/// wants, and it is constructible from Dart.
///
/// So: create a real OS thread with `CreateThread`, point it at a
/// group-bound callback, and call `Isolate.create` from in there. No C, no
/// embedder.
///
/// The callback may not touch any static that is not shared across the group,
/// so the only channel back is the thread's exit code - which is why this
/// returns a small integer instead of printing.
///
/// ```
/// D:/referencias_libs_pdf/dartsdk-3.13.3/bin/dart.exe run tool/sdk313/group_bound_create_probe.dart
/// ```
///
/// ## Result on 3.13.3, 7 September 2026: INCONCLUSIVE - it hangs
///
/// The process produced no output at all and was still alive after two
/// minutes, despite the five-second `WaitForSingleObject` below, which means
/// it never reached the wait or never came back from it. It had to be killed.
///
/// The likely explanation, and it is a hypothesis rather than a measurement:
/// the group-bound callback has to enter the isolate group as a mutator on the
/// foreign thread, and the main thread is inside `WaitForSingleObject` holding
/// the group - each waits for the other. If that is right, the deadlock is not
/// specific to `Isolate.create`; it is what a group-bound callback does
/// whenever the isolate that built it is blocked, which would be worth a bug
/// report of its own.
///
/// **This probe is therefore not evidence either way about `Isolate.create`.**
/// It is kept because the question it asks is the right one and because a hang
/// is a finding worth not losing. The decisive evidence is elsewhere and does
/// not depend on it: `Isolate.onEvent` and `Isolate.handleEvent` are
/// unconditional `throw UnsupportedError` stubs in
/// `sdk/lib/_internal/vm/lib/isolate_patch.dart` on `dart-sdk` main, so no
/// arrangement of threads reaches a working drain today.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

typedef _NativeCreateThread = IntPtr Function(
  Pointer<Void>,
  IntPtr,
  Pointer<NativeFunction<Uint32 Function(Pointer<Void>)>>,
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
);
typedef _DartCreateThread = int Function(
  Pointer<Void>,
  int,
  Pointer<NativeFunction<Uint32 Function(Pointer<Void>)>>,
  Pointer<Void>,
  int,
  Pointer<Uint32>,
);

typedef _NativeWait = Uint32 Function(IntPtr, Uint32);
typedef _DartWait = int Function(int, int);

typedef _NativeExitCode = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _DartExitCode = int Function(int, Pointer<Uint32>);

typedef _NativeClose = Int32 Function(IntPtr);
typedef _DartClose = int Function(int);

/// What the group-bound callback managed to do, encoded for the exit code.
const int kEntered = 10;
const int kCreated = 11;
const int kStateError = 12;
const int kOtherError = 13;

/// Runs on a foreign OS thread, inside the isolate group but inside no
/// isolate. Returns a code because it may not write to a static.
int _threadMain(Pointer<Void> parameter) {
  try {
    Isolate.create(debugName: 'group-bound-created');
    return kCreated;
  } on StateError {
    return kStateError;
  } on Object {
    return kOtherError;
  }
}

String _describe(int code) => switch (code) {
      kCreated => 'Isolate.create SUCCEEDED from a group-bound callback',
      kStateError => 'StateError - the guard rejected it here too',
      kOtherError => 'some other error',
      kEntered => 'the callback ran but did not reach the call',
      _ => 'the callback never ran, or the thread died (code $code)',
    };

void main() {
  if (!Platform.isWindows) {
    stdout.writeln('PROBE=SKIP not Windows');
    return;
  }
  stdout.writeln('SDK reported by the running VM: ${Platform.version}');

  final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
  final _DartCreateThread createThread =
      kernel32.lookupFunction<_NativeCreateThread, _DartCreateThread>(
          'CreateThread');
  final _DartWait waitForSingleObject =
      kernel32.lookupFunction<_NativeWait, _DartWait>('WaitForSingleObject');
  final _DartExitCode getExitCodeThread =
      kernel32.lookupFunction<_NativeExitCode, _DartExitCode>(
          'GetExitCodeThread');
  final _DartClose closeHandle =
      kernel32.lookupFunction<_NativeClose, _DartClose>('CloseHandle');

  final NativeCallable<Uint32 Function(Pointer<Void>)> callable;
  try {
    callable = NativeCallable<Uint32 Function(Pointer<Void>)>
        .isolateGroupBound(_threadMain, exceptionalReturn: 0);
  } on Object catch (error) {
    stdout
      ..writeln('NativeCallable.isolateGroupBound: ${error.runtimeType}: '
          '$error')
      ..writeln('PROBE=BLOCKED cannot build a group-bound callback');
    return;
  }

  final Pointer<Uint32> exitCode = calloc<Uint32>();
  try {
    final int thread = createThread(
      nullptr,
      0,
      callable.nativeFunction,
      nullptr,
      0,
      nullptr,
    );
    if (thread == 0) {
      stdout.writeln('PROBE=INCONCLUSIVE CreateThread failed');
      return;
    }
    // 0x00000102 is WAIT_TIMEOUT; anything but 0 (WAIT_OBJECT_0) means the
    // thread did not finish, which for this probe is as interesting as a
    // refusal - a hang is what a deadlock looks like from outside.
    final int waited = waitForSingleObject(thread, 5000);
    if (waited != 0) {
      stdout.writeln('  WaitForSingleObject returned 0x${waited.toRadixString(16)}');
      stdout.writeln('PROBE=INCONCLUSIVE the thread did not finish in 5 s');
      closeHandle(thread);
      return;
    }
    getExitCodeThread(thread, exitCode);
    final int code = exitCode.value;
    closeHandle(thread);

    stdout
      ..writeln('  thread exit code : $code')
      ..writeln('  meaning          : ${_describe(code)}');

    if (code == kCreated) {
      stdout.writeln('PROBE=WORKS Isolate.create is reachable from pure Dart');
      return;
    }
    stdout.writeln('PROBE=BLOCKED Isolate.create refused here as well');
  } finally {
    calloc.free(exitCode);
    callable.close();
  }
}

/// Minimal allocator so this probe needs no package. `package:ffi`'s `calloc`
/// is not available to a `tool/` script that must build with nothing.
final _Calloc calloc = _Calloc();

final class _Calloc {
  final _DartAlloc _alloc = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<IntPtr Function(IntPtr, Uint32, IntPtr),
          int Function(int, int, int)>('HeapAlloc');
  final _DartFree _free = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Int32 Function(IntPtr, Uint32, IntPtr),
          int Function(int, int, int)>('HeapFree');
  final int _heap = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap')();

  Pointer<T> call<T extends NativeType>() =>
      Pointer<T>.fromAddress(_alloc(_heap, 0x8 /* HEAP_ZERO_MEMORY */, 8));

  void free(Pointer<NativeType> pointer) =>
      _free(_heap, 0, pointer.address);
}

typedef _DartAlloc = int Function(int, int, int);
typedef _DartFree = int Function(int, int, int);
