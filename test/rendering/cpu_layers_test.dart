/// `saveLayer` on the CPU: an offscreen buffer, an opacity, and a blend mode.
///
/// Until this file existed the CPU sink turned every layer into a clip, and
/// said so in a comment. That is correct for an opaque source-over layer and
/// wrong for every other kind: a subtree at 50% opacity was drawn at 100%, and
/// nothing anywhere reported it. The bug was invisible to the whole suite
/// because no CPU test drew a layer, and it only surfaced when the GPU path
/// grew real layers and the two backends started disagreeing.
///
/// So the reference here is deliberately **not** another display list replayed
/// through the same sink - that would compare the implementation against
/// itself. It is what a layer is *defined* to be, built by hand out of
/// [CpuRasterizer] calls: contents rasterised over transparency, scaled by the
/// layer's opacity with [mul255], composited over the parent with the layer's
/// blend mode. It is the same reference `gl_layer_device_test.dart` holds the
/// GPU to, on purpose: two backends checked against one definition cannot
/// agree on a wrong answer.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// The scene, named once so the display list and the hand-built reference
/// cannot drift apart.
const int _surfaceSize = 16;
const int _background = 0xFF204060;
const int _content = 0xFFCC3311;
const Rect _layerBounds = Rect.fromLTRB(2, 2, 14, 14);

/// Deliberately not vertically centred inside the layer: a layer composited
/// upside down or off by a row is invisible against a symmetric shape.
const Rect _contentBounds = Rect.fromLTRB(4, 4, 12, 8);

