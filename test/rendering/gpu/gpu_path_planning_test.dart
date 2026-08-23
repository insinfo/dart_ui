import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_geometry.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/display_list_reader.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_batcher.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_mask_atlas.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_dispatch.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_planning.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_raster_sink.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

void main() {
  test('proposal is not published until execution is completed', () {
    final events = <GpuPathPlanningEvent>[];
    final telemetry = GpuPathPlanningTelemetry(
      candidateCapabilities: const GpuPathStrategyCapabilities(
        tessellation: true,
      ),
      stabilityProbe: (_) => true,
      onEvent: events.add,
    );
    final proposal = telemetry.plan(
      label: 'ordered icon',
      path: _triangle(),
      localToTarget: Transform2D.identity,
      clip: const Rect.fromLTRB(0, 0, 32, 32),
      fillRule: FillRule.nonZero,
      denseMaskCacheHit: false,
    );

    expect(proposal, isNotNull);
    expect(proposal!.candidate.strategy, GpuPathStrategy.tessellatedMesh);
    expect(telemetry.lastEvent, isNull);
    expect(events, isEmpty);

    final event = telemetry.complete(
      proposal,
      executedStrategy: GpuPathStrategy.coverageAtlas,
    );
    expect(event.candidateDiffersFromExecution, isTrue);
    expect(telemetry.lastEvent, same(event));
    expect(events, <GpuPathPlanningEvent>[event]);
  });

  test('an accepted experimental execution is reported explicitly', () {
    final telemetry = GpuPathPlanningTelemetry(
      candidateCapabilities: const GpuPathStrategyCapabilities(
        tessellation: true,
      ),
      stabilityProbe: (_) => true,
    );
    final path = _triangle();

    final event = telemetry.observe(
      label: 'retained icon',
      path: path,
      localToTarget: Transform2D.identity,
      clip: const Rect.fromLTRB(0, 0, 32, 32),
      fillRule: FillRule.nonZero,
      denseMaskCacheHit: false,
      executedStrategy: GpuPathStrategy.tessellatedMesh,
    );

    expect(event, isNotNull);
    expect(event!.executedStrategy, GpuPathStrategy.tessellatedMesh);
    expect(event.candidateDiffersFromExecution, isFalse);
    expect(telemetry.lastEvent, same(event));
  });

  test('display-list replay observes decisions but draws the same dense masks',
      () {
    final events = <GpuPathPlanningEvent>[];
    final telemetry = GpuPathPlanningTelemetry(
      candidateCapabilities: const GpuPathStrategyCapabilities(
        tessellation: true,
      ),
      stabilityProbe: (_) => true,
      onEvent: events.add,
    );
    final atlas = GpuMaskAtlas(width: 128, height: 128);
    final batcher = GpuBatcher()..beginFrame();
    final sink = GpuRasterSink(
      batcher: batcher,
      backendName: 'planning-test',
      maskAtlas: atlas,
      maskTextureId: 17,
      pathPlanningTelemetry: telemetry,
    );
    final path = _triangle();
    final list = DisplayList();
    final paint = list.addPaint(colorArgb: 0xFF204080);
    final pathId = list.addPath(path);
    list
      ..transform2D(const Transform2D.translation(8, 12))
      ..drawPath(pathId, paint)
      ..drawPath(pathId, paint);

    DisplayListPlayer(sink).play(
      DisplayListReader(list),
      DisplayListResources(list),
      deviceBounds: const Rect.fromLTRB(0, 0, 100, 100),
    );

    expect(events, hasLength(2));
    expect(events.first.candidate.strategy, GpuPathStrategy.tessellatedMesh);
    expect(events.first.executedStrategy, GpuPathStrategy.coverageAtlas);
    expect(events.first.candidateDiffersFromExecution, isTrue);
    expect(events.first.workload.denseMaskCacheHit, isFalse);
    expect(events.last.candidate.strategy, GpuPathStrategy.coverageAtlas);
    expect(events.last.workload.denseMaskCacheHit, isTrue);
    expect(atlas.rasterizationCount, 1);
    expect(atlas.cacheHitCount, 1);
    expect(batcher.quadCount, 2);
    expect(batcher.batchCount, 1);
    expect(batcher.batchAt(0).pipeline, GpuPipelineKind.coverageMask);
    expect(batcher.batchAt(0).textureId, 17);
  });

  test('candidate sparse metrics affect telemetry, never dispatch', () {
    const metrics = SparseStripPlanMetrics(
      batchCount: 1,
      sourceQuadCount: 2,
      solidInstanceCount: 1,
      alphaInstanceCount: 1,
      estimatedDrawCallCount: 2,
      alphaTexelBytes: 32,
      alphaUploadBytes: 32,
      alphaUploadCount: 1,
      atlasPageCount: 1,
      instanceBufferBytes: 48,
      sourceEncodedBytes: 64,
      retainedCapacityBytes: 1024,
      arenaGrowths: 0,
    );
    final telemetry = GpuPathPlanningTelemetry(
      candidateCapabilities:
          const GpuPathStrategyCapabilities(sparseStrips: true),
      sparseMetricsProbe: (_, __, ___, ____) => metrics,
    );

    telemetry.observe(
      label: 'path',
      path: _triangle(),
      localToTarget: Transform2D.identity,
      clip: const Rect.fromLTRB(0, 0, 64, 64),
      fillRule: FillRule.nonZero,
      denseMaskCacheHit: false,
    );

    expect(
        telemetry.lastEvent!.candidate.strategy, GpuPathStrategy.sparseStrips);
    expect(
        telemetry.lastEvent!.executedStrategy, GpuPathStrategy.coverageAtlas);
  });

  test('accepted recorder owns pixels and preserves dense batch order', () {
    final events = <GpuPathPlanningEvent>[];
    final recorder = _RecordingPathRecorder(accept: true);
    final telemetry = GpuPathPlanningTelemetry(
      candidateCapabilities: const GpuPathStrategyCapabilities(
        tessellation: true,
      ),
      stabilityProbe: (_) => true,
      onEvent: events.add,
    );
    final atlas = GpuMaskAtlas(width: 64, height: 64);
    final batcher = GpuBatcher()..beginFrame();
    final sink = GpuRasterSink(
      batcher: batcher,
      backendName: 'dispatch-test',
      maskAtlas: atlas,
      maskTextureId: 4,
      pathPlanningTelemetry: telemetry,
      pathCommandRecorder: recorder,
    );

    sink
      ..fillDeviceRect(
        const Rect.fromLTRB(0, 0, 4, 4),
        const Rect.fromLTRB(0, 0, 64, 64),
        _paint,
      )
      ..drawDevicePath(
        _triangle(),
        Transform2D.identity,
        const Rect.fromLTRB(0, 0, 64, 64),
        _paint,
      )
      ..fillDeviceRect(
        const Rect.fromLTRB(8, 0, 12, 4),
        const Rect.fromLTRB(0, 0, 64, 64),
        _paint,
      );

    expect(recorder.requests, hasLength(1));
    expect(recorder.requests.single.batchIndex, 1);
    expect(
      recorder.requests.single.candidateStrategy,
      GpuPathStrategy.tessellatedMesh,
    );
    expect(events.single.executedStrategy, GpuPathStrategy.tessellatedMesh);
    expect(atlas.rasterizationCount, 0);
    expect(batcher.quadCount, 2);
    expect(batcher.batchCount, 2);
  });

  test('recorder refusal and exception both retain the dense fallback', () {
    for (final recorder in <_RecordingPathRecorder>[
      _RecordingPathRecorder(accept: false),
      _RecordingPathRecorder(accept: false, throwOnRecord: true),
    ]) {
      final telemetry = GpuPathPlanningTelemetry(
        candidateCapabilities: const GpuPathStrategyCapabilities(
          tessellation: true,
        ),
        stabilityProbe: (_) => true,
      );
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final sink = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'dispatch-test',
        maskAtlas: atlas,
        maskTextureId: 8,
        pathPlanningTelemetry: telemetry,
        pathCommandRecorder: recorder,
      );

      expect(
        () => sink.drawDevicePath(
          _triangle(),
          Transform2D.identity,
          const Rect.fromLTRB(0, 0, 64, 64),
          _paint,
        ),
        returnsNormally,
      );
      expect(recorder.requests, hasLength(1));
      expect(atlas.rasterizationCount, 1);
      expect(sink.batcher.quadCount, 1);
      expect(
        telemetry.lastEvent!.executedStrategy,
        GpuPathStrategy.coverageAtlas,
      );
    }
  });

  test('advisory seam reports A, C and D while execution stays dense', () {
    GpuPathPlanningEvent observe(
      Path path,
      GpuPathStrategyCapabilities capabilities, {
      GpuPathStrategySelector selector = const GpuPathStrategySelector(),
    }) {
      final telemetry = GpuPathPlanningTelemetry(
        selector: selector,
        candidateCapabilities: capabilities,
      );
      telemetry.observe(
        label: 'candidate',
        path: path,
        localToTarget: Transform2D.identity,
        clip: const Rect.fromLTRB(0, 0, 128, 128),
        fillRule: FillRule.nonZero,
        denseMaskCacheHit: false,
      );
      return telemetry.lastEvent!;
    }

    final analytic = observe(
      Path.rect(const Rect.fromLTRB(0, 0, 20, 10)),
      const GpuPathStrategyCapabilities(),
    );
    final stencil = observe(
      _bowTie(),
      const GpuPathStrategyCapabilities(
        coverageAtlas: false,
        stencil: true,
      ),
    );
    final compute = observe(
      _complexCurve(),
      const GpuPathStrategyCapabilities(compute: true),
      selector: const GpuPathStrategySelector(computeSegmentThreshold: 8),
    );

    expect(analytic.candidate.strategy, GpuPathStrategy.analyticPrimitive);
    expect(stencil.candidate.strategy, GpuPathStrategy.stencilThenCover);
    expect(compute.candidate.strategy, GpuPathStrategy.computeTiles);
    expect(
      <GpuPathStrategy>[
        analytic.executedStrategy,
        stencil.executedStrategy,
        compute.executedStrategy,
      ],
      everyElement(GpuPathStrategy.coverageAtlas),
    );
  });

  test('planning and callback failures cannot break dense execution', () {
    final telemetry = GpuPathPlanningTelemetry(
      candidateCapabilities: const GpuPathStrategyCapabilities(
        analyticPrimitives: false,
        coverageAtlas: false,
      ),
      onEvent: (_) => throw StateError('consumer failed'),
    );
    final atlas = GpuMaskAtlas(width: 64, height: 64);
    final sink = GpuRasterSink(
      batcher: GpuBatcher()..beginFrame(),
      backendName: 'planning-test',
      maskAtlas: atlas,
      maskTextureId: 9,
      pathPlanningTelemetry: telemetry,
    );

    expect(
      () => sink.drawDevicePath(
        _triangle(),
        Transform2D.identity,
        const Rect.fromLTRB(0, 0, 64, 64),
        _paint,
      ),
      returnsNormally,
    );
    expect(sink.batcher.quadCount, 1);
    expect(atlas.rasterizationCount, 1);
    expect(telemetry.observationCount, 1);
    expect(telemetry.failureCount, 1);
    expect(telemetry.lastError, isA<UnsupportedError>());
  });

  test('callback exception is contained after a successful decision', () {
    final telemetry = GpuPathPlanningTelemetry(
      onEvent: (_) => throw StateError('telemetry consumer failed'),
    );
    telemetry.observe(
      label: 'triangle',
      path: _triangle(),
      localToTarget: Transform2D.identity,
      clip: const Rect.fromLTRB(0, 0, 64, 64),
      fillRule: FillRule.nonZero,
      denseMaskCacheHit: false,
    );
    expect(telemetry.lastEvent, isNotNull);
    expect(telemetry.failureCount, 1);
    expect(telemetry.lastError, isA<StateError>());
  });

  test('failed planning cannot leave a stale successful event', () {
    var shouldFail = false;
    final telemetry = GpuPathPlanningTelemetry(
      stabilityProbe: (_) {
        if (shouldFail) throw StateError('probe failed');
        return true;
      },
    );
    void observe() => telemetry.observe(
          label: 'triangle',
          path: _triangle(),
          localToTarget: Transform2D.identity,
          clip: const Rect.fromLTRB(0, 0, 64, 64),
          fillRule: FillRule.nonZero,
          denseMaskCacheHit: false,
        );

    observe();
    expect(telemetry.lastEvent, isNotNull);
    shouldFail = true;
    observe();

    expect(telemetry.observationCount, 2);
    expect(telemetry.failureCount, 1);
    expect(telemetry.lastEvent, isNull);
    expect(telemetry.lastError, isA<StateError>());
  });
}

final class _RecordingPathRecorder implements GpuPathCommandRecorder {
  _RecordingPathRecorder({
    required this.accept,
    this.throwOnRecord = false,
  });

  final bool accept;
  final bool throwOnRecord;
  final List<GpuPathDispatchRequest> requests = <GpuPathDispatchRequest>[];

  @override
  bool tryRecord(GpuPathDispatchRequest request) {
    requests.add(request);
    if (throwOnRecord) throw StateError('experimental executor failed');
    return accept;
  }
}

const ReplayPaint _paint = ReplayPaint(
  argbColor: 0xFF204080,
  style: paintStyleFill,
  strokeWidth: 0,
  blendMode: blendModeSrcOver,
  antiAlias: true,
);

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

Path _complexCurve() => (PathBuilder()
      ..moveTo(0, 0)
      ..cubicTo(0, 100, 100, 100, 100, 0)
      ..lineTo(100, 100)
      ..lineTo(0, 100)
      ..close())
    .build();
