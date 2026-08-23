/// The layer stack, with no GPU anywhere near it.
///
/// Everything a layer can get wrong is arithmetic: which pixels the target
/// covers, what the geometry inside it is written against, which batches
/// belong to which pass, and when a target may be handed back. None of it
/// needs a driver, and running it without one is what makes it debuggable -
/// the same reason `gpu_batcher_test.dart` and `gpu_mask_atlas_test.dart` run
/// on a machine with no GPU.
library;

import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_layer_stack.dart';
import 'package:test/test.dart';

void main() {
  group('a layer that costs nothing', () {
    test('an empty layer allocates no target and cuts no pass', () {
      final allocator = _SpyAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);

      final layer = stack.push(
        deviceBounds: Rect.zero,
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );

      expect(layer.kind, GpuLayerKind.empty);
      expect(allocator.acquired, 0);
      // One pass: the surface's own. A pass that draws into nothing would
      // still cost the backend a framebuffer binding and a clear.
      expect(stack.passCount, 1);
      expect(stack.pop(batchIndex: 0).kind, GpuLayerKind.empty);
      expect(stack.depth, 0);
    });

    test('an opaque source-over layer is flattened, not rendered', () {
      // The identity: compositing contents over transparency and that over the
      // parent is the same arithmetic as drawing them over the parent.
      final allocator = _SpyAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);

      final layer = stack.push(
        deviceBounds: const Rect.fromLTRB(10, 10, 50, 50),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0xFF,
        blendMode: blendModeSrcOver,
        batchIndex: 3,
      );

      expect(layer.kind, GpuLayerKind.flattened);
      expect(allocator.acquired, 0);
      expect(stack.passCount, 1);
      // Geometry inside it stays in surface coordinates: there is no second
      // target to move it into.
      expect(stack.originX, 0);
      expect(stack.originY, 0);
    });

    test('alpha 254 is not opaque enough to flatten', () {
      // The boundary, asserted because "nearly opaque" is exactly the case a
      // renderer is tempted to round away, and one level of alpha over a
      // hundred-pixel panel is a visible band against the same panel drawn
      // beside it.
      final allocator = _SpyAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);

      final layer = stack.push(
        deviceBounds: const Rect.fromLTRB(10, 10, 50, 50),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0xFE,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );

      expect(layer.kind, GpuLayerKind.offscreen);
      expect(allocator.acquired, 1);
    });

    test('an opaque layer with a blend mode of its own still needs a pass', () {
      final allocator = _SpyAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);

      final layer = stack.push(
        deviceBounds: const Rect.fromLTRB(10, 10, 50, 50),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0xFF,
        blendMode: blendModePlus,
        batchIndex: 0,
      );

      expect(layer.kind, GpuLayerKind.offscreen);
      expect(layer.blendMode, blendModePlus);
    });
  });

  group('an offscreen layer', () {
    test('snaps its bounds outward and renders at its own origin', () {
      final allocator = _SpyAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);

      final layer = stack.push(
        deviceBounds: const Rect.fromLTRB(10.3, 20.7, 50.2, 60.1),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );

      // Outward, so no pixel the layer touches even partially is lost, and on
      // whole pixels, so the origin subtracted from every mask and glyph
      // inside is an integer.
      expect(layer.deviceBounds, const Rect.fromLTRB(10, 20, 51, 61));
      expect(layer.pixelWidth, 41);
      expect(layer.pixelHeight, 41);
      expect(stack.originX, 10);
      expect(stack.originY, 20);
      expect(allocator.requests.single, <int>[41, 41]);
    });

    test('composites with the opacity in all four channels', () {
      // Premultiplied: the layer texture already carries its own alpha, so the
      // composite is a scale of all four channels and not a tint.
      final stack = GpuLayerStack(allocator: _SpyAllocator())
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      final layer = stack.push(
        deviceBounds: const Rect.fromLTRB(0, 0, 40, 40),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );

      expect(layer.opacity, closeTo(128 / 255, 1e-12));
    });

    test('samples only its own corner of a larger target, top-down', () {
      // The allocator hands out a target rounded up to a size class, so the
      // composite has to stop at the layer's own pixels - and start at texel
      // row 0, which is the top row by this renderer's declared convention.
      final stack = GpuLayerStack(allocator: _SpyAllocator(pad: 24))
        ..beginFrame(surfaceWidth: 200, surfaceHeight: 200);
      final layer = stack.push(
        deviceBounds: const Rect.fromLTRB(0, 0, 40, 30),
        clip: const Rect.fromLTRB(0, 0, 200, 200),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );

      expect(layer.target!.width, 64);
      expect(layer.target!.height, 54);
      expect(layer.u0, 0);
      expect(layer.v0, 0);
      expect(layer.u1, closeTo(40 / 64, 1e-12));
      expect(layer.v1, closeTo(30 / 54, 1e-12));
    });

    test('cuts the frame into three passes around its batches', () {
      final stack = GpuLayerStack(allocator: _SpyAllocator())
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);

      final layer = stack.push(
        deviceBounds: const Rect.fromLTRB(0, 0, 40, 40),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 2,
      );
      stack.pop(batchIndex: 5);

      expect(stack.passCount, 3);
      expect(stack.hasLayerPasses, isTrue);

      final surfaceBefore = stack.passAt(0);
      expect(surfaceBefore.target, isNull);
      expect(surfaceBefore.firstBatch, 0);
      expect(stack.passEnd(0, 6), 2);
      expect(surfaceBefore.clearsTarget, isFalse);
      expect(surfaceBefore.rendersTopDown, isFalse);

      final layerPass = stack.passAt(1);
      expect(layerPass.target, same(layer.target));
      expect(layerPass.firstBatch, 2);
      expect(stack.passEnd(1, 6), 5);
      expect(layerPass.viewportWidth, 40);
      expect(layerPass.viewportHeight, 40);
      // Cleared, because a pooled target holds the previous tenant's pixels
      // and a layer composites what it drew over transparency.
      expect(layerPass.clearsTarget, isTrue);
      // Top-down, because it will be sampled. See kYFlipTopDown.
      expect(layerPass.rendersTopDown, isTrue);

      final surfaceAfter = stack.passAt(2);
      expect(surfaceAfter.target, isNull);
      expect(surfaceAfter.firstBatch, 5);
      // The composite quad lands here, and the live batch count is the end.
      expect(stack.passEnd(2, 6), 6);
      expect(surfaceAfter.clearsTarget, isFalse);
    });

    test('a layer that batched nothing drops its pass and frees its target',
        () {
      // Not an optimisation: a backend skips a pass with no batches, so the
      // target would never be cleared, and the composite would then sample
      // whatever the previous tenant left in it.
      final allocator = _SpyAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);

      stack.push(
        deviceBounds: const Rect.fromLTRB(0, 0, 40, 40),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 4,
      );
      final layer = stack.pop(batchIndex: 4);

      expect(layer.drewSomething, isFalse);
      expect(stack.passCount, 1);
      expect(allocator.released, 1);
      expect(allocator.live, 0);
    });

    test('targets are released at the end of the frame, not at pop', () {
      // The composite quad has only been *recorded* at pop; the texture it
      // samples is read when the backend submits, which is after the frame.
      final allocator = _SpyAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);

      stack.push(
        deviceBounds: const Rect.fromLTRB(0, 0, 40, 40),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );
      stack.pop(batchIndex: 1);
      expect(allocator.released, 0, reason: 'still batched, not yet drawn');

      stack.endFrame();
      expect(allocator.released, 1);
    });

    test('a frame that threw halfway releases its targets on the next one', () {
      final allocator = _SpyAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      stack.push(
        deviceBounds: const Rect.fromLTRB(0, 0, 40, 40),
        clip: const Rect.fromLTRB(0, 0, 100, 100),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );

      // No pop, no endFrame: an unsupported primitive threw out of the middle
      // of the walk. Leaking one target per failed frame turns a recoverable
      // error into an allocator that fills up.
      stack.beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      expect(allocator.released, 1);
      expect(stack.depth, 0);
    });
  });

  group('nesting', () {
    test(
        'an inner layer renders against its own origin and composites into '
        'the outer one', () {
      final allocator = _SpyAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 200, surfaceHeight: 200);

      stack.push(
        deviceBounds: const Rect.fromLTRB(10, 10, 110, 110),
        clip: const Rect.fromLTRB(0, 0, 200, 200),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );
      expect(stack.originX, 10);
      expect(stack.targetWidth, 100);

      final inner = stack.push(
        deviceBounds: const Rect.fromLTRB(30, 40, 70, 90),
        clip: const Rect.fromLTRB(10, 10, 110, 110),
        alpha: 0x40,
        blendMode: blendModeSrcOver,
        batchIndex: 1,
      );
      // Device space throughout: the inner layer's bounds are absolute, and
      // it is the *origin* that moves, once per layer.
      expect(inner.deviceBounds, const Rect.fromLTRB(30, 40, 70, 90));
      expect(stack.originX, 30);
      expect(stack.originY, 40);
      expect(stack.targetWidth, 40);
      expect(stack.targetHeight, 50);

      stack.pop(batchIndex: 3);
      // Back in the outer layer's space, which is where the inner layer's
      // composite quad is drawn.
      expect(stack.originX, 10);
      expect(stack.originY, 10);
      expect(inner.parentOriginX, 10);
      expect(inner.parentOriginY, 10);

      stack.pop(batchIndex: 4);
      expect(stack.originX, 0);
      expect(allocator.acquired, 2);

      // surface, outer, inner, outer resumed, surface resumed.
      expect(stack.passCount, 5);
      expect(stack.passAt(1).target, isNotNull);
      expect(stack.passAt(2).target, isNotNull);
      expect(stack.passAt(2).target, isNot(same(stack.passAt(1).target)));
      expect(stack.passAt(2).clearsTarget, isTrue);
      // The outer layer resumes into its own target, top-down like the first
      // run of it, and is not cleared again - that would erase everything it
      // drew before the inner layer opened.
      expect(stack.passAt(3).target, same(stack.passAt(1).target));
      expect(stack.passAt(3).rendersTopDown, isTrue);
      expect(stack.passAt(3).clearsTarget, isFalse);
      expect(stack.passAt(4).target, isNull);
      expect(stack.passAt(4).rendersTopDown, isFalse);
    });

    test('a flattened layer inside an offscreen one keeps the inner origin',
        () {
      final stack = GpuLayerStack(allocator: _SpyAllocator())
        ..beginFrame(surfaceWidth: 200, surfaceHeight: 200);
      stack.push(
        deviceBounds: const Rect.fromLTRB(10, 10, 110, 110),
        clip: const Rect.fromLTRB(0, 0, 200, 200),
        alpha: 0x80,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );
      stack.push(
        deviceBounds: const Rect.fromLTRB(20, 20, 60, 60),
        clip: const Rect.fromLTRB(10, 10, 110, 110),
        alpha: 0xFF,
        blendMode: blendModeSrcOver,
        batchIndex: 0,
      );

      expect(stack.originX, 10, reason: 'a flattened layer moves nothing');
      expect(stack.targetWidth, 100);
      stack.pop(batchIndex: 0);
      expect(stack.originX, 10);
    });
  });

  group('limits', () {
    test('nesting past the declared depth raises a named error', () {
      final allocator = _SpyAllocator();
      final stack = GpuLayerStack(
        allocator: allocator,
        backendName: 'test',
        maxDepth: 3,
      )..beginFrame(surfaceWidth: 100, surfaceHeight: 100);

      for (var i = 0; i < 3; i++) {
        stack.push(
          deviceBounds: const Rect.fromLTRB(0, 0, 40, 40),
          clip: const Rect.fromLTRB(0, 0, 100, 100),
          alpha: 0x80,
          blendMode: blendModeSrcOver,
          batchIndex: i,
        );
      }

      expect(
        () => stack.push(
          deviceBounds: const Rect.fromLTRB(0, 0, 40, 40),
          clip: const Rect.fromLTRB(0, 0, 100, 100),
          alpha: 0x80,
          blendMode: blendModeSrcOver,
          batchIndex: 3,
        ),
        throwsA(
          isA<GpuLayerDepthExceededError>()
              .having((e) => e.depth, 'depth', 4)
              .having((e) => e.maxDepth, 'maxDepth', 3)
              .having((e) => e.backendName, 'backendName', 'test')
              .having((e) => e.toString(), 'message', contains('test')),
        ),
      );
      // The refusal costs nothing: no fourth target was taken.
      expect(allocator.acquired, 3);
    });

    test('the default depth is eight, and it is a memory budget', () {
      expect(GpuLayerStack.kDefaultMaxLayerDepth, 8);
      expect(GpuLayerStack(allocator: _SpyAllocator()).maxDepth, 8);
    });

    test('popping more than was pushed is a StateError, not a negative depth',
        () {
      final stack = GpuLayerStack(allocator: _SpyAllocator())
        ..beginFrame(surfaceWidth: 10, surfaceHeight: 10);
      expect(() => stack.pop(batchIndex: 0), throwsStateError);
    });
  });

  group('layer attachments', () {
    GpuLayer push(GpuLayerStack stack, {int size = 40}) => stack.push(
          deviceBounds: Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
          clip: const Rect.fromLTRB(0, 0, 1000, 1000),
          alpha: 128,
          blendMode: blendModeSrcOver,
          batchIndex: 0,
        );

    test('colour-only by default, and the plain method is what is called', () {
      // The behaviour every backend had before a policy existed, and still has
      // when it declares none.
      final allocator = _AttachmentSpyAllocator();
      final stack = GpuLayerStack(allocator: allocator)
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      push(stack);
      expect(allocator.requests, <GpuPassAttachments?>[null]);
      expect(stack.currentPass.attachments, GpuPassAttachments.colorOnly);
    });

    test('a policy asking for colour-only also takes the plain method', () {
      // Not a detail: an allocator that has never seen the richer request must
      // keep receiving the one it implements for the common case.
      final allocator = _AttachmentSpyAllocator();
      final stack = GpuLayerStack(
        allocator: allocator,
        layerAttachmentPolicy: (_, __) => GpuPassAttachments.colorOnly,
      )..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      push(stack);
      expect(allocator.requests, <GpuPassAttachments?>[null]);
    });

    test('a policy asking for more reaches an allocator that can supply it',
        () {
      const wanted = GpuPassAttachments(stencilBits: 8, sampleCount: 4);
      final allocator = _AttachmentSpyAllocator()..supplied = wanted;
      final stack = GpuLayerStack(
        allocator: allocator,
        layerAttachmentPolicy: (_, __) => wanted,
      )..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      push(stack);
      expect(allocator.requests, <GpuPassAttachments?>[wanted]);
      expect(stack.currentPass.attachments, wanted,
          reason: 'the pass has to describe the target that was handed over, '
              'because that is what a strategy decision reads');
    });

    test('the pass reports what was supplied, not what was asked for', () {
      // An allocator may downgrade - a driver that refuses a multisampled
      // target, a pool that hands back a colour-only one. Believing the
      // *request* here would let a stencil draw run against a framebuffer with
      // no stencil, which is the one failure this whole descriptor exists to
      // prevent.
      final allocator = _AttachmentSpyAllocator()
        ..supplied = GpuPassAttachments.colorOnly;
      final stack = GpuLayerStack(
        allocator: allocator,
        layerAttachmentPolicy: (_, __) =>
            const GpuPassAttachments(stencilBits: 8, sampleCount: 4),
      )..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      push(stack);
      expect(stack.currentPass.attachments, GpuPassAttachments.colorOnly);
    });

    test('an allocator that cannot answer the richer request still works', () {
      // The compatibility guarantee: four backends implement only the plain
      // interface, and a policy must not make the stack unable to open a layer
      // on any of them.
      final allocator = _SpyAllocator();
      final stack = GpuLayerStack(
        allocator: allocator,
        layerAttachmentPolicy: (_, __) =>
            const GpuPassAttachments(stencilBits: 8, sampleCount: 4),
      )..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      final GpuLayer layer = push(stack);
      expect(layer.kind, GpuLayerKind.offscreen);
      expect(allocator.acquired, 1);
      expect(stack.currentPass.attachments, GpuPassAttachments.colorOnly);
    });

    test('the policy sees the layer size, not the surface size', () {
      // The size is the only fact available at push time, which is why the
      // policy is expressed in terms of it - see the doc on
      // GpuLayerStack.layerAttachmentPolicy.
      final List<List<int>> seen = <List<int>>[];
      final stack = GpuLayerStack(
        allocator: _AttachmentSpyAllocator(),
        layerAttachmentPolicy: (int width, int height) {
          seen.add(<int>[width, height]);
          return GpuPassAttachments.colorOnly;
        },
      )..beginFrame(surfaceWidth: 1000, surfaceHeight: 1000);
      push(stack, size: 64);
      expect(seen, <List<int>>[
        <int>[64, 64]
      ]);
    });
  });
}

