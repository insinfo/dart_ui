/// Portable audio/video synchronisation policy for a video player.
///
/// The types here are pure decision logic: no `dart:ffi`, no `dart:io`, no
/// timers, no I/O and no imports at all. A player owns a master clock —
/// normally the audio playback position, or the wall clock when a file has no
/// audio — and a decoder that produces frames carrying a presentation
/// timestamp. For every decoded frame the player asks [AvSynchronizer.evaluate]
/// what to do with it and then performs the one side effect the answer names:
/// draw it, throw it away, hold it back for a while and ask again, or — once
/// the picture has fallen so far behind that frame-by-frame catch-up is
/// hopeless — stop pretending and seek the decoder to where the clock already
/// is.
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

  /// Throw the frame away and seek the decoder to the master clock.
  ///
  /// The caller performs the seek and nothing else: the synchronizer has
  /// already cleared its own drift history and drop-spiral state by the time
  /// this answer is returned. That is deliberate and is not what [reset] does.
  /// [reset] belongs to a *user* seek and zeroes every counter with it; a
  /// resync must leave [AvSyncStats.resynced] and the lifetime drift extremes
  /// standing, because they are the only evidence the stall happened. Making
  /// the caller responsible would also make it possible to forget, and a
  /// forgotten reset here re-reads the gap that justified the seek as fresh
  /// drift on the very next frame.
  ///
  /// The gap is measured in seconds rather than in frames, and dropping is the
  /// wrong tool for it: a drop buys back exactly one frame duration and costs a
  /// full decode, so closing a gap of seconds takes about its own length in
  /// wall time with one frame in `maxConsecutiveDrops + 1` reaching the screen.
  /// A single seek ends with the picture on the sound immediately. It is
  /// visible — the image jumps — which is why
  /// [AvSynchronizer.resyncThreshold] is an order of magnitude past anything
  /// ordinary jitter can reach, and why [AvSynchronizer.resyncCooldown] keeps a
  /// player that simply cannot decode in real time from jumping every frame.
  ///
  /// Named for the remedy rather than the mechanism: `seek` would read as the
  /// user dragging the scrub bar, and this is the synchronizer asking to be put
  /// back on the clock.
  resync,
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
  bool get isResync => action == AvSyncAction.resync;

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
/// Drift is only sampled on decisions that consume a frame ([presented],
/// [dropped] and [resynced]). A [waited] decision is a deliberate postponement,
/// and counting its drift would bias the average towards frames that were
/// merely early.
///
/// ## Why every drift figure comes twice
///
/// [averageDrift], [minDrift] and [maxDrift] cover everything since the last
/// [AvSynchronizer.reset]; the `recent` figures cover only the last
/// [AvSynchronizer.recentDriftWindow] consumed frames. Both are kept because
/// they answer different questions and each is misleading alone.
///
/// A player that stalls for twelve seconds — a modal file dialog blocking the
/// UI thread, a swapped-out process — records a twelve-second [minDrift] and
/// then reports it for the rest of the session, long after it has recovered.
/// Read on its own, that number says the player is broken right now, which is
/// false. The lifetime average has the same defect in slower motion: a single
/// stall drags it to a value it then sits at for hours, so "average drift is
/// -775 ms" stops meaning "the picture is three quarters of a second late" and
/// starts meaning "the picture was, once".
///
/// The recent figures are therefore what a status bar should show, because they
/// describe the present. They are not a replacement: dropping the lifetime
/// extremes would delete the only evidence that the stall happened at all, and
/// that evidence is exactly what a bug report needs. Clearing them on a
/// [AvSyncAction.resync] would be worse still — it would erase the number that
/// justified the seek at the moment the seek is taken. So: report both, and let
/// the caller choose which question it is asking.
final class AvSyncStats {
  const AvSyncStats({
    required this.presented,
    required this.dropped,
    required this.waited,
    required this.resynced,
    required this.averageDrift,
    required this.minDrift,
    required this.maxDrift,
    required this.recentSamples,
    required this.recentAverageDrift,
    required this.recentMinDrift,
    required this.recentMaxDrift,
  });

