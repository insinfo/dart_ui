import 'dart:async';

import 'package:poc_10_event_loop/poc_10_event_loop.dart';

Future<void> main() async {
  final loop = Win32EventLoop();
  var timerTicks = 0;
  final stopwatch = Stopwatch()..start();
  final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    timerTicks++;
    loop.wake();
  });

  try {
    await loop.runUntil(() => timerTicks >= 3);
    // The stopping tick may have posted its wake message after the condition
    // was checked; drain that final native iteration before asserting.
    await loop.pump(Duration.zero);
  } finally {
    timer.cancel();
    loop.dispose();
  }

  stopwatch.stop();
  if (timerTicks < 3 || loop.wakeMessages < 3) {
    throw StateError('Timer/wakeup integration did not complete.');
  }
  print('POC-10: Win32 + Dart cooperative event loop');
  print('Timer ticks: $timerTicks | Wake messages: ${loop.wakeMessages}');
  print('Elapsed: ${stopwatch.elapsedMilliseconds}ms | '
      'Native messages: ${loop.nativeMessages}');
  print('✅ Dart Timer and Win32 wakeup integration passed.');
}
