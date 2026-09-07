/// Counting laps from a distance that wraps.
///
/// ## Why not "did the kart cross the line this step?"
///
/// That is the obvious implementation and it is wrong in three ways this one
/// is not, all of which a player finds within a minute:
///
///   * **it counts the wrong laps.** A segment test against the start line
///     fires for a kart that spins on the line and wobbles across it four
///     times, and it fires for a kart that reversed out of turn 7 and crossed
///     it backwards. Mario Kart's answer to that is a checkpoint ring you have
///     to visit in order, which is the same idea as this one with the
///     resolution turned down;
///   * **it can miss.** At 27 m/s and a 120 Hz step the kart moves 22 cm per
///     step, which is fine - until the frame rate drops, the accumulator
///     clamps, and one step covers three metres. A crossing test that missed
///     one lap in a hundred would be a bug reported as "it sometimes doesn't
///     count";
///   * **it has nothing to say about position.** First and second place is a
///     comparison of *how far round*, and that number has to exist anyway.
///
/// So the counter integrates progress instead. [update] is handed the arc
/// length from [TrackPath.project], removes the wrap, and accumulates. Laps
/// are then a division, and driving backwards over the line subtracts a lap
/// because the accumulated distance genuinely went down.
library;

/// Laps, lap times and race position for one kart.
final class LapCounter {
  LapCounter({
    required this.trackLength,
    double startDistance = 0,
    double startProgress = 0,
  })  : _previousDistance = startDistance,
        progress = startProgress;

  /// One lap, metres.
  final double trackLength;

  double _previousDistance;

  /// Signed distance travelled along the centreline since the start line.
  ///
  /// Signed and not clamped: a kart that reverses past the line is at a
  /// negative progress, which is exactly the state that must not count as
  /// having started a lap.
  ///
  /// Seeded negative for a kart on the grid, which is *behind* the line: with
  /// it left at zero, a kart six metres back would complete its first lap six
  /// metres early, and every lap after it, so the whole race would be short by
  /// the length of the grid.
  double progress;

  /// The race time at each completed lap, in order. Kept rather than the lap
  /// *durations* so that a backwards crossing can be undone exactly by
  /// dropping the last entry - subtracting a duration back out accumulates
  /// float error, and the error is visible because these are printed to the
  /// hundredth.
  final List<double> crossingTimes = <double>[];

  /// How many whole laps have been completed.
  ///
  /// Never negative, and the floor is not cosmetic. A kart on the grid is
  /// *behind* the line, so its [progress] is negative and the bare division
  /// answers -1 - which would put the whole field on lap zero for the first
  /// seven metres of every race. Reversing over the line from the racing side
  /// still un-counts a lap, because that only takes [progress] from above one
  /// lap to below it, and the division does that on its own.
  int get lapsCompleted {
    final int whole = (progress / trackLength).floor();
    return whole < 0 ? 0 : whole;
  }

  /// The lap being driven, 1-based, as a HUD shows it.
  int get lap => lapsCompleted + 1;

  /// Duration of each completed lap, derived from [crossingTimes].
  List<double> get lapTimes {
    final List<double> times = <double>[];
    for (int i = 0; i < crossingTimes.length; i++) {
      times.add(crossingTimes[i] - (i == 0 ? 0 : crossingTimes[i - 1]));
    }
    return times;
  }

  double? get bestLap {
    final List<double> times = lapTimes;
    if (times.isEmpty) return null;
    double best = times.first;
    for (final double time in times) {
      if (time < best) best = time;
    }
    return best;
  }

  /// Feeds one step's arc length and returns whether a lap was completed.
  ///
  /// [distance] is [TrackPath.project]'s `distance`, in `[0, trackLength)`.
  /// [now] is the race clock, used only to stamp a crossing.
  bool update(double distance, double now) {
    double delta = distance - _previousDistance;
    // The wrap. Half a lap in one step is not a step, it is a wrap: at 27 m/s
    // and a 120 Hz tick a step is 22 cm, and the accumulator's clamp caps the
    // worst case far below half a lap.
    if (delta > trackLength / 2) {
      delta -= trackLength;
    } else if (delta < -trackLength / 2) {
      delta += trackLength;
    }
    progress += delta;
    _previousDistance = distance;

    final int completed = lapsCompleted;
    bool gained = false;
    while (crossingTimes.length < completed) {
      crossingTimes.add(now);
      gained = true;
    }
    while (crossingTimes.length > completed && crossingTimes.isNotEmpty) {
      // Backwards over the line. The lap is un-counted, and its time with it,
      // so that crossing forwards again re-times the whole lap rather than
      // handing the player a lap of nought point one seconds.
      crossingTimes.removeLast();
    }
    return gained;
  }

  @override
  String toString() => 'LapCounter(lap $lap, '
      '${progress.toStringAsFixed(1)} m of $trackLength m)';
}
