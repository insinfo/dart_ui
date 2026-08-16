/// The Direct3D 12 device against a real driver, when there is one.
///
/// The same shape as `test/rendering/gpu/gl_device_test.dart` and for the same
/// reason: a struct layout that is right and a device that never opened
/// produce a suite that is green and a renderer that has never drawn a pixel.
///
/// It skips - with the reason printed - on any machine that is not Windows or
/// has no Direct3D 12 adapter, because "this CI container has no GPU" is not a
/// defect in the renderer. The failure path is asserted too: on a machine
/// without the runtime the backend must come back with a named diagnostic and
/// not with an exception, which is the half of section 6.6 that is easy to
/// leave untested.
library;

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_backend.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_library.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_offscreen_target.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import 'd3d12_session.dart';

void main() {
  final D3d12Session session = D3d12Session.open();

  group('the backend reports what this machine can do', () {
    test('probe never throws and always names its conclusion', () {
      final BackendProbeResult result = const D3d12RendererBackend().probe();
      printOnFailure(result.describe());
      if (result.supported) {
        expect(result.supports(Capability.gpuPresentation), isTrue);
        // A supported backend still carries notes - the feature level, the
        // declared refusal of offscreen layers - so the report is never empty.
        expect(result.diagnostics, isNotEmpty);
      } else {
        // The half that matters on a machine without Direct3D 12: the answer
        // is not a bare false, it names what was missing.
        expect(result.failures, isNotEmpty);
      }
    }, skip: D3d12Session.platformSkip);

    test('a machine without the runtime is a diagnostic, not an exception', () {
      // Not simulated: this asserts the shape the loader promises, on whatever
      // machine is running. Either the libraries loaded, or the attempt names
      // the one that did not - never a thrown ArgumentError out of
      // lookupFunction, which tells a caller nothing about which DLL was
      // absent.
      final D3d12LibraryLoad load = D3d12Library.open();
      if (load.isLoaded) {
        expect(load.diagnostics.where((d) => d.isFailure), isEmpty);
      } else {
        expect(load.diagnostics, isNotEmpty);
        expect(
          load.diagnostics.first.kind,
          anyOf(DiagnosticKind.missingLibrary, DiagnosticKind.missingSymbol),
        );
        printOnFailure(load.diagnostics.join('\n'));
      }
    }, skip: D3d12Session.platformSkip);

    test('supportsSurface accepts exactly the two descriptors it builds', () {
      const D3d12RendererBackend backend = D3d12RendererBackend();
      expect(
        backend.supportsSurface(const MemorySurfaceDescriptor(
          pixelWidth: 4,
          pixelHeight: 4,
        )),
        isTrue,
      );
      expect(backend.supportsSurface(_ForeignSurface()), isFalse);
    }, skip: D3d12Session.platformSkip);
  });

  group('a live Direct3D 12 device', () {
    tearDownAll(session.close);

    test('reports an adapter and the feature level it was created at', () {
      final D3d12RenderDevice device = session.device!;
      // An empty adapter string means DXGI answered and the description was
      // never read, which looks like a working renderer until a bug report
      // needs to say which GPU it was.
      expect(device.info.deviceDescription, isNotEmpty);
      // Declared, not defaulted: D3D12CreateDevice takes a *minimum* level and
      // this backend probes highest first, so the reported one is the highest
      // that answered.
      expect(
        device.featureLevelText,
        anyOf('11_0', '11_1', '12_0', '12_1', '12_2'),
      );
      expect(device.info.driverVersion, contains(device.featureLevelText));
      printOnFailure('${device.info.deviceDescription} at feature level '
          '${device.featureLevelText}');
    }, skip: session.skipReason);

    test('answers its capabilities honestly', () {
      final RendererCapabilities capabilities = session.device!.capabilities;
      // FLIP_DISCARD throws the back buffer's contents away on every present,
      // so there is nothing a damage rectangle could preserve.
      expect(capabilities.supportsPartialPresent, isFalse);
      // The antialiasing is analytic - boxCoverage in the pixel shader and the
      // coverage-mask atlas - and nothing here creates a multisample resource.
      expect(capabilities.supportsMsaa, isFalse);
      expect(capabilities.supportsCompute, isFalse);
      expect(capabilities.maxTextureSize, greaterThanOrEqualTo(16384));
      expect(capabilities.supportsFormat(PixelFormat.rgba8888Premultiplied),
          isTrue);
    }, skip: session.skipReason);

    test('clears to the requested colour', () async {
      final D3d12OffscreenTarget target = session.target(4, 4);
      final PresentResult result =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF204060);

      expect(result.status, PresentStatus.presented);
      expect(_pixel(target.framebuffer, 0, 0), <int>[0x20, 0x40, 0x60, 0xFF]);
      target.dispose();
    }, skip: session.skipReason);

    test('draws an aliased rectangle at exactly the pixels asked for',
        () async {
      final D3d12OffscreenTarget target = session.target(8, 8);
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF3366CC, antiAlias: false);
      list.drawRect(2, 1, 6, 4, paint);
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      final Framebuffer framebuffer = target.framebuffer;
      // Inside, on the boundary and outside. Direct3D writes render-target row
      // 0 at the top, so an off-by-one in the projection - or a stray y flip
      // ported from the GL backend, which needs one - moves the whole
      // rectangle and nothing else notices.
      expect(_pixel(framebuffer, 2, 1), <int>[0x33, 0x66, 0xCC, 0xFF]);
      expect(_pixel(framebuffer, 5, 3), <int>[0x33, 0x66, 0xCC, 0xFF]);
      expect(_pixel(framebuffer, 1, 1), <int>[0, 0, 0, 0xFF]);
      expect(_pixel(framebuffer, 6, 1), <int>[0, 0, 0, 0xFF]);
      expect(_pixel(framebuffer, 2, 4), <int>[0, 0, 0, 0xFF]);
      target.dispose();
    }, skip: session.skipReason);

    test('the analytic coverage antialiases a half-pixel edge', () async {
      final D3d12OffscreenTarget target = session.target(8, 8);
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawRect(2.5, 0, 6, 8, paint);
      await target.renderDisplayList(list, clearColor: 0xFF000000);

      // boxCoverage on a rect whose left edge cuts column 2 in half. A
      // renderer with no coverage term paints that column either fully white
      // or fully black; both are visible as a hard edge.
      final int edge = _pixel(target.framebuffer, 2, 4)[0];
      expect(edge, greaterThan(100));
      expect(edge, lessThan(160));
      expect(_pixel(target.framebuffer, 3, 4)[0], 0xFF);
      expect(_pixel(target.framebuffer, 1, 4)[0], 0);
      target.dispose();
    }, skip: session.skipReason);

    test('an antialiased path goes through the coverage mask atlas', () async {
      final D3d12OffscreenTarget target = session.target(16, 16);
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawRRect(2, 2, 14, 14, 4, 4, 4, 4, 4, 4, 4, 4, paint);
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      // The centre is inside the rounded rect and the corner is outside it,
      // which is only true if the alpha8 mask reached the texture through the
      // upload heap and the copy.
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

      final D3d12OffscreenTarget target = session.target(8, 8);
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      final int id = list.addImage(image);
      list.drawImage(id, 0, 0, 2, 2, 0, 0, 8, 8, paint);
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      expect(_pixel(target.framebuffer, 4, 4), <int>[0xFF, 0, 0, 0xFF]);
      expect(target.images.length, 1);
      target.dispose();
    }, skip: session.skipReason);

    test('a texture larger than the device allows is refused, not fatal', () {
      final D3d12RenderDevice device = session.device!;
      final int tooBig = device.capabilities.maxTextureSize + 1;

      expect(
        () => device.createTexture(
          width: tooBig,
          height: 4,
          format: GpuTextureFormat.rgba8888Premultiplied,
        ),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
      // The point of the check: the device is still alive afterwards.
      expect(device.isLost, isFalse);
      final D3d12Texture small = device.createTexture(
        width: 4,
        height: 4,
        format: GpuTextureFormat.rgba8888Premultiplied,
      );
      expect(small.isValid, isTrue);
      // A real texture never collides with kNoTexture, because descriptor
      // index 0 is reserved for the placeholder the device binds for a batch
      // that samples nothing.
      expect(small.id, isNot(kNoTexture));
      device.releaseTexture(small);
    }, skip: session.skipReason);

    test('an offscreen layer is refused by name rather than flattened',
        () async {
      // The declared limit of this backend, asserted so it cannot rot into a
      // silent wrong picture. A layer at 50% opacity drawn straight into its
      // parent renders at 100% and reports nothing, which reads as a paint bug
      // several layers of abstraction away from the missing feature.
      final D3d12OffscreenTarget target = session.target(16, 16);
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0x80FFFFFF);
      final int solid = list.addPaint(colorArgb: 0xFFFF0000, antiAlias: false);
      list
        ..saveLayer(0, 0, 16, 16, paint)
        ..drawRect(2, 2, 14, 14, solid)
        ..restore();

      await expectLater(
        target.renderDisplayList(list, clearColor: 0xFF000000),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
      target.dispose();
    }, skip: session.skipReason);
  });
}

/// A descriptor from no backend at all, to prove `supportsSurface` says no.
final class _ForeignSurface implements NativeSurfaceDescriptor {
  @override
  String get kind => 'foreign';
  @override
  int get pixelWidth => 4;
  @override
  int get pixelHeight => 4;
  @override
  double get scale => 1;
}

List<int> _pixel(Framebuffer framebuffer, int x, int y) {
  final int offset = framebuffer.offsetOf(x, y);
  return <int>[
    framebuffer.pixels[offset],
    framebuffer.pixels[offset + 1],
    framebuffer.pixels[offset + 2],
    framebuffer.pixels[offset + 3],
  ];
}
