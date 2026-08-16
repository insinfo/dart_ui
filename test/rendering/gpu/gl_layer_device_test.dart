/// Layers on a real driver, against what the CPU rasteriser produces.
///
/// This is the test that outranks every other one in this directory. The
/// device-independent tests assert that the sink emits a quad with the right
/// corners, the right texture coordinates and an opacity of 0.5 in four
/// channels - all of which can be perfectly true while the picture is upside
/// down, blended twice, or composited against the wrong background. Only a
/// readback answers that, and only a readback compared against an independent
/// implementation answers whether the *number* in each channel is right.
///
/// The reference is built with [CpuRasterizer] directly rather than by
/// replaying the same display list through `MemoryRenderTarget`, and that is
/// not a shortcut - it is the whole point. The CPU *sink* flattens a layer
/// exactly the way the GPU sink used to, so replaying the list through it
/// would compare one renderer's bug against another's and agree. The reference
/// here is what a layer is *defined* to be: contents rasterised over
/// transparency, scaled by the layer's opacity, composited over the parent.
///
/// It skips rather than fails where no driver answers, because "this machine
/// has no GPU" is not a defect in the renderer.
library;

import 'dart:io';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/raster/blend.dart';
import 'package:dart_ui/src/rendering/raster/rasterizer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

/// The scene, named once so the GPU list and the CPU reference cannot drift.
const int _surfaceSize = 16;
const int _background = 0xFF204060;
const int _content = 0xFFCC3311;
const Rect _layerBounds = Rect.fromLTRB(2, 2, 14, 14);

/// Deliberately **not** vertically centred inside the layer. A layer composited
/// upside down - the failure an FBO's bottom-left origin produces if the
/// projection is not inverted - is invisible against a symmetric shape, and
/// this is exactly the bug the orientation convention exists to prevent.
const Rect _contentBounds = Rect.fromLTRB(4, 4, 12, 8);

