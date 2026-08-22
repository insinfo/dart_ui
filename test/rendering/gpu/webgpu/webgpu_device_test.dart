@TestOn('browser')

/// The WebGPU device and its canvas target: the claims parity cannot see.
///
/// The WebGPU sibling of `webgl_device_test.dart`, with the same division of
/// labour: this file checks the things that do not show up in an image - the
/// probe answering instead of throwing, the refusals naming themselves, the
/// layer pool actually pooling, a resize dropping the frame in flight - plus
/// the one thing only a browser can check at all, which is that the WGSL
/// module and the pipelines built from it are accepted by a real WebGPU
/// implementation.
///
/// There is no readback assertion anywhere in this file, and that is the
/// backend's design showing: the WebGPU backend has no offscreen readback
/// target yet (see `webgpu_backend.dart`'s library comment), so "it presented"
/// is asserted through [PresentResult] and the pixel-exact claims stay with
/// the WebGL2 parity suite.
///
/// See `webgpu_session.dart` for the skip contract. The short form:
/// `@TestOn('browser')` keeps this out of CI's plain `dart test`, and inside
/// a browser every test names why it skipped when WebGPU is absent - which,
/// for WebGPU, is a configuration the production code handles by falling back
/// to WebGL2 rather than by failing.
library;

import 'package:dart_ui/src/backends/web/web_gpu_presenter.dart';
import 'package:dart_ui/src/backends/web/web_window.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_backend.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_canvas_target.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_interop.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import 'webgpu_session.dart';

