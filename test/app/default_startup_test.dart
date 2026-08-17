/// Production defaults, command-line policy and GPU-first fallback.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('ApplicationOptions.fromArguments', () {
    test('parses the high-level startup flags in one place', () {
      final ApplicationOptions options = ApplicationOptions.fromArguments(
        const <String>[
          '--dark',
          '--gpu',
          '--headless',
          '--scale=1.5',
          '--frames',
          '7',
        ],
        title: 'Example',
      );

      expect(options.title, 'Example');
      expect(options.theme, ThemeData.neutralDark);
      expect(options.renderingPolicy, RenderingPolicy.gpuOnly);
      expect(options.requestedBackend, 'headless');
      expect(options.headlessRenderScale, 1.5);
      expect(options.frameBudget, 7);
    });

    test('rejects contradictory and malformed flags', () {
      expect(
        () => ApplicationOptions.fromArguments(
          const <String>['--dark', '--light'],
        ),
        throwsArgumentError,
      );
      expect(
        () => ApplicationOptions.fromArguments(
          const <String>['--gpu', '--cpu'],
        ),
        throwsArgumentError,
      );
      expect(
        () => ApplicationOptions.fromArguments(
          const <String>['--scale', '0'],
        ),
        throwsArgumentError,
      );
      expect(
        () => ApplicationOptions.fromArguments(
          const <String>['--frames=-1'],
        ),
        throwsArgumentError,
      );
    });
  });

  group('platform resolver', () {
    test('orders GPU before native CPU and headless CPU on Windows', () {
      final List<PresentationPathEntry> paths =
          PlatformBackendResolver.defaultPresentations(
        operatingSystem: 'windows',
      );

      expect(
        paths.map((PresentationPathEntry path) => path.name),
        <String>['direct3d11', 'opengl', 'win32-dib', 'headless-cpu'],
      );
      expect(paths[0].kind, PresentationKind.gpu);
      expect(paths[1].kind, PresentationKind.gpu);
      expect(paths[2].kind, PresentationKind.cpu);
      expect(
        paths[0].rasterizationApproach,
        RasterizationApproach.analyticCoverageAtlas,
      );
      expect(
        paths[0].compatibleWindowingBackends,
        const <String>{'win32'},
      );
    });

    test('orders OpenGL before PutImage on Linux', () {
      final List<PresentationPathEntry> paths =
          PlatformBackendResolver.defaultPresentations(
        operatingSystem: 'linux',
      );

      expect(
        paths.map((PresentationPathEntry path) => path.name),
        <String>['opengl', 'x11-putimage', 'headless-cpu'],
      );
      expect(paths.first.kind, PresentationKind.gpu);
    });
  });

  test('public runApp needs no backend lists and installs root ambients',
      () async {
    final List<_AmbientSnapshot> seen = <_AmbientSnapshot>[];
    final Application application = await runApp(
      _AmbientProbe(seen.add),
      options: ApplicationOptions.fromArguments(
        const <String>['--headless', '--dark', '--frames=1', '--scale=2'],
        size: const Size(12, 8),
      ),
    );

    expect(application.windowingSelection.chosen?.name, 'headless');
    expect(application.presentationSelection.chosen?.name, 'headless-cpu');
    expect(application.framesPresented, 1);
    expect(seen.single.theme, ThemeData.neutralDark);
    expect(seen.single.direction, TextDirection.leftToRight);
    expect(seen.single.media.size, const Size(12, 8));
    expect(seen.single.media.devicePixelRatio, 2);
    expect(seen.single.focusScope, isNotNull);
  });

  test('an unpinned attach failure falls through to the next path', () async {
    final List<BackendDiagnostic> diagnostics = <BackendDiagnostic>[];
    final Application application = await Application.start(
      rootWidget: const SizedBox(width: 1, height: 1),
      backends: <WindowingBackendEntry>[
        const WindowingBackendEntry(
          name: 'headless',
          create: HeadlessWindowingBackend.new,
        ),
      ],
      presentations: <PresentationPathEntry>[
        PresentationPathEntry(
          name: 'gpu-that-breaks',
          kind: PresentationKind.gpu,
          rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
          probe: () => BackendProbeResult(
            backendName: 'gpu-that-breaks',
            supported: true,
            capabilities: <Capability>{Capability.gpuPresentation},
          ),
          attach: (NativeWindow _) async =>
              throw StateError('swapchain creation failed'),
        ),
        PresentationPathEntry.cpuRenderer(name: 'cpu-fallback'),
      ],
      options: ApplicationOptions(onDiagnostic: diagnostics.add),
    );
    addTearDown(() async {
      application.dispose();
      await application.closed;
    });

    expect(application.presentationSelection.chosen?.name, 'cpu-fallback');
    expect(
      application.presentationSelection.rejected
          .singleWhere(
              (BackendRejection item) => item.name == 'gpu-that-breaks')
          .reason,
      RejectionReason.unsupported,
    );
    expect(
      diagnostics.single.message,
      contains('passed its probe but could not attach'),
    );
  });

  test('the production Win32 default renders through a GPU target', () async {
    if (!Platform.isWindows) return;

    final Application application = await Application.start(
        rootWidget: const ColoredBox(color: Color(0xFF123456)),
      backends: PlatformBackendResolver.defaultBackends(),
      presentations: PlatformBackendResolver.defaultPresentations(),
      options: const ApplicationOptions(size: Size(64, 48)),
    );
    try {
      expect(
        application.presentationSelection.chosen?.kind,
        PresentationKind.gpu,
      );
      expect(
        application.primaryWindow.host.presenter.info.rasterizationApproach,
        RasterizationApproach.analyticCoverageAtlas,
      );
      await application.drawFrame();
      expect(application.framesPresented, 1);
    } finally {
      application.dispose();
      await application.closed;
    }
  });
}

final class _AmbientSnapshot {
  const _AmbientSnapshot({
    required this.theme,
    required this.direction,
    required this.media,
    required this.focusScope,
  });

  final ThemeData theme;
  final TextDirection direction;
  final MediaQueryData media;
  final FocusScopeNode? focusScope;
}

final class _AmbientProbe extends StatelessWidget {
  const _AmbientProbe(this.onBuild);

  final void Function(_AmbientSnapshot value) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(_AmbientSnapshot(
      theme: Theme.of(context),
      direction: Directionality.of(context),
      media: MediaQuery.of(context),
      focusScope: FocusScope.of(context),
    ));
    return const ColoredBox(color: Color(0xFF102030));
  }
}
