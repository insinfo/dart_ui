/// Portable audio/video synchronisation policy for a video player.
///
/// The types here are pure decision logic: no `dart:ffi`, no `dart:io`, no
/// timers, no I/O and no imports at all. A player owns a master clock —
/// normally the audio playback position, or the wall clock when a file has no
/// audio — and a decoder that produces frames carrying a presentation
/// timestamp. For every decoded frame the player asks [AvSynchronizer.evaluate]
/// what to do with it and then performs the one side effect the answer names:
/// draw it, throw it away, or hold it back for a while and ask again.
///
/// Keeping the policy free of time sources is what makes it testable without
/// hardware: a test feeds a synthetic clock and asserts on decisions.
library;

/// What a player should do with one decoded frame at a given clock position.
enum AvSyncAction {
  /// Draw the frame now.
  present,

  /// Discard the frame without drawing it so video can catch up with audio.
  drop,

  /// Hold the frame back for [AvSyncDecision.delay] and evaluate it again.
  ///
  /// The delay is bounded (see [AvSynchronizer.maxWaitDelay]), so a caller must
  /// treat a wait as "ask me again later", never as "this frame is due exactly
  /// then".
  wait,
}

/// The answer [AvSynchronizer.evaluate] gives for a single frame.
final class AvSyncDecision {
  const AvSyncDecision({
    required this.action,
    required this.drift,
    this.delay = Duration.zero,
  });

  final AvSyncAction action;

  /// How long to wait before evaluating the frame again.
  ///
  /// Always [Duration.zero] unless [action] is [AvSyncAction.wait], and never
  /// larger than [AvSynchronizer.maxWaitDelay].
  final Duration delay;

  /// Frame presentation timestamp minus the master clock position.
  ///
  /// Negative means the frame is late: the clock has already moved past the
  /// moment this frame should have been on screen.
  final Duration drift;

  bool get isPresent => action == AvSyncAction.present;
  bool get isDrop => action == AvSyncAction.drop;
  bool get isWait => action == AvSyncAction.wait;

  @override
  bool operator ==(Object other) =>
      other is AvSyncDecision &&
      other.action == action &&
      other.delay == delay &&
      other.drift == drift;

  @override
  int get hashCode => Object.hash(action, delay, drift);

  @override
  String toString() =>
      'AvSyncDecision(${action.name}, drift: ${drift.inMicroseconds}us, '
      'delay: ${delay.inMicroseconds}us)';
}

/// Immutable snapshot of what an [AvSynchronizer] has decided so far.
///
/// Drift is only sampled on decisions that consume a frame ([presented] and
/// [dropped]). A [waited] decision is a deliberate postponement, and counting
/// its drift would bias the average towards frames that were merely early.
final class AvSyncStats {
  const AvSyncStats({
    required this.presented,
    required this.dropped,
    required this.waited,
    required this.averageDrift,
    required this.minDrift,
    required this.maxDrift,
  });

  /// A synchronizer that has decided nothing yet.
  static const AvSyncStats empty = AvSyncStats(
    presented: 0,
    dropped: 0,
    waited: 0,
    averageDrift: Duration.zero,
    minDrift: Duration.zero,
    maxDrift: Duration.zero,
  );

  /// Frames answered with [AvSyncAction.present].
  final int presented;

  /// Frames answered with [AvSyncAction.drop].
  final int dropped;

  /// Decisions answered with [AvSyncAction.wait].
  ///
  /// This counts decisions, not distinct frames: one very early frame can be
  /// waited on several times before it is finally presented.
  final int waited;

  /// Mean drift over the [driftSamples] consumed frames, truncated towards
  /// zero. [Duration.zero] while no frame has been consumed.
  final Duration averageDrift;

  /// Most negative (latest) drift seen on a consumed frame.
  final Duration minDrift;

  /// Most positive (earliest) drift seen on a consumed frame.
  final Duration maxDrift;

  /// Number of consumed frames behind [averageDrift], [minDrift] and
  /// [maxDrift].
  int get driftSamples => presented + dropped;

  /// Largest drift magnitude seen on a consumed frame, ignoring direction.
  Duration get maxAbsoluteDrift {
    final Duration low = minDrift.abs();
    final Duration high = maxDrift.abs();
    return low > high ? low : high;
  }

  @override
  String toString() => 'AvSyncStats(presented: $presented, dropped: $dropped, '
      'waited: $waited, averageDrift: ${averageDrift.inMicroseconds}us, '
      'minDrift: ${minDrift.inMicroseconds}us, '
      'maxDrift: ${maxDrift.inMicroseconds}us)';
}

