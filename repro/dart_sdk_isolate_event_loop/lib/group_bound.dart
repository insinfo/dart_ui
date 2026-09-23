/// Shared harness for the `group_bound_*` probes: start a foreign OS thread on
/// a `NativeCallable.isolateGroupBound` start routine, wait for it one of two
/// ways, and report what the callback wrote back.
///
/// The callback may not touch a Dart static that is not shared across the
/// group, so its only channel back is a pair of `Int32` slots passed as the
/// thread argument: `[0]` is 1 when `--shutdown` was passed, `[1]` is the
/// result code.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'native.dart';

/// Result codes written to slot `[1]`.
const int kNotRun = 0;
const int kEntered = 1;
const int kTrivialDone = 2;
const int kCreateOk = 3;
const int kCreateStateError = 4;
const int kCreateOtherError = 5;
const int kCreateShutdownOk = 6;
const int kShutdownError = 7;

String describe(int code) => switch (code) {
  kNotRun => 'the callback never ran',
  kEntered => 'the callback started but did not finish',
  kTrivialDone => 'trivial callback ran to completion',
  kCreateOk => 'Isolate.create succeeded inside the callback',
  kCreateStateError => 'Isolate.create threw StateError inside the callback',
  kCreateOtherError => 'Isolate.create threw something else',
  kCreateShutdownOk =>
    'Isolate.create and then shutdownSync succeeded inside the callback',
  kShutdownError => 'Isolate.create succeeded but shutdownSync threw',
  _ => 'unknown code $code',
};

/// Runs one case. [windows] and [posix] build the group-bound start routine
/// for the platform in use; only one of them is called.
///
/// `--wait=blocking` makes the main isolate wait in a native call
/// (`pthread_join` / `WaitForSingleObject(INFINITE)`) with no deadline: a hang
/// there is the finding, and `bin/run_all.dart` holds the watchdog.
/// `--wait=async` polls slot `[1]` from a `Timer` instead, so the main isolate
/// is idle in its event loop between polls, with a 5 s deadline.
Future<void> runGroupBoundCase(
  List<String> args, {
  required String label,
  required NativeCallable<WinThreadStart> Function() windows,
  required NativeCallable<PosixThreadStart> Function() posix,
}) async {
  final String wait = args.contains('--wait=async') ? 'async' : 'blocking';
  stdout
    ..writeln('SDK: ${Platform.version}')
    ..writeln('callback=$label wait=$wait');

  final Pointer<Int32> slots = malloc(8).cast<Int32>()
    ..[0] = args.contains('--shutdown') ? 1 : 0
    ..[1] = kNotRun;

  NativeCallable<WinThreadStart>? windowsCallable;
  NativeCallable<PosixThreadStart>? posixCallable;
  final NativeThread thread;
  try {
    thread = NativeThread.start(
      windows: () => (windowsCallable = windows()).nativeFunction,
      posix: () => (posixCallable = posix()).nativeFunction,
      argument: slots.cast(),
    );
  } on Object catch (error) {
    stdout.writeln('RESULT=BLOCKED ${error.runtimeType}: $error');
    return;
  }
  stdout.writeln('thread started; main isolate now waits ($wait)');

  if (wait == 'blocking') {
    thread.join();
  } else {
    final Stopwatch clock = Stopwatch()..start();
    final Completer<void> done = Completer<void>();
    Timer.periodic(const Duration(milliseconds: 10), (Timer timer) {
      if (slots[1] >= kTrivialDone || clock.elapsedMilliseconds > 5000) {
        timer.cancel();
        done.complete();
      }
    });
    await done.future;
    if (slots[1] < kTrivialDone) {
      stdout
        ..writeln('slot after 5 s: ${slots[1]} (${describe(slots[1])})')
        ..writeln(
          'RESULT=HANG_ASYNC the callback did not finish while the '
          'main isolate was idle in its event loop',
        );
      // Joining would block forever; leave the thread behind.
      exit(3);
    }
    thread.join();
  }

  windowsCallable?.close();
  posixCallable?.close();
  final int code = slots[1];
  stdout
    ..writeln('slot: $code (${describe(code)})')
    ..writeln(
      code >= kTrivialDone
          ? 'RESULT=COMPLETED ${describe(code)}'
          : 'RESULT=UNEXPECTED ${describe(code)}',
    );
}