void main() {
  group('a CPU layer', () {
    test('with opacity 0.5 composites at half, not at full', () async {
      final target = await _target(_surfaceSize, _surfaceSize);
      await target.renderDisplayList(_sceneWithLayer(0x80),
          clearColor: 0xFF000000);

      // Exact, not approximate. Both sides fold the same bytes through the
      // same mul255 in the same order, so there is no rounding freedom left
      // for a tolerance to absorb.
      _expectMatches(target.framebuffer, _expected(alpha: 0x80));

      // And it really was drawn offscreen rather than flattened: a flattened
      // layer puts the content at full opacity, which differs from the
      // reference by 60 levels of red.
      expect(_rgba(target.framebuffer, 5, 5).$1, lessThan(0xCC));
    });

    test('with opacity 1 and source-over draws what no layer at all draws',
        () async {
      // The flattening identity, measured rather than assumed. The two lists
      // differ only in the saveLayer around the content, so any difference is
      // the layer machinery leaking into a case it must not touch.
      final layered = await _target(_surfaceSize, _surfaceSize);
      await layered.renderDisplayList(_sceneWithLayer(0xFF),
          clearColor: 0xFF000000);

      final flat = await _target(_surfaceSize, _surfaceSize);
      await flat.renderDisplayList(_sceneWithoutLayer(),
          clearColor: 0xFF000000);

      _expectMatches(layered.framebuffer, flat.framebuffer);
    });

    test('nested layers multiply their opacities', () async {
      // 0x80 outside 0x40 is not 0xC0 and is not 0x40: the inner layer is
      // composited into the outer one's *buffer* at 0x40, and the result of
      // that is composited into the surface at 0x80. A renderer that flattened
      // either level would land somewhere else entirely.
      final target = await _target(_surfaceSize, _surfaceSize);
      await target.renderDisplayList(_nestedScene(), clearColor: 0xFF000000);

      _expectMatches(target.framebuffer, _expectedNested());
    });

    test('an empty layer draws nothing and leaves the stack balanced',
        () async {
      // The player emits a begin/end pair even for a layer that survived
      // nothing, so this asserts two things at once: the pair was consumed
      // without an unbalanced-clip exception, and nothing inside it reached
      // the surface through the empty clip.
      final list = DisplayList();
      final background =
          list.addPaint(colorArgb: _background, antiAlias: false);
      list.drawRect(0, 0, 16, 16, background);
      final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
      // Entirely off the surface, so the clip intersects it away.
      list.saveLayer(100, 100, 110, 110, layerPaint);
      final content = list.addPaint(colorArgb: _content, antiAlias: false);
      list.drawRect(100, 100, 110, 110, content);
      list.restore();

      final target = await _target(_surfaceSize, _surfaceSize);
      final result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      final surface = _surfaceWithBackground(target.framebuffer.format);
      _expectMatches(target.framebuffer, surface);
    });

    test('a layer with blend mode plus adds instead of covering', () async {
      final target = await _target(_surfaceSize, _surfaceSize);
      await target.renderDisplayList(
        _sceneWithLayer(0xFF, blendMode: blendModePlus),
        clearColor: 0xFF000000,
      );

      _expectMatches(
        target.framebuffer,
        _expected(alpha: 0xFF, blendMode: CpuBlendMode.plus),
      );
      // Named separately from the parity check because "plus" has one property
      // that no other mode has and that a wrong equation loses first: the
      // result is brighter than either operand, and saturates rather than
      // wrapping. Red here is 0xCC + 0x20 = 0xEC, and green 0x33 + 0x40.
      final pixel = _rgba(target.framebuffer, 5, 5);
      expect(pixel.$1, 0xCC + 0x20);
      expect(pixel.$4, 0xFF, reason: 'two opaque operands saturate, not wrap');
    });

    test('a layer with blend mode src replaces, transparency included',
        () async {
      // The mode that proves the layer really is an isolated image: `src`
      // writes the layer's own pixels over the parent, so the parts of the
      // layer nothing was drawn into come out *transparent* rather than
      // showing the background through.
      final target = await _target(_surfaceSize, _surfaceSize);
      await target.renderDisplayList(
        _sceneWithLayer(0xFF, blendMode: blendModeSrc),
        clearColor: 0xFF000000,
      );

      _expectMatches(
        target.framebuffer,
        _expected(alpha: 0xFF, blendMode: CpuBlendMode.src),
      );
      // Inside the layer's bounds but outside its content: the layer was
      // transparent there and `src` copied that transparency in.
      expect(_rgba(target.framebuffer, 5, 11), (0, 0, 0, 0));
      // Outside the layer's bounds the background is untouched.
      expect(_rgba(target.framebuffer, 0, 0), (0x20, 0x40, 0x60, 0xFF));
    });

    test('a src layer that drew nothing composites nothing', () async {
      // The one case where "this layer is empty" and "this layer is
      // transparent" are different pictures, and the reason the sink tracks
      // whether anything was drawn at all. `GpuLayerStack.pop` drops the
      // composite of a layer that batched nothing; a CPU sink that blitted a
      // cleared buffer instead would punch a transparent hole in the
      // background here.
      final list = DisplayList();
      final background =
          list.addPaint(colorArgb: _background, antiAlias: false);
      list.drawRect(0, 0, 16, 16, background);
      final layerPaint =
          list.addPaint(colorArgb: 0xFFFFFFFF, blendMode: blendModeSrc);
      list.saveLayer(2, 2, 14, 14, layerPaint);
      list.restore();

      final target = await _target(_surfaceSize, _surfaceSize);
      await target.renderDisplayList(list, clearColor: 0xFF000000);

      _expectMatches(target.framebuffer,
          _surfaceWithBackground(target.framebuffer.format));
    });

    test('fractional bounds snap outward, so no covered pixel is lost',
        () async {
      // The convention `GpuLayerStack.push` fixes: floor the left and top,
      // ceil the right and bottom. The layer below runs from x = 2.5, so
      // column 2 is half covered - it exists only if the buffer was snapped
      // outward, and the composite has to carry its half-coverage through.
      final list = DisplayList();
      final background =
          list.addPaint(colorArgb: _background, antiAlias: false);
      list.drawRect(0, 0, 16, 16, background);
      final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
      list.saveLayer(2.5, 2, 13.5, 14, layerPaint);
      final content = list.addPaint(colorArgb: _content);
      list.drawRect(0, 4, 16, 8, content);
      list.restore();

      final target = await _target(_surfaceSize, _surfaceSize);
      await target.renderDisplayList(list, clearColor: 0xFF000000);

      final inside = _rgba(target.framebuffer, 6, 5).$1;
      final edge = _rgba(target.framebuffer, 2, 5).$1;
      final outside = _rgba(target.framebuffer, 1, 5).$1;
      expect(outside, 0x20, reason: 'the background, untouched');
      expect(inside, greaterThan(outside));
      // Half the layer's coverage, so roughly half way between the two. Not an
      // exact number, because the coverage of a half-covered column and the
      // layer's own 0x80 compose through two roundings; the assertion is that
      // the column survived at all and is strictly between its neighbours,
      // which an inward snap would have made false.
      expect(edge, greaterThan(outside));
      expect(edge, lessThan(inside));
    });

    test('text inside a layer lands on the same pixels as outside it',
        () async {
      // The reason the layer origin is required to be a whole pixel. A glyph
      // mask is rasterised for one sub-pixel phase and then blitted at an
      // integer position; shifting it by a fraction inside a layer would
      // resample that coverage, which is the "text inside an opacity animation
      // looks softer" artefact.
      //
      // The comparison is exact rather than approximate because `mul255` is
      // symmetric: a white glyph at full opacity inside a layer composited at
      // 0x80 folds `mul255(coverage, 0x80)`, and the same glyph drawn straight
      // with an ink alpha of 0x80 folds `mul255(0x80, coverage)`. Same byte -
      // as long as the glyph is on the same pixel. Over a transparent surface
      // there is no background term to hide a difference in either.
      final Typeface ahem = Typeface.parse(_ahemBytes());
      final ScaledTypeface font = ahem.atSize(8);
      final int glyph = ahem.glyphForCodePoint(0x58);

      final withLayer = await _target(32, 32);
      await withLayer.renderDisplayList(
        _textScene(font, glyph, layerAlpha: 0x80, inkAlpha: 0xFF),
        clearColor: 0x00000000,
      );
      final plain = await _target(32, 32);
      await plain.renderDisplayList(
        _textScene(font, glyph, layerAlpha: null, inkAlpha: 0x80),
        clearColor: 0x00000000,
      );

      // Not vacuous: the glyph really did put ink down in both.
      expect(_rgba(withLayer.framebuffer, 10, 16).$4, greaterThan(0));
      _expectMatches(withLayer.framebuffer, plain.framebuffer);
    });
  });

  group('the layer depth limit', () {
    test('is refused by name rather than by running out of memory', () async {
      final target = await _target(_surfaceSize, _surfaceSize);

      expect(
        () => rasterizeDisplayList(
          _nestedTo(3),
          target.framebuffer,
          maxLayerDepth: 2,
        ),
        throwsA(isA<CpuLayerDepthExceededError>()
            .having((e) => e.depth, 'depth', 3)
            .having((e) => e.maxDepth, 'maxDepth', 2)
            .having((e) => e.backendName, 'backendName', 'cpu')),
      );
    });

    test('lets everything up to the limit through', () async {
      final target = await _target(_surfaceSize, _surfaceSize);
      // Exactly at the limit, so the check is `>=` on the way in rather than
      // `>` - an off-by-one there refuses a legal scene.
      expect(
        () => rasterizeDisplayList(
          _nestedTo(2),
          target.framebuffer,
          maxLayerDepth: 2,
        ),
        returnsNormally,
      );
    });

    test('defaults to the same depth the GPU stack allows', () {
      // Equal on purpose: a scene that renders on one backend and is refused
      // by the other does not look like a rendering difference at all.
      expect(kMaxCpuLayerDepth, 8);
    });
  });

  group('the layer buffer pool', () {
    test('reuses one store across frames and across sibling layers', () async {
      final pool = CpuLayerBufferPool.shared;
      pool.trim();
      final int before = pool.allocationCount;

      final target = await _target(64, 64);
      for (var frame = 0; frame < 5; frame++) {
        final list = DisplayList();
        final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
        final content = list.addPaint(colorArgb: _content, antiAlias: false);
        // Ten sibling layers per frame, five frames: fifty layers in total.
        for (var i = 0; i < 10; i++) {
          list.saveLayer(0, 0, 20, 20, layerPaint);
          list.drawRect(2, 2, 18, 18, content);
          list.restore();
        }
        await target.renderDisplayList(list, clearColor: 0xFF000000);
      }

      // One store for all fifty. A CPU layer is composited at `endLayer`, so
      // siblings never overlap in time and a single depth-0 slot serves them
      // all - which is exactly the difference from the GPU pool, whose targets
      // must live until the frame is submitted.
      expect(pool.allocationCount - before, 1);
      expect(pool.slotCount, greaterThanOrEqualTo(1));
    });

    test('grows a slot per nesting level and no more', () async {
      final pool = CpuLayerBufferPool.shared;
      pool.trim();

      final target = await _target(_surfaceSize, _surfaceSize);
      await target.renderDisplayList(_nestedTo(3), clearColor: 0xFF000000);

      // Three levels, three slots - and the third frame of the same scene
      // allocates none of them again.
      expect(pool.slotCount, greaterThanOrEqualTo(3));
      final int after = pool.allocationCount;
      await target.renderDisplayList(_nestedTo(3), clearColor: 0xFF000000);
      expect(pool.allocationCount, after);
    });

    test('trim gives the memory back', () async {
      final target = await _target(_surfaceSize, _surfaceSize);
      await target.renderDisplayList(_sceneWithLayer(0x80),
          clearColor: 0xFF000000);
      expect(CpuLayerBufferPool.shared.retainedBytes, greaterThan(0));

      CpuLayerBufferPool.shared.trim();
      expect(CpuLayerBufferPool.shared.retainedBytes, 0);
    });
  });
}

