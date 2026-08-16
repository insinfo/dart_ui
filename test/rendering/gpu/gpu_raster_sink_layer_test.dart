/// Layers, and the two atlas flush protocols, as the sink drives them.
///
/// The sink is where a layer stops being a stack entry and becomes geometry:
/// where the contents are written, what the composite quad's four corners and
/// four texture coordinates are, and what colour modulates it. All of that is
/// arithmetic over typed arrays and none of it needs a device, which is why it
/// is asserted here in numbers rather than only in the GL parity test - a
/// readback says "these two pictures differ" and this says where.
library;

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_batcher.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_layer_stack.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_mask_atlas.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_raster_sink.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

const int _maskTextureId = 7;
const Rect _surface = Rect.fromLTRB(0, 0, 100, 100);

void main() {
  group('a layer with opacity', () {
    test('composites one quad at its own bounds, modulated in four channels',
        () {
      final allocator = _SpyAllocator();
      final sink = _sink(allocator: allocator);

      sink
        ..beginLayer(
            const Rect.fromLTRB(2, 2, 14, 14), _surface, _layerPaint(0x80))
        ..fillDeviceRect(const Rect.fromLTRB(4, 4, 12, 12), _surface,
            _paint(argb: 0xFFCC3311, antiAlias: false))
        ..endLayer();

      expect(sink.batcher.quadCount, 2);
      // The composite is the last quad, in the surface's coordinates.
      expect(_quadAt(sink, 1), <double>[2, 2, 14, 14]);
      // One texel per pixel over the whole target the fake allocator sized
      // exactly; a real pool rounds up and the coordinates shrink to match.
      expect(_uvAt(sink, 1), <double>[0, 0, 1, 1]);
      // Premultiplied: all four channels scale, because the layer's texture
      // already carries its own alpha. A tint here would colour the layer.
      const double opacity = 0x80 / 255.0;
      expect(_colorAt(sink, 1), <Matcher>[
        closeTo(opacity, 1e-6),
        closeTo(opacity, 1e-6),
        closeTo(opacity, 1e-6),
        closeTo(opacity, 1e-6),
      ]);
      // The shape rect equals the quad, so the analytic coverage term is 1
      // everywhere; letting it run against a fractional rect would shave the
      // outer row and column off every layer.
      expect(_shapeAt(sink, 1), _quadAt(sink, 1));

      final composite = sink.batcher.batchAt(sink.batcher.batchCount - 1);
      expect(composite.pipeline, GpuPipelineKind.texturedImage);
      expect(composite.textureId, allocator.targets.single.textureId);
      expect(composite.blendMode, blendModeSrcOver);
    });

    test('the contents are written against the layer origin, not the surface',
        () {
      // The layer's target is only layer-sized, so a rectangle at device
      // (4, 4) inside a layer that starts at (2, 2) is at (2, 2) in it.
      final sink = _sink();
      sink
        ..beginLayer(
            const Rect.fromLTRB(2, 2, 14, 14), _surface, _layerPaint(0x80))
        ..fillDeviceRect(const Rect.fromLTRB(4, 4, 12, 12), _surface,
            _paint(antiAlias: false));

      expect(_quadAt(sink, 0), <double>[2, 2, 10, 10]);
      // And so is the scissor, or the layer's contents would be clipped by a
      // rectangle in another coordinate system - which on a layer near the
      // bottom of the screen clips the whole thing away.
      final batch = sink.batcher.batchAt(0);
      expect(<int>[
        batch.scissorLeft,
        batch.scissorTop,
        batch.scissorRight,
        batch.scissorBottom,
      ], <int>[
        -2,
        -2,
        98,
        98
      ]);
    });

    test('the layer paint\'s blend mode composites the layer, not its contents',
        () {
      final sink = _sink();
      sink
        ..beginLayer(const Rect.fromLTRB(0, 0, 10, 10), _surface,
            _layerPaint(0xFF, blendMode: blendModePlus))
        ..fillDeviceRect(const Rect.fromLTRB(0, 0, 10, 10), _surface,
            _paint(antiAlias: false))
        ..endLayer();

      expect(sink.batcher.batchCount, 2);
      // The contents blend inside the layer with their own mode...
      expect(sink.batcher.batchAt(0).blendMode, blendModeSrcOver);
      expect(sink.batcher.batchAt(0).pipeline, GpuPipelineKind.solid);
      // ...and the finished layer is added to the parent.
      expect(sink.batcher.batchAt(1).blendMode, blendModePlus);
      expect(sink.batcher.batchAt(1).pipeline, GpuPipelineKind.texturedImage);
      // Opaque, so the composite is the texture unmodulated.
      expect(_colorAt(sink, 1), <Matcher>[
        closeTo(1, 1e-6),
        closeTo(1, 1e-6),
        closeTo(1, 1e-6),
        closeTo(1, 1e-6),
      ]);
    });

    test('a layer that drew nothing composites nothing', () {
      final allocator = _SpyAllocator();
      final sink = _sink(allocator: allocator);
      sink
        ..beginLayer(
            const Rect.fromLTRB(2, 2, 14, 14), _surface, _layerPaint(0x80))
        ..endLayer();

      // No composite quad: the target was never cleared, so sampling it would
      // paint the previous tenant of the pool onto the screen.
      expect(sink.batcher.quadCount, 0);
      expect(allocator.released, 1);
    });

    test('an empty layer costs no target at all', () {
      final allocator = _SpyAllocator();
      final sink = _sink(allocator: allocator);
      sink
        ..beginLayer(Rect.zero, _surface, _layerPaint(0x80))
        ..endLayer();

      expect(allocator.acquired, 0);
      expect(sink.batcher.quadCount, 0);
      expect(sink.layerDepth, 0);
    });

    test('an opaque source-over layer draws straight into the parent', () {
      final allocator = _SpyAllocator();
      final sink = _sink(allocator: allocator);
      sink
        ..beginLayer(
            const Rect.fromLTRB(2, 2, 14, 14), _surface, _layerPaint(0xFF))
        ..fillDeviceRect(const Rect.fromLTRB(4, 4, 12, 12), _surface,
            _paint(antiAlias: false))
        ..endLayer();

      expect(allocator.acquired, 0);
      expect(sink.batcher.quadCount, 1);
      // Surface coordinates, because there is no second target to move into.
      expect(_quadAt(sink, 0), <double>[4, 4, 12, 12]);
    });

    test('and costs no draw call break, which gpu_batcher.dart promises', () {
      // A layer used purely as a clip is common, and breaking the batch around
      // every one of them would make `saveLayer` cost draw calls for nothing.
      final sink = _sink()
        ..fillDeviceRect(
            const Rect.fromLTRB(0, 0, 4, 4), _surface, _paint(antiAlias: false))
        ..beginLayer(
            const Rect.fromLTRB(2, 2, 14, 14), _surface, _layerPaint(0xFF))
        ..fillDeviceRect(const Rect.fromLTRB(4, 4, 12, 12), _surface,
            _paint(antiAlias: false))
        ..endLayer()
        ..fillDeviceRect(const Rect.fromLTRB(20, 20, 24, 24), _surface,
            _paint(antiAlias: false));

      expect(sink.batcher.quadCount, 3);
      expect(sink.batcher.batchCount, 1);
    });
  });

  group('nested layers', () {
    test('the inner composite lands in the outer layer\'s coordinates', () {
      final allocator = _SpyAllocator();
      final sink = _sink(allocator: allocator);

      sink
        ..beginLayer(
            const Rect.fromLTRB(10, 10, 90, 90), _surface, _layerPaint(0x80))
        ..beginLayer(const Rect.fromLTRB(30, 40, 70, 80),
            const Rect.fromLTRB(10, 10, 90, 90), _layerPaint(0x40))
        ..fillDeviceRect(const Rect.fromLTRB(30, 40, 70, 80),
            const Rect.fromLTRB(10, 10, 90, 90), _paint(antiAlias: false))
        ..endLayer()
        ..endLayer();

      expect(allocator.acquired, 2);
      expect(sink.batcher.quadCount, 3);
      // The innermost rectangle fills its own layer, which starts at (30, 40).
      expect(_quadAt(sink, 0), <double>[0, 0, 40, 40]);
      // The inner composite is drawn into the outer layer, which starts at
      // (10, 10): device (30, 40) becomes (20, 30).
      expect(_quadAt(sink, 1), <double>[20, 30, 60, 70]);
      expect(_colorAt(sink, 1),
          <Matcher>[closeTo(0x40 / 255, 1e-6), anything, anything, anything]);
      // And the outer composite is drawn onto the surface at its own bounds.
      expect(_quadAt(sink, 2), <double>[10, 10, 90, 90]);
      expect(_colorAt(sink, 2),
          <Matcher>[closeTo(0x80 / 255, 1e-6), anything, anything, anything]);
      // Three targets would mean one was not reused; two means each layer got
      // its own, which is required - they are alive at the same time.
      expect(allocator.targets[0].textureId,
          isNot(allocator.targets[1].textureId));
    });

    test('nesting past the declared depth fails by name', () {
      final sink = _sink(maxDepth: 2);
      sink
        ..beginLayer(
            const Rect.fromLTRB(0, 0, 50, 50), _surface, _layerPaint(0x80))
        ..beginLayer(
            const Rect.fromLTRB(0, 0, 50, 50), _surface, _layerPaint(0x80));

      expect(
        () => sink.beginLayer(
            const Rect.fromLTRB(0, 0, 50, 50), _surface, _layerPaint(0x80)),
        throwsA(isA<GpuLayerDepthExceededError>()
            .having((e) => e.maxDepth, 'maxDepth', 2)),
      );
    });
  });

  group('a sink with no layer stack', () {
    test('refuses a layer that composites instead of flattening it in silence',
        () {
      // The behaviour this whole file replaced: the old sink incremented a
      // counter, drew the subtree at full opacity and reported nothing.
      final sink = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'test',
      );

      expect(
        () => sink.beginLayer(
            const Rect.fromLTRB(0, 0, 10, 10), _surface, _layerPaint(0x80)),
        throwsA(isA<UnsupportedCapabilityError>()
            .having((e) => e.detail, 'detail', contains('GpuLayerStack'))),
      );
    });

    test('still handles the layer that is only a clip', () {
      final sink = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'test',
      )
        ..beginLayer(
            const Rect.fromLTRB(0, 0, 10, 10), _surface, _layerPaint(0xFF))
        ..endLayer();

      expect(sink.layerDepth, 0);
    });

    test('an unbalanced endLayer throws rather than going negative', () {
      final sink = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'test',
      );
      expect(sink.endLayer, throwsStateError);
    });
  });

  group('the one case flattening gets wrong', () {
    test('a non-source-over primitive inside a flattened layer is refused', () {
      // `plus` against transparency and then over the parent is not `plus`
      // against the parent. Flattening is an identity for source-over contents
      // and only for those, so the exception is refused by name rather than
      // drawn as a picture that looks deliberate.
      final sink = _sink()
        ..beginLayer(
            const Rect.fromLTRB(0, 0, 50, 50), _surface, _layerPaint(0xFF));

      expect(
        () => sink.fillDeviceRect(const Rect.fromLTRB(0, 0, 10, 10), _surface,
            _paint(blendMode: blendModePlus)),
        throwsA(isA<UnsupportedCapabilityError>()
            .having((e) => e.detail, 'detail', contains('flattened layer'))),
      );
    });

    test('the same primitive inside a real layer is fine', () {
      // Inside an offscreen target the blend runs against transparency, which
      // is exactly what isolation means.
      final sink = _sink()
        ..beginLayer(
            const Rect.fromLTRB(0, 0, 50, 50), _surface, _layerPaint(0x80));

      expect(
        () => sink.fillDeviceRect(const Rect.fromLTRB(0, 0, 10, 10), _surface,
            _paint(blendMode: blendModePlus)),
        returnsNormally,
      );
    });

    test('and outside every layer it is fine, because there is no isolation',
        () {
      final sink = _sink();
      expect(
        () => sink.fillDeviceRect(const Rect.fromLTRB(0, 0, 10, 10), _surface,
            _paint(blendMode: blendModePlus)),
        returnsNormally,
      );
    });
  });

  group('the mask atlas flush protocol', () {
    test('a full atlas flushes in order and the retry succeeds', () {
      // A 64x64 atlas holds one 40x40 mask and no second one, and the first is
      // pinned because this frame has already drawn with it.
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final List<String> events = <String>[];
      late final GpuRasterSink sink;
      sink = _sink(
        maskAtlas: atlas,
        onAtlasFlush: () {
          // Everything the handler is promised: the dirty region is still
          // there to upload, the masks are still there to be sampled by the
          // batches it is about to issue, and the batch list is final.
          events
            ..add('dirty=${atlas.isDirty}')
            ..add('cached=${atlas.cachedMaskCount}')
            ..add('batches=${sink.batcher.batchCount}');
        },
      );

      sink.drawDevicePath(_rectPath(0, 0, 40, 40), Transform2D.identity,
          _surface, _paint(antiAlias: false));
      expect(sink.batcher.batchCount, 1);
      sink.drawDevicePath(_rectPath(50, 0, 90, 40), Transform2D.identity,
          _surface, _paint(antiAlias: false));

      // Called once. Twice would mean the retry did not happen on an empty
      // atlas, which is a loop that issues draw calls forever.
      expect(events, <String>['dirty=true', 'cached=1', 'batches=1']);
      expect(sink.batcher.quadCount, 2, reason: 'no shape was dropped');
      // Two batches out of two identical states: the sink closed the open
      // batch before the handler issued it, so the second mask cannot merge
      // into a draw call that has already been submitted.
      expect(sink.batcher.batchCount, 2);
      expect(sink.batcher.batchAt(0).textureId, _maskTextureId);
      expect(sink.batcher.batchAt(1).textureId, _maskTextureId);
      // Recycled after the handler, not before: one mask resident, the new
      // one, and both were genuinely rasterised.
      expect(atlas.cachedMaskCount, 1);
      expect(atlas.rasterizationCount, 2);
      expect(atlas.isDirty, isTrue, reason: 'the retry wrote new texels');
    });

    test('a full atlas with no handler fails by name rather than silently', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final sink = _sink(maskAtlas: atlas);

      sink.drawDevicePath(_rectPath(0, 0, 40, 40), Transform2D.identity,
          _surface, _paint(antiAlias: false));
      expect(
        () => sink.drawDevicePath(_rectPath(50, 0, 90, 40),
            Transform2D.identity, _surface, _paint(antiAlias: false)),
        throwsA(isA<UnsupportedCapabilityError>()
            .having((e) => e.detail, 'detail', contains('onAtlasFlush'))),
      );
    });

    test(
        'a flush inside a layer keeps the batches on the right side of the '
        'pass boundary', () {
      // The interesting interaction between the two halves of this change: the
      // handler submits mid-frame *while a layer target is bound*, and the
      // batches recorded after it still belong to the layer's pass. A pass
      // boundary that landed on the wrong batch would draw the rest of the
      // layer's contents onto the surface instead.
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      final allocator = _SpyAllocator();
      var flushes = 0;
      final stack = GpuLayerStack(allocator: allocator, backendName: 'test')
        ..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
      final sink = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'test',
        maskAtlas: atlas,
        maskTextureId: _maskTextureId,
        layerStack: stack,
        onAtlasFlush: () => flushes++,
      );

      sink.beginLayer(
          const Rect.fromLTRB(0, 0, 100, 100), _surface, _layerPaint(0x80));
      sink.drawDevicePath(_rectPath(0, 0, 40, 40), Transform2D.identity,
          _surface, _paint(antiAlias: false));
      sink.drawDevicePath(_rectPath(50, 0, 90, 40), Transform2D.identity,
          _surface, _paint(antiAlias: false));
      sink.endLayer();

      expect(flushes, 1);
      // Two masks and one composite, all kept.
      expect(sink.batcher.quadCount, 3);
      // surface, layer, surface resumed - the flush splits batches inside the
      // layer's range and does not add a pass of its own.
      expect(stack.passCount, 3);
      expect(stack.passAt(1).firstBatch, 0);
      expect(stack.passAt(2).firstBatch, 2,
          reason: 'both mask batches belong to the layer');
      expect(stack.passEnd(2, sink.batcher.batchCount), 3);
    });

    test('a shape clipped away is not a flush and not an error', () {
      final atlas = GpuMaskAtlas(width: 64, height: 64);
      var flushes = 0;
      final sink = _sink(maskAtlas: atlas, onAtlasFlush: () => flushes++);

      sink.drawDevicePath(_rectPath(500, 500, 540, 540), Transform2D.identity,
          const Rect.fromLTRB(0, 0, 100, 100), _paint());

      expect(flushes, 0);
      expect(sink.batcher.quadCount, 0);
      expect(atlas.rasterizationCount, 0);
    });
  });

  group('a shape larger than the atlas', () {
    test('is tiled, contiguously and without overlap', () {
      // Tiling and not a CPU fallback: this sink has no surface to fall back
      // to. The atlas's own budget is the tile size.
      final atlas = GpuMaskAtlas();
      final sink = _sink(maskAtlas: atlas);
      const Rect clip = Rect.fromLTRB(0, 0, 3000, 300);

      sink.drawDevicePath(_rectPath(0, 0, 3000, 300), Transform2D.identity,
          clip, _paint(antiAlias: false));

      final int tiles = (3000 / atlas.maxMaskWidth).ceil();
      expect(tiles, 3);
      expect(sink.batcher.quadCount, tiles);
      expect(atlas.rasterizationCount, tiles);

      // Contiguous: a gap would show as a hairline through the shape and an
      // overlap would double the coverage along it.
      var expectedLeft = 0.0;
      for (var i = 0; i < tiles; i++) {
        final quad = _quadAt(sink, i);
        expect(quad[0], expectedLeft);
        expect(quad[1], 0);
        expect(quad[3], 300);
        expectedLeft = quad[2];
      }
      expect(expectedLeft, 3000);
      // One batch: every tile shares pipeline, texture, blend and clip.
      expect(sink.batcher.batchCount, 1);
    });

    test('a tile that does not fit runs the flush protocol like any mask', () {
      // Three tiles of 254x100 into a 256x256 atlas: two stack as shelves of
      // 102 rows each, and the third has nowhere to go while the first two are
      // pinned to this frame.
      final atlas = GpuMaskAtlas(width: 256, height: 256);
      var flushes = 0;
      final sink = _sink(maskAtlas: atlas, onAtlasFlush: () => flushes++);
      const Rect clip = Rect.fromLTRB(0, 0, 600, 100);

      sink.drawDevicePath(_rectPath(0, 0, 600, 100), Transform2D.identity, clip,
          _paint(antiAlias: false));

      expect(sink.batcher.quadCount, 3, reason: 'no tile was dropped');
      expect(flushes, 1);
      // The flush split the tiles across two draw calls, which is the point of
      // closing the batch: the first two sample texels the third overwrote.
      expect(sink.batcher.batchCount, 2);
      expect(sink.batcher.batchAt(0).quadCount, 2);
      expect(sink.batcher.batchAt(1).quadCount, 1);
    });
  });
}

