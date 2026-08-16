/// Device-loss recovery on a real Direct3D 11 device, with the loss injected.
///
/// The counterpart of `../gl_recovery_device_test.dart`, and the reason it is a
/// separate file rather than more cases in that one: D3D11 recovers
/// *differently*. A GL context belongs to whoever made the window, so
/// `GlRenderDevice.recreateDevice` rebuilds every GL object on the context it
/// already has. `D3D11CreateDevice` has no such constraint, so
/// `D3d11RenderDevice.recreateDevice` really does produce a new
/// `ID3D11Device` - which is the documented recovery from
/// `DXGI_ERROR_DEVICE_REMOVED` - and the pixel-equality assertion below is
/// therefore about a *different* device drawing the same picture.
///
/// ## What is real and what is injected, stated rather than implied
///
/// **Injected:** the loss. A genuine `DXGI_ERROR_DEVICE_REMOVED` needs a TDR, a
/// driver update, or an adapter being unplugged. There is no supported way for
/// a test process to cause one: the documented triggers are a shader that
/// exceeds the GPU watchdog (which needs a compute or draw workload this
/// backend cannot express, and which would take the whole desktop session down
/// with it) and `ID3D11Device5::RemoveDevice`, which does not exist. So
/// [D3d11RenderDevice.markLost] is called directly, exactly as
/// `_markLostIfRemoved` and `checkDeviceRemoved` do when the driver reports it.
///
/// **Real, and executed on this machine when it has a device:** the release of
/// every COM object the dead device owned, a fresh `D3D11CreateDevice`, a fresh
/// HLSL compile through `d3dcompiler_47.dll`, fresh textures, fresh uploads, a
/// real `CopyResource` and `Map` of the result, and a byte-for-byte comparison.
///
/// Skipped with a stated reason off Windows or where no device answers. WARP
/// counts as a device: it is a conformant software rasteriser running the same
/// shaders, so the recovery path is the same one.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_recovery.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

