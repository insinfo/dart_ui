import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('BackendDiagnostic', () {
    test('separates the human message from the raw evidence', () {
      const diagnostic = BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'swapchain creation failed',
        detail: 'HRESULT=0x887A0004',
      );

      // The detail stays greppable rather than being folded into prose.
      expect(diagnostic.toString(), contains('HRESULT=0x887A0004'));
      expect(diagnostic.isFailure, isTrue);
    });

    test('a note is not a failure', () {
      const diagnostic = BackendDiagnostic.note('fell back to CPU raster');

      expect(diagnostic.isFailure, isFalse);
    });

    test('the named constructors carry the thing that was missing', () {
      const library = BackendDiagnostic.missingLibrary('libwayland-client.so');
      const symbol = BackendDiagnostic.missingSymbol('SLSGetEventPort');

      expect(library.message, contains('libwayland-client.so'));
      expect(library.kind, DiagnosticKind.missingLibrary);
      expect(symbol.message, contains('SLSGetEventPort'));
      expect(symbol.kind, DiagnosticKind.missingSymbol);
    });
  });

  group('BackendProbeResult', () {
    test('reports capabilities as a set that callers cannot mutate', () {
      final result = BackendProbeResult(
        backendName: 'win32',
        supported: true,
        capabilities: {Capability.window, Capability.cpuPresentation},
      );

      expect(result.supports(Capability.window), isTrue);
      expect(result.supports(Capability.vsync), isFalse);
      expect(
        () => result.capabilities.add(Capability.vsync),
        throwsUnsupportedError,
      );
    });

    test('separates failures from notes', () {
      final result = BackendProbeResult(
        backendName: 'wayland',
        supported: false,
        diagnostics: const [
          BackendDiagnostic.note('compositor is sway 1.9'),
          BackendDiagnostic.missingSymbol('xdg_wm_base'),
        ],
      );

      expect(result.diagnostics, hasLength(2));
      expect(result.failures, hasLength(1));
      expect(result.failures.single.kind, DiagnosticKind.missingSymbol);
    });

    test('describe names every fact, which is the whole point of the type', () {
      final description = BackendProbeResult(
        backendName: 'x11',
        supported: false,
        diagnostics: const [
          BackendDiagnostic(
            kind: DiagnosticKind.connectionFailed,
            message: 'cannot open display',
            detail: r'DISPLAY=',
          ),
        ],
      ).describe();

      expect(description, contains('backend: x11'));
      expect(description, contains('supported: false'));
      expect(description, contains('cannot open display'));
    });

    test('unsupported() is the single-reason shorthand', () {
      final result = BackendProbeResult.unsupported(
        'metal',
        const BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'no Metal-capable device',
        ),
      );

      expect(result.supported, isFalse);
      expect(result.capabilities, isEmpty);
      expect(result.failures, hasLength(1));
    });
  });

  group('BackendSelectionError', () {
    test('carries every attempt, so the message says what was tried', () {
      final error = BackendSelectionError(
        requested: 'vulkan',
        attempts: [
          BackendProbeResult.unsupported(
            'vulkan',
            const BackendDiagnostic.missingLibrary('libvulkan.so.1'),
          ),
          BackendProbeResult.unsupported(
            'opengl',
            const BackendDiagnostic(
              kind: DiagnosticKind.incompatibleVersion,
              message: 'needs GL 3.3, found 2.1',
            ),
          ),
        ],
      ).toString();

      // Both refusals survive into the message: silently falling through to
      // the next backend is exactly what section 6.6 forbids.
      expect(error, contains('requested: vulkan'));
      expect(error, contains('libvulkan.so.1'));
      expect(error, contains('needs GL 3.3'));
    });
  });

  group('UnsupportedCapabilityError', () {
    test('names the backend and the capability', () {
      final error = UnsupportedCapabilityError(
        backendName: 'skylight',
        capability: Capability.accessibility,
      ).toString();

      expect(error, contains('skylight'));
      expect(error, contains('accessibility'));
    });
  });
}
