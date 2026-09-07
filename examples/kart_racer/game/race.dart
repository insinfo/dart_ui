/// The race: the karts, the clock, the order they are in, and the one method
/// that advances all of it by exactly one fixed step.
///
/// Nothing here knows what a window is, what a frame is, or how fast the
/// machine is. [Race.step] takes a `dt` and an input and is the only way the
/// world changes, which is what makes `--replay` reproduce a race exactly and
/// what lets every test in `test/examples/kart_racer` drive a real race
/// without a display.
///
/// The fixed step is 1/120 s. Twice the frame rate, so that the numbers a
/// player feels - the yaw response, the grip, the drag - are integrated
/// finely enough that a frame-rate change cannot be felt in the handling, and
/// cheap enough that two steps per frame is nothing next to drawing.
library;

import 'dart:math' as math;

import 'lap_counter.dart';
import 'opponent.dart';
import 'track.dart';
import 'track_limits.dart';
import 'vehicle.dart';

/// The simulation's tick.
const Duration kSimulationStep = Duration(microseconds: 8333);

/// Seconds of lights before the race starts.
const double kCountdownSeconds = 3.2;

/// One competitor.
final class Racer {
  Racer({
    required this.name,
    required this.body,
    required this.counter,
    required this.colorArgb,
    this.driver,
  });

  final String name;
  final KartBody body;
  final LapCounter counter;

  /// The kart's paint, straight into the mesh material.
  final int colorArgb;

  /// Null for the human. The player's kart is a [Racer] like any other so that
  /// nothing in the race loop has to special-case it; only the source of the
  /// input differs.
  final WaypointDriver? driver;

  bool get isPlayer => driver == null;

  /// Where the kart is on the track, refreshed twice a step.
  TrackProjection? projection;

  /// The sample index to start the next search from. See [TrackPath.project].
  int? searchHint;

  SurfaceResponse surface = SurfaceResponse.road;
  WallImpact lastImpact = WallImpact.none;
  KartInput lastInput = KartInput.idle;

  /// The race clock when this kart took the flag, or null.
  double? finishTime;

  /// One-based finishing or running order, filled in by [Race.step].
  int position = 1;
}

/// A whole race.
final class Race {
  Race({
    required this.track,
    required this.racers,
    this.totalLaps = 3,
  }) {
    for (final Racer racer in racers) {
      final TrackProjection start = track.project(racer.body.x, racer.body.z);
      racer.projection = start;
      racer.searchHint = start.sampleIndex;
    }
    _orderRacers();
  }

  /// Builds the demo's race: the player plus [opponents] drivers, gridded
  /// behind the start line.
  factory Race.grid({int opponents = 2, int totalLaps = 3}) {
    final TrackPath track = buildCircuit();
    final List<Racer> racers = <Racer>[];
    const List<int> paint = <int>[
      0xFFE8402A, // the player: the only red kart on the grid
      0xFF2F80ED,
      0xFFF2C037,
      0xFF34C77B,
    ];
    for (int i = 0; i < opponents + 1; i++) {
      // Two abreast, rows six metres apart, which is enough that the kart
      // behind is not inside the one in front the moment the lights go out.
      final int row = i ~/ 2;
      final double lateral = i.isEven ? -2.6 : 2.6;
      final double back = 7.0 + row * 6.0;
      final double startDistance = (track.length - back) % track.length;
      final TrackSample frame = track.frameAt(startDistance);
      final KartBody body = KartBody(
        x: frame.x + frame.normalX * lateral,
        z: frame.z + frame.normalZ * lateral,
        // The heading whose forward is the track's tangent; see
        // `vehicle.dart` for why the arguments are in this order.
        heading: math.atan2(frame.tangentX, frame.tangentZ),
        tuning: const KartTuning(),
      );
      racers.add(Racer(
        name: i == 0 ? 'VOCÊ' : 'CPU $i',
        body: body,
        counter: LapCounter(
          trackLength: track.length,
          startDistance: startDistance,
          // The grid is behind the line, so progress starts negative by
          // exactly the distance to it.
          startProgress: -back,
        ),
        colorArgb: paint[i % paint.length],
        driver: i == 0
            ? null
            : WaypointDriver(
                track: track,
                // Each opponent runs a different line so they do not all
                // converge on the same apex and lock together.
                lineOffset: (i.isEven ? -1 : 1) * (1.4 + i * 0.5),
                corneringAcceleration: 12.6 - i * 0.9,
                speedLimit: 25.6 - i * 0.7,
              ),
      ));
    }
    return Race(track: track, racers: racers, totalLaps: totalLaps);
  }

  final TrackPath track;
  final List<Racer> racers;
  final int totalLaps;

  Racer get player => racers.first;

