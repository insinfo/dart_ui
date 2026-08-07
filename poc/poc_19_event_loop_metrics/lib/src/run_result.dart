import 'run_config.dart';
import 'stats.dart';

/// Everything measured for a single [RunConfig].
final class RunResult {
  const RunResult({
    required this.label,
    required this.mode,
    required this.scenario,
    required this.wallMs,
    required this.iterations,
    required this.wakeupsByTimeout,
    required this.wakeupsByEvent,
    required this.wakeupsByMessage,
    required this.idleWakeups,
    required this.cpuMs,
    required this.cpuCycles,
    required this.requestedWaitUs,
    required this.nativeWaitUs,
    required this.yieldUs,
    required this.frameGapUs,
    required this.messageLatencyUs,
    required this.frameTicks,
    required this.nominalFrameIntervalUs,
    required this.messagesReceived,
    required this.threadMigrations,
  });

  final String label;
  final LoopMode mode;
  final Scenario scenario;
  final double wallMs;

  /// Native wait calls performed. Zero for [LoopMode.baseline].
  final int iterations;

  final int wakeupsByTimeout;
  final int wakeupsByEvent;
  final int wakeupsByMessage;

  /// Timeout wakeups that found no Dart work and no native message — pure
  /// wasted CPU, the metric the proposal's `nextDeadline` is meant to remove.
  final int idleWakeups;

  final double cpuMs;
  final int cpuCycles;

  /// Timeout asked of the native wait.
  final Stats requestedWaitUs;

  /// Time the native wait actually blocked. Windows rounds timeouts up to the
  /// system timer resolution, so this is routinely larger than
  /// [requestedWaitUs] — the gap between the two is not the loop's fault, but
  /// it is the loop's problem.
  final Stats nativeWaitUs;

  /// Cost of `await Future.delayed(Duration.zero)`, the only primitive Dart
  /// offers today for handing a turn to the event loop.
  final Stats yieldUs;

  /// Interval between consecutive frame timer ticks.
  ///
  /// Measured as a gap rather than as drift against an absolute schedule
  /// because `Timer.periodic` reschedules from the moment it fires: a starved
  /// periodic timer does not catch up, it simply runs slower. The gap is what
  /// a frame budget actually experiences.
  final Stats frameGapUs;

  /// Wall time between a message being sent by another isolate and its
  /// handler running in the loop isolate.
  final Stats messageLatencyUs;

  final int frameTicks;
  final int? nominalFrameIntervalUs;
  final int messagesReceived;

  /// Times the isolate was observed on a different OS thread than it started
  /// on. Any value above zero means thread affinity is not guaranteed.
  final int threadMigrations;

  double get idleWakeupsPerSecond => idleWakeups / (wallMs / 1000);
  double get iterationsPerSecond => iterations / (wallMs / 1000);
  double get cpuPercent => cpuMs / wallMs * 100;
  double get megacyclesPerSecond => cpuCycles / 1e6 / (wallMs / 1000);

  /// Frame ticks actually delivered per second.
  double get effectiveHz => frameTicks / (wallMs / 1000);

  /// Target frame rate implied by [nominalFrameIntervalUs].
  double? get nominalHz =>
      nominalFrameIntervalUs == null ? null : 1000000 / nominalFrameIntervalUs!;

  Map<String, Object?> toJson() => <String, Object?>{
        'label': label,
        'mode': mode.name,
        'scenario': scenario.name,
        'wallMs': wallMs,
        'iterations': iterations,
        'iterationsPerSecond': iterationsPerSecond,
        'wakeupsByTimeout': wakeupsByTimeout,
        'wakeupsByEvent': wakeupsByEvent,
        'wakeupsByMessage': wakeupsByMessage,
        'idleWakeups': idleWakeups,
        'idleWakeupsPerSecond': idleWakeupsPerSecond,
        'cpuMs': cpuMs,
        'cpuPercent': cpuPercent,
        'cpuCycles': cpuCycles,
        'megacyclesPerSecond': megacyclesPerSecond,
        'requestedWaitUs': requestedWaitUs.toJson(),
        'nativeWaitUs': nativeWaitUs.toJson(),
        'yieldUs': yieldUs.toJson(),
        'frameTicks': frameTicks,
        'nominalHz': nominalHz,
        'effectiveHz': effectiveHz,
        'frameGapUs': frameGapUs.toJson(),
        'messagesReceived': messagesReceived,
        'messageLatencyUs': messageLatencyUs.toJson(),
        'threadMigrations': threadMigrations,
      };
}
