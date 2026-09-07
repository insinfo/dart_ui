/// Does the Dart 3.13 `Isolate.create` + `handleEvent` pair actually work, and
/// does it work from inside a native frame?
///
/// This file **does not compile under the `^3.6.0` this package declares**, and
/// that is the finding rather than an oversight. `tool/dart313_nested_drain_probe.dart`
/// reaches `handleEvent` through `dynamic` and so builds on any SDK; it cannot
/// reach `Isolate.create`, because a static member has no dynamic escape hatch.
/// So the whole directory is excluded from the analyzer in
/// `analysis_options.yaml` and is run only with an SDK that has the API:
///
/// ```
/// D:/referencias_libs_pdf/dartsdk-3.13.3/bin/dart.exe run tool/sdk313/created_isolate_drain_probe.dart
/// ```
///
/// The architecture under test is the one the API's own documentation
/// describes: a second isolate in the current group whose event loop is *not*
/// running, drained one event at a time by whoever owns the thread. If that
/// drain works from under a foreign frame, the modal-loop freeze this project
/// reported is solvable today, on 3.13, with no SDK change at all.
///
/// **Warning:** the measurement is a call that may deadlock. Run with a
/// timeout.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

typedef _NativeEnumWindows = Int32 Function(
  Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>,
  IntPtr,
);
typedef _DartEnumWindows = int Function(
  Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>,
  int,
);

typedef _NativeSleep = Void Function(Uint32);
typedef _DartSleep = void Function(int);

const int _blockFor = 1500;
const int _sliceMs = 100;

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

final _DartSleep _sleep =
    _kernel32.lookupFunction<_NativeSleep, _DartSleep>('Sleep');

final _DartEnumWindows _enumWindows =
    _user32.lookupFunction<_NativeEnumWindows, _DartEnumWindows>('EnumWindows');

/// The isolate whose loop we are driving by hand. Set before the native call.
Isolate? _worker;

int _drainCalls = 0;
String _drainOutcome = 'not attempted';
bool _calledBack = false;

/// Ticks counted **inside the worker isolate**.
///
/// A separate isolate in the same group still has its own copy of every static,
/// so this is the worker's own counter and is read back through [readTicks].
int _workerTicks = 0;

/// Arms a periodic timer inside the worker. Must be deeply immutable to be
/// passed to `runSync`, which a top-level function reference is.
void armTimer() {
  Timer.periodic(const Duration(milliseconds: 50), (_) => _workerTicks++);
}

/// Reads the worker's counter back. Returns an `int`, which is deeply
/// immutable, as `runSync` requires of a result.
int readTicks() => _workerTicks;

/// The callback the OS invokes on this thread, from inside `EnumWindows`.
int _onWindow(int hwnd, int lParam) {
  _calledBack = true;
  final Isolate? worker = _worker;
  if (worker == null) return 0;

  var slept = 0;
  while (slept < _blockFor) {
    _sleep(_sliceMs);
    slept += _sliceMs;
    try {
      worker.handleEvent();
      _drainCalls++;
      _drainOutcome = 'returned';
    } on Object catch (error) {
      _drainOutcome = '${error.runtimeType}: $error';
      break;
    }
  }
  return 0;
}

void main() {
  if (!Platform.isWindows) {
    stdout.writeln('PROBE=SKIP not Windows');
    return;
  }
  stdout.writeln('SDK reported by the running VM: ${Platform.version}');

  final Isolate worker;
  try {
    worker = Isolate.create(debugName: 'drained-worker');
  } on Object catch (error) {
    stdout
      ..writeln('Isolate.create: ${error.runtimeType}: $error')
      ..writeln('PROBE=BLOCKED the API is declared but not implemented');
    return;
  }
  _worker = worker;

  try {
    worker.runSync(armTimer);
  } on Object catch (error) {
    stdout
      ..writeln('runSync(armTimer): ${error.runtimeType}: $error')
      ..writeln('PROBE=BLOCKED could not arm work inside the created isolate');
    return;
  }

  final Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>> callback =
      Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_onWindow, 0);

  final Stopwatch elapsed = Stopwatch()..start();
  _enumWindows(callback, 0);
  final int wall = elapsed.elapsedMilliseconds;

  var ticks = -1;
  try {
    ticks = worker.runSync(readTicks);
  } on Object catch (error) {
    stdout.writeln('runSync(readTicks): ${error.runtimeType}: $error');
  }

  stdout
    ..writeln('a created isolate drained from under a native frame, '
        '$_blockFor ms in ${_blockFor ~/ _sliceMs} slices')
    ..writeln('  callback reached       : $_calledBack')
    ..writeln('  wall time in the call  : $wall ms')
    ..writeln('  handleEvent() returned : $_drainCalls of ${_blockFor ~/ _sliceMs}')
    ..writeln('  handleEvent() outcome  : $_drainOutcome')
    ..writeln('  worker timer ticks     : $ticks (about ${_blockFor ~/ 50} '
        'if its loop ran)');

  try {
    worker.shutdownSync();
  } on Object catch (error) {
    stdout.writeln('shutdownSync: ${error.runtimeType}: $error');
  }

  if (ticks > 0) {
    stdout.writeln('PROBE=WORKS a created isolate can be drained from a '
        'native frame');
    return;
  }
  stdout.writeln('PROBE=BLOCKED nothing ran in the created isolate');
}