  /// Seconds of lights left. Zero once the race is running.
  double countdownRemaining = kCountdownSeconds;

  /// The race clock, which starts at the green light.
  double time = 0;

  bool get started => countdownRemaining <= 0;

  /// Whether the player has taken the flag. Opponents keep driving; freezing
  /// the world at the flag leaves the finishing kart stuck mid-corner under
  /// the result panel, which reads as a crash.
  bool get finished => player.finishTime != null;

  /// How many steps have been taken, so a replay can be compared exactly.
  int stepsTaken = 0;

  /// Advances everything by [dt] seconds.
  void step(double dt, KartInput playerInput) {
    if (dt <= 0) return;
    stepsTaken++;
    if (!started) {
      countdownRemaining = math.max(0, countdownRemaining - dt);
    } else {
      time += dt;
    }

    for (final Racer racer in racers) {
      final KartBody body = racer.body;
      final TrackProjection before =
          track.project(body.x, body.z, hint: racer.searchHint);
      racer.projection = before;
      racer.searchHint = before.sampleIndex;
      racer.surface = surfaceAt(track, before.lateral);

      KartInput input;
      if (!started) {
        // The lights. Steering before the green is allowed and does nothing,
        // because the bicycle model needs speed to turn - which is the one
        // behaviour that makes a locked grid feel like a held clutch rather
        // than a frozen frame.
        input = playerInput.copyWith(throttle: 0, brake: 0, drift: false);
        if (!racer.isPlayer) input = KartInput.idle;
      } else if (racer.isPlayer) {
        input = racer.finishTime == null
            ? playerInput
            // After the flag the kart coasts to a stop on its own. Handing it
            // a brake instead would stop it dead under the results panel.
            : const KartInput();
      } else {
        input = racer.driver!.drive(body, before);
      }
      racer.lastInput = input;

      body.step(
        input,
        dt,
        gripScale: racer.surface.gripScale,
        powerScale: racer.surface.powerScale,
      );
    }

    _separateKarts();

    for (final Racer racer in racers) {
      final KartBody body = racer.body;
      // Re-projected after the move: the walls are resolved against where the
      // kart *is*, not where it was. Resolving against the pre-step projection
      // lets a kart at 27 m/s travel 22 cm into the barrier before anything
      // notices, and at a low frame rate it travels through it.
      final TrackProjection after =
          track.project(body.x, body.z, hint: racer.searchHint);
      racer.lastImpact = resolveTrackLimits(body, track, after);
      racer.projection = after;
      racer.searchHint = after.sampleIndex;
      racer.counter.update(after.distance, time);
      if (racer.finishTime == null &&
          racer.counter.lapsCompleted >= totalLaps) {
        racer.finishTime = time;
      }
    }

    _orderRacers();
  }

  /// Keeps two karts from occupying the same metre of road.
  ///
  /// Circles again, and elastic only enough to separate: karts that bounced
  /// off each other properly would turn every start into a pinball table.
  /// What this is really for is the case a player finds immediately - drafting
  /// up behind an opponent - where without it the two karts simply overlap and
  /// the front one is drawn inside the back one.
  void _separateKarts() {
    const double contact = kKartRadius * 2;
    for (int i = 0; i < racers.length; i++) {
      for (int j = i + 1; j < racers.length; j++) {
        final KartBody a = racers[i].body;
        final KartBody b = racers[j].body;
        double dx = b.x - a.x;
        double dz = b.z - a.z;
        double distance = math.sqrt(dx * dx + dz * dz);
        if (distance >= contact) continue;
        if (distance < 1e-6) {
          // Exactly coincident, which happens only when two karts are spawned
          // on the same spot. Any direction will do; picking none divides by
          // zero and both karts become NaN for the rest of the session.
          dx = 1;
          dz = 0;
          distance = 1;
        }
        final double nx = dx / distance;
        final double nz = dz / distance;
        final double overlap = (contact - distance) * 0.5;
        a.x -= nx * overlap;
        a.z -= nz * overlap;
        b.x += nx * overlap;
        b.z += nz * overlap;

        final double closing = (b.worldVelocityX - a.worldVelocityX) * nx +
            (b.worldVelocityZ - a.worldVelocityZ) * nz;
        if (closing >= 0) continue;
        final double impulse = closing * 0.5;
        a.setWorldVelocity(
          a.worldVelocityX + nx * impulse,
          a.worldVelocityZ + nz * impulse,
        );
        b.setWorldVelocity(
          b.worldVelocityX - nx * impulse,
          b.worldVelocityZ - nz * impulse,
        );
      }
    }
  }

