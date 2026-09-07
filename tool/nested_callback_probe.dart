/// Can the Dart event loop be served from inside a native call that has
/// called back into Dart?
///
/// This is the gap `doc/propostas/08_proposta_dart_sdk_laco_modal_aninhado_ptbr.md`
/// asks the SDK to close, reduced to the smallest program that shows it. No
/// window, no framework, no UI: just an ordinary FFI function that invokes a
/// Dart callback on the calling thread and does not return for a while.
///
/// That shape is not exotic. It is `EnumWindows`, `EnumFontFamiliesEx`,
/// `SetWindowsHookEx`, a COM event sink, `qsort`, and - the case this project
/// actually hit - the `WndProc` Windows calls from inside the modal loop it
/// runs for itself between `WM_ENTERSIZEMOVE` and `WM_EXITSIZEMOVE`. In every
/// one of them Dart code is running, on the isolate's own thread, with a
/// foreign frame underneath it.
///
/// The measurement: a 50 ms periodic timer is armed, then a native call is
/// made whose Dart callback blocks for 1500 ms. A live event loop would see
/// about 30 ticks. What the probe reports is how many actually get through,
/// and whether anything in `dart:isolate` can be called from inside the
/// callback to let them.
///
/// ```
/// dart run tool/nested_callback_probe.dart
/// ```
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

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

/// How long the Dart callback stays on the stack, in milliseconds.
const int _blockFor = 1500;

/// The periodic timer's interval. `_blockFor / _tickEvery` is what a running
/// event loop would produce.
const int _tickEvery = 50;

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

final _DartSleep _sleep =
    _kernel32.lookupFunction<_NativeSleep, _DartSleep>('Sleep');

final _DartEnumWindows _enumWindows =
    _user32.lookupFunction<_NativeEnumWindows, _DartEnumWindows>('EnumWindows');

/// Ticks counted by the periodic timer. Read after the native call returns.
int _ticks = 0;

/// Ticks that had already been counted when the callback was entered.
int _ticksOnEntry = -1;

/// Whether the callback ran at all, so a zero tick count cannot be confused
/// with a native call that never reached Dart.
bool _calledBack = false;

/// The callback Windows invokes, on this thread, from inside `EnumWindows`.
///
/// Blocking here is the whole point: it reproduces a modal loop's `WndProc`
/// without needing a human to hold a mouse button down. Returns 0 to stop the
/// enumeration after the first window, so the block happens exactly once.
int _onWindow(int hwnd, int lParam) {
  _calledBack = true;
  _ticksOnEntry = _ticks;

  // Everything a Dart programmer would reach for here, and what each one does.
  //
  //   * `await` - illegal: the function is called from native code and must
  //     return an `int` synchronously. Making it `async` returns a Future the
  //     caller cannot use, and the code after the first suspension point runs
  //     after `EnumWindows` has already returned.
  //   * `Timer.run`, `scheduleMicrotask` - they enqueue. Nothing drains the
  //     queue until this frame and the native frame beneath it both return.
  //   * `sleep` from `dart:io` - blocks exactly as `Sleep` does.
  //
  // There is no fourth option. That absence is the proposal.
  _sleep(_blockFor);
  return 0;
}

Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('PROBE=SKIP not Windows');
    return;
  }

  final Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>> callback =
      Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_onWindow, 0);

  final Timer timer =
      Timer.periodic(const Duration(milliseconds: _tickEvery), (_) => _ticks++);

  // A turn of the loop first, so the timer is genuinely armed and a tick count
  // of zero afterwards means "could not fire" rather than "was never started".
  await Future<void>.delayed(const Duration(milliseconds: _tickEvery * 2));
  final int before = _ticks;

  final Stopwatch elapsed = Stopwatch()..start();
  _enumWindows(callback, 0);
  final int wall = elapsed.elapsedMilliseconds;
  timer.cancel();

  final int during = _ticks - before;
  const int expected = _blockFor ~/ _tickEvery;

  stdout
    ..writeln('a Dart callback invoked from inside EnumWindows, blocking for '
        '$_blockFor ms')
    ..writeln('  callback reached      : $_calledBack')
    ..writeln('  wall time in the call : $wall ms')
    ..writeln('  ticks a live loop would see : about $expected')
    ..writeln('  ticks that got through      : $during');

  if (!_calledBack) {
    stdout.writeln('PROBE=INCONCLUSIVE the callback never ran');
    exitCode = 1;
    return;
  }
  if (wall < _blockFor) {
    stdout
        .writeln('PROBE=INCONCLUSIVE the call returned before the block ended');
    exitCode = 1;
    return;
  }
  if (during > 0) {
    // Would mean the VM found a way to service the loop under a foreign frame.
    // Worth knowing loudly if it ever becomes true.
    stdout.writeln('PROBE=CHANGED the event loop ran under a native frame');
    return;
  }
  stdout
    ..writeln('  ticks observed from *inside* the callback : $_ticksOnEntry '
        '(the count at entry; nothing was added while it ran)')
    ..writeln('PROBE=PASS the event loop is unreachable under a native frame');
}
