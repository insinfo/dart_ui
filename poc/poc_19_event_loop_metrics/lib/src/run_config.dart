/// How the loop decides how long to block in the native wait.
enum LoopMode {
  /// No native loop at all. Pure Dart control group.
  baseline,

  /// Native wait with a zero timeout. Best latency, worst CPU.
  spin,

  /// Native wait with a fixed timeout — what `poc_10_event_loop` does today,
  /// and the only option available without SDK support.
  polling,

  /// Native wait with a timeout derived from the next Dart deadline, plus a
  /// kernel event signalled whenever new Dart work is queued.
  ///
  /// This simulates the proposed `EventLoopDriver.nextDeadline` and
  /// `EventLoopDriver.setWakeCallback`. It is only implementable here because
  /// the POC owns both the timer schedule and the message source; a real
  /// framework does not, which is precisely the point of the proposal.
  oracle,
}

/// What the application is doing while the loop runs.
enum Scenario {
  /// Animating at 60 Hz: a 16 ms frame timer plus periodic cross-isolate
  /// messages. Exercises timer drift.
  animating,

  /// Idle, as a real app is most of the time: no frame timer, only occasional
  /// messages. Exercises wasted wakeups and CPU.
  idle,
}

/// Per-scenario workload parameters.
final class ScenarioProfile {
  const ScenarioProfile({
    required this.frameIntervalUs,
    required this.messageIntervalUs,
  });

  static const ScenarioProfile animating = ScenarioProfile(
    frameIntervalUs: 16667,
    messageIntervalUs: 50000,
  );

  static const ScenarioProfile idle = ScenarioProfile(
    frameIntervalUs: null,
    messageIntervalUs: 500000,
  );

  static ScenarioProfile of(Scenario scenario) => switch (scenario) {
        Scenario.animating => animating,
        Scenario.idle => idle,
      };

  /// `null` means nothing is scheduled — an oracle loop may block forever.
  final int? frameIntervalUs;
  final int messageIntervalUs;
}

/// One measured configuration.
final class RunConfig {
  const RunConfig({
    required this.label,
    required this.mode,
    required this.scenario,
    required this.duration,
    this.fixedTimeoutMs,
  });

  final String label;
  final LoopMode mode;
  final Scenario scenario;
  final Duration duration;

  /// Only meaningful for [LoopMode.polling].
  final int? fixedTimeoutMs;

  ScenarioProfile get profile => ScenarioProfile.of(scenario);

  /// The wake event is what [LoopMode.oracle] uses to avoid polling; the
  /// other modes must discover work by waking up on their own schedule.
  bool get usesWakeEvent => mode == LoopMode.oracle;
}
