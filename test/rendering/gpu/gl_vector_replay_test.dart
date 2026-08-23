/// The rules that decide which vector route a pass may take, with no driver.
///
/// `gl_device_test.dart` proves the decisions against a real GL context and a
/// real framebuffer, and it can only prove the combinations this machine's
/// hardware actually produces. The ones it cannot - a colour-only pass, a
/// stencil pass with too few samples, a device whose executor is off while its
/// attachments are present - are exactly the branches that decide a *refusal*,
/// and a branch that is never taken is a branch that rots silently. So they
/// are asserted here, where a pass's attachments are three integers in a value
/// object and no driver has to be persuaded to produce them.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_vector_replay.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_layer_stack.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_planning.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/vector/stencil_cover_draw_plan.dart';
import 'package:test/test.dart';

void main() {
  group('GlVectorReplay.create', () {
    test('builds nothing when every experimental executor is off', () {
      // Null is the established renderer: the target keeps the dense batch
      // loop and does not walk the ordered submitter at all.
      expect(
        GlVectorReplay.create(
          layers: _stack(),
          sparseEnabled: false,
          stencilEnabled: false,
          tessellationEnabled: false,
          queryStencil: (_) => null,
          surfaceFramebuffer: () => 0,
        ),
        isNull,
      );
    });

    test('builds the wiring when any one of them is on', () {
      expect(
        _replay(sparse: true, layers: _stack()),
        isNotNull,
      );
    });
  });

  group('capabilities follow the pass, not the device', () {
    test('sparse strips are the antialiased route and only that', () {
      final GlVectorReplay replay = _replay(sparse: true, layers: _stack())!;
      expect(
          replay.capabilities(const GpuPathDrawTraits()).sparseStrips, isTrue);
      expect(
          replay
              .capabilities(const GpuPathDrawTraits(antiAlias: false))
              .sparseStrips,
          isFalse,
          reason: 'sparse coverage is analytic; encoding an aliased fill '
              'through it would add a fringe the display list never asked '
              'for');
    });

    test('tessellation needs samples for an antialiased draw', () {
      final GlVectorReplay single =
          _replay(tessellation: true, layers: _stack())!;
      expect(
          single
              .capabilities(const GpuPathDrawTraits(antiAlias: false))
              .tessellation,
          isTrue);
      expect(
          single.capabilities(const GpuPathDrawTraits()).tessellation, isFalse,
          reason: 'the B shader has no analytic fringe, so on a '
              'single-sample pass an antialiased fill would come out hard');

      final GlVectorReplay multi = _replay(
        tessellation: true,
        layers: _stack(const GpuPassAttachments(sampleCount: 4)),
      )!;
      expect(multi.capabilities(const GpuPathDrawTraits()).tessellation, isTrue,
          reason: 'four samples are what the descriptor was extended to '
              'carry, and they make the same mesh a correct antialiased fill');
    });

    test('stencil needs both a stencil buffer and four samples', () {
      // Each half alone is not enough, and the pair is what turns C on. The
      // aliased case is included on purpose: a filled path is analytically
      // antialiased on every other route in this renderer, so a one-sample
      // cover pass is a different picture even for antiAlias: false - the
      // 144-level measurement in `gl_device_test.dart`.
      for (final (GpuPassAttachments attachments, bool expected)
          in <(GpuPassAttachments, bool)>[
        (GpuPassAttachments.colorOnly, false),
        (const GpuPassAttachments(stencilBits: 8), false),
        (const GpuPassAttachments(sampleCount: 4), false),
        (const GpuPassAttachments(stencilBits: 8, sampleCount: 4), true),
      ]) {
        final GlVectorReplay replay =
            _replay(stencil: true, layers: _stack(attachments))!;
        expect(replay.capabilities(const GpuPathDrawTraits()).stencil, expected,
            reason: 'antialiased draw against $attachments');
        expect(
            replay
                .capabilities(const GpuPathDrawTraits(antiAlias: false))
                .stencil,
            expected,
            reason: 'aliased draw against $attachments');
      }
    });

    test('a device with the executor off never reports the capability', () {
      final GlVectorReplay replay = _replay(
        sparse: true,
        layers:
            _stack(const GpuPassAttachments(stencilBits: 8, sampleCount: 4)),
      )!;
      expect(replay.capabilities(const GpuPathDrawTraits()).stencil, isFalse,
          reason: 'the attachments are there but no executor was built, and '
              'a capability is the conjunction of the two');
      expect(
          replay
              .capabilities(const GpuPathDrawTraits(antiAlias: false))
              .tessellation,
          isFalse);
    });

    test('a gradient draw reports sparse or nothing, never the atlas', () {
      // The inversion that makes gradients different from every other draw:
      // the dense coverage atlas is normally the guaranteed fallback, and for
      // a gradient it is not a fallback at all - it would paint a flat fill.
      // So the capability set for a gradient has to *withhold* it, which is
      // what turns "no route" into a named refusal in `GpuRasterSink` instead
      // of a silently wrong picture.
      const GpuPathDrawTraits gradient = GpuPathDrawTraits(hasGradient: true);

      final GlVectorReplay withCache = GlVectorReplay.create(
        layers: _stack(),
        sparseEnabled: true,
        stencilEnabled: true,
        tessellationEnabled: true,
        queryStencil: (_) => _capabilities,
        surfaceFramebuffer: () => 0,
        gradientCache: GpuGradientCache(allocator: _FakeTextures()),
      )!;
      final GpuPathStrategyCapabilities capable =
          withCache.capabilities(gradient);
      expect(capable.sparseStrips, isTrue);
      expect(capable.coverageAtlas, isFalse,
          reason: 'the atlas cannot draw a ramp, so offering it would promise '
              'a picture the renderer would get wrong');
      expect(capable.analyticPrimitives, isFalse);
      expect(capable.tessellation, isFalse,
          reason: 'approach B hands the rasteriser one solid material');
      expect(capable.stencil, isFalse);

      // No cache: nothing at all, which makes the selector raise and the sink
      // refuse by name.
      final GlVectorReplay noCache =
          _replay(sparse: true, tessellation: true, layers: _stack())!;
      final GpuPathStrategyCapabilities none = noCache.capabilities(gradient);
      expect(none.sparseStrips, isFalse);
      expect(none.coverageAtlas, isFalse);
      expect(none.hasGeneralPathStrategy, isFalse,
          reason: 'this is what makes GpuPathStrategySelector.select raise, '
              'which the planning telemetry contains and the sink turns into '
              'a refusal that names the backend');
    });

    test('a device with no sparse executor is given no gradient cache', () {
      // The cache is only useful to the route that samples it, so a device
      // without that route must not upload ramps nothing can read.
      final GlVectorReplay replay = GlVectorReplay.create(
        layers: _stack(),
        sparseEnabled: false,
        stencilEnabled: true,
        tessellationEnabled: true,
        queryStencil: (_) => _capabilities,
        surfaceFramebuffer: () => 0,
        gradientCache: GpuGradientCache(allocator: _FakeTextures()),
      )!;
      expect(replay.gradientCache, isNull);
      expect(replay.recorder.gradientCache, isNull);
    });

    test('a layer pass answers for its own target', () {
      // The point of putting attachments on the pass rather than the device:
      // the surface may carry stencil and samples while the pooled layer
      // target does not, and inside that layer the same draw must fall back.
      final GpuLayerStack layers = _stack(
        const GpuPassAttachments(stencilBits: 8, sampleCount: 4),
      );
      final GlVectorReplay replay = _replay(stencil: true, layers: layers)!;
      expect(replay.capabilities(const GpuPathDrawTraits()).stencil, isTrue);

      layers.push(
        deviceBounds: const Rect.fromLTRB(0, 0, 40, 40),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 128,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );
      expect(replay.capabilities(const GpuPathDrawTraits()).stencil, isFalse,
          reason: 'the colour-only layer target cannot execute a stencil '
              'pass, and saying it could would draw the cover quad unmasked');

      layers.pop(batchIndex: 0);
      expect(replay.capabilities(const GpuPathDrawTraits()).stencil, isTrue,
          reason: 'the surface pass resumes with its own attachments');
    });
  });

  group('the layer attachment policy', () {
    test('gives nothing away when approach C is off', () {
      // A default build must allocate layer targets exactly as it always did.
      for (final int size in <int>[64, 256, 4096]) {
        expect(
          glLayerAttachmentsFor(
            width: size,
            height: size,
            stencilCoverEnabled: false,
          ),
          GpuPassAttachments.colorOnly,
        );
      }
    });

    test('asks for stencil and samples only above the promotion threshold', () {
      // The threshold is not taste: `stencilMinimumDenseMaskBytes` is 16 KiB,
      // which a shape has to be roughly 128x128 to reach, and a shape cannot
      // be larger than the layer that clips it. Below that the attachments buy
      // a capability nothing inside the layer could use.
      GpuPassAttachments at(int width, int height) => glLayerAttachmentsFor(
            width: width,
            height: height,
            stencilCoverEnabled: true,
          );

      expect(at(127, 512), GpuPassAttachments.colorOnly,
          reason: 'either axis below the threshold is enough to refuse');
      expect(at(512, 127), GpuPassAttachments.colorOnly);
      expect(at(128, 128).hasStencil, isTrue);
      expect(at(128, 128).sampleCount, kGlLayerSampleCount);
    });

    test('layers take fewer samples than the surface, on purpose', () {
      // A frame has one surface and can have many layers, all resident until
      // it ends, so a layer's multisampled buffers are multiplied by the layer
      // count. Four is the minimum approach C needs, which makes it the
      // cheapest allocation that unblocks anything.
      expect(kGlLayerSampleCount, 4);
      expect(
        glLayerAttachmentsFor(
          width: 512,
          height: 512,
          stencilCoverEnabled: true,
        ),
        const GpuPassAttachments(stencilBits: 8, sampleCount: 4),
      );
    });
  });

  group('the stencil query is cached and contained', () {
    test('asked once per framebuffer per frame', () {
      var queries = 0;
      final GpuLayerStack layers = _stack(
        const GpuPassAttachments(stencilBits: 8, sampleCount: 4),
      );
      final GlVectorReplay replay = GlVectorReplay.create(
        layers: layers,
        sparseEnabled: false,
        stencilEnabled: true,
        tessellationEnabled: false,
        queryStencil: (_) {
          queries++;
          return _capabilities;
        },
        surfaceFramebuffer: () => 7,
      )!;
      replay.beginFrame();
      final StencilCoverCapabilities? first =
          replay.recorder.stencilCapabilitiesProbe!();
      final StencilCoverCapabilities? second =
          replay.recorder.stencilCapabilitiesProbe!();
      expect(first, same(_capabilities));
      expect(second, same(_capabilities));
      expect(queries, 1,
          reason: 'a framebuffer bind and several glGets per '
              'path draw is the hot path this cache exists to keep off');

      replay.beginFrame();
      replay.recorder.stencilCapabilitiesProbe!();
      expect(queries, 2, reason: 'a new frame may bind a different target');
    });

    test('a query that throws is a refusal, not a failed frame', () {
      final GlVectorReplay replay = GlVectorReplay.create(
        layers: _stack(const GpuPassAttachments(stencilBits: 8)),
        sparseEnabled: false,
        stencilEnabled: true,
        tessellationEnabled: false,
        queryStencil: (_) => throw StateError('the driver refused'),
        surfaceFramebuffer: () => 0,
      )!;
      replay.beginFrame();
      expect(replay.recorder.stencilCapabilitiesProbe!(), isNull);
    });

    test('a colour-only pass is never even asked', () {
      var queries = 0;
      final GlVectorReplay replay = GlVectorReplay.create(
        layers: _stack(),
        sparseEnabled: false,
        stencilEnabled: true,
        tessellationEnabled: false,
        queryStencil: (_) {
          queries++;
          return _capabilities;
        },
        surfaceFramebuffer: () => 0,
      )!;
      replay.beginFrame();
      expect(replay.recorder.stencilCapabilitiesProbe!(), isNull);
      expect(queries, 0);
    });
  });
}