  void _orderRacers() {
    final List<Racer> order = List<Racer>.of(racers)
      ..sort((Racer a, Racer b) {
        // A finished kart is ahead of an unfinished one whatever the
        // distances say, and two finished karts are ordered by the flag.
        final double? fa = a.finishTime;
        final double? fb = b.finishTime;
        if (fa != null && fb != null) return fa.compareTo(fb);
        if (fa != null) return -1;
        if (fb != null) return 1;
        return b.counter.progress.compareTo(a.counter.progress);
      });
    for (int i = 0; i < order.length; i++) {
      order[i].position = i + 1;
    }
  }

  /// A one-line summary, which is what `--replay` prints and what a test
  /// compares. Deliberately terse and deliberately stable: a regression shows
  /// up as a diff of this line.
  String get summary {
    final Racer p = player;
    final double? best = p.counter.bestLap;
    return 'laps=${p.counter.lapsCompleted}/$totalLaps '
        'position=${p.position}/${racers.length} '
        'time=${time.toStringAsFixed(3)} '
        'best=${best == null ? '-' : best.toStringAsFixed(3)} '
        'x=${p.body.x.toStringAsFixed(3)} '
        'z=${p.body.z.toStringAsFixed(3)} '
        'heading=${p.body.heading.toStringAsFixed(3)} '
        'speed=${p.body.speed.toStringAsFixed(3)} '
        'progress=${p.counter.progress.toStringAsFixed(2)} '
        'steps=$stepsTaken';
  }
}

/// One scripted moment of a replay: hold [input] until [until] seconds of race
/// time have passed.
final class ScriptedInput {
  const ScriptedInput(this.until, this.input);

  final double until;
  final KartInput input;
}

/// The input program `--replay` drives.
///
/// Hand-written and open-loop: there is no feedback in it at all, so it drives
/// the *first* half-lap roughly and then wanders off the line exactly as an
/// open-loop program must. That is fine and is the point - it exercises the
/// engine, the steering, the drift, the grass and the barriers in a fixed
/// order and produces one number that a regression moves. What it is not is a
/// good lap; for lap counting and a finish, see [runAutoRace].
List<ScriptedInput> defaultReplayScript() => const <ScriptedInput>[
      // Away from the grid, straight, to the braking board for turn 1.
      ScriptedInput(3.5, KartInput(throttle: 1)),
      // Turn 1, the long left across the top of the circuit.
      ScriptedInput(5.2, KartInput(throttle: 1, steer: -0.05)),
      ScriptedInput(7.5, KartInput(throttle: 0.5, steer: -0.09)),
      ScriptedInput(9.5, KartInput(throttle: 0.7, steer: -0.11)),
      // Held handbrake, which is where a mini-turbo is earned.
      ScriptedInput(11.5, KartInput(throttle: 0.45, steer: -0.3, drift: true)),
      ScriptedInput(13.5, KartInput(throttle: 0.9, steer: -0.11)),
      // The chicane: the right first, then back left.
      ScriptedInput(15.5, KartInput(throttle: 0.5, brake: 0.2, steer: -0.05)),
      ScriptedInput(17.5, KartInput(throttle: 0.6, steer: 0.11)),
      ScriptedInput(double.infinity, KartInput(throttle: 0.5, steer: -0.1)),
    ];

/// Runs [frames] frames of a race with no window and returns it.
///
/// Frames and not steps, so that the number on the command line means the same
/// thing it means for every other demo in this repository. Each frame takes
/// exactly [stepsPerFrame] fixed steps, which is what makes the result
/// identical on a fast machine and a slow one - and is the whole reason this
/// mode exists.
///
/// With [autopilot] the player's kart is driven by a [WaypointDriver] instead
/// of by [script]. That is the run worth diffing when what is being checked is
/// laps, lap times and the flag: an open-loop script cannot complete a lap,
/// and a closed-loop driver can, so between them they cover the physics and
/// the race.
Race runScriptedRace({
  int frames = 1800,
  int stepsPerFrame = 2,
  int opponents = 2,
  int totalLaps = 3,
  bool autopilot = false,
  List<ScriptedInput>? script,
}) {
  final Race race = Race.grid(opponents: opponents, totalLaps: totalLaps);
  final List<ScriptedInput> program = script ?? defaultReplayScript();
  final WaypointDriver? pilot =
      autopilot ? WaypointDriver(track: race.track) : null;
  final double dt = kSimulationStep.inMicroseconds / 1e6;
  for (int frame = 0; frame < frames; frame++) {
    for (int i = 0; i < stepsPerFrame; i++) {
      KartInput input = KartInput.idle;
      if (pilot != null) {
        final TrackProjection? where = race.player.projection;
        if (where != null) input = pilot.drive(race.player.body, where);
      } else {
        for (final ScriptedInput moment in program) {
          if (race.time <= moment.until) {
            input = moment.input;
            break;
          }
        }
      }
      race.step(dt, input);
    }
  }
  return race;
}
