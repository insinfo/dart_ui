/// The Direct3D 11 backend against a real device, when there is one.
///
/// The counterpart of `gl_device_test.dart`, and it exists for the same reason
/// that file gives: everything else under `test/rendering/gpu` runs on a machine
/// with no GPU, and a batcher that batches perfectly plus a shader that never
/// compiled produce a suite that is green and a renderer that has never drawn a
/// pixel.
///
/// So this is the end-to-end check - open a device, compile the HLSL, draw,
/// copy the render target to a staging texture, map it, and compare the bytes
/// against what the display list asked for. It skips rather than fails where no
/// device answers, because "this CI container runs Linux" is not a defect in the
/// renderer, and the Linux and macOS halves of CI are exactly where every test
/// in this file is skipped.
///
/// Two things this file checks that the GL one cannot:
///
///   * **The feature level is reported.** `D3D11CreateDevice` is handed a list
///     and picks; a device that came back at 10.0 has a 8192-texel limit and a
///     device at 11.1 has 16384, and nothing else in the suite would notice the
///     difference.
///   * **WARP is a legitimate answer.** A machine with no GPU still creates a
///     conformant software device that runs the same shaders through the same
///     code path, so these tests run on a build agent - and the fallback is
///     *reported*, because a frame time measured on WARP is a measurement of
///     the CPU.
library;

import 'dart:io';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_backend.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

