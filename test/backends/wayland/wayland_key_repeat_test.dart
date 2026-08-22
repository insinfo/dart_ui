import 'package:dart_ui/src/backends/wayland/wayland_key_repeat.dart';
import 'package:test/test.dart';

void main() {
  group('WaylandKeyRepeat', () {
    test('waits for the configured delay and then follows the rate', () {
      final repeat = WaylandKeyRepeat()
        ..configure(rateHz: 20, delayMilliseconds: 300)
        ..onKeyDown(30, 7, 1000);

      expect(repeat.millisecondsUntilDue(1000), 300);
      expect(repeat.takeDueRepeats(1299), 0);
      expect(repeat.takeDueRepeats(1300), 1);
      expect(repeat.millisecondsUntilDue(1300), 50);
      expect(repeat.takeDueRepeats(1450), 3);
      expect(repeat.armedKey, 30);
      expect(repeat.armedSurfaceId, 7);
    });

    test('a second press replaces the repeating key and surface', () {
      final repeat = WaylandKeyRepeat()
        ..configure(rateHz: 25, delayMilliseconds: 400)
        ..onKeyDown(30, 7, 0)
        ..onKeyDown(31, 8, 100);

      repeat.onKeyUp(30);
      expect(repeat.isArmed, isTrue);
      expect(repeat.armedKey, 31);
      expect(repeat.armedSurfaceId, 8);
      repeat.onKeyUp(31);
      expect(repeat.isArmed, isFalse);
    });

    test('disabled repeat cancels a key already held', () {
      final repeat = WaylandKeyRepeat()..onKeyDown(30, 7, 0);
      repeat.configure(rateHz: 0, delayMilliseconds: 400);

      expect(repeat.isArmed, isFalse);
      expect(repeat.millisecondsUntilDue(1000), isNull);
      expect(repeat.takeDueRepeats(1000), 0);
    });

    test('a long scheduler stall emits a bounded burst and drops backlog', () {
      final repeat = WaylandKeyRepeat()
        ..configure(rateHz: 100, delayMilliseconds: 0)
        ..onKeyDown(30, 7, 0);

      expect(repeat.takeDueRepeats(1000, maximumBurst: 8), 8);
      expect(repeat.takeDueRepeats(1000), 0);
      expect(repeat.millisecondsUntilDue(1000), 10);
    });

    test('negative compositor settings are safely clamped', () {
      final repeat = WaylandKeyRepeat()
        ..configure(rateHz: -10, delayMilliseconds: -50)
        ..onKeyDown(30, 7, 0);

      expect(repeat.rateHz, 0);
      expect(repeat.delayMilliseconds, 0);
      expect(repeat.isArmed, isFalse);
    });
  });
}