void main() {
  final session = _GlSession.open();

  group('a layer on a live GL device', () {
    tearDownAll(session.close);

    test('with opacity 0.5 matches the CpuRasterizer pixel for pixel',
        () async {
      final target = session.target(_surfaceSize, _surfaceSize);
      final result = await target.renderDisplayList(
        _sceneWithLayer(0x80),
        clearColor: 0xFF000000,
      );
      expect(result.status, PresentStatus.presented);

      final expected = _expectedWithLayer(0x80);
      // One level of tolerance, and it was not needed: on the driver this was
      // written against every one of the 256 pixels matches the CPU reference
      // *exactly*, in all four channels. The tolerance is there because the
      // two do the arithmetic differently - the CPU folds a byte through
      // mul255 and the GPU multiplies floats and rounds once at the end - and
      // a driver that rounds a blend the other way at a tie is allowed to.
      // Anything larger than a level is a real difference, not rounding.
      _expectMatches(target.framebuffer, expected, tolerance: 1);

      // And the layer really was drawn offscreen rather than flattened: a
      // flattened one would put the content at full opacity, which differs
      // from the reference by 60 levels in the red channel.
      final actual = _pixel(target.framebuffer, 5, 5);
      expect(actual[0], lessThan(0xCC));
      target.dispose();
    }, skip: session.skipReason);

    test('is not composited upside down', () async {
      // Stated separately from the parity test because it is the one failure
      // an orientation mistake produces, and reading "some pixels differ" off
      // a 16x16 diff is not the same as being told which way up it is.
      final target = session.target(_surfaceSize, _surfaceSize);
      await target.renderDisplayList(
        _sceneWithLayer(0x80),
        clearColor: 0xFF000000,
      );

      // The content occupies device rows 4..7 and nothing below row 8.
      final inside = _pixel(target.framebuffer, 8, 5);
      final below = _pixel(target.framebuffer, 8, 10);
      final background = _pixel(target.framebuffer, 8, 15);
      expect(inside[0], greaterThan(below[0] + 20),
          reason: 'the top half of the layer carries the ink');
      expect(below, background,
          reason: 'the bottom half of the layer is empty, so it is background');
      target.dispose();
    }, skip: session.skipReason);

    test('with opacity 1 and source-over draws what no layer at all draws',
        () async {
      // The flattening identity, measured rather than asserted: the two lists
      // differ only in the saveLayer around the content.
      final withLayer = session.target(_surfaceSize, _surfaceSize);
      await withLayer.renderDisplayList(_sceneWithLayer(0xFF),
          clearColor: 0xFF000000);
      final layered = _copy(withLayer.framebuffer);
      withLayer.dispose();

      final flat = session.target(_surfaceSize, _surfaceSize);
      await flat.renderDisplayList(_sceneWithoutLayer(),
          clearColor: 0xFF000000);
      _expectMatches(flat.framebuffer, layered, tolerance: 0);
      flat.dispose();
    }, skip: session.skipReason);

    test('nested layers multiply their opacities the way the CPU does',
        () async {
      final target = session.target(_surfaceSize, _surfaceSize);
      final result = await target.renderDisplayList(
        _nestedScene(),
        clearColor: 0xFF000000,
      );
      expect(result.status, PresentStatus.presented);
      // Two roundings on each side rather than one, and still exact on this
      // driver; see the tolerance note on the single-layer test.
      _expectMatches(target.framebuffer, _expectedNested(), tolerance: 1);
      expect(target.layers.depth, 0, reason: 'balanced begin/end');
      target.dispose();
    }, skip: session.skipReason);

    test('the same layer on ten frames creates one framebuffer', () async {
      // The pool's whole reason to exist, and invisible from the pixels: a
      // pool that allocated per frame would produce identical output and a
      // stuttering frame time.
      final target = session.target(_surfaceSize, _surfaceSize);
      for (var frame = 0; frame < 10; frame++) {
        await target.renderDisplayList(_sceneWithLayer(0x80),
            clearColor: 0xFF000000);
      }

      expect(target.layerPool.createCount, 1);
      expect(target.layerPool.reuseCount, 9);
      expect(target.layerPool.deleteCount, 0);
      // 12x12 rounds up to the 16 px size class per axis.
      expect(target.layerPool.idleCount, 1);
      target.dispose();
    }, skip: session.skipReason);

    test('a layer whose bounds moved by a pixel still reuses its target',
        () async {
      final target = session.target(_surfaceSize, _surfaceSize);
      for (var frame = 0; frame < 5; frame++) {
        final list = DisplayList();
        final background =
            list.addPaint(colorArgb: _background, antiAlias: false);
        list.drawRect(0, 0, 16, 16, background);
        final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
        // A layout animation moving a fraction of a pixel: the bounds snap
        // outward to a different whole-pixel size on alternate frames.
        list.saveLayer(2 + frame * 0.25, 2, 13, 13, layerPaint);
        final content = list.addPaint(colorArgb: _content, antiAlias: false);
        list.drawRect(4, 4, 12, 8, content);
        list.restore();
        await target.renderDisplayList(list, clearColor: 0xFF000000);
      }

      expect(target.layerPool.createCount, 1,
          reason: 'the size class is what the pool matches on');
      target.dispose();
    }, skip: session.skipReason);

    test('a layer is disposed without leaking its framebuffers', () async {
      final target = session.target(_surfaceSize, _surfaceSize);
      await target.renderDisplayList(_sceneWithLayer(0x80),
          clearColor: 0xFF000000);
      expect(target.layerPool.liveBytes, greaterThan(0));

      target.dispose();
      expect(target.layerPool.liveBytes, 0);
      expect(target.layerPool.idleCount, 0);
      expect(session.device!.isLost, isFalse);
    }, skip: session.skipReason);
  });
}

// ---------------------------------------------------------------------
// The scene, twice: once as a display list, once as CPU rasteriser calls
// ---------------------------------------------------------------------