/// Decides, frame by frame, how video should follow a master clock.
///
/// ## The three zones
///
/// With `drift = framePts - clock`:
///
/// * `|drift| <= syncTolerance` — present. The frame is close enough that no
///   viewer can tell, and micro-waiting on a millisecond of error would only
///   burn a scheduler round trip per frame.
/// * `drift > syncTolerance` — the frame is early, so wait `drift` (clamped to
///   [maxWaitDelay]) and evaluate it again.
/// * `drift < -dropThresholdFor(frameDuration)` — the frame is late enough that
///   skipping it buys real catch-up, so drop it, subject to the anti-spiral
///   guards below. Between that threshold and `-syncTolerance` the frame is
///   late but not worth skipping: present it, because a slightly stale image
///   beats no image.
///
/// Both boundaries are inclusive on the "present" side: a drift of exactly
/// `+syncTolerance`, `-syncTolerance` or `-dropThreshold` presents.
///
/// ## Not spiralling into an all-drop loop
///
/// If the machine simply cannot decode fast enough, every frame is late and a
/// naive policy drops all of them — which shows nothing at all, the worst
/// possible outcome. Two independent ceilings prevent that:
///
/// 1. [maxConsecutiveDrops] is a hard cap. After that many drops in a row the
///    next frame is presented no matter how late it is, so at least one frame
///    in `maxConsecutiveDrops + 1` always reaches the screen.
/// 2. A drop must be earning something. When the previous decision was already
///    a drop, this one only happens if drift improved by more than
///    [minDropImprovement] since then. On a machine that falls further behind
///    with every frame, drift gets worse rather than better, dropping is proven
///    useless, and the synchronizer goes back to presenting.
///
/// The second guard is what covers a genuinely slow machine; the first covers
/// the pathological cases the second cannot see, such as a source that gains
/// exactly as much as it loses between two frames.
///
/// ## Seeks
///
/// Call [reset] after every seek. A seek makes both the clock and the frame
/// timestamps jump, and without a reset the first frame of the new position
/// would be read as an enormous drift and would pollute [stats]. A backwards
/// clock jump that is *not* reported through [reset] still cannot stall the
/// player: the wait delay is clamped to [maxWaitDelay], so the caller comes
/// back within that bound and sees the new situation.
final class AvSynchronizer {
  AvSynchronizer({
    this.syncTolerance = const Duration(milliseconds: 20),
    this.dropThreshold = const Duration(milliseconds: 60),
    this.maxWaitDelay = const Duration(milliseconds: 250),
    this.maxConsecutiveDrops = 2,
    this.minDropImprovement = Duration.zero,
  }) {
    _checkNonNegative(syncTolerance, 'syncTolerance');
    _checkNonNegative(dropThreshold, 'dropThreshold');
    _checkNonNegative(minDropImprovement, 'minDropImprovement');
    if (maxWaitDelay <= Duration.zero) {
      throw ArgumentError.value(
        maxWaitDelay,
        'maxWaitDelay',
        'must be positive, otherwise a wait would spin',
      );
    }
    if (maxConsecutiveDrops < 0) {
      throw ArgumentError.value(
        maxConsecutiveDrops,
        'maxConsecutiveDrops',
        'must not be negative',
      );
    }
  }

  /// Half-width of the window around the clock where a frame is presented as
  /// is.
  ///
  /// Defaults to 20 ms. ITU-R BT.1359 puts the detectability limit for audio
  /// leading video at roughly 45 ms and for video leading audio at roughly
  /// 25 ms; 20 ms stays under both, so nothing inside this window reads as a
  /// lip-sync error, while the window is still wide enough that a 30 fps or
  /// 60 fps pipeline is not forced into a wait on every single frame.
  final Duration syncTolerance;

  /// How late a frame must be before dropping it is considered.
  ///
  /// Defaults to 60 ms, about two frames at 30 fps. That is under the ~100 ms
  /// at which late video becomes noticeable, and far enough past
  /// [syncTolerance] that ordinary jitter never triggers a drop. See
  /// [dropThresholdFor] for the frame-rate correction applied on top of it.
  final Duration dropThreshold;

  /// Upper bound on [AvSyncDecision.delay].
  ///
  /// Defaults to 250 ms, so a caller re-evaluates at least four times per
  /// second. This is the guard against a clock that moves backwards (a seek
  /// that was not reported, or an audio device that re-reports its position):
  /// a frame that looks hours early produces a 250 ms wait, not an hours-long
  /// stall.
  final Duration maxWaitDelay;

  /// Hard ceiling on drops in a row before a frame is presented regardless of
  /// how late it is. Defaults to 2, so at least every third frame is drawn.
  ///
  /// Zero disables dropping entirely, turning this into a present-or-wait
  /// policy.
  final int maxConsecutiveDrops;

  /// How much drift must improve between consecutive drops for dropping to
  /// continue.
  ///
  /// Defaults to [Duration.zero], meaning any strict improvement is enough and
  /// a drop that leaves drift equal or worse ends the run.
  final Duration minDropImprovement;