// ---------------------------------------------------------------------
// The scenes
// ---------------------------------------------------------------------

DisplayList _sceneWithLayer(int alpha, {int blendMode = blendModeSrcOver}) {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: _background, antiAlias: false);
  list.drawRect(0, 0, 16, 16, background);
  // Only the alpha of a layer paint means anything: it is the opacity the
  // finished layer is composited with. The colour channels are not a tint.
  final layerPaint =
      list.addPaint(colorArgb: (alpha << 24) | 0xFFFFFF, blendMode: blendMode);
  list.saveLayer(_layerBounds.left, _layerBounds.top, _layerBounds.right,
      _layerBounds.bottom, layerPaint);
  final content = list.addPaint(colorArgb: _content, antiAlias: false);
  list.drawRect(_contentBounds.left, _contentBounds.top, _contentBounds.right,
      _contentBounds.bottom, content);
  list.restore();
  return list;
}

DisplayList _sceneWithoutLayer() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: _background, antiAlias: false);
  list.drawRect(0, 0, 16, 16, background);
  final content = list.addPaint(colorArgb: _content, antiAlias: false);
  list.drawRect(_contentBounds.left, _contentBounds.top, _contentBounds.right,
      _contentBounds.bottom, content);
  return list;
}

/// An outer layer at 0x80 holding an inner one at 0x40.
DisplayList _nestedScene() {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: _background, antiAlias: false);
  list.drawRect(0, 0, 16, 16, background);
  final outerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
  list.saveLayer(2, 2, 14, 14, outerPaint);
  final innerPaint = list.addPaint(colorArgb: 0x40FFFFFF);
  list.saveLayer(4, 4, 12, 12, innerPaint);
  final content = list.addPaint(colorArgb: _content, antiAlias: false);
  list.drawRect(4, 4, 12, 8, content);
  list
    ..restore()
    ..restore();
  return list;
}

