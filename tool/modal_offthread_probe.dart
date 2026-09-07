/// Does moving a blocking Win32 call off the main isolate keep the Dart event
/// loop alive?
///
/// This is the one claim the whole off-thread file-dialog detour rests on, so
/// it is measured rather than argued. `IFileDialog::Show` cannot be run
/// unattended - it waits for a human - so `Sleep` from kernel32 stands in for
/// it: same shape, a blocking FFI call that does not return for a long time,
/// and the thing under test is the isolate boundary rather than the dialog.
///
/// A 50 ms periodic timer runs while the blocking call is in flight. If the
/// event loop is parked, almost no ticks get through; if it is running, roughly
/// `duration / 50` do. The gap between the two runs is the answer.
///
/// ```
/// dart run tool/modal_offthread_probe.dart
/// ```
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

typedef _NativeSleep = Void Function(Uint32);
typedef _DartSleep = void Function(int);

/// Blocks the calling operating-system thread for [milliseconds].
///
/// Deliberately not `sleep` from `dart:io`: that one is also a blocking call,
/// but it is the VM's own and the VM is entitled to know about it. A foreign
/// function the VM cannot see is what a modal dialog actually is.
void _blockNatively(int milliseconds) {
  final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
  kernel32.lookupFunction<_NativeSleep, _DartSleep>('Sleep')(milliseconds);
}

/// Counts timer ticks over [window] while [work] is in flight.
Future<int> _ticksDuring(Future<void> Function() work) async {
  var ticks = 0;
  final Timer timer =
      Timer.periodic(const Duration(milliseconds: 50), (_) => ticks++);
  try {
    await work();
  } finally {
    timer.cancel();
  }
  return ticks;
}

Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('PROBE=SKIP not Windows');
    return;
  }
  const int blockFor = 1500;
  const int expected = blockFor ~/ 50;

  // Warm both paths, so neither number carries a one-off library load or the
  // first isolate spawn of the process.
  await _ticksDuring(() async => _blockNatively(1));
  await _ticksDuring(() => Isolate.run(() => _blockNatively(1)));

  final int inline = await _ticksDuring(() async => _blockNatively(blockFor));
  final int offThread =
      await _ticksDuring(() => Isolate.run(() => _blockNatively(blockFor)));

  stdout
    ..writeln('blocking FFI call of $blockFor ms, 50 ms periodic timer, '
        'so a live event loop should see about $expected ticks')
    ..writeln('  on the main isolate : $inline ticks')
    ..writeln('  through Isolate.run : $offThread ticks');

  // The bar is deliberately loose. What is being shown is a difference of an
  // order of magnitude, not a precise tick count on a shared machine.
  final bool parked = inline <= 2;
  final bool alive = offThread >= expected ~/ 2;
  stdout.writeln(parked && alive ? 'PROBE=PASS' : 'PROBE=FAIL');
  exitCode = parked && alive ? 0 : 1;
}