  int _presented = 0;
  int _dropped = 0;
  int _waited = 0;
  int _driftSumMicroseconds = 0;
  int _driftSamples = 0;
  Duration _minDrift = Duration.zero;
  Duration _maxDrift = Duration.zero;
  int _consecutiveDrops = 0;
  Duration? _driftAtLastDrop;

  /// Statistics accumulated since construction or the last [reset].
  AvSyncStats get stats {
    if (_driftSamples == 0) {
      return AvSyncStats(
        presented: _presented,
        dropped: _dropped,
        waited: _waited,
        averageDrift: Duration.zero,
        minDrift: Duration.zero,
        maxDrift: Duration.zero,
      );
    }
    return AvSyncStats(
      presented: _presented,
      dropped: _dropped,
      waited: _waited,
      averageDrift:
          Duration(microseconds: _driftSumMicroseconds ~/ _driftSamples),
      minDrift: _minDrift,
      maxDrift: _maxDrift,
    );
  }

  /// Drops decided since the last presented frame.
  int get consecutiveDrops => _consecutiveDrops;

  /// How late a frame lasting [frameDuration] must be before it may be
  /// dropped.
  ///
  /// This is `max(dropThreshold, frameDuration)`. Skipping a frame only moves
  /// video forward by that frame's own duration, so on a low frame-rate stream
  /// — 2 fps, or a slide-show style capture — dropping a frame that is merely
  /// [dropThreshold] late would overshoot far past the clock and replace a
  /// small error with a large one. A non-positive [frameDuration], which
  /// decoders emit when a container carries no per-sample duration, simply
  /// falls back to [dropThreshold].
  Duration dropThresholdFor(Duration frameDuration) =>
      frameDuration > dropThreshold ? frameDuration : dropThreshold;

  /// Decides what to do with the frame stamped [framePts] while the master
  /// clock reads [clock].
  ///
  /// [frameDuration] is how long this frame is meant to stay on screen; pass
  /// [Duration.zero] when the decoder does not know. All three arguments may be
  /// negative — a clock is free to run ahead of the first timestamp — and the
  /// arithmetic is signed throughout.
  AvSyncDecision evaluate({
    required Duration framePts,
    required Duration clock,
    required Duration frameDuration,
  }) {
    final Duration drift = framePts - clock;

    // Zone 1: close enough. Checked first so it holds even when a caller
    // configures a drop threshold narrower than the tolerance.
    if (drift.abs() <= syncTolerance) {
      return _present(drift);
    }

    // Zone 2: early. Wait, but never longer than maxWaitDelay, so a clock that
    // jumped backwards cannot park the player.
    if (drift > syncTolerance) {
      _waited++;
      return AvSyncDecision(
        action: AvSyncAction.wait,
        drift: drift,
        delay: drift > maxWaitDelay ? maxWaitDelay : drift,
      );
    }

    // Zone 3: late. Drop only when it is allowed and provably useful.
    if (drift < -dropThresholdFor(frameDuration) && _mayDrop(drift)) {
      return _drop(drift);
    }
    return _present(drift);
  }

  /// Clears drift history and statistics.
  ///
  /// Call this right after a seek, so the discontinuity in both the clock and
  /// the timestamps is not measured as drift, and so the drop-spiral guards do
  /// not carry a decision from the old position into the new one.
  void reset() {
    _presented = 0;
    _dropped = 0;
    _waited = 0;
    _driftSumMicroseconds = 0;
    _driftSamples = 0;
    _minDrift = Duration.zero;
    _maxDrift = Duration.zero;
    _consecutiveDrops = 0;
    _driftAtLastDrop = null;
  }

  bool _mayDrop(Duration drift) {
    if (_consecutiveDrops >= maxConsecutiveDrops) return false;
    final Duration? previous = _driftAtLastDrop;
    if (previous != null && drift - previous <= minDropImprovement) {
      return false;
    }
    return true;
  }

  AvSyncDecision _present(Duration drift) {
    _presented++;
    _consecutiveDrops = 0;
    _driftAtLastDrop = null;
    _sampleDrift(drift);
    return AvSyncDecision(action: AvSyncAction.present, drift: drift);
  }

  AvSyncDecision _drop(Duration drift) {
    _dropped++;
    _consecutiveDrops++;
    _driftAtLastDrop = drift;
    _sampleDrift(drift);
    return AvSyncDecision(action: AvSyncAction.drop, drift: drift);
  }

  void _sampleDrift(Duration drift) {
    if (_driftSamples == 0) {
      _minDrift = drift;
      _maxDrift = drift;
    } else {
      if (drift < _minDrift) _minDrift = drift;
      if (drift > _maxDrift) _maxDrift = drift;
    }
    _driftSamples++;
    _driftSumMicroseconds += drift.inMicroseconds;
  }

  static void _checkNonNegative(Duration value, String name) {
    if (value < Duration.zero) {
      throw ArgumentError.value(value, name, 'must not be negative');
    }
  }
}
