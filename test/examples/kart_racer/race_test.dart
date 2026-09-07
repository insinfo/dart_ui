/// A whole race, headless.
///
/// This is the file that would catch a regression nobody thought to write a
/// test for: it runs the same fixed steps `--replay` runs and asserts the
/// things a player would notice within one lap - that the grid is on the road
/// and pointing the right way, that the opponents get round, that the order is
/// the order, and that two runs of the same program land on the same metre.
library;

import 'dart:math' as math;

import 'package:test/test.dart';

import '../../../examples/kart_racer/game/lap_counter.dart';
import '../../../examples/kart_racer/game/race.dart';
import '../../../examples/kart_racer/game/track.dart';
import '../../../examples/kart_racer/game/track_limits.dart';
import '../../../examples/kart_racer/game/vehicle.dart';

final double dt = kSimulationStep.inMicroseconds / 1e6;

void main() {
  group('the grid', () {
    final Race race = Race.grid(opponents: 3);

    test('is on the road and behind the line', () {
      for (final Racer racer in race.racers) {
        final TrackProjection where = racer.projection!;
        expect(
            where.lateral.abs(), lessThan(race.track.halfWidth - kKartRadius),
            reason: '${racer.name} is in the barrier');
        expect(racer.counter.progress, lessThan(0),
            reason: '${racer.name} is past the start line');
        expect(racer.counter.lapsCompleted, 0);
        expect(racer.counter.lap, 1);
      }
    });

    test('points along the track, not across it', () {
      for (final Racer racer in race.racers) {
        final TrackSample frame = racer.projection!.sample;
        final double alignment = racer.body.forwardX * frame.tangentX +
            racer.body.forwardZ * frame.tangentZ;
        expect(alignment, greaterThan(0.99), reason: racer.name);
      }
    });

    test('has no two karts inside each other', () {
      for (int i = 0; i < race.racers.length; i++) {
        for (int j = i + 1; j < race.racers.length; j++) {
          final KartBody a = race.racers[i].body;
          final KartBody b = race.racers[j].body;
          final double gap = math.sqrt(
            (a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z),
          );
          expect(gap, greaterThan(kKartRadius * 2));
        }
      }
    });

    test('the player is the first racer and the only one with no driver', () {
      expect(race.player.isPlayer, isTrue);
      expect(race.racers.skip(1).every((Racer r) => !r.isPlayer), isTrue);
    });
  });

  group('the lights', () {
    test('nothing moves before the green, whatever the player presses', () {
      final Race race = Race.grid(opponents: 2);
      final double x = race.player.body.x;
      const KartInput flooring = KartInput(throttle: 1, steer: 1, drift: true);
      for (int i = 0; i < 120; i++) {
        race.step(dt, flooring);
      }
      expect(race.started, isFalse);
      expect(race.time, 0);
      expect(race.player.body.x, x);
      expect(race.player.body.speed, 0);
      // And the steering is genuinely inert rather than suppressed: the
      // bicycle model needs speed to turn, so a locked grid feels like a held
      // clutch rather than a frozen frame.
      expect(race.player.body.heading, isNot(isNaN));
    });

    test('the green light starts the clock', () {
      final Race race = Race.grid(opponents: 1);
      final int steps = (kCountdownSeconds / dt).ceil() + 4;
      for (int i = 0; i < steps; i++) {
        race.step(dt, const KartInput(throttle: 1));
      }
      expect(race.started, isTrue);
      expect(race.time, greaterThan(0));
      expect(race.player.body.speed, greaterThan(0));
    });
  });

  group('a race', () {
    test('the opponents get round the circuit at a plausible pace', () {
      // The one property that says the track, the physics and the driver all
      // agree: an opponent that could not take turn 3 would sit against the
      // barrier and never finish, and an opponent taking 12-second laps would
      // mean the circuit had collapsed to a point.
      final Race race = runScriptedRace(frames: 6000, opponents: 2);
      for (final Racer racer in race.racers.skip(1)) {
        expect(racer.finishTime, isNotNull,
            reason: '${racer.name} never finished');
        final double? best = racer.counter.bestLap;
        expect(best, isNotNull);
        expect(best, greaterThan(20), reason: 'a lap that fast is a shortcut');
        expect(best, lessThan(60), reason: 'something is stuck in a barrier');
      }
    });

    test('the opponents stay on the road', () {
      final Race race = Race.grid(opponents: 2);
      double worst = 0;
      for (int i = 0; i < 120 * 60; i++) {
        race.step(dt, KartInput.idle);
        for (final Racer racer in race.racers.skip(1)) {
          worst = math.max(worst, racer.projection!.lateral.abs());
        }
      }
      // Allowed onto the kerbs and the grass; not allowed to be through the
      // barrier, which is what `wallOffset` is.
      expect(worst, lessThan(race.track.wallOffset));
    });

    test('the autopilot finishes ahead of nobody by accident', () {
      final Race race =
          runScriptedRace(frames: 6000, opponents: 2, autopilot: true);
      expect(race.player.finishTime, isNotNull);
      expect(race.player.counter.lapsCompleted, greaterThanOrEqualTo(3));
      // Every finisher's time is at least the sum of three plausible laps.
      for (final Racer racer in race.racers) {
        final double? finish = racer.finishTime;
        if (finish == null) continue;
        expect(finish, greaterThan(3 * 20.0));
      }
    });

    test('position is the running order and then the finishing order', () {
      final Race race = Race.grid(opponents: 2);
      for (int i = 0; i < 120 * 40; i++) {
        race.step(dt, KartInput.idle);
      }
      final List<Racer> byPosition = List<Racer>.of(race.racers)
        ..sort((Racer a, Racer b) => a.position.compareTo(b.position));
      for (int i = 1; i < byPosition.length; i++) {
        expect(
          byPosition[i - 1].counter.progress,
          greaterThanOrEqualTo(byPosition[i].counter.progress),
        );
      }
      // The idle player has not moved, so it is last.
      expect(race.player.position, race.racers.length);
    });

    test('a finished kart keeps its place however far the others go', () {
      final Race race =
          runScriptedRace(frames: 7000, opponents: 2, autopilot: true);
      final List<Racer> finishers = race.racers
          .where((Racer r) => r.finishTime != null)
          .toList()
        ..sort((Racer a, Racer b) => a.position.compareTo(b.position));
      for (int i = 1; i < finishers.length; i++) {
        expect(finishers[i - 1].finishTime!,
            lessThanOrEqualTo(finishers[i].finishTime!));
      }
    });
  });

  group('determinism', () {
    test('two runs of the same program land on the same metre', () {
      // The whole reason `--replay` exists. A simulation that read the wall
      // clock, or a `Set` iteration order, or an uninitialised field would
      // diverge here and nowhere else visible.
      final Race a = runScriptedRace(frames: 900);
      final Race b = runScriptedRace(frames: 900);
      expect(a.summary, b.summary);
      for (int i = 0; i < a.racers.length; i++) {
        expect(a.racers[i].body.x, b.racers[i].body.x);
        expect(a.racers[i].body.z, b.racers[i].body.z);
        expect(a.racers[i].body.heading, b.racers[i].body.heading);
      }
    });

    test('the step count is frames times steps per frame, exactly', () {
      final Race race = runScriptedRace(frames: 300, stepsPerFrame: 2);
      expect(race.stepsTaken, 600);
      // Within one step: the countdown is consumed by whole steps, so the
      // step that finishes it gives the race clock only what was left over.
      expect(race.time, closeTo(600 * dt - kCountdownSeconds, dt));
    });

    test('the summary carries the fields a regression is read from', () {
      final String summary = runScriptedRace(frames: 60).summary;
      for (final String field in <String>[
        'laps=',
        'position=',
        'time=',
        'x=',
        'z=',
        'heading=',
        'speed=',
        'progress=',
        'steps=',
      ]) {
        expect(summary, contains(field));
      }
    });
  });

  group('kart against kart', () {
    test('two karts on the same spot are separated rather than made NaN', () {
      // Coincident bodies are the case that divides by zero: the direction to
      // push them apart is undefined, and picking none turns both karts into
      // NaN for the rest of the session.
      final TrackPath track = buildCircuit();
      final TrackSample frame = track.frameAt(30);
      KartBody at(double lateral) => KartBody(
            x: frame.x + frame.normalX * lateral,
            z: frame.z + frame.normalZ * lateral,
            heading: math.atan2(frame.tangentX, frame.tangentZ),
          );
      final Race race = Race(
        track: track,
        racers: <Racer>[
          Racer(
            name: 'a',
            body: at(0),
            counter: LapCounter(trackLength: track.length),
            colorArgb: 0xFFFF0000,
          ),
          Racer(
            name: 'b',
            body: at(0),
            counter: LapCounter(trackLength: track.length),
            colorArgb: 0xFF0000FF,
          ),
        ],
      );
      race.step(dt, KartInput.idle);
      final KartBody a = race.racers[0].body;
      final KartBody b = race.racers[1].body;
      expect(a.x.isFinite, isTrue);
      expect(b.x.isFinite, isTrue);
      final double gap =
          math.sqrt((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z));
      expect(gap, greaterThan(0));
    });

    test('a kart driven into the back of another pushes it, not through it',
        () {
      final Race race = Race.grid(opponents: 1);
      for (int i = 0; i < 120 * 30; i++) {
        race.step(dt, const KartInput(throttle: 1));
        final KartBody a = race.racers[0].body;
        final KartBody b = race.racers[1].body;
        final double gap =
            math.sqrt((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z));
        expect(gap, greaterThan(kKartRadius * 1.9));
      }
    });
  });
}
