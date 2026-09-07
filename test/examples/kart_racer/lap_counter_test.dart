/// Lap counting, including the crossings a segment test gets wrong.
///
/// Everything here goes through [_Driver] rather than calling
/// [LapCounter.update] with a jump. That is not tidiness: [LapCounter] reads a
/// step of more than half a lap as a *wrap*, which is the only way it can tell
/// "crossed the line" from "reversed most of a lap", so a test that moved the
/// kart 400 m in one call would be exercising the wrap handler rather than the
/// counter. Feeding it in short steps is what the game does.
library;

import 'package:test/test.dart';

import '../../../examples/kart_racer/game/lap_counter.dart';

/// A round number, so every expectation below reads without arithmetic.
const double kLap = 500;

/// Moves a kart along the centreline in short steps, the way a race does.
final class _Driver {
  _Driver(this.counter, {double at = 0, this.secondsPerMetre = 0.05})
      : _at = at;

  final LapCounter counter;

  /// 20 m/s, so a lap of this fixture is twenty-five seconds.
  final double secondsPerMetre;

  double _at;
  double clock = 0;

  /// Laps the counter reported as newly completed during the last [drive].
  int lapsGained = 0;

  void drive(double metres) {
    lapsGained = 0;
    const double step = 2.0;
    final int steps = (metres.abs() / step).ceil();
    for (int i = 0; i < steps; i++) {
      final double delta = metres / steps;
      _at = (_at + delta) % kLap;
      if (_at < 0) _at += kLap;
      clock += delta.abs() * secondsPerMetre;
      if (counter.update(_at, clock)) lapsGained++;
    }
  }
}

void main() {
  test('a fresh counter is on lap one with nothing completed', () {
    final LapCounter counter = LapCounter(trackLength: kLap);
    expect(counter.lapsCompleted, 0);
    expect(counter.lap, 1);
    expect(counter.lapTimes, isEmpty);
    expect(counter.bestLap, isNull);
  });

  test('progress accumulates through the wrap', () {
    final LapCounter counter = LapCounter(trackLength: kLap);
    final _Driver driver = _Driver(counter)..drive(120);
    expect(counter.progress, closeTo(120, 1e-9));
    // Past the line. The arc length wraps from 499 to 0, and the counter has
    // to read that as +1 and not as -499.
    driver.drive(400);
    expect(counter.progress, closeTo(520, 1e-9));
    expect(counter.lapsCompleted, 1);
    expect(counter.lap, 2);
  });

  test('a lap is completed at the line and stamped with the race clock', () {
    final LapCounter counter = LapCounter(trackLength: kLap);
    final _Driver driver = _Driver(counter)..drive(480);
    expect(driver.lapsGained, 0);
    expect(counter.lapsCompleted, 0);
    driver.drive(40);
    expect(driver.lapsGained, 1);
    expect(counter.lapsCompleted, 1);
    // 500 m at 20 m/s.
    expect(counter.lapTimes.single, closeTo(25, 0.2));
    expect(counter.bestLap, closeTo(25, 0.2));
  });

  test('lap times are the gaps between crossings, not the clock', () {
    final LapCounter counter = LapCounter(trackLength: kLap);
    final _Driver driver = _Driver(counter)..drive(kLap);
    // Half the speed for the second lap, so the two are distinguishable.
    final _Driver slow = _Driver(counter, at: 0, secondsPerMetre: 0.1)
      ..clock = driver.clock;
    slow.drive(kLap);
    expect(counter.lapTimes, hasLength(2));
    expect(counter.lapTimes[0], closeTo(25, 0.2));
    expect(counter.lapTimes[1], closeTo(50, 0.3));
    expect(counter.bestLap, closeTo(25, 0.2));
  });

  group('backwards over the line', () {
    test('un-counts the lap', () {
      final LapCounter counter = LapCounter(trackLength: kLap);
      final _Driver driver = _Driver(counter)..drive(kLap + 20);
      expect(counter.lapsCompleted, 1);
      expect(counter.lapTimes, hasLength(1));

      // Reversing back over it. A crossing test firing on the segment would
      // count a *second* lap here instead of taking one away.
      driver.drive(-30);
      expect(counter.lapsCompleted, 0);
      expect(counter.lap, 1);
      expect(counter.lapTimes, isEmpty);
    });

    test('and going forward again re-times the whole lap', () {
      final LapCounter counter = LapCounter(trackLength: kLap);
      final _Driver driver = _Driver(counter)..drive(kLap + 20);
      final double firstTime = counter.lapTimes.single;
      driver
        ..drive(-30)
        ..drive(30);
      expect(counter.lapsCompleted, 1);
      // The lap is timed to the *new* crossing, so it is longer by the whole
      // detour. Subtracting a duration back out instead would hand the player
      // a lap of a second and a half.
      expect(counter.lapTimes.single, greaterThan(firstTime + 1));
    });

    test('wobbling on the line does not count four laps', () {
      final LapCounter counter = LapCounter(trackLength: kLap);
      final _Driver driver = _Driver(counter)..drive(kLap);
      expect(counter.lapsCompleted, 1);
      for (int i = 0; i < 4; i++) {
        driver
          ..drive(-6)
          ..drive(6);
      }
      expect(counter.lapsCompleted, 1);
      expect(counter.lapTimes, hasLength(1));
    });

    test('reversing off the grid does not go below zero laps', () {
      // A kart reversing before it ever reached the line has completed no
      // laps, and no fewer than none. What it must *not* do is bank a
      // negative that a later crossing pays off - which is why the count is
      // floored and [progress] is not.
      final LapCounter counter = LapCounter(trackLength: kLap);
      _Driver(counter).drive(-40);
      expect(counter.progress, closeTo(-40, 1e-9));
      expect(counter.lapsCompleted, 0);
      expect(counter.lap, 1);
    });
  });

  test('a grid position behind the line completes a full lap, not a short one',
      () {
    // The bug this exists to stop: seeded at zero, a kart gridded eight metres
    // back would complete its first lap eight metres early - and every lap
    // after it - so a three-lap race would be twenty-four metres short.
    const double back = 8;
    final LapCounter counter = LapCounter(
      trackLength: kLap,
      startDistance: kLap - back,
      startProgress: -back,
    );
    final _Driver driver = _Driver(counter, at: kLap - back);
    driver.drive(back);
    expect(counter.lapsCompleted, 0, reason: 'the line only starts lap 1');
    driver.drive(kLap - 1);
    expect(counter.lapsCompleted, 0, reason: 'one metre short');
    driver.drive(2);
    expect(counter.lapsCompleted, 1);
  });

  test('exactly one lap is reported per lap driven', () {
    final LapCounter counter = LapCounter(trackLength: kLap);
    final _Driver driver = _Driver(counter);
    int gained = 0;
    for (int i = 0; i < 3; i++) {
      driver.drive(kLap);
      gained += driver.lapsGained;
    }
    // The answer that matters to the race loop, which sets a finishing time
    // the first time `lapsCompleted` reaches the total: no double counts on
    // the step that crosses, and none missed.
    expect(gained, 3);
    expect(counter.lapsCompleted, 3);
    expect(counter.lapTimes, hasLength(3));
  });
}