// ---------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------

GpuRasterSink _sink({
  GpuMaskAtlas? maskAtlas,
  _SpyAllocator? allocator,
  void Function()? onAtlasFlush,
  int maxDepth = GpuLayerStack.kDefaultMaxLayerDepth,
}) {
  final stack = GpuLayerStack(
    allocator: allocator ?? _SpyAllocator(),
    backendName: 'test',
    maxDepth: maxDepth,
  )..beginFrame(surfaceWidth: 100, surfaceHeight: 100);
  return GpuRasterSink(
    batcher: GpuBatcher()..beginFrame(),
    backendName: 'test',
    maskAtlas: maskAtlas,
    maskTextureId: maskAtlas == null ? 0 : _maskTextureId,
    layerStack: stack,
    onAtlasFlush: onAtlasFlush,
  );
}

Path _rectPath(double left, double top, double right, double bottom) =>
    (PathBuilder()..addRect(Rect.fromLTRB(left, top, right, bottom))).build();

ReplayPaint _paint({
  int argb = 0xFF204080,
  bool antiAlias = true,
  int blendMode = blendModeSrcOver,
}) =>
    ReplayPaint(
      argbColor: argb,
      style: paintStyleFill,
      strokeWidth: 0,
      blendMode: blendMode,
      antiAlias: antiAlias,
    );

