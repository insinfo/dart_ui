/// Observe strategy decisions for real path draws without changing pixels.
library;

import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../path/fill_rule.dart';
import 'gpu_path_strategy.dart';
import 'gpu_path_workload_builder.dart';
import 'vector/sparse_strip_draw_plan.dart';

typedef GpuPathStabilityProbe = bool Function(Path path);
typedef GpuSparseMetricsProbe = SparseStripPlanMetrics? Function(
  Path path,
  Transform2D localToTarget,
  Rect clip,
  FillRule fillRule,
);

/// One advisory decision and the strategy that actually produced its pixels.
final class GpuPathPlanningEvent {
  const GpuPathPlanningEvent({
    required this.label,
    required this.workload,
    required this.candidate,
  });

  final String label;
  final GpuPathWorkload workload;
  final GpuPathStrategyDecision candidate;

  /// Planning is observation-only until a backend wires a complete executor.
  GpuPathStrategy get executedStrategy => GpuPathStrategy.coverageAtlas;

  bool get candidateDiffersFromExecution =>
      candidate.strategy != executedStrategy;
}

/// Optional telemetry seam used by [GpuRasterSink]'s dense path route.
///
/// Candidate capabilities may describe experimental executors, but this
/// object never dispatches to them. It derives a workload and reports what the
/// selector would choose while the sink continues through its existing dense
/// mask atlas. Planning and callback failures are contained and recorded so
/// enabling telemetry cannot turn a renderable frame into an exception.
final class GpuPathPlanningTelemetry {
  GpuPathPlanningTelemetry({
    this.builder = const GpuPathWorkloadBuilder(),
    this.selector = const GpuPathStrategySelector(),
    this.candidateCapabilities = const GpuPathStrategyCapabilities(),
    this.stabilityProbe,
    this.sparseMetricsProbe,
    this.onEvent,
  });

  final GpuPathWorkloadBuilder builder;
  final GpuPathStrategySelector selector;
  final GpuPathStrategyCapabilities candidateCapabilities;
  final GpuPathStabilityProbe? stabilityProbe;
  final GpuSparseMetricsProbe? sparseMetricsProbe;
  final void Function(GpuPathPlanningEvent event)? onEvent;

  int observationCount = 0;
  int failureCount = 0;
  GpuPathPlanningEvent? lastEvent;
  Object? lastError;
  StackTrace? lastStackTrace;

  void observe({
    required String label,
    required Path path,
    required Transform2D localToTarget,
    required Rect clip,
    required FillRule fillRule,
    required bool denseMaskCacheHit,
  }) {
    observationCount++;
    try {
      final workload = builder.build(
        path,
        bounds: localToTarget.transformRect(path.bounds),
        clip: clip,
        localToTarget: localToTarget,
        geometryStable: stabilityProbe?.call(path) ?? false,
        denseMaskCacheHit: denseMaskCacheHit,
        sparseMetrics:
            sparseMetricsProbe?.call(path, localToTarget, clip, fillRule),
      );
      final event = GpuPathPlanningEvent(
        label: label,
        workload: workload,
        candidate: selector.select(workload, candidateCapabilities),
      );
      lastEvent = event;
      lastError = null;
      lastStackTrace = null;
      try {
        onEvent?.call(event);
      } catch (error, stackTrace) {
        failureCount++;
        lastError = error;
        lastStackTrace = stackTrace;
      }
    } catch (error, stackTrace) {
      failureCount++;
      lastEvent = null;
      lastError = error;
      lastStackTrace = stackTrace;
    }
  }
}
