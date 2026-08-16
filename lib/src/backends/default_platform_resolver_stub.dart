/// Defaults for runtimes without `dart:io` platform discovery.
library;

import '../app/application.dart';
import '../rendering/cpu_renderer.dart';
import 'headless/headless_backend.dart';

/// The non-native counterpart of the desktop platform resolver.
final class PlatformBackendResolver {
  const PlatformBackendResolver._();

  static List<WindowingBackendEntry> defaultBackends({
    ApplicationOptions options = const ApplicationOptions(),
    String? operatingSystem,
  }) =>
      <WindowingBackendEntry>[
        WindowingBackendEntry(
          name: 'headless',
          create: () => HeadlessWindowingBackend(
            renderScale: options.headlessRenderScale,
          ),
        ),
      ];

  static List<PresentationPathEntry> defaultPresentations({
    String? operatingSystem,
  }) =>
      <PresentationPathEntry>[
        PresentationPathEntry.cpuRenderer(
          backend: const CpuRendererBackend(),
          name: 'headless-cpu',
        ),
      ];
}
