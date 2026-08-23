import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_vector_path_recorder.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_layer_stack.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_dispatch.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_planning.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_vector_command_stream.dart';
import 'package:dart_ui/src/rendering/gpu/vector/stencil_cover_draw_plan.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

void main() {
  test('records a retained tessellated payload only for aliased paint', () {
    final fixture = _Fixture();
    final recorder = GlVectorPathRecorder(stream: fixture.stream);

    expect(
      recorder.tryRecord(
        fixture.request(GpuPathStrategy.tessellatedMesh, _aliasedPaint),
      ),
      isTrue,
    );
    expect(fixture.stream.vectorCommandCount, 1);
    fixture.stream.finish(totalBatchCount: 0);
    final vector = fixture.stream.passAt(0).commands.single.vector!;
    expect(vector.payload, isA<GlTessellatedPathPayload>());
    expect(vector.material, same(_aliasedPaint));
    expect(recorder.acceptedCount, 1);
  });

  test('a refusal leaves the ordered stream untouched', () {
    final fixture = _Fixture();
    final recorder = GlVectorPathRecorder(stream: fixture.stream);

    expect(
      recorder.tryRecord(
        fixture.request(GpuPathStrategy.tessellatedMesh, _aaPaint),
      ),
      isFalse,
    );
    expect(fixture.stream.vectorCommandCount, 0);
    expect(recorder.refusalCount, 1);
  });

  test('sparse payload is complete and translated into layer space', () {
    final fixture = _Fixture();
    fixture.layers.push(
      deviceBounds: const Rect.fromLTRB(10, 20, 50, 60),
      clip: const Rect.fromLTRB(0, 0, 100, 100),
      alpha: 128,
      blendMode: blendModeSrcOver,
      batchIndex: 0,
    );
    final recorder = GlVectorPathRecorder(stream: fixture.stream);

    expect(
      recorder.tryRecord(
        fixture.request(
          GpuPathStrategy.sparseStrips,
          _aaPaint,
          transform: const Transform2D.translation(12, 23),
          clip: const Rect.fromLTRB(10, 20, 50, 60),
        ),
      ),
      isTrue,
    );
    fixture.stream.finish(totalBatchCount: 0);
    final vector = fixture.stream.passAt(0).commands.single.vector!;
    final payload = vector.payload as GlSparsePathPayload;
    expect(payload.plan.batchCount, 1);
    expect(vector.layerOriginX, 10);
    expect(vector.layerOriginY, 20);
    expect(vector.targetClip, const Rect.fromLTRB(0, 0, 40, 40));
  });

  test('stencil uses supplied target capabilities and refuses layer mismatch',
      () {
    const capabilities = StencilCoverCapabilities(
      stencilBits: 8,
      sampleCount: 4,
      separateFrontBackOperations: true,
      wrapOperations: true,
      invertOperation: true,
      scissoredClear: true,
    );
    // The pass has to *declare* the attachments as well as the device
    // reporting the capabilities: the two are different facts, and only the
    // pass knows which framebuffer the command will be executed against.
    final surface = _Fixture(
      surfaceAttachments: const GpuPassAttachments(
        stencilBits: 8,
        sampleCount: 4,
      ),
    );
    final surfaceRecorder = GlVectorPathRecorder(
      stream: surface.stream,
      stencilCapabilities: capabilities,
    );
    expect(
      surfaceRecorder.tryRecord(
        surface.request(GpuPathStrategy.stencilThenCover, _aaPaint),
      ),
      isTrue,
    );

    final layer = _Fixture(
      surfaceAttachments: const GpuPassAttachments(
        stencilBits: 8,
        sampleCount: 4,
      ),
    );
    layer.layers.push(
      deviceBounds: const Rect.fromLTRB(0, 0, 40, 40),
      clip: const Rect.fromLTRB(0, 0, 100, 100),
      alpha: 128,
      blendMode: blendModeSrcOver,
      batchIndex: 0,
    );
    final layerRecorder = GlVectorPathRecorder(
      stream: layer.stream,
      stencilCapabilities: capabilities,
    );
    expect(
      layerRecorder.tryRecord(
        layer.request(GpuPathStrategy.stencilThenCover, _aaPaint),
      ),
      isFalse,
    );
    expect(layer.stream.vectorCommandCount, 0);
  });

  test('a colour-only pass refuses stencil however capable the device is', () {
    // The failure this forbids is not a refusal: it is a stencil-then-cover
    // command executed against a framebuffer with no stencil buffer, where the
    // cover quad draws unmasked and a shape becomes its bounding box.
    const capabilities = StencilCoverCapabilities(
      stencilBits: 8,
      sampleCount: 4,
      separateFrontBackOperations: true,
      wrapOperations: true,
      invertOperation: true,
      scissoredClear: true,
    );
    final fixture = _Fixture();
    expect(fixture.layers.currentPass.attachments.hasStencil, isFalse);
    final recorder = GlVectorPathRecorder(
      stream: fixture.stream,
      stencilCapabilities: capabilities,
      // Even with the escape hatch open: the attachment check is the one that
      // decides, because it is the one that describes reality.
      allowStencilInLayers: true,
    );
    expect(
      recorder.tryRecord(
        fixture.request(GpuPathStrategy.stencilThenCover, _aaPaint),
      ),
      isFalse,
    );
    expect(fixture.stream.vectorCommandCount, 0);
    expect(recorder.refusalCount, 1);
  });

  test('a stencil layer target is accepted through the pass probe', () {
    // The mirror of the case above: with a probe wired, a layer whose target
    // really carries stencil is allowed, because the pass says so. Before
    // attachments reached the descriptor this was a blanket "no layers" flag.
    const capabilities = StencilCoverCapabilities(
      stencilBits: 8,
      sampleCount: 4,
      separateFrontBackOperations: true,
      wrapOperations: true,
      invertOperation: true,
      scissoredClear: true,
    );
    final fixture = _Fixture(
      layerAttachments: const GpuPassAttachments(
        stencilBits: 8,
        sampleCount: 4,
      ),
    );
    fixture.layers.push(
      deviceBounds: const Rect.fromLTRB(0, 0, 40, 40),
      clip: const Rect.fromLTRB(0, 0, 100, 100),
      alpha: 128,
      blendMode: blendModeSrcOver,
      batchIndex: 0,
    );
    expect(fixture.layers.currentPass.attachments.hasStencil, isTrue,
        reason: 'the stencil-carrying allocator answered this pass');
    final recorder = GlVectorPathRecorder(
      stream: fixture.stream,
      stencilCapabilitiesProbe: () => capabilities,
    );
    expect(
      recorder.tryRecord(
        fixture.request(GpuPathStrategy.stencilThenCover, _aaPaint),
      ),
      isTrue,
    );
    fixture.stream.finish(totalBatchCount: 0);
    expect(fixture.stream.vectorCommandCount, 1);
  });
}

