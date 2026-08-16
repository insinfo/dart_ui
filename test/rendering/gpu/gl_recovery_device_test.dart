/// Device-loss recovery on a real GL device, with the loss injected.
///
/// `gpu_recovery_test.dart` proves the protocol - the eight steps, their
/// order, the inventory, the fallback - against a fake device, on any machine.
/// It cannot prove the one claim that matters most: that after a device has
/// been lost, discarded, recreated and repopulated, the next frame draws **the
/// same pixels** as the frame before the loss. Nothing but a driver can answer
/// that, so this file needs one and skips with a stated reason when there is
/// none. The CI runs Linux and macOS as well as Windows.
///
/// ## What is real here and what is injected
///
/// **Injected:** the loss itself. A real GPU reset needs a TDR, a driver
/// update or an adapter being unplugged, and no test can arrange one. So
/// [GpuDeviceState.markLost] is called directly, which is exactly what the
/// driver paths do when `GL_CONTEXT_LOST` or a refused `makeCurrent` arrives -
/// see `GlRenderDevice.checkError` and `makeCurrentOrLose`.
///
/// **Real:** everything after that. Every texture really is invalidated, every
/// GL object really is discarded and recompiled on the driver, the atlases
/// really are re-rasterised and re-uploaded, and the pixels really are read
/// back off the GPU and compared byte for byte.
///
/// One thing a GL device cannot do and this file does not pretend to: create a
/// new context. The context belongs to whoever made the window, and
/// `GlRenderDevice.recreateDevice` rebuilds every GL *object* on the existing
/// one - which is precisely the state `GL_ARB_robustness` describes after a
/// reset. A context that will not go current at all is refused by name.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_recovery.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