void main() {
  final session = _D3d11Session.open();

  group('a real Direct3D 11 device losing and recovering', () {
    tearDownAll(session.close);

    test('the frame after a recovery draws the same pixels as the one before',
        () async {
      final D3d11RenderDevice device = session.device!;
      final D3d11OffscreenTarget target = session.target(32, 32);
      final sink = RecordingRendererEventSink();
      final coordinator = GpuRecoveryCoordinator(host: device, events: sink);

      final DisplayList list = _richList();
      expect(
        (await target.renderDisplayList(list, clearColor: 0xFF102030)).status,
        PresentStatus.presented,
      );
      final Uint8List before = Uint8List.fromList(target.framebuffer.pixels);
      expect(_isAllOneColour(before), isFalse,
          reason: 'a blank frame would make the comparison meaningless');

      // The pointer to the device that is about to die, kept only to prove the
      // recovery really replaced it rather than reusing it.
      final int deadDevice = device.device.pointer.address;

      device.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));

      final GpuRecoveryReport report = coordinator.recover();
      printOnFailure('$report');
      expect(report.isRecovered, isTrue, reason: '$report');
      expect(device.isLost, isFalse);
      expect(device.device.pointer.address, isNot(deadDevice),
          reason: 'D3D11 recovery must create a new ID3D11Device, not reuse '
              'the removed one');
      // GetDeviceRemovedReason is the only reliable question, and the new
      // device answers S_OK.
      expect(device.checkDeviceRemoved('after a recovery'), isFalse);

      expect(
        (await target.renderDisplayList(list, clearColor: 0xFF102030)).status,
        PresentStatus.presented,
      );
      expect(_firstDifference(before, target.framebuffer.pixels), -1,
          reason: 'the recreated device drew a different picture');
      expect(target.framebuffer.pixels, orderedEquals(before));

      final DeviceRecovered recovered = sink.ofType<DeviceRecovered>().single;
      expect(recovered.backendName, 'direct3d11');
      expect(recovered.needsFullRepaint, isTrue);
      printOnFailure('recovery took ${recovered.elapsed.inMilliseconds}ms on '
          '${device.info.deviceDescription}');
      target.dispose();
    }, skip: session.skipReason);

    test('an image whose source was dropped fails by name, not by drawing',
        () async {
      final D3d11RenderDevice device = session.device!;
      final D3d11OffscreenTarget target = session.target(16, 16);
      final coordinator = GpuRecoveryCoordinator(host: device);

      final Framebuffer image = _checkerboard();
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      final int id = list.addImage(image);
      list.drawImage(id, 0, 0, 4, 4, 0, 0, 16, 16, paint);

      await target.renderDisplayList(list, clearColor: 0xFF000000);
      expect(target.images.retainedSourceBytes, 4 * 4 * 4);
      expect(target.images.dropSource(image), isTrue);
      expect(target.images.retainedSourceBytes, 0);
      expect(target.images.unrecoverableCount, 1);

      device.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));
      final GpuRecoveryReport report = coordinator.recover();

      expect(report.status, GpuRecoveryStatus.recoveredWithLosses);
      expect(report.unrecoverableResources.single,
          contains('direct3d11 image #0'));

      await expectLater(
        target.renderDisplayList(list, clearColor: 0xFF000000),
        throwsA(isA<UnsupportedCapabilityError>().having(
            (UnsupportedCapabilityError e) => e.backendName,
            'backendName',
            'direct3d11')),
      );
      target.dispose();
    }, skip: session.skipReason);

    test('an image with its source retained comes back identical', () async {
      final D3d11RenderDevice device = session.device!;
      final D3d11OffscreenTarget target = session.target(16, 16);
      final coordinator = GpuRecoveryCoordinator(host: device);

      final Framebuffer image = _checkerboard();
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      final int id = list.addImage(image);
      list.drawImage(id, 0, 0, 4, 4, 0, 0, 16, 16, paint);

      await target.renderDisplayList(list, clearColor: 0xFF000000);
      final Uint8List before = Uint8List.fromList(target.framebuffer.pixels);

      device.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));
      expect(coordinator.recover().status, GpuRecoveryStatus.recovered);

      await target.renderDisplayList(list, clearColor: 0xFF000000);
      expect(target.framebuffer.pixels, orderedEquals(before));
      target.dispose();
    }, skip: session.skipReason);

    test('a frame in flight when the device dies is rejected, not drawn',
        () async {
      final D3d11RenderDevice device = session.device!;
      final D3d11OffscreenTarget target = session.target(8, 8);

      final Frame frame =
          target.beginFrame(const FrameRequest(clearColor: 0xFF00FF00));
      final int generationBefore = frame.generation;

      device.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the device was removed while a frame was in flight',
      ));

      final PresentResult result = await target.present(frame);
      expect(result.status, PresentStatus.deviceLost);
      expect(result.diagnostic!.message, contains('in flight'));
      expect(target.generation, greaterThan(generationBefore));

      expect(
          GpuRecoveryCoordinator(host: device).recover().isRecovered, isTrue);
      expect((await target.present(frame)).status, PresentStatus.stale);
      target.dispose();
    }, skip: session.skipReason);

    test('submissions stop while a recovery is in progress', () async {
      final D3d11RenderDevice device = session.device!;
      final D3d11OffscreenTarget target = session.target(8, 8);
      await target.renderDisplayList(_richList(), clearColor: 0xFF000000);

      final int blockedBefore = device.blockedSubmissionCount;
      device.stopSubmissions();
      expect(device.submissionsStopped, isTrue);
      // A null render-target pointer would be caught by the guard before
      // anything reached OMSetRenderTargets, which is the point: the door is
      // closed before the driver is touched.
      expect(
        device.submit(target.batcher, 8, 8, null, nullptr),
        isFalse,
      );
      expect(device.blockedSubmissionCount, blockedBefore + 1);

      device.markLost(const BackendDiagnostic(
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
      final D3d11RenderDevice device = session.device!;
      final D3d11OffscreenTarget target = session.target(8, 8);
      final D3d11Texture stale = device.createTexture(
        width: 4,
        height: 4,
        format: GpuTextureFormat.alpha8,
      );
      expect(stale.isValid, isTrue);

      device.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));
      expect(stale.isValid, isFalse);

      expect(
          GpuRecoveryCoordinator(host: device).recover().isRecovered, isTrue);
      expect(stale.isValid, isFalse,
          reason: 'the COM pointer belongs to an ID3D11Device that has been '
              'released; binding it is undefined');
      final D3d11Texture fresh = device.createTexture(
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
      final D3d11RenderDevice device = session.device!;
      final D3d11OffscreenTarget target = session.target(8, 8);
      final sink = RecordingRendererEventSink();
      final coordinator = GpuRecoveryCoordinator(host: device, events: sink);
      // Relative, because the session's device is shared with the cases above
      // and lossCount deliberately never goes back down.
      final int lossesBefore = device.state.lossCount;

      for (var i = 0; i < 3; i++) {
        device.markLost(BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'reset ${i + 1} in a loop',
        ));
        expect(coordinator.recover().isRecovered, isTrue);
        expect(
          (await target.renderDisplayList(_richList(), clearColor: 0xFF000000))
              .status,
          PresentStatus.presented,
        );
      }

      device.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'reset 4 in a loop',
      ));
      expect(coordinator.recover().status, GpuRecoveryStatus.fellBackToCpu);
      expect(sink.ofType<RendererFellBackToCpu>(), hasLength(1));
      expect(device.isLost, isTrue);
      expect(
        (await target.renderDisplayList(_richList(), clearColor: 0xFF000000))
            .status,
        PresentStatus.deviceLost,
      );
      expect(device.state.lossCount - lossesBefore, 4);
      target.dispose();

      // Left usable for the shared session's teardown.
      expect(
          GpuRecoveryCoordinator(host: device).recover().isRecovered, isTrue);
    }, skip: session.skipReason);
  });
}

/// A list that exercises a solid rectangle (no atlas), a rounded rectangle (the
/// mask atlas) and an image (the image cache) at once. Comparing pixels over
/// only one of them would miss a recovery that rebuilt one and forgot the rest.
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

final class _D3d11Session {
  _D3d11Session._(this.device, this.skipReason);

  final D3d11RenderDevice? device;

  /// Null when the device opened. A string - which `skip:` accepts - when it
  /// did not, so a run on Linux names what was missing rather than passing
  /// quietly.
  final String? skipReason;

  static _D3d11Session open() {
    if (!Platform.isWindows) {
      return _D3d11Session._(
        null,
        'Direct3D 11 needs Windows; this is ${Platform.operatingSystem}',
      );
    }
    try {
      return _D3d11Session._(D3d11RendererBackend.openDevice(), null);
    } on BackendSelectionError catch (error) {
      return _D3d11Session._(null, 'no D3D11 device: $error');
    } on Object catch (error) {
      return _D3d11Session._(null, 'opening a D3D11 device threw: $error');
    }
  }

  D3d11OffscreenTarget target(int width, int height) =>
      device!.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.rgba8888Premultiplied,
      )) as D3d11OffscreenTarget;

  void close() => device?.dispose();
}