/// A layer paint carries its opacity in the alpha channel and nothing else;
/// the colour channels are not a tint and are ignored.
ReplayPaint _layerPaint(int alpha, {int blendMode = blendModeSrcOver}) =>
    _paint(argb: (alpha << 24) | 0xFFFFFF, blendMode: blendMode);

List<double> _quadAt(GpuRasterSink sink, int index) {
  final buffer = sink.batcher.buffer;
  final int first = index * kGpuVerticesPerQuad;
  return <double>[
    buffer.vertexFloat(first, kGpuPositionOffset),
    buffer.vertexFloat(first, kGpuPositionOffset + 1),
    buffer.vertexFloat(first + 2, kGpuPositionOffset),
    buffer.vertexFloat(first + 2, kGpuPositionOffset + 1),
  ];
}

List<double> _uvAt(GpuRasterSink sink, int index) {
  final buffer = sink.batcher.buffer;
  final int first = index * kGpuVerticesPerQuad;
  return <double>[
    buffer.vertexFloat(first, kGpuTexCoordOffset),
    buffer.vertexFloat(first, kGpuTexCoordOffset + 1),
    buffer.vertexFloat(first + 2, kGpuTexCoordOffset),
    buffer.vertexFloat(first + 2, kGpuTexCoordOffset + 1),
  ];
}