void main() {
  final session = _GlSession.open();

  group('a real GL device losing and recovering', () {
    tearDownAll(session.close);

    test('the frame after a recovery draws the same pixels as the one before',
        () async {
      // The assertion this whole change exists for. A recovery that recreated
      // the device and left the sink wired to a freed texture name draws
      // *something*; only equality with the pre-loss frame proves it drew the
      // right thing.
      final GlRenderDevice device = session.device!;
      final GlOffscreenTarget target = session.target(32, 32);
      final sink = RecordingRendererEventSink();
      final coordinator = GpuRecoveryCoordinator(host: device, events: sink);

      final DisplayList list = _richList();
      expect(
          (await target.renderDisplayList(list, clearColor: 0xFF102030)).status,
          PresentStatus.presented);
      final Uint8List before = Uint8List.fromList(target.framebuffer.pixels);
      expect(_isAllOneColour(before), isFalse,
          reason: 'a blank frame would make the comparison meaningless');

      device.state.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));

      final GpuRecoveryReport report = coordinator.recover();
      printOnFailure('$report');
      expect(report.isRecovered, isTrue, reason: '$report');
      expect(report.status, GpuRecoveryStatus.recovered);
      expect(device.isLost, isFalse);

      expect(
          (await target.renderDisplayList(list, clearColor: 0xFF102030)).status,
          PresentStatus.presented);
      final Uint8List after = target.framebuffer.pixels;

      expect(after.length, before.length);
      expect(_firstDifference(before, after), -1,
          reason: 'the recovered device drew a different picture; the first '
              'differing byte is where to look');
      expect(after, orderedEquals(before));

      // And the record section 23.12 step 7 asks for.
      final DeviceRecovered recovered = sink.ofType<DeviceRecovered>().single;
      expect(recovered.backendName, 'opengl');
      expect(recovered.lossCount, greaterThanOrEqualTo(1));
      expect(recovered.needsFullRepaint, isTrue);
      expect(recovered.elapsed, isNotNull);
      printOnFailure('recovery took ${recovered.elapsed.inMilliseconds}ms');

      target.dispose();
    }, skip: session.skipReason);

    test('an image re-uploaded from its retained source draws identically',
        () async {
      final GlRenderDevice device = session.device!;
      final GlOffscreenTarget target = session.target(16, 16);
      final coordinator = GpuRecoveryCoordinator(host: device);

      final Framebuffer image = _checkerboard();
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      final int id = list.addImage(image);
      list.drawImage(id, 0, 0, 4, 4, 0, 0, 16, 16, paint);

      await target.renderDisplayList(list, clearColor: 0xFF000000);
      final Uint8List before = Uint8List.fromList(target.framebuffer.pixels);
      expect(target.images.length, 1);
      // The retention policy, measured rather than asserted in prose: the cache
      // is holding exactly the image's bytes.
      expect(target.images.retainedSourceBytes, 4 * 4 * 4);
      expect(target.images.unrecoverableCount, 0);

      device.state.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));
      final GpuRecoveryReport report = coordinator.recover();
      expect(report.status, GpuRecoveryStatus.recovered, reason: '$report');
      // The image was re-uploaded, not silently skipped.
      expect(report.repopulatedCount, greaterThanOrEqualTo(3));

      await target.renderDisplayList(list, clearColor: 0xFF000000);
      expect(target.framebuffer.pixels, orderedEquals(before));
      target.dispose();
    }, skip: session.skipReason);

    test('an image whose source was dropped fails by name, not by drawing',
        () async {
      final GlRenderDevice device = session.device!;
      final GlOffscreenTarget target = session.target(16, 16);
      final coordinator = GpuRecoveryCoordinator(host: device);

      final Framebuffer image = _checkerboard();
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      final int id = list.addImage(image);
      list.drawImage(id, 0, 0, 4, 4, 0, 0, 16, 16, paint);

      await target.renderDisplayList(list, clearColor: 0xFF000000);
      // The application decided it would never need to re-upload this one.
      expect(target.images.dropSource(image), isTrue);
      expect(target.images.retainedSourceBytes, 0);
      expect(target.images.unrecoverableCount, 1);

      device.state.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));
      final GpuRecoveryReport report = coordinator.recover();

      // Recovered, and honest about what did not come back.
      expect(report.status, GpuRecoveryStatus.recoveredWithLosses);
      expect(report.unrecoverableResources, hasLength(1));
      expect(report.unrecoverableResources.single, contains('opengl image #0'));
      expect(report.unrecoverableResources.single, contains('4x4'));

      // And the frame that asks for it is refused *by name*. Not a blank
      // rectangle, not the previous texture's contents, not a crash.
      await expectLater(
        target.renderDisplayList(list, clearColor: 0xFF000000),
        throwsA(isA<UnsupportedCapabilityError>()
            .having((UnsupportedCapabilityError e) => e.backendName,
                'backendName', 'opengl')
            .having((UnsupportedCapabilityError e) => e.toString(), 'detail',
                contains('Framebuffer'))),
      );
      target.dispose();
    }, skip: session.skipReason);

    test('a frame in flight when the device dies is rejected, not drawn',
        () async {
      final GlRenderDevice device = session.device!;
      final GlOffscreenTarget target = session.target(8, 8);

      // A frame begun, recorded, and then overtaken by the loss - which is
      // what a TDR arriving mid-frame is.
      final Frame frame = target.beginFrame(
        const FrameRequest(clearColor: 0xFF00FF00),
      );
      final int generationBefore = frame.generation;

      device.state.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the device died while a frame was in flight',
      ));

      final PresentResult result = await target.present(frame);
      expect(result.status, PresentStatus.deviceLost);
      expect(result.isSuccess, isFalse);
      expect(
          result.diagnostic!.message, contains('while a frame was in flight'));
      // The target's generation moved, so the frame could not be presented
      // even if the device came back a microsecond later.
      expect(target.generation, greaterThan(generationBefore));

      final coordinator = GpuRecoveryCoordinator(host: device);
      expect(coordinator.recover().isRecovered, isTrue);
      // Still rejected after the recovery: it belongs to a dead generation.
      expect((await target.present(frame)).status, PresentStatus.stale);
      target.dispose();
    }, skip: session.skipReason);

    test('submissions stop while a recovery is in progress', () async {
      // Invisible from the pixels: a device that went on issuing draws into a
      // reset context produces the same blank frame as one that refused. Only
      // the counter tells them apart.
      final GlRenderDevice device = session.device!;
      final GlOffscreenTarget target = session.target(8, 8);
      await target.renderDisplayList(_richList(), clearColor: 0xFF000000);

      final int blockedBefore = device.blockedSubmissionCount;
      device.stopSubmissions();
      expect(device.submissionsStopped, isTrue);
      expect(device.submit(target.batcher, 8, 8, null), isFalse);
      expect(device.blockedSubmissionCount, blockedBefore + 1);

      // The recovery reopens them.
      device.state.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));
      expect(
          GpuRecoveryCoordinator(host: device).recover().isRecovered, isTrue);
      expect(device.submissionsStopped, isFalse);
      target.dispose();
    }, skip: session.skipReason);

    test('a texture from before the loss stays invalid after the recovery',
        () async {
      // The check that survives a recovery. `isLost` goes back to false, so a
      // validity test that asked only that question would declare every
      // pre-loss name healthy again - and those names point at memory the
      // driver freed.
      final GlRenderDevice device = session.device!;
      final GlOffscreenTarget target = session.target(8, 8);
      final GlTexture stale = device.createTexture(
        width: 4,
        height: 4,
        format: GpuTextureFormat.alpha8,
      );
      expect(stale.isValid, isTrue);

      device.state.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));
      expect(stale.isValid, isFalse);

      expect(
          GpuRecoveryCoordinator(host: device).recover().isRecovered, isTrue);
      expect(device.isLost, isFalse);
      expect(stale.isValid, isFalse,
          reason: 'a name from the previous device must never come back to '
              'life, or the next bind is undefined output');

      // A texture created after the recovery is valid, so the device really is
      // usable again rather than merely reporting so.
      final GlTexture fresh = device.createTexture(
        width: 4,
        height: 4,
        format: GpuTextureFormat.alpha8,
      );
      expect(fresh.isValid, isTrue);
      device.releaseTexture(fresh);
      target.dispose();
    }, skip: session.skipReason);

    test('losing the device four times in the window falls back to the CPU',
        () async {
      final GlRenderDevice device = session.device!;
      final GlOffscreenTarget target = session.target(8, 8);
      final sink = RecordingRendererEventSink();
      final coordinator = GpuRecoveryCoordinator(host: device, events: sink);

      for (var i = 0; i < 3; i++) {
        device.state.markLost(BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'reset ${i + 1} in a loop',
        ));
        expect(coordinator.recover().isRecovered, isTrue);
        expect(
            (await target.renderDisplayList(_richList(),
                    clearColor: 0xFF000000))
                .status,
            PresentStatus.presented);
      }

      device.state.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'reset 4 in a loop',
      ));
      final GpuRecoveryReport report = coordinator.recover();

      expect(report.status, GpuRecoveryStatus.fellBackToCpu);
      expect(sink.ofType<RendererFellBackToCpu>(), hasLength(1));
      // Terminal, and the device stays lost - which is what makes the owner
      // switch renderers instead of showing a frozen window.
      expect(device.isLost, isTrue);
      expect(
          (await target.renderDisplayList(_richList(), clearColor: 0xFF000000))
              .status,
          PresentStatus.deviceLost);
      target.dispose();

      // This device is finished for the rest of the file, so the session is
      // closed and reopened by whatever runs next. Recreated here rather than
      // left lost, because `tearDownAll` disposes it either way.
      expect(
          GpuRecoveryCoordinator(host: device).recover().isRecovered, isTrue);
    }, skip: session.skipReason);
  });
}