const StencilCoverCapabilities _capabilities = StencilCoverCapabilities(
  stencilBits: 8,
  sampleCount: 4,
  separateFrontBackOperations: true,
  wrapOperations: true,
  invertOperation: true,
  scissoredClear: true,
);

GpuLayerStack _stack([
  GpuPassAttachments attachments = GpuPassAttachments.colorOnly,
]) =>
    GpuLayerStack(allocator: _Allocator())
      ..beginFrame(
        surfaceWidth: 100,
        surfaceHeight: 100,
        surfaceAttachments: attachments,
      );

GlVectorReplay? _replay({
  required GpuLayerStack layers,
  bool sparse = false,
  bool stencil = false,
  bool tessellation = false,
}) =>
    GlVectorReplay.create(
      layers: layers,
      sparseEnabled: sparse,
      stencilEnabled: stencil,
      tessellationEnabled: tessellation,
      queryStencil: (_) => _capabilities,
      surfaceFramebuffer: () => 0,
    );

/// Enough of a texture allocator for a gradient cache that is never sampled.
///
/// These tests are about which routes are *reported*, not about pixels, so the
/// ramp only has to be allocatable - and building it here rather than opening a
/// GL device is what keeps this file runnable on a machine with no GPU.
final class _FakeTextures implements GpuTextureAllocator {
  @override
  GpuTextureHandle createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    GpuTextureFilter filter = GpuTextureFilter.nearest,
  }) =>
      _FakeTexture(width, height, format, filter);

  @override
  void uploadRegion(
    GpuTextureHandle texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {}

  @override
  void releaseTexture(GpuTextureHandle texture) {}
}

final class _FakeTexture implements GpuTextureHandle {
  const _FakeTexture(this.width, this.height, this.format, this.filter);

  @override
  int get id => 7;
  @override
  final int width;
  @override
  final int height;
  @override
  final GpuTextureFormat format;
  @override
  final GpuTextureFilter filter;
  @override
  bool get isValid => true;
}

/// Hands out colour-only targets, which is what every real allocator in this
/// repository does for a layer today.
final class _Allocator implements GpuLayerTargetAllocator {
  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) =>
      _Target(width, height);

  @override
  void releaseLayerTarget(GpuLayerTarget target) {}
}

final class _Target implements GpuLayerTarget {
  const _Target(this.width, this.height);

  @override
  int get id => 1;
  @override
  int get textureId => 2;
  @override
  final int width;
  @override
  final int height;
}