void main() {
  late WebGpuSession session;

  setUpAll(() async {
    session = await WebGpuSession.open();
  });
  tearDownAll(() => session.close());

  /// Skips the calling test when there is no device, naming the reason.
  bool ready() {
    final String? reason = session.skipReason;
    if (reason == null) return true;
    printOnFailure('skipped: $reason');
    markTestSkipped('no WebGPU device: $reason');
    return false;
  }

  group('the backend probe', () {
    test('answers instead of throwing, whatever the browser says', () {
      // Never throws is the whole contract - section 6.6 - and it holds even
      // in a browser with no WebGPU at all, which is why this one does not
      // need a device and is never skipped.
      late BackendProbeResult result;
      expect(
        () => result = const WebGpuRendererBackend().probe(),
        returnsNormally,
      );
      expect(result.backendName, WebGpuRendererBackend.backendName);
      expect(result.diagnostics, isNotEmpty,
          reason: 'supported or not, the probe explains itself');
    });

    test('agrees with navigator.gpu about whether WebGPU exists here', () {
      final BackendProbeResult result = const WebGpuRendererBackend().probe();
      expect(
        result.supported,
        navigatorGpu() != null,
        reason: 'presence of navigator.gpu is the one synchronous fact the '
            'probe claims to report',
      );
    });

    test('claims the canvas descriptor and only the canvas descriptor', () {
      const WebGpuRendererBackend backend = WebGpuRendererBackend();
      final web.HTMLCanvasElement canvas =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      expect(
        backend.supportsSurface(WebGpuCanvasSurfaceDescriptor(
          canvas: canvas,
          generation: GenerationToken(),
        )),
        isTrue,
      );
      expect(
        backend.supportsSurface(const MemorySurfaceDescriptor(
          pixelWidth: 4,
          pixelHeight: 4,
        )),
        isFalse,
        reason: 'this backend has no offscreen readback target, and claiming '
            'the descriptor would promise one createTarget refuses',
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
        reason: 'the backend clamps its fallback to 2048 and the '
            'specification\'s own default limit is 8192',
      );
      // A canvas is composited whole and each task starts on an undefined
      // swap texture, so there is nothing to partially present into.
      expect(capabilities.supportsPartialPresent, isFalse);
      // The antialiasing is analytic, on every backend of this family.
      expect(capabilities.supportsMsaa, isFalse);
    });

    test('refuses the readback descriptor by name', () {
      if (!ready()) return;
      expect(
        () => session.device!.createTarget(const MemorySurfaceDescriptor(
          pixelWidth: 4,
          pixelHeight: 4,
        )),
        throwsA(
          isA<UnsupportedCapabilityError>().having(
            (UnsupportedCapabilityError e) => '$e',
            'message',
            contains('readback'),
          ),
        ),
        reason: 'the missing offscreen target must stay a visible gap, not '
            'become a target that renders perfectly and reads back garbage',
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
            contains('WebGpuCanvasTarget'),
          ),
        ),
      );
    });

    test('refuses a texture larger than the device allows', () {
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

    test('a released texture says it is dead', () {
      if (!ready()) return;
      final WebGpuTexture texture = session.device!.createTexture(
        width: 8,
        height: 8,
        format: GpuTextureFormat.alpha8,
      );
      expect(texture.isValid, isTrue);
      expect(texture.id, isNot(kNoTexture),
          reason: 'kNoTexture means "samples nothing" and a real texture '
              'handed that id would be unbindable');
      session.device!.releaseTexture(texture);
      expect(texture.isValid, isFalse);
    });
  });

  group('the canvas target', () {
    test('opens on a detached canvas and presents a frame', () async {
      if (!ready()) return;
      final _CanvasFixture fixture = await _CanvasFixture.open(64, 64);
      if (fixture.target == null) {
        // The session opened a device, so a canvas refusing here is worth
        // seeing in the log rather than folding into a generic failure.
        markTestSkipped('the canvas refused: ${fixture.failure}');
        return;
      }
      final WebGpuCanvasTarget target = fixture.target!;
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF3366CC, antiAlias: false);
      list.drawRect(2, 2, 60, 60, paint);
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      fixture.dispose();
    });

    test('the same layer drawn twice creates one layer texture', () async {
      if (!ready()) return;
      final _CanvasFixture fixture = await _CanvasFixture.open(24, 24);
      if (fixture.target == null) {
        markTestSkipped('the canvas refused: ${fixture.failure}');
        return;
      }
      final WebGpuCanvasTarget target = fixture.target!;
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

      final PresentResult first =
          await target.renderDisplayList(scene(), clearColor: 0xFF000000);
      expect(first.status, PresentStatus.presented,
          reason: '${first.diagnostic}');
      final int afterFirst = target.layerPool.createdCount;
      expect(afterFirst, greaterThan(0), reason: 'the layer needed a target');

      final PresentResult second =
          await target.renderDisplayList(scene(), clearColor: 0xFF000000);
      expect(second.status, PresentStatus.presented,
          reason: '${second.diagnostic}');
      expect(
        target.layerPool.createdCount,
        afterFirst,
        reason: 'the second frame must reuse the first frame\'s texture; the '
            'pooling is completely invisible from the pixels, which is why it '
            'is asserted here',
      );
      expect(target.layerPool.reuseCount, greaterThan(0));
      fixture.dispose();
    });

    test('a resize bumps the generation, so a frame in flight is dropped',
        () async {
      if (!ready()) return;
      final _CanvasFixture fixture = await _CanvasFixture.open(16, 16);
      if (fixture.target == null) {
        markTestSkipped('the canvas refused: ${fixture.failure}');
        return;
      }
      final WebGpuCanvasTarget target = fixture.target!;
      final Frame frame = target.beginFrame(const FrameRequest());
      final int before = target.generation;
      target.resize(32, 32, 1);
      expect(target.generation, greaterThan(before));
      final PresentResult result = await target.present(frame);
      expect(
        result.status,
        PresentStatus.stale,
        reason: 'a frame recorded for the old size must be dropped, not '
            'drawn stretched into a surface that moved',
      );
      fixture.dispose();
    });
  });

  group('the presenter', () {
    test('attaches where WebGPU exists and refuses loudly where it does not',
        () async {
      // Deliberately not skip-gated: both outcomes are contract. On a browser
      // with WebGPU the attach must succeed against a wrapped canvas; on one
      // without, it must throw BackendSelectionError - the exact shape the
      // selection machinery catches to fall back to the WebGL2 entry - and
      // never anything else.
      final web.HTMLCanvasElement canvas =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      canvas
        ..width = 8
        ..height = 8;
      final WebWindow window = WebWindow.wrap(canvas);
      if (session.skipReason != null) {
        await expectLater(
          WebGpuCanvasPresenter.attach(window),
          throwsA(isA<BackendSelectionError>()),
          reason: 'an attach that throws anything else would take the whole '
              'selection down instead of falling through to webgl2',
        );
      } else {
        final WebGpuCanvasPresenter presenter =
            await WebGpuCanvasPresenter.attach(window);
        expect(presenter.info.name, WebGpuRendererBackend.backendName);
        expect(presenter.isDeviceLost, isFalse);
        presenter.dispose();
      }
      window.dispose();
    });
  });
}

/// A detached canvas with a WebGPU target on it, or the reason there is none.
///
/// Each fixture owns its own device - `WebGpuCanvasTarget.open` requests one
/// per canvas, which is also what production does - so [dispose] tears both
/// down and the session's shared device is never entangled with a canvas.
final class _CanvasFixture {
  _CanvasFixture._(this.target, this.device, this.failure);

  final WebGpuCanvasTarget? target;
  final WebGpuRenderDevice? device;
  final BackendDiagnostic? failure;

  static Future<_CanvasFixture> open(int width, int height) async {
    final web.HTMLCanvasElement canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement;
    canvas
      ..width = width
      ..height = height;
    final ({
      WebGpuCanvasTarget? target,
      WebGpuRenderDevice? device,
      BackendDiagnostic? failure,
    }) opened = await WebGpuCanvasTarget.open(WebGpuCanvasSurfaceDescriptor(
      canvas: canvas,
      generation: GenerationToken(),
    ));
    return _CanvasFixture._(opened.target, opened.device, opened.failure);
  }

  void dispose() {
    target?.dispose();
    device?.dispose();
  }
}

/// A descriptor no web backend recognises, for the refusal tests.
final class _ForeignSurface implements NativeSurfaceDescriptor {
  @override
  String get kind => 'foreign-test-surface';

  @override
  int get pixelWidth => 4;

  @override
  int get pixelHeight => 4;

  @override
  double get scale => 1;
}