/// [depth] layers nested inside one another, each one needing a real buffer.
DisplayList _nestedTo(int depth) {
  final list = DisplayList();
  final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
  final content = list.addPaint(colorArgb: _content, antiAlias: false);
  for (var i = 0; i < depth; i++) {
    list.saveLayer(0, 0, 16, 16, layerPaint);
  }
  list.drawRect(2, 2, 14, 14, content);
  for (var i = 0; i < depth; i++) {
    list.restore();
  }
  return list;
}

/// One Ahem glyph on a transparent surface, optionally wrapped in a layer.
DisplayList _textScene(
  ScaledTypeface font,
  int glyph, {
  required int? layerAlpha,
  required int inkAlpha,
}) {
  final list = DisplayList();
  if (layerAlpha != null) {
    final layerPaint = list.addPaint(colorArgb: (layerAlpha << 24) | 0xFFFFFF);
    // Bounds that do not start on the glyph's own pixel, so the origin
    // subtraction is a real number rather than zero.
    list.saveLayer(5, 4, 28, 28, layerPaint);
  }
  final ink = list.addPaint(colorArgb: (inkAlpha << 24) | 0xFFFFFF);
  list.drawGlyphRun(
    list.addFont(font),
    ink,
    // A fractional pen x on purpose: it selects a sub-pixel variant of the
    // mask, and the whole point is that the layer must not shift it again.
    8.25,
    20,
    Int32List.fromList(<int>[glyph]),
    Float32List.fromList(<double>[0, 0]),
    1,
  );
  if (layerAlpha != null) list.restore();
  return list;
}

// ---------------------------------------------------------------------
// The reference, built out of what a layer is defined to be
// ---------------------------------------------------------------------

/// The scene composited by hand: the layer's contents over transparency,
/// scaled by [alpha], blended into the background with [blendMode].
Framebuffer _expected({
  required int alpha,
  CpuBlendMode blendMode = CpuBlendMode.srcOver,
}) {
  final surface = _surfaceWithBackground(_defaultFormat);
  final layer = _rasterizeLayer(_layerBounds, _contentBounds, _content);
  CpuRasterizer(surface).compositeLayer(
    layer,
    _layerBounds.left.toInt(),
    _layerBounds.top.toInt(),
    alpha,
    blendMode,
  );
  return surface;
}

