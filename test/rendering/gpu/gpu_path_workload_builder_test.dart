import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_workload_builder.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:test/test.dart';

void main() {
  const builder = GpuPathWorkloadBuilder();

  test('A: recognizes a real axis-aligned rectangle as analytic', () {
    final workload = builder.build(
      Path.rect(const Rect.fromLTRB(0.2, 1.8, 20.1, 11.2)),
    );
    final decision = const GpuPathStrategySelector().select(
      workload,
      const GpuPathStrategyCapabilities(compute: true, stencil: true),
    );

    expect(workload.pixelWidth, 21);
    expect(workload.pixelHeight, 11);
    expect(workload.segmentCount, 4);
    expect(workload.isAnalyticPrimitive, isTrue);
    expect(decision.strategy, GpuPathStrategy.analyticPrimitive);
  });

  test('A: arbitrary rotation prevents rectangle analytic misclassification',
      () {
    final workload = builder.build(
      Path.rect(const Rect.fromLTRB(0, 0, 20, 10)),
      localToTarget: Transform2D.rotation(0.3),
    );
    final decision = const GpuPathStrategySelector().select(
      workload,
      const GpuPathStrategyCapabilities(),
    );

    expect(workload.isAnalyticPrimitive, isFalse);
    expect(decision.strategy, GpuPathStrategy.coverageAtlas);
  });

  test('sparse: copies one measured plan snapshot without manual costs', () {
    const metrics = SparseStripPlanMetrics(
      batchCount: 1,
      sourceQuadCount: 3,
      solidInstanceCount: 1,
      alphaInstanceCount: 2,
      estimatedDrawCallCount: 2,
      alphaTexelBytes: 64,
      alphaUploadBytes: 64,
      alphaUploadCount: 1,
      atlasPageCount: 1,
      instanceBufferBytes: 64,
      sourceEncodedBytes: 80,
      retainedCapacityBytes: 4096,
      arenaGrowths: 0,
    );
    final workload = builder.build(
      _triangle(),
      pixelWidth: 128,
      pixelHeight: 128,
      sparseMetrics: metrics,
    );
    final decision = const GpuPathStrategySelector().select(
      workload,
      const GpuPathStrategyCapabilities(sparseStrips: true),
    );

    expect(workload.sparseEncodedBytes, metrics.sourceEncodedBytes);
    expect(workload.sparseUploadBytes, metrics.alphaUploadBytes);
    expect(workload.sparseInstanceBytes, metrics.instanceBufferBytes);
    expect(workload.sparseEstimatedDrawCalls, metrics.estimatedDrawCallCount);
    expect(workload.sparseAtlasPageCount, metrics.atlasPageCount);
    expect(decision.strategy, GpuPathStrategy.sparseStrips);
  });

  test('B: stable simple path derives retained tessellation eligibility', () {
    final workload = builder.build(
      _triangle(),
      geometryStable: true,
      pixelWidth: 64,
      pixelHeight: 64,
    );
    final decision = const GpuPathStrategySelector().select(
      workload,
      const GpuPathStrategyCapabilities(tessellation: true),
    );

    expect(workload.tessellationEligible, isTrue);
    expect(workload.hasSelfIntersections, isFalse);
    expect(workload.segmentCount, 3);
    expect(decision.strategy, GpuPathStrategy.tessellatedMesh);
  });

  test('C: rejected dynamic topology routes to stencil', () {
    final workload = builder.build(
      _bowTie(),
      pixelWidth: 64,
      pixelHeight: 64,
    );
    final decision = const GpuPathStrategySelector().select(
      workload,
      const GpuPathStrategyCapabilities(
        coverageAtlas: false,
        tessellation: true,
        stencil: true,
      ),
    );

    expect(workload.tessellationEligible, isFalse);
    expect(workload.hasSelfIntersections, isTrue);
    expect(decision.strategy, GpuPathStrategy.stencilThenCover);
  });

  test('D: flattened segment count drives compute threshold', () {
    final path = (PathBuilder()
          ..moveTo(0, 0)
          ..cubicTo(0, 100, 100, 100, 100, 0)
          ..lineTo(100, 100)
          ..lineTo(0, 100)
          ..close())
        .build();
    final workload = builder.build(
      path,
      pixelWidth: 100,
      pixelHeight: 100,
      flattenTolerance: 0.25,
    );
    final decision = const GpuPathStrategySelector(
      computeSegmentThreshold: 8,
    ).select(
      workload,
      const GpuPathStrategyCapabilities(compute: true),
    );

    expect(workload.segmentCount, greaterThanOrEqualTo(8));
    expect(decision.strategy, GpuPathStrategy.computeTiles);
  });

  test('bounds and clip become outward-rounded visible dimensions', () {
    final workload = builder.build(
      _triangle(),
      bounds: const Rect.fromLTRB(-2.2, 1.2, 20.2, 30.7),
      clip: const Rect.fromLTRB(0.1, 5.4, 10.9, 40),
    );
    expect(workload.pixelWidth, 11);
    expect(workload.pixelHeight, 26);
  });

  test('cache residency remains an external measured fact', () {
    final workload = builder.build(
      _triangle(),
      pixelWidth: 32,
      pixelHeight: 32,
      denseMaskCacheHit: true,
    );
    final decision = const GpuPathStrategySelector().select(
      workload,
      const GpuPathStrategyCapabilities(compute: true),
    );
    expect(decision.strategy, GpuPathStrategy.coverageAtlas);
  });

  test('rejects inconsistent dimensions and empty visible bounds', () {
    expect(
      () => builder.build(_triangle(), pixelWidth: 10),
      throwsArgumentError,
    );
    expect(
      () => builder.build(
        _triangle(),
        bounds: const Rect.fromLTRB(0, 0, 2, 2),
        clip: const Rect.fromLTRB(3, 3, 4, 4),
      ),
      throwsArgumentError,
    );
    expect(
      () => builder.build(
        _triangle(),
        bounds: const Rect.fromLTRB(0, 0, 2, 2),
        pixelWidth: 2,
        pixelHeight: 2,
      ),
      throwsArgumentError,
    );
  });
}

Path _triangle() => (PathBuilder()
      ..moveTo(0, 0)
      ..lineTo(20, 0)
      ..lineTo(0, 20)
      ..close())
    .build();

Path _bowTie() => (PathBuilder()
      ..moveTo(0, 0)
      ..lineTo(20, 20)
      ..lineTo(0, 20)
      ..lineTo(20, 0)
      ..close())
    .build();
