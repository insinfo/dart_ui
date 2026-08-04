@TestOn('windows')
library;

import 'dart:async';

import 'package:poc_10_event_loop/poc_10_event_loop.dart';
import 'package:test/test.dart';

void main() {
  test('Dart timers execute while Win32 messages wake the loop', () async {
    final loop = Win32EventLoop();
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      ticks++;
      loop.wake();
    });
    addTearDown(() {
      timer.cancel();
      loop.dispose();
    });

    await loop.runUntil(() => ticks >= 2,
        idleTimeout: const Duration(milliseconds: 30));
    await loop.pump(Duration.zero);

    expect(ticks, greaterThanOrEqualTo(2));
    expect(loop.wakeMessages, greaterThanOrEqualTo(2));
  });
}
