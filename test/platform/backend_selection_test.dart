import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

BackendCandidate candidate(
  String name, {
  bool supported = true,
  Set<Capability> capabilities = const {Capability.window},
  bool experimental = false,
  List<BackendDiagnostic> diagnostics = const [],
}) =>
    BackendCandidate(
      name: name,
      experimental: experimental,
      probe: BackendProbeResult(
        backendName: name,
        supported: supported,
        capabilities: capabilities,
        diagnostics: diagnostics,
      ),
    );

void main() {
  group('selectBackend', () {
    test('takes the first that qualifies, in the order given', () {
      final selection = selectBackend([
        candidate('vulkan', supported: false),
        candidate('opengl'),
        candidate('cpu'),
      ]);

      expect(selection.chosen?.name, 'opengl');
      expect(selection.isSuccess, isTrue);
    });

    test('records why each one was passed over, including the healthy ones',
        () {
      final selection = selectBackend([
        candidate(
          'vulkan',
          supported: false,
          diagnostics: const [
            BackendDiagnostic.missingLibrary('libvulkan.so.1'),
          ],
        ),
        candidate('opengl'),
        candidate('cpu'),
      ]);

      final byName = {for (final r in selection.rejected) r.name: r};
      expect(byName['vulkan']!.reason, RejectionReason.unsupported);
      // cpu was fine. It lost to opengl, and saying so is the difference
      // between a log that answers the next bug report and one that does not.
      expect(byName['cpu']!.reason, RejectionReason.outranked);
      expect(byName['cpu']!.detail, contains('opengl'));
    });

    test('a required capability outweighs order', () {
      final selection = selectBackend(
        [
          candidate('opengl', capabilities: {Capability.window}),
          candidate('cpu', capabilities: {
            Capability.window,
            Capability.cpuPresentation,
          }),
        ],
        required: {Capability.cpuPresentation},
      );

      expect(selection.chosen?.name, 'cpu');
      final rejection = selection.rejected.single;
      expect(rejection.reason, RejectionReason.missingCapability);
      // Naming the capability, not just "did not qualify".
      expect(rejection.detail, contains('cpuPresentation'));
    });

    test('an experimental backend is never chosen without opting in', () {
      final candidates = [
        candidate('appkitSignal', experimental: true),
        candidate('appkitNativeHost'),
      ];

      expect(selectBackend(candidates).chosen?.name, 'appkitNativeHost');
      expect(
        selectBackend(candidates, allowExperimental: true).chosen?.name,
        'appkitSignal',
      );
      expect(
        selectBackend(candidates).rejected.first.reason,
        RejectionReason.needsExplicitOptIn,
      );
    });

    test('a pinned backend that cannot run fails instead of falling back', () {
      // The whole point of section 6.6. Asking for vulkan and silently
      // getting the CPU renderer is the outcome this refuses to produce.
      final selection = selectBackend(
        [
          candidate('vulkan', supported: false),
          candidate('cpu'),
        ],
        requested: 'vulkan',
      );

      expect(selection.isSuccess, isFalse);
      expect(selection.chosen, isNull);
      expect(
        selection.rejected.firstWhere((r) => r.name == 'cpu').reason,
        RejectionReason.notRequested,
      );
    });

    test('describe carries the whole story, on success too', () {
      final description = selectBackend(
        [
          candidate(
            'vulkan',
            supported: false,
            diagnostics: const [
              BackendDiagnostic.missingLibrary('libvulkan.so.1'),
            ],
          ),
          candidate('opengl'),
        ],
        required: {Capability.window},
      ).describe();

      expect(description, contains('chosen: opengl'));
      expect(description, contains('vulkan'));
      expect(description, contains('libvulkan.so.1'));
      expect(description, contains('window'));
    });

    test('nothing qualifying is a reportable outcome, not an exception', () {
      final selection = selectBackend([
        candidate('vulkan', supported: false),
        candidate('opengl', supported: false),
      ]);

      expect(selection.isSuccess, isFalse);
      expect(selection.rejected, hasLength(2));
      expect(selection.describe(), contains('chosen: none'));
    });
  });
}
