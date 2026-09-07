/// The Metal backend's probe, and the exactness of what it claims.
///
/// This file used to assert, mostly, that the backend does **not** claim to
/// work. It now asserts something narrower and harder: that what it claims is
/// exactly what it can do. On a Mac the probe reports `supported: true` -
/// `createDevice` returns a device that renders, and `metal_cpu_parity_test`
/// holds its pixels against the CPU rasteriser - while `supportsSurface`
/// answers **true only for a memory surface**, because no drawable is ever
/// acquired.
///
/// The failure this guards against is unchanged: a `RendererBackend` that
/// probes green and then throws makes the selection policy prefer it over the
/// CPU rasteriser and the application does not start. Section 6.6 - faked
/// capability is worse than absent capability - is a runtime property here,
/// and the way to satisfy it once something works is to narrow the claim, not
/// to keep refusing everything.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_backend.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

void main() {
  const MetalRendererBackend backend = MetalRendererBackend();

  group('identity', () {
    test('names itself in the same space as the other backends', () {
      // Lowercase, stable, matched on by selection policy and never by
      // rendering code: opengl, direct3d11, direct3d12, cpu, metal.
      expect(MetalRendererBackend.backendName, 'metal');
      expect(backend.info.name, MetalRendererBackend.backendName);
      expect(backend.info.deviceDescription, isNotEmpty);
    });

    test('the description names the architecture it implements', () {
      expect(backend.info.deviceDescription, contains('IOSurface'));
      expect(backend.info.deviceDescription, contains('ADR 0005'));
    });
  });

  group('the probe', () {
    test('never throws', () {
      // The reason BackendProbeResult exists instead of a bool: a probe that
      // throws cannot report, and "no GPU here" is a normal answer.
      expect(backend.probe, returnsNormally);
    });

    test('supported exactly where a device can be opened', () {
      final BackendProbeResult result = backend.probe();
      expect(result.backendName, 'metal');
      expect(result.diagnostics, isNotEmpty);
      if (!Platform.isMacOS) {
        expect(result.supported, isFalse);
        return;
      }
      // True on the macOS leg of CI, and true because
      // MTLCreateSystemDefaultDevice answered: the probe opens a device and
      // throws it away rather than inferring one from the presence of
      // Metal.framework. A headless Mac has the framework and no GPU.
      expect(result.supported, isTrue);
    });

    test('claims both presentations, and still never a window', () {
      // This test asserted `never gpuPresentation` until 07/09/2026, and the
      // reason it changed is a measurement rather than a decision: run
      // 34165428755 wrapped an IOSurface as an MTLTexture, drew into it and
      // read the right bytes back out through IOSurfaceLock. The condition
      // Capability.gpuPresentation documents - a window surface can be handed
      // to createTarget and the pixels reach a screen without a readback - is
      // now met by MetalWindowTarget.
      //
      // cpuPresentation stays, and is not redundant: the memory target still
      // reaches the caller through getBytes:, which genuinely is a readback.
      // The two capabilities describe two surface kinds, not two opinions
      // about one.
      final BackendProbeResult result = backend.probe();
      // Capability.window is a *windowing* backend's claim - the thing that
      // creates an NSWindow - and a renderer never creates one. That this
      // stays absent while gpuPresentation appears is the distinction.
      expect(result.capabilities, isNot(contains(Capability.window)));
      if (Platform.isMacOS) {
        expect(result.capabilities, contains(Capability.cpuPresentation));
        expect(result.capabilities, contains(Capability.gpuPresentation));
      } else {
        expect(result.capabilities, isEmpty);
      }
    });

    test('every diagnostic says something actionable', () {
      for (final BackendDiagnostic diagnostic in backend.probe().diagnostics) {
        expect(diagnostic.message, isNotEmpty);
        expect(diagnostic.message.length, greaterThan(10),
            reason: 'a diagnostic nobody can act on is worse than none: '
                '"${diagnostic.message}"');
      }
    });

    test('off macOS it says Metal is not on this platform', () {
      if (Platform.isMacOS) return;
      final BackendProbeResult result = backend.probe();
      final BackendDiagnostic first = result.diagnostics.first;
      expect(first.kind, DiagnosticKind.unsupportedPlatform);
      expect(first.message, contains('Apple'));
      // And says so without blaming the machine: this is the expected result
      // on Windows and Linux, not a defect.
      expect(first.detail, contains('not a defect'));
    });

    test('on macOS it names what is still missing, by name', () {
      if (!Platform.isMacOS) return;
      final BackendProbeResult result = backend.probe();
      final Iterable<BackendDiagnostic> policy = result.diagnostics.where(
          (BackendDiagnostic d) => d.kind == DiagnosticKind.rejectedByPolicy);
      expect(policy, hasLength(1));
      // A probe that says "supported" and stops is useless to whoever has to
      // decide whether to select this backend for a window. What is still
      // missing changed on 07/09/2026 - presentation landed, text and clips
      // did not - so this asserts the current refusals by name rather than
      // the old ones.
      expect(policy.single.message, contains('IOSurface'));
      expect(policy.single.detail, contains('PRESENT_SLOT'));
      expect(policy.single.detail, contains('glyph atlas'));
      expect(policy.single.detail, contains('refused by name'));
    });
  });

  group('supportsSurface', () {
    test('a memory surface yes', () {
      expect(
        backend.supportsSurface(
            const MemorySurfaceDescriptor(pixelWidth: 4, pixelHeight: 4)),
        isTrue,
      );
    });

    test('a presentable IOSurface yes', () {
      // ADR 0005's window path. Answered on any platform, because
      // supportsSurface is a question about the *descriptor* and not about
      // the machine - the machine question is probe(), and selection asks
      // both.
      expect(backend.supportsSurface(_FakePresentSurface()), isTrue);
    });

    test('anything else no', () {
      // The narrowing that lets `supported: true` stay honest: selection
      // policy asks this per surface, so a backend that presents to two kinds
      // of surface says which two instead of claiming all of them. A
      // CAMetalLayer surface would land here, and deliberately: on the macOS
      // backend that owns the window the layer is in another process.
      expect(backend.supportsSurface(const _NotAMemorySurface()), isFalse);
    });
  });

  group('createDevice', () {
    test('off macOS it throws a selection error carrying the probe', () async {
      if (Platform.isMacOS) return;
      Object? thrown;
      try {
        await backend.createDevice();
      } on Object catch (error) {
        thrown = error;
      }
      // The difference between "you have no GPU" and "this renderer is not
      // finished". They call for opposite reactions, and only the diagnostics
      // distinguish them.
      expect(thrown, isA<BackendSelectionError>());
      final BackendSelectionError error = thrown! as BackendSelectionError;
      expect(error.requested, 'metal');
      expect(error.attempts, hasLength(1));
      expect(error.attempts.single.diagnostics, isNotEmpty);
      expect(error.attempts.single.supported, isFalse);
    });

    test('on macOS it opens a device that draws', () async {
      if (!Platform.isMacOS) return;
      final RenderDevice device = await backend.createDevice();
      try {
        expect(device.isLost, isFalse);
        expect(device.info.name, 'metal');
        // Which GPU it is, which is the one piece of a RendererInfo a bug
        // report needs.
        expect(device.info.deviceDescription, contains('Metal on '));
        expect(
            device.capabilities
                .supportsFormat(PixelFormat.rgba8888Premultiplied),
            isTrue);
        expect(device.capabilities.supportsCompute, isFalse);

        final RenderTarget target = device.createTarget(
          const MemorySurfaceDescriptor(
            pixelWidth: 8,
            pixelHeight: 8,
            format: PixelFormat.rgba8888Premultiplied,
          ),
        );
        try {
          // A value, not a survival: the frame carries the buffer the readback
          // lands in, and the present has to say it presented.
          final Frame frame =
              target.beginFrame(const FrameRequest(clearColor: 0xFF204060));
          final PresentResult result = await target.present(frame);
          expect(result.status, PresentStatus.presented);
          expect(frame.hasCpuPixels, isTrue);
          final Framebuffer pixels = frame.framebuffer;
          expect(
            <int>[
              pixels.pixels[0],
              pixels.pixels[1],
              pixels.pixels[2],
              pixels.pixels[3],
            ],
            <int>[0x20, 0x40, 0x60, 0xFF],
          );

          // A frame from before a resize is refused rather than drawn into a
          // texture that no longer exists.
          final Frame stale = target.beginFrame(const FrameRequest());
          target.resize(16, 16, 1);
          expect((await target.present(stale)).status, PresentStatus.stale);
          expect(target.generation, 1);
        } finally {
          target.dispose();
        }

        // A window surface is refused by name, by the same object that just
        // accepted a memory one.
        expect(
          () => device.createTarget(const _NotAMemorySurface()),
          throwsA(isA<UnsupportedCapabilityError>()),
        );
      } finally {
        device.dispose();
      }
    });
  });

  group('describeSystemDefaultDevice', () {
    test('is empty and silent where there is no Metal', () {
      if (Platform.isMacOS) return;
      expect(MetalRendererBackend.describeSystemDefaultDevice, returnsNormally);
      expect(MetalRendererBackend.describeSystemDefaultDevice(), isEmpty);
    });

    test('names the GPU and the registryID question', () {
      // The one piece of this file that survives unchanged once the device
      // exists. ADR 0005 records an open doubt - two processes each open their
      // own MTLDevice, and on a Mac with two GPUs they may not be the same one
      // - and this is where the number that would answer it is reported.
      final List<BackendDiagnostic> report =
          MetalRendererBackend.describeSystemDefaultDevice();
      if (report.isEmpty) return;
      expect(report.single.message, isNotEmpty);
    },
        skip: Platform.isMacOS
            ? null
            : 'needs a Mac: reads -[MTLDevice name] and -[MTLDevice registryID] '
                'off a real device. On Windows there is no Objective-C runtime to '
                'send a message to, and the empty-and-silent case is covered by '
                'the test above.');
  });
}

