@TestOn('linux')
library;

import 'dart:io';

import 'package:mvp_02_x11_counter/mvp_02_x11_counter.dart';
import 'package:test/test.dart';

void main() {
  test('MVP-02 smoke runs when DISPLAY is available', () {
    if (Platform.environment['DISPLAY'] == null) {
      markTestSkipped('X11 display is not available locally.');
    }
    expect(X11CounterHost().run(smokeTest: true), isTrue);
  });
}
