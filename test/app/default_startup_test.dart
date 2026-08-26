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
        <String>[
          'direct3d11',
          'opengl',
          'direct2d',
          'direct3d12',
          'vulkan',
          'win32-dib',
          'headless-cpu',
        ],
      );
      expect(paths[0].kind, PresentationKind.gpu);
      expect(paths[1].kind, PresentationKind.gpu);
      expect(paths[2].kind, PresentationKind.gpu);
      expect(paths[3].kind, PresentationKind.gpu);
      expect(paths[4].kind, PresentationKind.gpu);
      expect(paths[5].kind, PresentationKind.cpu);
      expect(
        paths[0].rasterizationApproach,
        RasterizationApproach.analyticCoverageAtlas,
      );
      expect(
        paths[0].compatibleWindowingBackends,
        const <String>{'win32'},
      );
      for (final PresentationPathEntry path in paths.take(6)) {
        expect(
          path.compatibleWindowingBackends,
          const <String>{'win32'},
          reason: '${path.name} attaches to a Win32 window and to nothing '
              'else; declaring that is what keeps it out of a headless '
              'fallback',
        );
      }
    });

    test('Vulkan is registered but never reached by fallback', () {
      final List<PresentationPathEntry> paths =
          PlatformBackendResolver.defaultPresentations(
        operatingSystem: 'windows',
      );

      // The flag is the whole point of the entry: `VulkanWindowTarget` has no
      // glyph atlas, so a UI that lands on it by fallback loses text. It is
      // registered so that it can be asked for by name, and marked so that it
      // is never chosen for anybody who did not.
      expect(
        paths
            .singleWhere((PresentationPathEntry p) => p.name == 'vulkan')
            .experimental,
        isTrue,
      );
      expect(
        paths
            .singleWhere((PresentationPathEntry p) => p.name == 'direct3d12')
            .experimental,
        isFalse,
      );
    });

    test('the Windows Direct3D 12 path probes a real device', () {
      if (!Platform.isWindows) return;
      final PresentationPathEntry d3d12 =
          PlatformBackendResolver.defaultPresentations(
        operatingSystem: 'windows',
      ).singleWhere((PresentationPathEntry path) => path.name == 'direct3d12');

      final BackendProbeResult result = d3d12.probe();

      expect(result.supported, isTrue, reason: result.describe());
      expect(result.capabilities, contains(Capability.gpuPresentation));
    });

    test('the Windows Vulkan path probes through VK_KHR_win32_surface', () {
      if (!Platform.isWindows) return;
      final PresentationPathEntry vulkan =
          PlatformBackendResolver.defaultPresentations(
        operatingSystem: 'windows',
      ).singleWhere((PresentationPathEntry path) => path.name == 'vulkan');

      final BackendProbeResult result = vulkan.probe();

      // A machine with no Vulkan loader is a legitimate answer and not a
      // failure; what this asserts is that the answer names the reason either
      // way, and that a yes really was checked against the WSI extension
      // rather than against an offscreen instance.
      if (!result.supported) {
        expect(result.diagnostics, isNotEmpty, reason: result.describe());
        return;
      }
      expect(result.capabilities, contains(Capability.gpuPresentation));
      expect(
        result.diagnostics.map((BackendDiagnostic item) => item.message),
        contains(contains('VK_KHR_win32_surface')),
      );
    });

    test('orders OpenGL before PutImage on Linux', () {
      final List<PresentationPathEntry> paths =
          PlatformBackendResolver.defaultPresentations(
        operatingSystem: 'linux',
      );

      expect(
        paths.map((PresentationPathEntry path) => path.name),
        <String>['opengl', 'wayland-shm', 'x11-putimage', 'headless-cpu'],
      );
      expect(paths.first.kind, PresentationKind.gpu);
    });

    test('the Windows OpenGL path probes through WGL rather than EGL', () {
      if (!Platform.isWindows) return;
      final List<PresentationPathEntry> paths =
          PlatformBackendResolver.defaultPresentations(
        operatingSystem: 'windows',
      );
      final PresentationPathEntry openGl = paths
          .singleWhere((PresentationPathEntry path) => path.name == 'opengl');

      final BackendProbeResult result = openGl.probe();

      // The claim in the name holds either way, so it is asserted first: the
      // Windows entry must never answer through EGL.
      expect(
        result.diagnostics.map((BackendDiagnostic item) => item.message),
        isNot(contains(contains('Windows has no EGL'))),
      );
      // And, as with Vulkan above, a no is a legitimate answer rather than a
      // failure: a machine with no display driver - a CI runner on the
      // Microsoft Basic Render Driver - has only the OpenGL 1.1 software
      // implementation inside opengl32.dll, which resolves a fraction of the
      // entry points this backend needs. What is asserted there is that the
      // probe says why.
      if (!result.supported) {
        expect(result.diagnostics, isNotEmpty, reason: result.describe());
        return;
      }
      expect(result.capabilities, contains(Capability.gpuPresentation));
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
