/// Section 5.1's policy, checked one clause at a time.
///
/// The clause that matters most here is the last one: what happens to a GPU
/// candidate while `Capability.gpuPresentation` does not exist yet. The wrong
/// answer - and the easy one - is to let it lose quietly to the CPU path,
/// which is precisely the failure section 6.6 was written against: an
/// application running on the software rasteriser on a machine with a good GPU,
/// with nothing in any log that says why.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

PresentationCandidate path(
  String name, {
  PresentationKind kind = PresentationKind.cpu,
  bool supported = true,
  Set<Capability>? capabilities,
  bool experimental = false,
  List<BackendDiagnostic> diagnostics = const <BackendDiagnostic>[],
}) =>
    PresentationCandidate(
      name: name,
      kind: kind,
      experimental: experimental,
      probe: BackendProbeResult(
        backendName: name,
        supported: supported,
        capabilities: capabilities ??
            (kind == PresentationKind.cpu
                ? const <Capability>{Capability.cpuPresentation}
                : const <Capability>{Capability.gpuPresentation}),
        diagnostics: diagnostics,
      ),
    );

void main() {
  group('the GPU extension point', () {
    test('rendering policy can force either presentation family', () {
      final List<PresentationCandidate> candidates = <PresentationCandidate>[
        path(
          'gpu',
          kind: PresentationKind.gpu,
          capabilities: const <Capability>{Capability.gpuPresentation},
        ),
        path(
          'cpu',
          capabilities: const <Capability>{Capability.cpuPresentation},
        ),
      ];

      final PresentationSelection cpu = selectPresentation(
        candidates,
        renderingPolicy: RenderingPolicy.cpuOnly,
      );
      final PresentationSelection gpu = selectPresentation(
        candidates,
        renderingPolicy: RenderingPolicy.gpuOnly,
      );

      expect(cpu.chosen?.name, 'cpu');
      expect(
        cpu.rejected.single.reason,
        RejectionReason.rejectedByPolicy,
      );
      expect(gpu.chosen?.name, 'gpu');
      expect(gpu.renderingPolicy, RenderingPolicy.gpuOnly);
    });

    test('by default a GPU path is verified against gpuPresentation', () {
      final selection = selectPresentation(<PresentationCandidate>[
        path(
          'direct2d',
          kind: PresentationKind.gpu,
          capabilities: const <Capability>{Capability.gpuPresentation},
        ),
        path('cpu'),
      ]);

      expect(selection.chosen?.name, 'direct2d');
      expect(selection.chosen?.kind, PresentationKind.gpu);
      expect(kGpuPresentationCapability, Capability.gpuPresentation);
      expect(selection.describe(), contains('gpu capability: gpuPresentation'));
      expect(selection.rejected.single.reason, RejectionReason.outranked);
    });

    test('a GPU path that only reports cpuPresentation is named, not guessed',
        () {
      // The real case: an offscreen-only GL context reads its framebuffer back
      // to the CPU and honestly reports `cpuPresentation`. It must lose *and
      // say so*, because "the GPU backend is right there and something chose
      // the software rasteriser" is the report that answers the bug.
      final selection = selectPresentation(<PresentationCandidate>[
        path(
          'opengl',
          kind: PresentationKind.gpu,
          capabilities: const <Capability>{Capability.cpuPresentation},
        ),
        path('cpu'),
      ]);

      expect(selection.chosen?.name, 'cpu');
      final rejection =
          selection.rejected.firstWhere((r) => r.name == 'opengl');
      expect(rejection.reason, RejectionReason.missingCapability);
      expect(rejection.detail, 'gpuPresentation');
    });

    test('supplying no capability rejects every GPU path by name', () {
      // Still a supported configuration, and still loud: an application that
      // wants to prove it is on the CPU path passes null and gets a report
      // naming why each GPU candidate was refused, rather than a silent loss.
      final selection = selectPresentation(
        <PresentationCandidate>[
          path(
            'direct2d',
            kind: PresentationKind.gpu,
            capabilities: const <Capability>{Capability.gpuPresentation},
          ),
          path('cpu'),
        ],
        gpuPresentationCapability: null,
      );

      expect(selection.chosen?.name, 'cpu');
      expect(selection.gpuPresentationCapability, isNull);

      final rejection =
          selection.rejected.firstWhere((r) => r.name == 'direct2d');
      expect(rejection.reason, RejectionReason.missingCapability);
      expect(rejection.detail, contains('gpuPresentation'));
      expect(rejection.detail, contains('kGpuPresentationCapability'));
      expect(selection.describe(), contains('gpu capability: none supplied'));
    });
  });

  group('declared preference', () {
    test('hoists the named paths without scrambling the rest', () {
      final selection = selectPresentation(
        <PresentationCandidate>[
          path('cpu'),
          path('win32-dib'),
          path('x11-putimage'),
        ],
        preferred: <String>['x11-putimage', 'win32-dib'],
      );

      expect(selection.chosen?.name, 'x11-putimage');
      // The fallback chain is preserved below the preference: win32-dib was
      // preferred second, so it is the one that lost to the winner directly.
      expect(selection.rejected.map((r) => r.name).toList(),
          <String>['win32-dib', 'cpu']);
    });

    test('a preference for something absent changes nothing', () {
      final selection = selectPresentation(
        <PresentationCandidate>[path('cpu'), path('win32-dib')],
        preferred: <String>['metal'],
      );

      expect(selection.chosen?.name, 'cpu');
    });
  });

  group('overrides', () {
    test('a flag pins the path', () {
      final selection = selectPresentation(
        <PresentationCandidate>[path('cpu'), path('win32-dib')],
        arguments: const <String>['--presentation=win32-dib'],
      );

      expect(selection.chosen?.name, 'win32-dib');
      expect(selection.requested, 'win32-dib');
      expect(selection.overrideSource, SelectionOverrideSource.commandLineFlag);
      expect(selection.describe(), contains('via commandLineFlag'));
    });

    test('the separated form of the flag is accepted too', () {
      final selection = selectPresentation(
        <PresentationCandidate>[path('cpu'), path('win32-dib')],
        arguments: const <String>['--presentation', 'win32-dib'],
      );

      expect(selection.chosen?.name, 'win32-dib');
    });

    test('an environment variable pins it, and a flag outranks it', () {
      const candidates = <String>['cpu', 'win32-dib'];
      final fromEnvironment = selectPresentation(
        <PresentationCandidate>[for (final name in candidates) path(name)],
        environment: const <String, String>{
          'DART_UI_PRESENTATION': 'win32-dib'
        },
      );
      expect(fromEnvironment.chosen?.name, 'win32-dib');
      expect(fromEnvironment.overrideSource,
          SelectionOverrideSource.environmentVariable);

      // A variable exported three days ago must not beat a flag typed now.
      final both = selectPresentation(
        <PresentationCandidate>[for (final name in candidates) path(name)],
        arguments: const <String>['--presentation=cpu'],
        environment: const <String, String>{
          'DART_UI_PRESENTATION': 'win32-dib'
        },
      );
      expect(both.chosen?.name, 'cpu');
      expect(both.overrideSource, SelectionOverrideSource.commandLineFlag);
    });

    test('an explicit request outranks both', () {
      final selection = selectPresentation(
        <PresentationCandidate>[path('cpu'), path('win32-dib')],
        requested: 'cpu',
        arguments: const <String>['--presentation=win32-dib'],
        environment: const <String, String>{
          'DART_UI_PRESENTATION': 'win32-dib'
        },
      );

      expect(selection.chosen?.name, 'cpu');
      expect(selection.overrideSource, SelectionOverrideSource.explicit);
    });

    test('an empty flag value pins nothing rather than pinning ""', () {
      final selection = selectPresentation(
        <PresentationCandidate>[path('cpu')],
        arguments: const <String>['--presentation='],
      );

      expect(selection.chosen?.name, 'cpu');
      expect(selection.requested, isNull);
      expect(selection.overrideSource, SelectionOverrideSource.none);
    });

    test('a pinned path that cannot run fails instead of falling back', () {
      final selection = selectPresentation(
        <PresentationCandidate>[
          path(
            'direct2d',
            kind: PresentationKind.gpu,
            supported: false,
            diagnostics: const <BackendDiagnostic>[
              BackendDiagnostic.missingLibrary('d2d1.dll'),
            ],
          ),
          path('cpu'),
        ],
        requested: 'direct2d',
      );

      expect(selection.isSuccess, isFalse);
      expect(
        selection.rejected.firstWhere((r) => r.name == 'cpu').reason,
        RejectionReason.notRequested,
      );

      final error = selection.toError();
      expect(error.requested, 'direct2d');
      expect(error.attempts, hasLength(2));
      expect(error.toString(), contains('d2d1.dll'));
    });
  });

  group('reporting', () {
    test('describe carries the whole story, on success too', () {
      final description = selectPresentation(<PresentationCandidate>[
        path(
          'direct2d',
          kind: PresentationKind.gpu,
          supported: false,
          diagnostics: const <BackendDiagnostic>[
            BackendDiagnostic.missingLibrary('d2d1.dll'),
          ],
        ),
        path('cpu'),
      ]).describe();

      expect(description, contains('chosen: cpu (cpu)'));
      expect(description, contains('direct2d'));
      expect(description, contains('d2d1.dll'));
    });

    test('an experimental path is never chosen without opting in', () {
      final candidates = <PresentationCandidate>[
        path('experimental-blit', experimental: true),
        path('cpu'),
      ];

      expect(selectPresentation(candidates).chosen?.name, 'cpu');
      expect(
        selectPresentation(candidates).rejected.first.reason,
        RejectionReason.needsExplicitOptIn,
      );
      expect(
        selectPresentation(candidates, allowExperimental: true).chosen?.name,
        'experimental-blit',
      );
    });

    test('nothing qualifying is a reportable outcome, not an exception', () {
      final selection = selectPresentation(<PresentationCandidate>[
        path('direct2d', kind: PresentationKind.gpu, supported: false),
        path(
          'opengl',
          kind: PresentationKind.gpu,
          capabilities: const <Capability>{Capability.cpuPresentation},
        ),
      ]);

      expect(selection.isSuccess, isFalse);
      expect(selection.rejected, hasLength(2));
      expect(selection.describe(), contains('chosen: none'));
      expect(selection.toError().attempts, hasLength(2));
    });
  });

  group('the same override machinery on windowing backends', () {
    BackendCandidate backend(String name, {bool supported = true}) =>
        BackendCandidate(
          name: name,
          probe: BackendProbeResult(
            backendName: name,
            supported: supported,
            capabilities: const <Capability>{Capability.window},
          ),
        );

    test('DART_UI_BACKEND pins the windowing backend', () {
      final selection = selectBackend(
        <BackendCandidate>[backend('wayland'), backend('x11')],
        environment: const <String, String>{'DART_UI_BACKEND': 'x11'},
      );

      expect(selection.chosen?.name, 'x11');
      expect(selection.overrideSource,
          SelectionOverrideSource.environmentVariable);
      expect(selection.describe(), contains('via environmentVariable'));
    });

    test('preferred reorders the fallback chain', () {
      final selection = selectBackend(
        <BackendCandidate>[backend('wayland'), backend('x11')],
        preferred: <String>['x11'],
      );

      expect(selection.chosen?.name, 'x11');
      expect(selection.rejected.single.name, 'wayland');
    });

    test('toError carries every probe that ran', () {
      final selection = selectBackend(<BackendCandidate>[
        backend('wayland', supported: false),
        backend('x11', supported: false),
      ]);

      expect(selection.isSuccess, isFalse);
      final error = selection.toError();
      expect(error.attempts, hasLength(2));
      expect(error.toString(), contains('wayland'));
      expect(error.toString(), contains('x11'));
    });

    test('the default environment is empty, so a test is never ambient', () {
      // If this ever reads Platform.environment, a developer with
      // DART_UI_BACKEND exported would see a different result here than CI.
      final selection = selectBackend(<BackendCandidate>[backend('headless')]);
      expect(selection.requested, isNull);
      expect(selection.overrideSource, SelectionOverrideSource.none);
    });
  });
}