List<double> _colorAt(GpuRasterSink sink, int index) {
  final buffer = sink.batcher.buffer;
  final int first = index * kGpuVerticesPerQuad;
  return <double>[
    buffer.vertexFloat(first, kGpuColorOffset),
    buffer.vertexFloat(first, kGpuColorOffset + 1),
    buffer.vertexFloat(first, kGpuColorOffset + 2),
    buffer.vertexFloat(first, kGpuColorOffset + 3),
  ];
}

List<double> _shapeAt(GpuRasterSink sink, int index) {
  final buffer = sink.batcher.buffer;
  final int first = index * kGpuVerticesPerQuad;
  return <double>[
    buffer.vertexFloat(first, kGpuShapeRectOffset),
    buffer.vertexFloat(first, kGpuShapeRectOffset + 1),
    buffer.vertexFloat(first, kGpuShapeRectOffset + 2),
    buffer.vertexFloat(first, kGpuShapeRectOffset + 3),
  ];
}

/// An allocator of integers: what a layer target is, minus the driver.
final class _SpyAllocator implements GpuLayerTargetAllocator {
  final List<GpuLayerTarget> targets = <GpuLayerTarget>[];
  int acquired = 0;
  int released = 0;
  int _next = 1;

  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) {
    acquired++;
    final int id = _next++;
    final target = _FakeTarget(id, 500 + id, width, height);
    targets.add(target);
    return target;
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
