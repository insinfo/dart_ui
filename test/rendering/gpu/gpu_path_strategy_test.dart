import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

void main() {
  const selector = GpuPathStrategySelector();

  GpuPathWorkload workload({
    int width = 256,
    int height = 256,
    int segments = 100,
    bool analytic = false,
    bool cacheHit = false,
    bool stable = false,
    bool selfIntersects = false,
    bool tessellationEligible = true,
    int? sparseBytes,
    int? sparseUploadBytes,
    int? sparseInstanceBytes,
    int? sparseDrawCalls,
    int? sparsePages,
  }) =>
      GpuPathWorkload(
        pixelWidth: width,
        pixelHeight: height,
        segmentCount: segments,
        isAnalyticPrimitive: analytic,
        denseMaskCacheHit: cacheHit,
        geometryStable: stable,
        hasSelfIntersections: selfIntersects,
        tessellationEligible: tessellationEligible,
        sparseEncodedBytes: sparseBytes,
        sparseUploadBytes: sparseUploadBytes,
        sparseInstanceBytes: sparseInstanceBytes,
        sparseEstimatedDrawCalls: sparseDrawCalls,
        sparseAtlasPageCount: sparsePages,
      );

  test('analytic primitives always keep the cheapest UI path', () {
    final decision = selector.select(
      workload(analytic: true, segments: 10000),
      const GpuPathStrategyCapabilities(
        compute: true,
        stencil: true,
      ),
    );
    expect(decision.strategy, GpuPathStrategy.analyticPrimitive);
  });

  test('a resident dense mask wins before recomputing dynamic geometry', () {
    final decision = selector.select(
      workload(cacheHit: true, segments: 10000),
      const GpuPathStrategyCapabilities(compute: true),
    );
    expect(decision.strategy, GpuPathStrategy.coverageAtlas);
  });

  test('complex deforming geometry selects compute when available', () {
    final decision = selector.select(
      workload(segments: 512),
      const GpuPathStrategyCapabilities(
        sparseStrips: true,
        stencil: true,
        compute: true,
      ),
    );
    expect(decision.strategy, GpuPathStrategy.computeTiles);
  });

  test('measured sparse savings beat a new dense atlas upload', () {
    final decision = selector.select(
      workload(sparseBytes: 4096),
      const GpuPathStrategyCapabilities(sparseStrips: true),
    );
    expect(decision.strategy, GpuPathStrategy.sparseStrips);
    expect(decision.reason, contains('4096 bytes'));
  });

  test('selector prefers measured GPU transfer over source encoding', () {
    final decision = selector.select(
      workload(
        sparseBytes: 100,
        sparseUploadBytes: 40000,
        sparseInstanceBytes: 10000,
      ),
      const GpuPathStrategyCapabilities(sparseStrips: true),
    );
    expect(decision.strategy, GpuPathStrategy.coverageAtlas);
  });

  test('too many sparse page runs reject otherwise small transfers', () {
    final decision = selector.select(
      workload(
        sparseUploadBytes: 1024,
        sparseInstanceBytes: 1024,
        sparseDrawCalls: 65,
        sparsePages: 2,
      ),
      const GpuPathStrategyCapabilities(sparseStrips: true),
    );
    expect(decision.strategy, GpuPathStrategy.coverageAtlas);
  });

  test('stable simple geometry selects a retainable tessellation', () {
    final decision = selector.select(
      workload(stable: true, segments: 300),
      const GpuPathStrategyCapabilities(tessellation: true),
    );
    expect(decision.strategy, GpuPathStrategy.tessellatedMesh);
  });

  test('self-intersecting dynamic geometry avoids simple tessellation', () {
    final decision = selector.select(
      workload(stable: false, selfIntersects: true),
      const GpuPathStrategyCapabilities(
        coverageAtlas: false,
        tessellation: true,
        stencil: true,
      ),
    );
    expect(decision.strategy, GpuPathStrategy.stencilThenCover);
  });

  test('tessellator refusal prevents retained mesh selection', () {
    final decision = selector.select(
      workload(stable: true, tessellationEligible: false),
      const GpuPathStrategyCapabilities(tessellation: true),
    );
    expect(decision.strategy, GpuPathStrategy.coverageAtlas);
  });

  test('a large uncached mask prefers stencil over a fresh dense upload', () {
    // 256x256 is 65 536 bytes of alpha8 the CPU would have to rasterise and
    // upload. A stencil-capable pass replaces that with perimeter geometry, so
    // above the threshold the mask stops being the cheap answer.
    final decision = selector.select(
      workload(stable: true, tessellationEligible: false),
      const GpuPathStrategyCapabilities(
        tessellation: true,
        stencil: true,
      ),
    );
    expect(decision.strategy, GpuPathStrategy.stencilThenCover);
    expect(decision.reason, contains('65536'));
  });

  test('a small mask keeps the atlas even where stencil exists', () {
    // 64x64 is 4 096 bytes: below the threshold the two extra passes cost more
    // than the upload they replace.
    final decision = selector.select(
      workload(
        width: 64,
        height: 64,
        stable: true,
        tessellationEligible: false,
      ),
      const GpuPathStrategyCapabilities(stencil: true),
    );
    expect(decision.strategy, GpuPathStrategy.coverageAtlas);
  });

  test('a cached mask beats stencil at any size', () {
    // The cache hit costs no rasterisation and no upload at all, so there is
    // nothing left for stencil to save.
    final decision = selector.select(
      workload(width: 1024, height: 1024, cacheHit: true, stable: true),
      const GpuPathStrategyCapabilities(stencil: true),
    );
    expect(decision.strategy, GpuPathStrategy.coverageAtlas);
  });

  test('the stencil threshold is configurable and pins its own boundary', () {
    const tuned = GpuPathStrategySelector(stencilMinimumDenseMaskBytes: 65537);
    final decision = tuned.select(
      workload(stable: true, tessellationEligible: false),
      const GpuPathStrategyCapabilities(stencil: true),
    );
    expect(decision.strategy, GpuPathStrategy.coverageAtlas,
        reason: 'one byte over the mask keeps it on the dense route');
  });

  test('tessellation requires explicit eligibility evidence', () {
    final decision = selector.select(
      const GpuPathWorkload(
        pixelWidth: 32,
        pixelHeight: 32,
        segmentCount: 4,
        geometryStable: true,
      ),
      const GpuPathStrategyCapabilities(tessellation: true),
    );
    expect(decision.strategy, GpuPathStrategy.coverageAtlas);
  });

  test('atlas remains the universal fallback on existing GPUs', () {
    final decision = selector.select(
      workload(sparseBytes: 60000),
      const GpuPathStrategyCapabilities(sparseStrips: true),
    );
    expect(decision.strategy, GpuPathStrategy.coverageAtlas);
  });

  test('strategy metadata covers every public rasterization family', () {
    expect(
      GpuPathStrategy.sparseStrips.rasterizationApproach,
      RasterizationApproach.sparseStripsHybrid,
    );
    expect(
      GpuPathStrategy.tessellatedMesh.rasterizationApproach,
      RasterizationApproach.tessellatedMeshes,
    );
    expect(
      GpuPathStrategy.stencilThenCover.rasterizationApproach,
      RasterizationApproach.stencilThenCover,
    );
    expect(
      GpuPathStrategy.computeTiles.rasterizationApproach,
      RasterizationApproach.computeTiles,
    );
  });

  test('invalid workloads and incapable devices fail explicitly', () {
    expect(
      () => selector.select(
        workload(width: 0),
        const GpuPathStrategyCapabilities(),
      ),
      throwsArgumentError,
    );
    expect(
      () => selector.select(
        workload(selfIntersects: true),
        const GpuPathStrategyCapabilities(
          analyticPrimitives: false,
          coverageAtlas: false,
        ),
      ),
      throwsUnsupportedError,
    );
  });
}
