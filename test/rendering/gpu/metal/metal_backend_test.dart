/// The Metal backend's probe, and the honesty of its refusal.
///
/// Most of what is asserted here is that the backend does **not** claim to
/// work. That reads oddly for a test suite until the failure it prevents is
/// named: a `RendererBackend` that probes `supported: true` and then throws
/// from `createDevice` makes the selection policy prefer it over the CPU
/// rasteriser, and the application does not start. Section 6.6 - faked
/// capability is worse than absent capability - is a runtime property here, not
/// a slogan, and this is where it is checked.
library;

import 'dart:io';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_backend.dart';
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

    test('reports unsupported, everywhere, today', () {
      final BackendProbeResult result = backend.probe();
      expect(result.backendName, 'metal');
      expect(result.supported, isFalse);
      expect(result.diagnostics, isNotEmpty);
    });

    test('claims no capability', () {
      // An unsupported backend that still listed gpuPresentation would be read
      // by a capability report as a machine that can do it.
      expect(backend.probe().capabilities, isEmpty);
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

    test('on macOS the refusal is the code, not the machine', () {
      if (!Platform.isMacOS) return;
      final BackendProbeResult result = backend.probe();
      expect(result.supported, isFalse);
      final Iterable<BackendDiagnostic> policy = result.diagnostics.where(
          (BackendDiagnostic d) => d.kind == DiagnosticKind.rejectedByPolicy);
      // Either the frameworks are missing - a legitimate machine answer - or
      // they are present and the refusal names this renderer as the thing that
      // is unfinished. What must never happen is supported: true.
      if (policy.isNotEmpty) {
        expect(policy.single.message, contains('no device implementation'));
        expect(policy.single.detail, contains('6.6'));
      }
    });
  });

  group('supportsSurface', () {
    test('is false for a memory surface, because there is no device', () {
      // Not a placeholder. A backend that cannot create a device supports no
      // surface, and answering otherwise would describe the backend that is
      // intended rather than the one that exists.
      expect(
        backend.supportsSurface(
            const MemorySurfaceDescriptor(pixelWidth: 4, pixelHeight: 4)),
        isFalse,
      );
    });
  });

  group('createDevice', () {
    test('throws a selection error carrying the probe', () async {
      await expectLater(
        backend.createDevice(),
        throwsA(isA<BackendSelectionError>().having(
          (BackendSelectionError error) => error.requested,
          'requested',
          'metal',
        )),
      );
    });

    test('the error carries the diagnostics, not just a name', () async {
      // The difference between "you have no GPU" and "this renderer is not
      // finished". They call for opposite reactions, and only the diagnostics
      // distinguish them.
      Object? thrown;
      try {
        await backend.createDevice();
      } on Object catch (error) {
        thrown = error;
      }
      expect(thrown, isA<BackendSelectionError>());
      final BackendSelectionError error = thrown! as BackendSelectionError;
      expect(error.attempts, hasLength(1));
      expect(error.attempts.single.diagnostics, isNotEmpty);
      expect(error.attempts.single.supported, isFalse);
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
