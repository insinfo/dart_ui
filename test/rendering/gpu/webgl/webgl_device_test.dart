@TestOn('browser')

/// The WebGL2 device and its targets: the things parity cannot see.
///
/// A parity suite compares pixels, so everything it checks is something that
/// shows up in an image. This file is for the claims that do not: whether the
/// layer pool actually pools, whether the probe answers rather than throwing,
/// whether a resize invalidates the generation, and whether a lost context is
/// reported as lost instead of silently drawing nothing.
///
/// That last one is the reason this file matters most on this platform. On a
/// lost WebGL context every entry point is *defined* to become a no-op that
/// raises nothing, so a backend that forgot to ask `isContextLost()` would
/// issue a whole frame of draws into nowhere, report success, and present an
/// empty canvas - which reads as a bug in the scene. There is a test below that
/// takes the context away on purpose and asserts the device notices.
///
/// See `webgl_session.dart` for the skip contract; the short form is that
/// `@TestOn('browser')` keeps this file out of the CI run entirely, and
/// [WebGlSession.skipReason] keeps it honest inside a browser that has no GPU.
library;

import 'dart:js_interop';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_framebuffer_pool.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import 'webgl_session.dart';

void main() {
  final WebGlSession session = WebGlSession.open();
  tearDownAll(session.close);

  /// Skips the calling test when there is no device, naming the reason.
  bool ready() {
    final String? reason = session.skipReason;
    if (reason == null) return true;
    printOnFailure('skipped: $reason');
    markTestSkipped('no WebGL2 device: $reason');
    return false;
  }

  group('the backend probe', () {
    test('answers instead of throwing, whatever the browser says', () {
      // Never throws is the whole contract - section 6.6 - and it holds even
      // in a browser with WebGL disabled, which is why this one does not need
      // a device and is not skipped.
      late BackendProbeResult result;
      expect(
        () => result = const WebGlRendererBackend().probe(),
        returnsNormally,
      );
      expect(result.backendName, 'webgl2');
      expect(
        result.diagnostics,
        isNotEmpty,
        reason: 'supported or not, the probe has to say something a bug '
            'report can carry',
      );
      printOnFailure(result.describe());
    });

    test('names the adapter when it is supported', () {
      if (!ready()) return;
      final BackendProbeResult result = const WebGlRendererBackend().probe();
      expect(result.supported, isTrue);
      expect(result.supports(Capability.gpuPresentation), isTrue);
      // The unmasked renderer string is what makes a bug report actionable;
      // the masked one is the constant "WebKit WebGL" in several browsers.
      printOnFailure(result.describe());
    });

    test('claims both the descriptors it can build a target for', () {
      const WebGlRendererBackend backend = WebGlRendererBackend();
      expect(
        backend.supportsSurface(const MemorySurfaceDescriptor(
          pixelWidth: 4,
          pixelHeight: 4,
        )),
        isTrue,
      );
      final web.HTMLCanvasElement canvas =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      expect(
        backend.supportsSurface(WebGlCanvasSurfaceDescriptor(
          canvas: canvas,
          generation: GenerationToken(),
        )),
        isTrue,
      );
    });
  });

  group('the device', () {
    test('reports a texture size the specification allows', () {
      if (!ready()) return;
      final RendererCapabilities capabilities = session.device!.capabilities;
      expect(
        capabilities.maxTextureSize,
        greaterThanOrEqualTo(2048),
        reason: 'WebGL2 mandates at least 2048',
      );
      // Partial present is false because a canvas is composited whole and
      // `preserveDrawingBuffer` is off, so there is nothing to preserve.
      expect(capabilities.supportsPartialPresent, isFalse);
      // The antialiasing is analytic, and the context asks for antialias:false
      // precisely so a multisampled buffer cannot add a second, disagreeing
      // one on top.
      expect(capabilities.supportsMsaa, isFalse);
      expect(
        capabilities.supportsFormat(PixelFormat.rgba8888Premultiplied),
        isTrue,
      );
    });

    test('refuses a descriptor it cannot present to, by name', () {
      if (!ready()) return;
      expect(
        () => session.device!.createTarget(_ForeignSurface()),
        throwsA(
          isA<UnsupportedCapabilityError>().having(
            (UnsupportedCapabilityError e) => '$e',
            'message',
            contains('WebGlCanvasTarget'),
          ),
        ),
        reason: 'a silent fallback to an offscreen target would render the '
            'frame perfectly and show it nowhere, which reads as a bug in the '
            'scene rather than in the backend',
      );
    });

    test('refuses a texture larger than the context allows', () {
      if (!ready()) return;
      final int limit = session.device!.capabilities.maxTextureSize;
      expect(
        () => session.device!.createTexture(
          width: limit + 1,
          height: 4,
          format: GpuTextureFormat.rgba8888Premultiplied,
        ),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
    });
  });

  group('the offscreen target', () {
    test('presents, and its readback is not blank', () async {
      if (!ready()) return;
      final WebGlOffscreenTarget target = session.target(16, 16);
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF3366CC, antiAlias: false);
      list.drawRect(2, 2, 14, 14, paint);
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      // The pixel at the centre is the one the rectangle covers. Checked
      // because a target that presented successfully and drew nothing is the
      // failure a lost context produces.
      final int offset = target.framebuffer.offsetOf(8, 8);
      expect(
        target.framebuffer.pixels[offset],
        isNot(0),
        reason: 'the readback is black, so nothing was drawn',
      );
      target.dispose();
    });

    test('a resize bumps the generation, so a frame in flight is dropped',
        () async {
      if (!ready()) return;
      final WebGlOffscreenTarget target = session.target(8, 8);
      final Frame frame = target.beginFrame(const FrameRequest());
      final int before = target.generation;
      target.resize(16, 16, 1);
      expect(target.generation, greaterThan(before));
      final PresentResult result = await target.present(frame);
      expect(
        result.status,
        PresentStatus.stale,
        reason: 'a frame recorded for the old size must be dropped, not drawn '
            'into a surface that moved',
      );
      target.dispose();
    });
  });

  group('the layer pool', () {
    test('rounds sizes into buckets rather than keying on the exact size', () {
      // Pure arithmetic, so it needs no device and never skips. The rule it
      // encodes is why a scrolling list asking for 300x81 then 300x82 hits the
      // pool instead of allocating twice.
      expect(webGlLayerBucket(1), 16);
      expect(webGlLayerBucket(16), 16);
      expect(webGlLayerBucket(17), 32);
      expect(webGlLayerBucket(81), 128);
      expect(webGlLayerBucket(82), 128,
          reason: '81 and 82 must land in one bucket');
      expect(webGlLayerBucket(300), 512);
    });

    test('the same layer drawn twice creates one framebuffer', () async {
      if (!ready()) return;
      final WebGlOffscreenTarget target = session.target(24, 24);
      DisplayList scene() {
        final DisplayList list = DisplayList();
        final int layerPaint =
            list.addPaint(colorArgb: 0x80FFFFFF, antiAlias: false);
        final int fill = list.addPaint(colorArgb: 0xFFEE7711, antiAlias: false);
        list
          ..saveLayer(4, 4, 20, 20, layerPaint)
          ..drawRect(5, 5, 18, 18, fill)
          ..restore();
        return list;
      }

      await target.renderDisplayList(scene(), clearColor: 0xFF000000);
      final int afterFirst = target.layerPool.createdCount;
      expect(afterFirst, greaterThan(0), reason: 'the layer needed a target');

      await target.renderDisplayList(scene(), clearColor: 0xFF000000);
      expect(
        target.layerPool.createdCount,
        afterFirst,
        reason: 'the second frame must reuse the first frame\'s target; '
            'allocating a framebuffer and a texture per layer per frame is one '
            'of the most expensive things a renderer can do, and it is '
            'completely invisible from the pixels',
      );
      expect(target.layerPool.reuseCount, greaterThan(0));
      target.dispose();
    });
  });

  group('a lost context', () {
    test('is noticed rather than silently drawn into', () async {
      if (!ready()) return;
      // A device of its own: this test destroys the context, so it must not be
      // the one every other test in the file is sharing.
      final web.HTMLCanvasElement canvas =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      canvas
        ..width = 8
        ..height = 8;
      final web.WebGL2RenderingContext? gl = createWebGl2Context(canvas);
      if (gl == null) {
        markTestSkipped('a second context could not be created');
        return;
      }
      final ({WebGlRenderDevice? device, BackendDiagnostic? failure}) opened =
          WebGlRenderDevice.adoptContext(gl);
      final WebGlRenderDevice? device = opened.device;
      if (device == null) {
        markTestSkipped('a second device could not be opened: '
            '${opened.failure}');
        return;
      }
      expect(device.isLost, isFalse);

      final JSObject? extension = gl.getExtension('WEBGL_lose_context');
      if (extension == null) {
        device.dispose();
        markTestSkipped('WEBGL_lose_context is not available, so the loss '
            'cannot be provoked');
        return;
      }
      (extension as _LoseContext).loseContext();

      // The whole point: every WebGL call is now a no-op that raises nothing,
      // so the only way to know is to ask.
      expect(
        device.checkContextAlive(),
        isFalse,
        reason: 'a device that did not ask would issue a frame of draws into '
            'nothing and report success',
      );
      expect(device.isLost, isTrue);
      expect(
        device.deviceState.lossDiagnostic?.kind,
        DiagnosticKind.connectionFailed,
      );
      // And a recovery run before the browser has restored the context refuses
      // by name rather than pretending.
      final BackendDiagnostic? failure = device.recreateDevice();
      expect(failure, isNotNull);
      expect('$failure', contains('webglcontextrestored'));
      device.dispose();
    });
  });
}

/// A descriptor from no backend at all, to check the refusal path.
final class _ForeignSurface implements NativeSurfaceDescriptor {
  @override
  String get kind => 'foreign';

  @override
  int get pixelWidth => 8;

  @override
  int get pixelHeight => 8;

  @override
  double get scale => 1;
}

extension type _LoseContext._(JSObject _) implements JSObject {
  external void loseContext();
}