  /// A synchronizer that has decided nothing yet.
  static const AvSyncStats empty = AvSyncStats(
    presented: 0,
    dropped: 0,
    waited: 0,
    resynced: 0,
    averageDrift: Duration.zero,
    minDrift: Duration.zero,
    maxDrift: Duration.zero,
    recentSamples: 0,
    recentAverageDrift: Duration.zero,
    recentMinDrift: Duration.zero,
    recentMaxDrift: Duration.zero,
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

  /// Frames answered with [AvSyncAction.resync].
  ///
  /// One per stall the player could not close by dropping. A number that keeps
  /// growing is the honest report that this machine cannot decode the stream in
  /// real time; the picture is staying on the sound only because it keeps
  /// jumping.
  final int resynced;

  /// Mean drift over the [driftSamples] consumed frames, truncated towards
  /// zero. [Duration.zero] while no frame has been consumed.
  final Duration averageDrift;

  /// Most negative (latest) drift seen on a consumed frame.
  final Duration minDrift;

  /// Most positive (earliest) drift seen on a consumed frame.
  final Duration maxDrift;

  /// Consumed frames behind the `recent` figures: at most
  /// [AvSynchronizer.recentDriftWindow], fewer only right after a
  /// [AvSynchronizer.reset].
  final int recentSamples;

  /// Mean drift over the last [recentSamples] consumed frames.
  final Duration recentAverageDrift;

  /// Most negative (latest) drift over the last [recentSamples] consumed
  /// frames.
  final Duration recentMinDrift;

  /// Most positive (earliest) drift over the last [recentSamples] consumed
  /// frames.
  final Duration recentMaxDrift;

  /// Number of consumed frames behind [averageDrift], [minDrift] and
  /// [maxDrift].
  int get driftSamples => presented + dropped + resynced;

  /// Largest drift magnitude seen on a consumed frame, ignoring direction.
  Duration get maxAbsoluteDrift {
    final Duration low = minDrift.abs();
    final Duration high = maxDrift.abs();
    return low > high ? low : high;
  }

  /// Largest drift magnitude over the last [recentSamples] consumed frames,
  /// ignoring direction.
  Duration get recentMaxAbsoluteDrift {
    final Duration low = recentMinDrift.abs();
    final Duration high = recentMaxDrift.abs();
    return low > high ? low : high;
  }

  @override
  String toString() => 'AvSyncStats(presented: $presented, dropped: $dropped, '
      'waited: $waited, resynced: $resynced, '
      'averageDrift: ${averageDrift.inMicroseconds}us, '
      'minDrift: ${minDrift.inMicroseconds}us, '
      'maxDrift: ${maxDrift.inMicroseconds}us, '
      'recentAverageDrift: ${recentAverageDrift.inMicroseconds}us, '
      'recentMinDrift: ${recentMinDrift.inMicroseconds}us, '
      'recentMaxDrift: ${recentMaxDrift.inMicroseconds}us)';
}

/// Decides, frame by frame, how video should follow a master clock.
///
/// ## The zones
///
/// With `drift = framePts - clock`:
///
/// * `|drift| <= syncTolerance` — present. The frame is close enough that no
///   viewer can tell, and micro-waiting on a millisecond of error would only
///   burn a scheduler round trip per frame.
/// * `drift > syncTolerance` — the frame is early, so wait `drift` (clamped to
///   [maxWaitDelay]) and evaluate it again.
/// * `drift < -resyncThresholdFor(frameDuration)` — the frame is so late that
///   catching up frame by frame is not worth attempting, so ask the caller to
///   seek. See "Recovering from a stall" below.
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
/// ## Recovering from a stall
///
/// Those guards keep the picture moving, but they say nothing about ever
/// arriving. A player whose UI thread is blocked for several seconds — a modal
/// file dialog, a swapped-out process — comes back with the audio clock seconds
/// ahead of the next decoded frame, and from there the drop path is not a
/// recovery at all:
///
/// * a drop buys back one frame duration, so a gap of `G` needs
///   `G / frameDuration` frames skipped: 300 frames for a twelve-second gap at
///   25 fps, every one of them decoded in full before being thrown away;
/// * [maxConsecutiveDrops] caps the run at two, so only two frames in three can
///   be skipped and the video timeline advances at roughly twice real time —
///   meaning a gap takes about its own length again in wall time to close,
///   showing one frame in three the whole way;
/// * worse, the improvement guard usually forbids even that. Falling behind is
///   exactly the case where drift does *not* improve between drops, so dropping
///   switches itself off and the gap never closes at all. That is the reported
///   failure: `waited` frozen because nothing is ever early again, and an
///   average drift that settles at -775 ms and stays there for the rest of the
///   file.
///
/// So beyond [resyncThreshold] the answer is [AvSyncAction.resync]: stop
/// pretending, seek the decoder to the clock, and [reset]. One visible jump,
/// and the picture is back on the sound.
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
    this.resyncThreshold = const Duration(seconds: 2),
    this.resyncCooldown = const Duration(seconds: 5),
    this.recentDriftWindow = 120,
  }) {
    _checkNonNegative(syncTolerance, 'syncTolerance');
    _checkNonNegative(dropThreshold, 'dropThreshold');
    _checkNonNegative(minDropImprovement, 'minDropImprovement');
    _checkNonNegative(resyncCooldown, 'resyncCooldown');
    if (resyncThreshold <= dropThreshold) {
      throw ArgumentError.value(
        resyncThreshold,
        'resyncThreshold',
        'must be past dropThreshold, otherwise every frame worth dropping '
            'would be seeked instead and the picture would never settle',
      );
    }
    if (recentDriftWindow < 1) {
      throw ArgumentError.value(
        recentDriftWindow,
        'recentDriftWindow',
        'must be at least 1; a window of zero would report no recent drift '
            'at all, which reads as perfect synchronisation',
      );
    }
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

  /// How far behind the clock the picture must fall before the answer stops
  /// being "drop" and becomes [AvSyncAction.resync].
  ///
  /// **Two seconds**, and the number is a floor on how bad things must be
  /// rather than a target, because the remedy is a visible jump in the picture.
  /// Three constraints fix it between them:
  ///
  /// * it must be far past ordinary lateness. It is 33 times [dropThreshold]
  ///   and eight times [maxWaitDelay], so no amount of decode jitter reaches
  ///   it;
  /// * it must be past what a *persistently slow* machine sits at. A player
  ///   that cannot quite decode in real time settles at a steady few hundred
  ///   milliseconds behind — one real report of this defect had it at 775 ms —
  ///   and jumping the picture at that is trading a fault nobody can see for
  ///   one everybody can. Two seconds is comfortably above it;
  /// * and it must be below the stalls that motivated the action at all. A
  ///   modal dialog blocking the UI thread, a process swapped out, a laptop
  ///   waking up: those are measured in seconds, and the case that prompted
  ///   this reached twelve.
  ///
  /// There is no way to pick this from the signal alone, because "the picture
  /// is late" and "the player was frozen" produce the same measurement. The
  /// threshold is where one explanation stops being plausible and the other
  /// starts.
  final Duration resyncThreshold;

  /// How far the master clock must advance after a resync before another one
  /// is allowed.
  ///
  /// **Five seconds.** Without it, a machine that genuinely cannot decode the
  /// stream would sit permanently past [resyncThreshold] and jump on every
  /// frame, which is far worse than being late — the picture would become a
  /// slide show of unrelated moments. With it, such a machine jumps at most
  /// once per five seconds of playback, and the growing [AvSyncStats.resynced]
  /// is the honest report that the stream is beyond this hardware.
  ///
  /// Measured in **master-clock advance**, not wall time, which is what keeps
  /// this file free of any clock of its own: the caller already passes the
  /// clock position on every [evaluate], so the cooldown is arithmetic on a
  /// number that is already in hand. It also gives the right behaviour when
  /// playback is paused — a paused clock does not advance, so a pause of any
  /// length does not silently re-arm the jump.
  final Duration resyncCooldown;

  /// How many consumed frames the `recent` figures in [AvSyncStats] cover.
  ///
  /// **120**, which is roughly five seconds at 24 or 25 fps and two at 60. Long
  /// enough that one late frame does not swing it, short enough that it still
  /// describes the present rather than the session. See [AvSyncStats] for why
  /// both windows are reported instead of one.
  final int recentDriftWindow;

  int _presented = 0;
  int _dropped = 0;
  int _waited = 0;
  int _resynced = 0;
  int _driftSumMicroseconds = 0;
  int _driftSamples = 0;
  Duration _minDrift = Duration.zero;
  Duration _maxDrift = Duration.zero;
  int _consecutiveDrops = 0;
  Duration? _driftAtLastDrop;

  /// The last [recentDriftWindow] drift samples, oldest overwritten first.
  ///
  /// A plain ring rather than a running sum with subtraction: floating error
  /// does not accumulate, and the minimum and maximum over the window cannot
  /// be maintained incrementally anyway once the value leaving the window is
  /// the one that held the extreme.
  late final List<int> _recentDrift = List<int>.filled(recentDriftWindow, 0);
  int _recentCount = 0;
  int _recentNext = 0;

  /// Master-clock position at the last resync, or null if there has not been
  /// one since the last [reset].
  Duration? _clockAtLastResync;

  /// Statistics accumulated since construction or the last [reset].
  AvSyncStats get stats {
    var recentSum = 0;
    var recentMin = 0;
    var recentMax = 0;
    for (var i = 0; i < _recentCount; i++) {
      final int sample = _recentDrift[i];
      recentSum += sample;
      if (i == 0 || sample < recentMin) recentMin = sample;
      if (i == 0 || sample > recentMax) recentMax = sample;
    }
    return AvSyncStats(
      presented: _presented,
      dropped: _dropped,
      waited: _waited,
      resynced: _resynced,
      averageDrift: _driftSamples == 0
          ? Duration.zero
          : Duration(microseconds: _driftSumMicroseconds ~/ _driftSamples),
      minDrift: _driftSamples == 0 ? Duration.zero : _minDrift,
      maxDrift: _driftSamples == 0 ? Duration.zero : _maxDrift,
      recentSamples: _recentCount,
      recentAverageDrift: _recentCount == 0
          ? Duration.zero
          : Duration(microseconds: recentSum ~/ _recentCount),
      recentMinDrift: Duration(microseconds: recentMin),
      recentMaxDrift: Duration(microseconds: recentMax),
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

  /// How late a frame lasting [frameDuration] must be before the answer
  /// becomes [AvSyncAction.resync].
  ///
  /// This is `max(resyncThreshold, frameDuration * 4)`, for the reason
  /// [dropThresholdFor] scales too, only more so. On a two-frames-per-second
  /// capture a single frame is worth half a second, so a fixed two-second
  /// threshold would call four frames of lateness a stall — and four frames is
  /// exactly where dropping still works. Four frames' worth is the floor, and
  /// on any ordinary frame rate the constant wins and this returns
  /// [resyncThreshold] unchanged.
  Duration resyncThresholdFor(Duration frameDuration) {
    final Duration scaled = frameDuration * 4;
    return scaled > resyncThreshold ? scaled : resyncThreshold;
  }

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

    // Zone 3: hopelessly late. Checked before the drop zone because it is a
    // strict subset of it - every frame past the resync threshold is also past
    // the drop threshold - and because dropping is what fails here. See
    // "Recovering from a stall".
    if (drift < -resyncThresholdFor(frameDuration) &&
        _mayResync(clock: clock)) {
      return _resync(drift, clock: clock);
    }

    // Zone 4: late. Drop only when it is allowed and provably useful.
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
    _resynced = 0;
    _driftSumMicroseconds = 0;
    _driftSamples = 0;
    _minDrift = Duration.zero;
    _maxDrift = Duration.zero;
    _consecutiveDrops = 0;
    _driftAtLastDrop = null;
    _recentCount = 0;
    _recentNext = 0;
    // Cleared too, so the first frame after a user seek can resync if the
    // seek landed somewhere the decoder cannot reach in time. Keeping the
    // cooldown across a seek would mean the one moment a player is most
    // likely to need a resync is the one moment it is forbidden.
    _clockAtLastResync = null;
  }

  /// Whether a resync is allowed at [clock], per [resyncCooldown].
  bool _mayResync({required Duration clock}) {
    final Duration? last = _clockAtLastResync;
    if (last == null) return true;
    // Absolute, so a clock that jumped *backwards* since the last resync also
    // counts as having moved on. Without the absolute value a backward jump
    // would read as negative advance and lock the player out of resyncing for
    // as long as it took to play back to where it was.
    return (clock - last).abs() >= resyncCooldown;
  }

  AvSyncDecision _resync(Duration drift, {required Duration clock}) {
    _resynced++;
    _clockAtLastResync = clock;
    // Sampled before the history is cleared: this drift is the measurement
    // that justified the jump, and it is the one number a bug report needs.
    _sampleDrift(drift);
    // The caller only seeks. Everything that would misread the discontinuity
    // as fresh drift is cleared here rather than left to a reset the caller
    // has to remember - see [AvSyncAction.resync]. The lifetime average and
    // extremes survive on purpose; the recent window does not, because its
    // whole job is to describe the present and the present is about to be a
    // different position in the file.
    _consecutiveDrops = 0;
    _driftAtLastDrop = null;
    _recentCount = 0;
    _recentNext = 0;
    return AvSyncDecision(action: AvSyncAction.resync, drift: drift);
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

    // And into the ring the `recent` figures read. Written at `_recentNext`
    // rather than appended, so the window costs one fixed allocation for the
    // life of the synchronizer instead of a list that grows for the length of
    // the film.
    _recentDrift[_recentNext] = drift.inMicroseconds;
    _recentNext = (_recentNext + 1) % recentDriftWindow;
    if (_recentCount < recentDriftWindow) _recentCount++;
  }

  static void _checkNonNegative(Duration value, String name) {
    if (value < Duration.zero) {
      throw ArgumentError.value(value, name, 'must not be negative');
    }
  }
}