final class _Fixture {
  _Fixture({
    GpuPassAttachments surfaceAttachments = GpuPassAttachments.colorOnly,
    GpuPassAttachments layerAttachments = GpuPassAttachments.colorOnly,
  }) : layers = GpuLayerStack(
          allocator: _Allocator(attachments: layerAttachments),
        )
          ..beginFrame(
            surfaceWidth: 100,
            surfaceHeight: 100,
            surfaceAttachments: surfaceAttachments,
          ) {
    stream = GpuVectorCommandStream<ReplayPaint, GlVectorPathPayload>(layers)
      ..resetForFrame();
  }

  final GpuLayerStack layers;
  late final GpuVectorCommandStream<ReplayPaint, GlVectorPathPayload> stream;

  GpuPathDispatchRequest request(
    GpuPathStrategy strategy,
    ReplayPaint paint, {
    Transform2D transform = Transform2D.identity,
    Rect clip = const Rect.fromLTRB(0, 0, 100, 100),
  }) =>
      GpuPathDispatchRequest(
        proposal: GpuPathPlanningProposal(
          label: 'triangle',
          workload: const GpuPathWorkload(
            pixelWidth: 20,
            pixelHeight: 20,
            segmentCount: 3,
            tessellationEligible: true,
          ),
          candidate: GpuPathStrategyDecision(strategy, 'test'),
        ),
        path: _triangle(),
        localToTarget: transform,
        clip: clip,
        fillRule: FillRule.nonZero,
        paint: paint,
        batchIndex: 0,
      );
}

const ReplayPaint _aliasedPaint = ReplayPaint(
  argbColor: 0xFF204080,
  style: paintStyleFill,
  strokeWidth: 0,
  blendMode: blendModeSrcOver,
  antiAlias: false,
);

const ReplayPaint _aaPaint = ReplayPaint(
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

final class _Allocator implements GpuLayerTargetAllocator {
  const _Allocator({this.attachments = GpuPassAttachments.colorOnly});

  /// What the targets this allocator hands out declare. Colour-only is what
  /// every real allocator in the repository produces for a layer today; the
  /// stencil variant exists so the pass-attachment path can be exercised on
  /// both sides of its decision.
  final GpuPassAttachments attachments;

  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) =>
      _Target(width, height, attachments);

  @override
  void releaseLayerTarget(GpuLayerTarget target) {}
}

final class _Target implements GpuLayerTarget, GpuAttachmentAwareTarget {
  const _Target(this.width, this.height, this.passAttachments);

  @override
  int get id => 1;
  @override
  int get textureId => 2;
  @override
  final int width;
  @override
  final int height;
  @override
  final GpuPassAttachments passAttachments;
}