/// A surface descriptor this backend has never been able to present to.
///
/// Declared here rather than borrowed from a window backend so that the test
/// does not need Win32 or X11 types to say "not a memory surface".
final class _NotAMemorySurface implements NativeSurfaceDescriptor {
  const _NotAMemorySurface();

  @override
  String get kind => 'not-a-memory-surface';

  @override
  int get pixelWidth => 8;

  @override
  int get pixelHeight => 8;

  @override
  double get scale => 1;
}

/// A window surface with no window behind it.
///
/// Enough to answer [MetalRendererBackend.supportsSurface], which asks only
/// what kind of thing it is - and deliberately not enough to present, so a
/// test that accidentally tried would get a named refusal rather than a
/// crash.
final class _FakePresentSurface implements MetalPresentSurface {
  @override
  String get kind => 'iosurface';

  @override
  int get pixelWidth => 8;

  @override
  int get pixelHeight => 8;

  @override
  double get scale => 1;

  @override
  int get slotCount => 2;

  @override
  int get backSlot => 0;

  @override
  int get bytesPerRow => 64;

  @override
  bool get isPresentable => false;

  @override
  int get presentGeneration => 0;

  @override
  Pointer<Void> surfaceRefForSlot(int slot) => nullptr;

  @override
  Future<PresentResult> presentBackBuffer({required int generation}) async =>
      const PresentResult(status: PresentStatus.failed);
}
