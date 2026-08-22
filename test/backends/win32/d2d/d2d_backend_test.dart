/// The Direct2D backend against the real runtime, when there is one.
///
/// The same shape as `d3d12_device_test.dart`: skips - with the reason
/// printed - on any machine that is not Windows, and asserts the failure path
/// too, because "probe reports instead of throwing" is the half of section
/// 6.6 that is easy to leave untested.
library;

import 'package:dart_ui/src/backends/win32/d2d/d2d1_library.dart';
import 'package:dart_ui/src/backends/win32/d2d/d2d_backend.dart';
import 'package:dart_ui/src/backends/win32/d2d/d2d_targets.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import 'd2d_session.dart';

void main() {
  final D2dSession session = D2dSession.open();

  tearDownAll(session.close);

  group('the backend reports what this machine can do', () {
    test('probe never throws and always names its conclusion', () {
      final BackendProbeResult result = const D2dRendererBackend().probe();
      printOnFailure(result.describe());
      if (result.supported) {
        expect(result.supports(Capability.gpuPresentation), isTrue);
        expect(result.diagnostics, isNotEmpty);
      } else {
        expect(result.diagnostics, isNotEmpty,
            reason: 'an unsupported probe with no diagnostic is exactly the '
                'silent failure section 6.6 forbids');
      }
    });

    test('the library loader reports a missing DLL as data', () {
      // On Windows this loads; elsewhere it must *report*, not throw. Both
      // arms assert the contract that matters on the machine the test is on.
      final D2d1LibraryLoad load = D2d1Library.open();
      if (load.isLoaded) {
        expect(load.diagnostics, isEmpty);
      } else {
        expect(load.diagnostics, isNotEmpty);
      }
    });
  });

  group('the device over a real factory', () {
    test('opens, describes itself, and refuses foreign surfaces by name', () {
      final D2dRenderDevice device = session.device!;
      expect(device.info.name, 'direct2d');
      expect(device.isLost, isFalse);
      expect(
        device.capabilities.supportsFormat(PixelFormat.bgra8888Premultiplied),
        isTrue,
      );
      expect(
        () => device.createTarget(const MemorySurfaceDescriptor(
          pixelWidth: 8,
          pixelHeight: 8,
        )),
        throwsA(isA<UnsupportedCapabilityError>()),
        reason: 'memory surfaces belong to D2dOffscreenSurface; quietly '
            'rendering offscreen for a window request would show nothing',
      );
    }, skip: session.skipReason);

    test('supportsSurface answers by descriptor type, not by name', () {
      const D2dRendererBackend backend = D2dRendererBackend();
      expect(
        backend.supportsSurface(Win32D2dSurfaceDescriptor(
          windowHandle: 0x1234,
          pixelWidth: 10,
          pixelHeight: 10,
          generation: GenerationToken(),
        )),
        isTrue,
      );
      expect(
        backend.supportsSurface(
          const MemorySurfaceDescriptor(pixelWidth: 8, pixelHeight: 8),
        ),
        isFalse,
      );
    });

    test('an offscreen surface opens and reads back its size', () {
      final D2dOffscreenSurface surface = session.surface(16, 12);
      addTearDown(surface.dispose);
      final Framebuffer pixels = surface.readback();
      expect(pixels.width, 16);
      expect(pixels.height, 12);
      expect(pixels.format, PixelFormat.bgra8888Premultiplied);
    }, skip: session.skipReason);
  }, skip: D2dSession.platformSkip);
}
