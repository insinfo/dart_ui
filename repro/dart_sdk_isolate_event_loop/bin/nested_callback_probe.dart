/// Can anything run the isolate's event loop while Dart code is executing
/// inside a callback that native code invoked on the isolate's own thread?
///
/// Reproduction for https://github.com/dart-lang/sdk/issues/64230, portable to
/// Windows, Linux and macOS. The native frame is `qsort` from the C runtime,
/// whose comparator is a plain `Pointer.fromFunction` callback: the same shape
/// as a Win32 `WndProc` called from inside the OS modal move/resize loop, an
/// `EnumWindows` callback, or a GLib/AppKit nested run loop.
///
/// ```
/// dart run bin/nested_callback_probe.dart
/// ```
///
/// A 50 ms periodic timer is armed and allowed to tick, then `qsort` is called
/// on two elements. The comparator blocks for 1500 ms the first time it runs.
/// A live event loop would deliver about 30 ticks during the call.
///
/// Uses no experimental API, so it compiles on every SDK. Inside the
/// comparator there is nothing to call: `await` is not allowed in a callback
/// that must return synchronously, `Timer.run` and `scheduleMicrotask` only
/// enqueue, and `Isolate.handleEvent` - the one `dart:isolate` entry point
/// that names "handle one event" - throws `UnsupportedError` on 3.13.x and is
/// no longer public on dev (`bin/on_event_probe.dart` shows both).
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dart_sdk_isolate_event_loop/native.dart';

const int blockFor = 1500;
const int tickEvery = 50;

int ticks = 0;
int ticksAtEntry = -1;
int ticksAtExit = -1;
int comparisons = 0;

int compare(Pointer<Void> a, Pointer<Void> b) {
  if (comparisons++ > 0) return 0;
  ticksAtEntry = ticks;
  sleepNative(blockFor);
  ticksAtExit = ticks;
  return 0;
}

Future<void> main() async {
  stdout
    ..writeln('SDK: ${Platform.version}')
    ..writeln('native frame: qsort comparator, blocking $blockFor ms');

  final Timer timer = Timer.periodic(
    const Duration(milliseconds: tickEvery),
    (_) => ticks++,
  );
  // Let the timer tick first, so zero ticks later means "could not fire", not
  // "never armed".
  await Future<void>.delayed(const Duration(milliseconds: tickEvery * 3));
  final int armed = ticks;

  final Pointer<Int32> items = malloc(8).cast<Int32>()
    ..[0] = 2
    ..[1] = 1;
  final Stopwatch clock = Stopwatch()..start();
  qsort(items.cast(), 2, 4, Pointer.fromFunction<CompareNative>(compare, 0));
  final int wall = clock.elapsedMilliseconds;
  free(items.cast());

  final int during = ticksAtExit - ticksAtEntry;
  // What the loop does once the native frame is gone, for contrast.
  await Future<void>.delayed(const Duration(milliseconds: tickEvery * 3));
  timer.cancel();

  stdout
    ..writeln('  ticks before the call        : $armed')
    ..writeln('  comparator reached           : ${ticksAtEntry >= 0}')
    ..writeln('  wall time inside qsort       : $wall ms')
    ..writeln('  ticks a live loop would see  : about ${blockFor ~/ tickEvery}')
    ..writeln('  ticks delivered during call  : $during')
    ..writeln('  ticks after qsort returned   : ${ticks - ticksAtExit}');

  if (ticksAtEntry < 0 || wall < blockFor) {
    stdout.writeln('RESULT=INCONCLUSIVE the comparator did not block');
    exitCode = 1;
  } else if (during > 0) {
    stdout.writeln('RESULT=CHANGED the event loop ran under a native frame');
  } else {
    stdout.writeln(
      'RESULT=REPRODUCED no timer tick was delivered while Dart '
      'ran under a native frame',
    );
  }
}
