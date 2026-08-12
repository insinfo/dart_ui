/// The GL backend against a real driver, when there is one.
///
/// Everything else under `test/rendering/gpu` runs on a machine with no GPU,
/// which is the right default and is also the reason this file has to exist:
/// a batcher that batches perfectly and a shader that never compiled produce
/// a suite that is green and a renderer that has never drawn a pixel.
///
/// So this is the end-to-end check - open a device, draw, read the pixels
/// back and compare them against what the display list asked for. It skips
/// rather than fails where no driver answers, because "this CI container has
/// no DRM node" is not a defect in the renderer.
///
/// The Windows path goes through `Win32GlSurface`, which is where the window
/// a WGL context needs is allowed to be named. That import is legal here and
/// illegal in `lib/src/rendering`; `test/architecture/layering_test.dart`
/// enforces the difference.
library;

import 'dart:io';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

void main() {
  final session = _GlSession.open();

  group('a live GL device', () {
    tearDownAll(session.close);

    test('reports a vendor, a renderer and a version', () {
      final device = session.device!;
      // Empty strings here mean the context was not actually current when
      // glGetString ran, which is the failure that looks like a working
      // renderer until the first draw.
      expect(device.info.deviceDescription, isNotEmpty);
      expect(device.info.driverVersion, isNotEmpty);
      expect(device.capabilities.maxTextureSize, greaterThanOrEqualTo(2048));
      printOnFailure('${device.info.deviceDescription} / '
          '${device.info.driverVersion}');
    }, skip: session.skipReason);

    test('resolves every entry point the renderer needs', () {
      // The Windows regression this whole change exists for: opengl32.dll
      // exports OpenGL 1.1, so a table built from the export table alone is
      // missing glCreateShader, glGenBuffers and glGenVertexArrays and the
      // renderer can never start.
      expect(missingGlSymbols(session.context!.procAddress), isEmpty);
    }, skip: session.skipReason);

    test('clears to the requested colour', () async {
      final target = session.target(4, 4);
      final list = DisplayList();
      final result =
          await target.renderDisplayList(list, clearColor: 0xFF204060);

      expect(result.status, PresentStatus.presented);
      expect(_pixel(target.framebuffer, 0, 0), <int>[0x20, 0x40, 0x60, 0xFF]);
      target.dispose();
    }, skip: session.skipReason);

    test('draws an aliased rectangle at exactly the pixels asked for',
        () async {
      final target = session.target(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFF3366CC, antiAlias: false);
      list.drawRect(2, 1, 6, 4, paint);
      final result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      final framebuffer = target.framebuffer;
      // Inside, on the boundary and outside. An off-by-one in the projection
      // flip moves the whole rectangle by a row and nothing else notices.
      expect(_pixel(framebuffer, 2, 1), <int>[0x33, 0x66, 0xCC, 0xFF]);
      expect(_pixel(framebuffer, 5, 3), <int>[0x33, 0x66, 0xCC, 0xFF]);
      expect(_pixel(framebuffer, 1, 1), <int>[0, 0, 0, 0xFF]);
      expect(_pixel(framebuffer, 6, 1), <int>[0, 0, 0, 0xFF]);
      expect(_pixel(framebuffer, 2, 4), <int>[0, 0, 0, 0xFF]);
      target.dispose();
    }, skip: session.skipReason);

    test('the analytic coverage antialiases a half-pixel edge', () async {
      final target = session.target(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawRect(2.5, 0, 6, 8, paint);
      await target.renderDisplayList(list, clearColor: 0xFF000000);

      // The shader's boxCoverage on a rect whose left edge cuts column 2 in
      // half. A renderer with no coverage term paints that column either
      // fully white or fully black; both are visible as a hard edge.
      final edge = _pixel(target.framebuffer, 2, 4)[0];
      expect(edge, greaterThan(100));
      expect(edge, lessThan(160));
      expect(_pixel(target.framebuffer, 3, 4)[0], 0xFF);
      expect(_pixel(target.framebuffer, 1, 4)[0], 0);
      target.dispose();
    }, skip: session.skipReason);

    test('an antialiased path goes through the mask atlas', () async {
      final target = session.target(16, 16);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawRRect(2, 2, 14, 14, 4, 4, 4, 4, 4, 4, 4, 4, paint);
      final result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      // The centre is inside the rounded rect and the corner is outside it,
      // which is only true if the alpha8 mask reached the texture.
      expect(_pixel(target.framebuffer, 8, 8)[0], 0xFF);
      expect(_pixel(target.framebuffer, 2, 2)[0], lessThan(0x40));
      target.dispose();
    }, skip: session.skipReason);

    test('a drawn image is uploaded and sampled', () async {
      // The path that threw for every caller until GlImageCache existed: the
      // sink asked for a GpuImageResolver and nothing implemented one.
      final image = Framebuffer.allocate(
        width: 2,
        height: 2,
        format: PixelFormat.rgba8888Premultiplied,
      );
      for (var i = 0; i < 4; i++) {
        image.pixels[i * 4] = 0xFF;
        image.pixels[i * 4 + 1] = 0x00;
        image.pixels[i * 4 + 2] = 0x00;
        image.pixels[i * 4 + 3] = 0xFF;
      }

      final target = session.target(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      final id = list.addImage(image);
      list.drawImage(id, 0, 0, 2, 2, 0, 0, 8, 8, paint);
      final result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      expect(_pixel(target.framebuffer, 4, 4), <int>[0xFF, 0, 0, 0xFF]);
      expect(target.images.length, 1);
      target.dispose();
    }, skip: session.skipReason);

    test('a texture larger than the device allows is refused, not fatal', () {
      final device = session.device!;
      final tooBig = device.capabilities.maxTextureSize + 1;

      expect(
        () => device.createTexture(
          width: tooBig,
          height: 4,
          format: GpuTextureFormat.rgba8888Premultiplied,
        ),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
      // The point of the check: the device is still alive afterwards. Letting
      // GL_INVALID_VALUE mark the device lost turned "this image is too big"
      // into a renderer that could never draw again.
      expect(device.isLost, isFalse);
      final small = device.createTexture(
        width: 4,
        height: 4,
        format: GpuTextureFormat.rgba8888Premultiplied,
      );
      expect(small.isValid, isTrue);
      device.releaseTexture(small);
    }, skip: session.skipReason);

    test('textures carry the filter they were asked for', () {
      final device = session.device!;
      final mask = device.createTexture(
        width: 8,
        height: 8,
        format: GpuTextureFormat.alpha8,
      );
      final image = device.createTexture(
        width: 8,
        height: 8,
        format: GpuTextureFormat.rgba8888Premultiplied,
        filter: GpuTextureFilter.linear,
      );

      expect(mask.filter, GpuTextureFilter.nearest);
      expect(image.filter, GpuTextureFilter.linear);
      device
        ..releaseTexture(mask)
        ..releaseTexture(image);
    }, skip: session.skipReason);
  });
}

/// One GL device for the whole file, or the reason there is none.
///
/// Shared because creating a context costs tens of milliseconds and, on
/// Windows, a window: doing it per test would make the suite's cost depend on
/// how many assertions it contains.
final class _GlSession {
  _GlSession._(this.device, this.context, this.skipReason, this._surface);

  final GlRenderDevice? device;
  final GlContext? context;

  /// Null when the device opened. A string - which `skip:` accepts - when it
  /// did not, so the report names the driver that was missing.
  final String? skipReason;

  final Win32GlSurface? _surface;

  static _GlSession open() {
    try {
      return Platform.isWindows ? _openWindows() : _openEgl();
    } on Object catch (error) {
      return _GlSession._(
          null, null, 'opening a GL device threw: $error', null);
    }
  }

  static _GlSession _openWindows() {
    final attempt = Win32GlSurface.hidden();
    final surface = attempt.surface;
    if (surface == null) {
      return _GlSession._(
          null, null, 'no GL surface: ${attempt.diagnostics.join('; ')}', null);
    }
    final contextAttempt = surface.createContext();
    final context = contextAttempt.context;
    if (context == null) {
      surface.dispose();
      return _GlSession._(null, null,
          'no GL context: ${contextAttempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(context, surface.glLibrary),
        context,
        null,
        surface,
      );
    } on BackendSelectionError catch (error) {
      surface.dispose();
      return _GlSession._(null, null, 'no GL device: $error', null);
    }
  }

  static _GlSession _openEgl() {
    final load = GlLibrary.open();
    if (!load.isLoaded) {
      return _GlSession._(
          null, null, 'no GL library: ${load.attempted.join(', ')}', null);
    }
    final attempt = const GlContextFactory()
        .create(width: 16, height: 16, glLibrary: load.library!);
    final context = attempt.context;
    if (context == null) {
      return _GlSession._(null, null,
          'no EGL context: ${attempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(context, load.library!),
        context,
        null,
        null,
      );
    } on BackendSelectionError catch (error) {
      return _GlSession._(null, null, 'no GL device: $error', null);
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

List<int> _pixel(Framebuffer framebuffer, int x, int y) {
  final offset = y * framebuffer.bytesPerRow + x * 4;
  return <int>[
    framebuffer.pixels[offset],
    framebuffer.pixels[offset + 1],
    framebuffer.pixels[offset + 2],
    framebuffer.pixels[offset + 3],
  ];
}