DisplayList _sceneWithLayer(int alpha) {
  final list = DisplayList();
  final background = list.addPaint(colorArgb: _background, antiAlias: false);
  list.drawRect(0, 0, 16, 16, background);
  // Only the alpha of a layer paint means anything: it is the opacity the
  // finished layer is composited with. The colour channels are not a tint.
  final layerPaint = list.addPaint(colorArgb: (alpha << 24) | 0xFFFFFF);
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

/// A layer at [alpha] over the background, composited by hand out of the parts
/// a layer is defined as.
Framebuffer _expectedWithLayer(int alpha) {
  final surface = _surfaceWithBackground();
  final layer = _rasterizeLayer(_layerBounds, _contentBounds, _content);
  _scale(layer, alpha);
  CpuRasterizer(surface).drawFramebuffer(
    layer,
    Rect.fromLTWH(_layerBounds.left, _layerBounds.top, _layerBounds.width,
        _layerBounds.height),
  );
  return surface;
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
  list.restore();
  list.restore();
  return list;
}

Framebuffer _expectedNested() {
  final surface = _surfaceWithBackground();
  const Rect inner = Rect.fromLTRB(4, 4, 12, 12);

  // The inner layer, at its own opacity, composited into the outer one.
  final innerImage = _rasterizeLayer(inner, _contentBounds, _content);
  _scale(innerImage, 0x40);
  final outerImage = Framebuffer.allocate(
    width: _layerBounds.width.round(),
    height: _layerBounds.height.round(),
    format: PixelFormat.rgba8888Premultiplied,
  );
  CpuRasterizer(outerImage).drawFramebuffer(
    innerImage,
    Rect.fromLTWH(inner.left - _layerBounds.left, inner.top - _layerBounds.top,
        inner.width, inner.height),
  );

  _scale(outerImage, 0x80);
  CpuRasterizer(surface).drawFramebuffer(
    outerImage,
    Rect.fromLTWH(_layerBounds.left, _layerBounds.top, _layerBounds.width,
        _layerBounds.height),
  );
  return surface;
}

Framebuffer _surfaceWithBackground() {
  final surface = Framebuffer.allocate(
    width: _surfaceSize,
    height: _surfaceSize,
    format: PixelFormat.rgba8888Premultiplied,
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
    format: PixelFormat.rgba8888Premultiplied,
  );
  CpuRasterizer(image).fillRect(
    Rect.fromLTRB(content.left - bounds.left, content.top - bounds.top,
        content.right - bounds.left, content.bottom - bounds.top),
    argb,
  );
  return image;
}

/// Scales a premultiplied image by [alpha], which is what compositing a layer
/// at an opacity does to it: all four channels, because the image already
/// carries its own alpha.
void _scale(Framebuffer image, int alpha) {
  for (var i = 0; i < image.pixels.length; i++) {
    image.pixels[i] = mul255(image.pixels[i], alpha);
  }
}

// ---------------------------------------------------------------------
// Comparison and session plumbing
// ---------------------------------------------------------------------

void _expectMatches(
  Framebuffer actual,
  Framebuffer expected, {
  required int tolerance,
}) {
  final differences = <String>[];
  for (var y = 0; y < expected.height; y++) {
    for (var x = 0; x < expected.width; x++) {
      final a = _pixel(actual, x, y);
      final e = _pixel(expected, x, y);
      for (var c = 0; c < 4; c++) {
        if ((a[c] - e[c]).abs() > tolerance) {
          differences.add('($x, $y): got $a, want $e');
          break;
        }
      }
    }
  }
  // Every differing pixel, not the first: one pixel out is a rounding
  // question and a hundred is a wrong picture, and the two need different
  // investigations.
  expect(differences, isEmpty,
      reason: '${differences.length} pixels differ by more than $tolerance');
}

Framebuffer _copy(Framebuffer source) {
  final copy = Framebuffer.allocate(
    width: source.width,
    height: source.height,
    format: source.format,
  );
  copy.pixels.setRange(0, copy.pixels.length, source.pixels);
  return copy;
}

List<int> _pixel(Framebuffer framebuffer, int x, int y) {
  final offset = y * framebuffer.bytesPerRow + x * 4;
  return <int>[
    framebuffer.pixels[offset],
    framebuffer.pixels[offset + 1],
    framebuffer.pixels[offset + 2],
    framebuffer.pixels[offset + 3],
  ];
}

/// One GL device for the whole file, or the reason there is none. The same
/// shape as `gl_device_test.dart`'s, for the same reason: a context costs tens
/// of milliseconds and, on Windows, a window.
final class _GlSession {
  _GlSession._(this.device, this.skipReason, this._surface);

  final GlRenderDevice? device;
  final String? skipReason;
  final Win32GlSurface? _surface;

  static _GlSession open() {
    try {
      return Platform.isWindows ? _openWindows() : _openEgl();
    } on Object catch (error) {
      return _GlSession._(null, 'opening a GL device threw: $error', null);
    }
  }

  static _GlSession _openWindows() {
    final attempt = Win32GlSurface.hidden();
    final surface = attempt.surface;
    if (surface == null) {
      return _GlSession._(
          null, 'no GL surface: ${attempt.diagnostics.join('; ')}', null);
    }
    final contextAttempt = surface.createContext();
    final context = contextAttempt.context;
    if (context == null) {
      surface.dispose();
      return _GlSession._(null,
          'no GL context: ${contextAttempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(context, surface.glLibrary),
        null,
        surface,
      );
    } on BackendSelectionError catch (error) {
      surface.dispose();
      return _GlSession._(null, 'no GL device: $error', null);
    }
  }

  static _GlSession _openEgl() {
    final load = GlLibrary.open();
    if (!load.isLoaded) {
      return _GlSession._(
          null, 'no GL library: ${load.attempted.join(', ')}', null);
    }
    final attempt = const GlContextFactory()
        .create(width: 16, height: 16, glLibrary: load.library!);
    final context = attempt.context;
    if (context == null) {
      return _GlSession._(
          null, 'no EGL context: ${attempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(context, load.library!),
        null,
        null,
      );
    } on BackendSelectionError catch (error) {
      return _GlSession._(null, 'no GL device: $error', null);
    }
  }

  GlOffscreenTarget target(int width, int height) =>
      device!.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.rgba8888Premultiplied,
      )) as GlOffscreenTarget;

  void close() {
    device?.dispose();
    _surface?.dispose();
  }
}