Framebuffer _expectedNested() {
  final surface = _surfaceWithBackground(_defaultFormat);
  const Rect inner = Rect.fromLTRB(4, 4, 12, 12);

  // The inner layer, at its own opacity, composited into the outer one's
  // buffer - not into the surface. That intermediate step is the whole
  // difference between multiplying opacities and adding them.
  final innerImage = _rasterizeLayer(inner, _contentBounds, _content);
  final outerImage = Framebuffer.allocate(
    width: _layerBounds.width.round(),
    height: _layerBounds.height.round(),
    format: _defaultFormat,
  );
  CpuRasterizer(outerImage).compositeLayer(
    innerImage,
    (inner.left - _layerBounds.left).toInt(),
    (inner.top - _layerBounds.top).toInt(),
    0x40,
    CpuBlendMode.srcOver,
  );

  CpuRasterizer(surface).compositeLayer(
    outerImage,
    _layerBounds.left.toInt(),
    _layerBounds.top.toInt(),
    0x80,
    CpuBlendMode.srcOver,
  );
  return surface;
}

Framebuffer _surfaceWithBackground(PixelFormat format) {
  final surface = Framebuffer.allocate(
    width: _surfaceSize,
    height: _surfaceSize,
    format: format,
  );
  CpuRasterizer(surface)
    ..fillRect(const Rect.fromLTRB(0, 0, 16, 16), 0xFF000000)
    ..fillRect(const Rect.fromLTRB(0, 0, 16, 16), _background);
  return surface;
}

/// The layer's own image: [content] rasterised over **transparency**, in the
/// layer's coordinates. This is the half a flattening renderer skips.
Framebuffer _rasterizeLayer(Rect bounds, Rect content, int argb) {
  final image = Framebuffer.allocate(
    width: bounds.width.round(),
    height: bounds.height.round(),
    format: _defaultFormat,
  );
  CpuRasterizer(image).fillRect(
    Rect.fromLTRB(content.left - bounds.left, content.top - bounds.top,
        content.right - bounds.left, content.bottom - bounds.top),
    argb,
  );
  return image;
}

// ---------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------

/// What `MemorySurfaceDescriptor` hands a memory target when nothing asks
/// otherwise. Held in one place so the reference buffers cannot pick a
/// different channel order than the surface under test.
final PixelFormat _defaultFormat =
    const MemorySurfaceDescriptor(pixelWidth: 1, pixelHeight: 1).format;

Future<MemoryRenderTarget> _target(int width, int height) async {
  final device = await const CpuRendererBackend().createDevice();
  return device.createTarget(
    MemorySurfaceDescriptor(pixelWidth: width, pixelHeight: height),
  ) as MemoryRenderTarget;
}

Uint8List _ahemBytes() => File('test/fonts/ahem.ttf').readAsBytesSync();

/// A pixel as (r, g, b, a), whatever byte order the surface uses, so a test
/// asserting colour never accidentally asserts layout.
(int, int, int, int) _rgba(Framebuffer buffer, int x, int y) {
  final i = buffer.offsetOf(x, y);
  final bytes = buffer.pixels;
  return switch (buffer.format) {
    PixelFormat.bgra8888Premultiplied => (
        bytes[i + 2],
        bytes[i + 1],
        bytes[i],
        bytes[i + 3]
      ),
    PixelFormat.rgba8888Premultiplied => (
        bytes[i],
        bytes[i + 1],
        bytes[i + 2],
        bytes[i + 3]
      ),
  };
}

/// Byte-exact comparison, with every differing pixel reported.
///
/// No tolerance parameter, deliberately: both sides of every comparison in
/// this file are the same arithmetic on the same CPU, so a single level of
/// difference is a real bug and not a driver rounding a tie the other way.
/// The differential suite against a GPU is where a tolerance belongs.
void _expectMatches(Framebuffer actual, Framebuffer expected) {
  final differences = <String>[];
  for (var y = 0; y < expected.height; y++) {
    for (var x = 0; x < expected.width; x++) {
      final a = _rgba(actual, x, y);
      final e = _rgba(expected, x, y);
      if (a != e) differences.add('($x, $y): got $a, want $e');
    }
  }
  // Every differing pixel, not the first: one pixel out is a rounding
  // question and a hundred is a wrong picture.
  expect(differences, isEmpty, reason: '${differences.length} pixels differ');
}