void main() {
  group('the probe', () {
    test('never throws, and says what it found either way', () {
      // Section 6.6: a probe that throws takes the whole backend selection
      // down with it, which is worse than one that reports a failure. On Linux
      // this is the assertion that the missing DLL becomes a diagnostic.
      const backend = D3d11RendererBackend();
      final BackendProbeResult result = backend.probe();

      expect(result.backendName, 'direct3d11');
      expect(result.diagnostics, isNotEmpty,
          reason: 'a probe that only explains its failures leaves the '
              'successful case unauditable');
      printOnFailure(result.diagnostics.join('\n'));

      if (!Platform.isWindows) {
        expect(result.supported, isFalse,
            reason: 'Direct3D 11 does not exist off Windows and must not '
                'claim to');
      }
    });

    test('says DirectComposition is not wired, by name', () {
      // Section 6.6 again, and the rule it sets: an absent capability is
      // declared by the name of what is missing, never left to be discovered.
      const backend = D3d11RendererBackend();
      final String report = backend
          .probe()
          .diagnostics
          .map((d) => '${d.message} ${d.detail}')
          .join('\n');
      if (!Platform.isWindows) {
        // Off Windows the probe stops at the missing DLL and has nothing else
        // to report, which is itself the honest answer.
        return;
      }
      expect(report, contains('DirectComposition'));
      expect(report, contains('DCompositionCreateDevice'));
      expect(report, contains('CreateSwapChainForComposition'));
    });

    test('accepts the two descriptors it can present to and no others', () {
      const backend = D3d11RendererBackend();
      expect(
        backend.supportsSurface(const MemorySurfaceDescriptor(
          pixelWidth: 4,
          pixelHeight: 4,
          format: PixelFormat.rgba8888Premultiplied,
        )),
        isTrue,
      );
      expect(backend.supportsSurface(const _AlienSurface()), isFalse);
    });
  });

  group('a live Direct3D 11 device', () {
    final session = _D3d11Session.open();
    tearDownAll(session.close);

    test('reports an adapter and the feature level it settled on', () {
      final D3d11RenderDevice device = session.device!;
      // An empty description means the DXGI walk from device to adapter did
      // not happen, which is the failure that looks like a working renderer
      // until somebody reads a bug report.
      expect(device.info.deviceDescription, isNotEmpty);
      expect(device.info.driverVersion, contains('feature level'));
      expect(kD3d11FeatureLevels, contains(device.featureLevel));
      // The device's own answer, asked through the vtable rather than taken
      // from the create call's out-parameter: a wrong slot number for
      // GetFeatureLevel would return whatever the neighbouring method does.
      expect(device.device.getFeatureLevel(device.device.pointer),
          device.featureLevel);
      printOnFailure('${device.info.deviceDescription} at feature level '
          '${d3dFeatureLevelName(device.featureLevel)}');
    }, skip: session.skipReason);

    test('the texture limit follows the feature level', () {
      final D3d11RenderDevice device = session.device!;
      expect(
        device.capabilities.maxTextureSize,
        device.featureLevel >= d3dFeatureLevel11_0 ? 16384 : 8192,
      );
    }, skip: session.skipReason);

    test('claims nothing it has not implemented', () {
      // Section 6.6. Partial present needs Present1 and a swap effect that
      // preserves the back buffer; MSAA needs a multisampled target; compute
      // needs shaders the bindings deliberately stop before. Claiming any of
      // them would make a caller skip a redraw whose pixels were never sent.
      final RendererCapabilities capabilities = session.device!.capabilities;
      expect(capabilities.supportsPartialPresent, isFalse);
      expect(capabilities.supportsMsaa, isFalse);
      expect(capabilities.supportsCompute, isFalse);
      expect(capabilities.supportsExternalTextures, isFalse);
    }, skip: session.skipReason);

    test('is not lost the moment it is created', () {
      final D3d11RenderDevice device = session.device!;
      expect(device.isLost, isFalse);
      // GetDeviceRemovedReason is the only reliable question, and S_OK is what
      // a live device answers.
      expect(device.checkDeviceRemoved('a test'), isFalse);
    }, skip: session.skipReason);

    test('clears to the requested colour', () async {
      final D3d11OffscreenTarget target = session.target(4, 4);
      final PresentResult result =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF204060);

      expect(result.status, PresentStatus.presented);
      // The clear colour is packed premultiplied BGRA in a 32-bit int and
      // ClearRenderTargetView takes straight floats in RGBA order; an
      // unswapped channel here is the whole bug.
      expect(_pixel(target.framebuffer, 0, 0), <int>[0x20, 0x40, 0x60, 0xFF]);
      target.dispose();
    }, skip: session.skipReason);

    test('draws an aliased rectangle at exactly the pixels asked for',
        () async {
      final D3d11OffscreenTarget target = session.target(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFF3366CC, antiAlias: false);
      list.drawRect(2, 1, 6, 4, paint);
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      final Framebuffer framebuffer = target.framebuffer;
      // Inside, on the boundary and outside. This is the assertion that would
      // catch a y flip: D3D11's render target is top-down and GL's is not, so
      // a port that kept GL's projection draws this rectangle six rows away.
      expect(_pixel(framebuffer, 2, 1), <int>[0x33, 0x66, 0xCC, 0xFF]);
      expect(_pixel(framebuffer, 5, 3), <int>[0x33, 0x66, 0xCC, 0xFF]);
      expect(_pixel(framebuffer, 1, 1), <int>[0, 0, 0, 0xFF]);
      expect(_pixel(framebuffer, 6, 1), <int>[0, 0, 0, 0xFF]);
      expect(_pixel(framebuffer, 2, 4), <int>[0, 0, 0, 0xFF]);
      expect(_pixel(framebuffer, 2, 0), <int>[0, 0, 0, 0xFF]);
      target.dispose();
    }, skip: session.skipReason);

    test('the analytic coverage antialiases a half-pixel edge', () async {
      final D3d11OffscreenTarget target = session.target(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawRect(2.5, 0, 6, 8, paint);
      await target.renderDisplayList(list, clearColor: 0xFF000000);

      // boxCoverage on a rect whose left edge cuts column 2 in half. A shader
      // with no coverage term paints that column fully white or fully black,
      // and both read as a hard edge.
      final int edge = _pixel(target.framebuffer, 2, 4)[0];
      expect(edge, greaterThan(100));
      expect(edge, lessThan(160));
      expect(_pixel(target.framebuffer, 3, 4)[0], 0xFF);
      expect(_pixel(target.framebuffer, 1, 4)[0], 0);
      target.dispose();
    }, skip: session.skipReason);

    test('an antialiased path goes through the mask atlas', () async {
      final D3d11OffscreenTarget target = session.target(16, 16);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawRRect(2, 2, 14, 14, 4, 4, 4, 4, 4, 4, 4, 4, paint);
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      // The centre is inside the rounded rect and the corner is outside it,
      // which is only true if the R8_UNORM mask reached the texture and the
      // point sampler read it one texel per pixel.
      expect(_pixel(target.framebuffer, 8, 8)[0], 0xFF);
      expect(_pixel(target.framebuffer, 2, 2)[0], lessThan(0x40));
      target.dispose();
    }, skip: session.skipReason);

    test('a drawn image is uploaded and sampled', () async {
      final Framebuffer image = Framebuffer.allocate(
        width: 2,
        height: 2,
        format: PixelFormat.rgba8888Premultiplied,
      );
      for (var i = 0; i < 4; i++) {
        image.pixels[i * 4] = 0xFF;
        image.pixels[i * 4 + 3] = 0xFF;
      }

      final D3d11OffscreenTarget target = session.target(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      final int id = list.addImage(image);
      list.drawImage(id, 0, 0, 2, 2, 0, 0, 8, 8, paint);
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      expect(_pixel(target.framebuffer, 4, 4), <int>[0xFF, 0, 0, 0xFF]);
      expect(target.images.length, 1);
      target.dispose();
    }, skip: session.skipReason);

    test('a layer at half opacity composites through a pooled target',
        () async {
      final D3d11OffscreenTarget target = session.target(16, 16);
      final list = DisplayList();
      final background = list.addPaint(colorArgb: 0xFF000000, antiAlias: false);
      list.drawRect(0, 0, 16, 16, background);
      final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
      list.saveLayer(0, 0, 16, 16, layerPaint);
      final content = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      list
        ..drawRect(4, 4, 12, 12, content)
        ..restore();

      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);
      expect(result.status, PresentStatus.presented);
      // 0xFF white through a 0x80 layer over black is 0x80, and it is only
      // that if the content really went into an offscreen target and came back
      // as one composite. A backend that flattened the layer would paint white.
      expect(_pixel(target.framebuffer, 8, 8)[0], closeTo(0x80, 1));
      expect(target.layerPool.createdCount, greaterThan(0));
      target.dispose();
    }, skip: session.skipReason);

    test('the same layer over ten frames allocates one pooled target',
        () async {
      // Reuse is invisible in the pixels and very visible in the frame time.
      final D3d11OffscreenTarget target = session.target(16, 16);
      final list = DisplayList();
      final layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
      list.saveLayer(0, 0, 16, 16, layerPaint);
      final content = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      list
        ..drawRect(4, 4, 12, 12, content)
        ..restore();

      for (var i = 0; i < 10; i++) {
        await target.renderDisplayList(list, clearColor: 0xFF000000);
      }
      expect(target.layerPool.createdCount, 1);
      target.dispose();
    }, skip: session.skipReason);

    test('a texture larger than the device allows is refused, not fatal', () {
      final D3d11RenderDevice device = session.device!;
      final int tooBig = device.capabilities.maxTextureSize + 1;

      expect(
        () => device.createTexture(
          width: tooBig,
          height: 4,
          format: GpuTextureFormat.rgba8888Premultiplied,
        ),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
      // The point of the check: the device is still alive afterwards. Turning
      // "this image is too big" into device loss produces a renderer that can
      // never draw again, which is a worse failure than the one it reports.
      expect(device.isLost, isFalse);
      final D3d11Texture small = device.createTexture(
        width: 4,
        height: 4,
        format: GpuTextureFormat.rgba8888Premultiplied,
      );
      expect(small.isValid, isTrue);
      device.releaseTexture(small);
      expect(small.isValid, isFalse);
    }, skip: session.skipReason);

    test('textures carry the filter they were asked for', () {
      final D3d11RenderDevice device = session.device!;
      final D3d11Texture mask = device.createTexture(
        width: 8,
        height: 8,
        format: GpuTextureFormat.alpha8,
      );
      final D3d11Texture image = device.createTexture(
        width: 8,
        height: 8,
        format: GpuTextureFormat.rgba8888Premultiplied,
        filter: GpuTextureFilter.linear,
      );

      expect(mask.filter, GpuTextureFilter.nearest);
      expect(image.filter, GpuTextureFilter.linear);
      expect(mask.id, isNot(image.id));
      device
        ..releaseTexture(mask)
        ..releaseTexture(image);
    }, skip: session.skipReason);

    test('a zero-sized texture is an argument error', () {
      expect(
        () => session.device!.createTexture(
          width: 0,
          height: 8,
          format: GpuTextureFormat.alpha8,
        ),
        throwsArgumentError,
      );
    }, skip: session.skipReason);

    test('the DXGI factory is walked from the adapter and cached', () {
      // Created from the device's own adapter rather than with
      // CreateDXGIFactory1, because a swap chain must be made by the factory
      // that owns the adapter the device runs on - which works either way on a
      // single-GPU machine and fails on a laptop with two.
      final diagnostics = <BackendDiagnostic>[];
      final DxgiFactory2? first =
          session.device!.dxgiFactory(diagnostics: diagnostics);
      expect(first, isNotNull, reason: diagnostics.join('; '));
      final DxgiFactory2? second = session.device!.dxgiFactory();
      expect(identical(first, second), isTrue,
          reason: 'walking device -> IDXGIDevice -> adapter -> factory costs '
              'three COM calls and three references, so it happens once');
    }, skip: session.skipReason);

    test('a device lost is reported and never silently recovered', () {
      // The honest claim this backend makes: it detects and reports device
      // loss and does not come back from it. Forced here rather than waited
      // for, because a real TDR is not something a test can arrange.
      final D3d11RenderDevice device = D3d11RendererBackend.openDevice();
      final D3d11Texture texture = device.createTexture(
        width: 4,
        height: 4,
        format: GpuTextureFormat.alpha8,
      );
      expect(texture.isValid, isTrue);

      device.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));

      expect(device.isLost, isTrue);
      // Every resource the device made answers false, because the driver freed
      // them and the surviving pointers no longer point at textures.
      expect(texture.isValid, isFalse);
      final PresentResult? blocked = device.state.blockedPresent();
      expect(blocked, isNotNull);
      expect(blocked!.status, PresentStatus.deviceLost);
      device.dispose();
    }, skip: session.skipReason);

    test('the device refuses a descriptor it cannot present to', () {
      expect(
        () => session.device!.createTarget(const _AlienSurface()),
        throwsA(
          isA<UnsupportedCapabilityError>()
              .having(
                  (e) => e.capability, 'capability', Capability.gpuPresentation)
              .having((e) => e.toString(), 'detail',
                  contains('win32_d3d11_surface.dart')),
        ),
      );
    }, skip: session.skipReason);
  });
}