/// A list that exercises three different resources at once: a solid rectangle
/// (no atlas), a rounded rectangle (the mask atlas) and an image (the image
/// cache). A pixel comparison over only one of them would miss a recovery that
/// rebuilt one and forgot the others.
DisplayList _richList() {
  final list = DisplayList();
  final int solid = list.addPaint(colorArgb: 0xFF3366CC, antiAlias: false);
  list.drawRect(1, 1, 12, 12, solid);
  final int soft = list.addPaint(colorArgb: 0xFFFFFFFF);
  list.drawRRect(14, 2, 30, 18, 5, 5, 5, 5, 5, 5, 5, 5, soft);
  final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
  final int id = list.addImage(_checkerboard());
  list.drawImage(id, 0, 0, 4, 4, 2, 20, 26, 30, paint);
  return list;
}

/// A 4x4 image with four distinct colours, so a wrong texture, a wrong filter
/// or a wrong row order all show up.
Framebuffer _checkerboard() {
  final Framebuffer image = Framebuffer.allocate(
    width: 4,
    height: 4,
    format: PixelFormat.rgba8888Premultiplied,
  );
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      final int offset = y * image.bytesPerRow + x * 4;
      image.pixels[offset] = (x & 1) == 0 ? 0xFF : 0x20;
      image.pixels[offset + 1] = (y & 1) == 0 ? 0xFF : 0x20;
      image.pixels[offset + 2] = ((x + y) & 1) == 0 ? 0xFF : 0x20;
      image.pixels[offset + 3] = 0xFF;
    }
  }
  return image;
}

int _firstDifference(Uint8List a, Uint8List b) {
  final int limit = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < limit; i++) {
    if (a[i] != b[i]) return i;
  }
  return a.length == b.length ? -1 : limit;
}

bool _isAllOneColour(Uint8List pixels) {
  for (var i = 4; i < pixels.length; i++) {
    if (pixels[i] != pixels[i % 4]) return false;
  }
  return true;
}

/// The same session helper `gl_device_test.dart` uses, for the same reason: a
/// GL device is opened through a window on Windows and through EGL elsewhere,
/// and neither is guaranteed to exist.
final class _GlSession {
  _GlSession._(this.device, this.skipReason, this._surface);

  final GlRenderDevice? device;

  /// Null when the device opened. A string - which `skip:` accepts - when it
  /// did not, so a run with no driver names what was missing rather than
  /// passing quietly.
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
    final Win32GlSurfaceAttempt attempt = Win32GlSurface.hidden();
    final Win32GlSurface? surface = attempt.surface;
    if (surface == null) {
      return _GlSession._(
          null, 'no GL surface: ${attempt.diagnostics.join('; ')}', null);
    }
    final GlContextAttempt contextAttempt = surface.createContext();
    final GlContext? context = contextAttempt.context;
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
    final GlLibraryLoad load = GlLibrary.open();
    if (!load.isLoaded) {
      return _GlSession._(
          null, 'no GL library: ${load.attempted.join(', ')}', null);
    }
    final GlContextAttempt attempt = const GlContextFactory()
        .create(width: 16, height: 16, glLibrary: load.library!);
    final GlContext? context = attempt.context;
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