/// An allocator made of integers, which is the whole point: "the stack asked
/// for one target and gave it back" is a claim about calls, not about pixels.
final class _SpyAllocator implements GpuLayerTargetAllocator {
  _SpyAllocator({this.pad = 0});

  /// Added to every requested dimension, standing in for a real pool's
  /// rounding up to a size class.
  final int pad;

  final List<List<int>> requests = <List<int>>[];
  int acquired = 0;
  int released = 0;
  int _nextId = 1;

  int get live => acquired - released;

  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) {
    requests.add(<int>[width, height]);
    acquired++;
    final int id = _nextId++;
    return _FakeTarget(id, id + 100, width + pad, height + pad);
  }

  @override
  void releaseLayerTarget(GpuLayerTarget target) => released++;
}

final class _FakeTarget implements GpuLayerTarget {
  _FakeTarget(this.id, this.textureId, this.width, this.height);

  @override
  final int id;

  @override
  final int textureId;

  @override
  final int width;

  @override
  final int height;
}

/// A spy that can also answer the richer request, and records which one it
/// was asked for.
final class _AttachmentSpyAllocator
    implements GpuLayerTargetAllocator, GpuAttachmentAwareAllocator {
  final List<GpuPassAttachments?> requests = <GpuPassAttachments?>[];

  /// What this allocator actually hands back, which is not required to be what
  /// was asked for - a real pool may round up or refuse and downgrade.
  GpuPassAttachments supplied = GpuPassAttachments.colorOnly;

  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) {
    requests.add(null);
    return _FakeTarget(1, 101, width, height);
  }

  @override
  GpuLayerTarget acquireLayerTargetWith(
    int width,
    int height,
    GpuPassAttachments attachments,
  ) {
    requests.add(attachments);
    return _AttachmentFakeTarget(2, 102, width, height, supplied);
  }

  @override
  void releaseLayerTarget(GpuLayerTarget target) {}
}

final class _AttachmentFakeTarget
    implements GpuLayerTarget, GpuAttachmentAwareTarget {
  _AttachmentFakeTarget(
    this.id,
    this.textureId,
    this.width,
    this.height,
    this.passAttachments,
  );

  @override
  final int id;
  @override
  final int textureId;
  @override
  final int width;
  @override
  final int height;
  @override
  final GpuPassAttachments passAttachments;
}
