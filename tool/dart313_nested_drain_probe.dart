/// Can the Dart 3.13 isolate API service the event loop from inside a native
/// frame - and can it be reached while the package still declares `^3.6.0`?
///
/// Two questions, one probe, because the answers are coupled.
///
/// **1. Does it work?** `Isolate.handleEvent` handles at most one pending event
/// for an isolate. Its documentation says the isolate "can only be entered for
/// synchronous execution between turns of its event loop, when no other thread
/// is executing code in the target isolate". The case this project needs is not
/// another thread - it is *this* thread, with a Dart frame and a foreign frame
/// already on the stack, which is what a `WndProc` invoked from the OS's own
/// modal loop looks like. The documentation does not say whether that is
/// allowed, so it is measured here rather than assumed.
///
/// **2. Can a `^3.6.0` package call it?** Not by naming it: the member does not
/// exist in 3.6 and the compiler rejects the reference. Every call in this file
/// therefore goes through `dynamic`, which defers resolution to run time. That
/// is the whole trick under test, and it only reaches *instance* members -
/// `Isolate.create` and `Isolate.pinToCurrentThread` are static and have no
/// dynamic escape hatch.
///
/// ```
/// # the SDK the package targets today
/// dart run tool/dart313_nested_drain_probe.dart
///
/// # the SDK that has the API
/// D:/referencias_libs_pdf/dartsdk-3.13.3/bin/dart.exe run tool/dart313_nested_drain_probe.dart
/// ```
///
/// **Warning:** the point of the measurement is a call that may deadlock. Run
/// it with a timeout.
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

/// Total time the Dart callback stays on the stack, in milliseconds.
const int _blockFor = 1500;

/// How long each slice of that block lasts. The drain is attempted between
/// slices, so a working drain has 15 chances to let a 50 ms timer through.
const int _sliceMs = 100;

const int _tickEvery = 50;

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

final _DartSleep _sleep =
    _kernel32.lookupFunction<_NativeSleep, _DartSleep>('Sleep');

final _DartEnumWindows _enumWindows =
    _user32.lookupFunction<_NativeEnumWindows, _DartEnumWindows>('EnumWindows');

int _ticks = 0;
bool _calledBack = false;

/// What `handleEvent` did when called under a foreign frame.
String _drainOutcome = 'not attempted';

/// How many times it returned without throwing.
int _drainCalls = 0;

/// The callback the OS invokes on this thread, from inside `EnumWindows`.
///
/// Blocks in slices, attempting to service the event loop between them. This is
/// the shape of a `WndProc` that wants to keep an animation running during a
/// window drag, minus the window.
int _onWindow(int hwnd, int lParam) {
  _calledBack = true;

  // Through `dynamic` on purpose: naming `handleEvent` statically would stop
  // this file compiling under the `^3.6.0` the package declares. See the
  // library comment.
  final dynamic self = Isolate.current;

  var slept = 0;
  while (slept < _blockFor) {
    _sleep(_sliceMs);
    slept += _sliceMs;
    try {
      self.handleEvent();
      _drainCalls++;
      _drainOutcome = 'returned';
    } on NoSuchMethodError {
      // The 3.6 answer: the member is simply not there at run time either.
      _drainOutcome = 'NoSuchMethodError (member absent in this SDK)';
      break;
    } on UnsupportedError catch (error) {
      _drainOutcome = 'UnsupportedError: $error';
      break;
    } on Object catch (error) {
      // Anything else is the interesting answer: the VM refusing re-entry in a
      // defined way, which is far better than a deadlock and is exactly what
      // the proposal asks the contract to specify.
      _drainOutcome = '${error.runtimeType}: $error';
      break;
    }
  }
  return 0;
}

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    stdout.writeln('PROBE=SKIP not Windows');
    return;
  }

  stdout.writeln('SDK reported by the running VM: ${Platform.version}');

  final Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>> callback =
      Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_onWindow, 0);

  final Timer timer =
      Timer.periodic(const Duration(milliseconds: _tickEvery), (_) => _ticks++);
  await Future<void>.delayed(const Duration(milliseconds: _tickEvery * 2));
  final int before = _ticks;

  final Stopwatch elapsed = Stopwatch()..start();
  _enumWindows(callback, 0);
  final int wall = elapsed.elapsedMilliseconds;
  timer.cancel();

  final int during = _ticks - before;
  const int expected = _blockFor ~/ _tickEvery;

  stdout
    ..writeln('a Dart callback under a native frame, blocking $_blockFor ms in '
        '${_blockFor ~/ _sliceMs} slices')
    ..writeln('  callback reached          : $_calledBack')
    ..writeln('  wall time in the call     : $wall ms')
    ..writeln('  handleEvent() attempts    : ${_blockFor ~/ _sliceMs}')
    ..writeln('  handleEvent() returned    : $_drainCalls')
    ..writeln('  handleEvent() outcome     : $_drainOutcome')
    ..writeln('  ticks a live loop would see : about $expected')
    ..writeln('  ticks that got through      : $during');

  if (!_calledBack) {
    stdout.writeln('PROBE=INCONCLUSIVE the callback never ran');
    exitCode = 1;
    return;
  }
  if (during > 0) {
    stdout.writeln('PROBE=WORKS the event loop ran under a native frame');
    return;
  }
  stdout.writeln('PROBE=BLOCKED the event loop stayed unreachable');
}