/// A descriptor no backend in this repository knows.
final class _AlienSurface implements NativeSurfaceDescriptor {
  const _AlienSurface();

  @override
  String get kind => 'alien';

  @override
  int get pixelWidth => 4;

  @override
  int get pixelHeight => 4;

  @override
  double get scale => 1.0;
}

/// One device for the whole file, or the reason there is none.
///
/// Shared because creating a device compiles two shaders and builds every
/// pipeline object, and doing that per test would make the suite's cost depend
/// on how many assertions it contains.
final class _D3d11Session {
  _D3d11Session._(this.device, this.skipReason);

  final D3d11RenderDevice? device;

  /// Null when the device opened. A string - which `skip:` accepts - when it
  /// did not, so a run on Linux names what was missing rather than passing
  /// quietly.
  final String? skipReason;

  static _D3d11Session open() {
    if (!Platform.isWindows) {
      return _D3d11Session._(null,
          'Direct3D 11 needs Windows; this is ${Platform.operatingSystem}');
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

List<int> _pixel(Framebuffer framebuffer, int x, int y) {
  final int offset = y * framebuffer.bytesPerRow + x * 4;
  return <int>[
    framebuffer.pixels[offset],
    framebuffer.pixels[offset + 1],
    framebuffer.pixels[offset + 2],
    framebuffer.pixels[offset + 3],
  ];
}
