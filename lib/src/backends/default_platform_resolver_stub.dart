/// Defaults for runtimes without `dart:io` platform discovery.
library;

import '../app/application.dart';
import '../platform/backend_selection.dart';
import '../rendering/cpu_renderer.dart';
import '../rendering/gpu/webgl/webgl_backend.dart';
import '../rendering/gpu/webgl/webgl_mesh_renderer.dart';
import '../rendering/gpu/webgpu/webgpu_backend.dart';
import '../rendering/gpu/webgpu/webgpu_mesh_renderer.dart';
import '../rendering/mesh/mesh_scene.dart';
import 'headless/headless_backend.dart';
import 'web/web_gl_presenter.dart';
import 'web/web_gpu_presenter.dart';
import 'web/web_window.dart';

/// The non-native counterpart of the desktop platform resolver.
final class PlatformBackendResolver {
  const PlatformBackendResolver._();

  static List<WindowingBackendEntry> defaultBackends({
    ApplicationOptions options = const ApplicationOptions(),
    String? operatingSystem,
  }) =>
      <WindowingBackendEntry>[
        const WindowingBackendEntry(
          name: 'web',
          create: WebWindowingBackend.new,
        ),
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
        PresentationPathEntry(
          name: WebGpuRendererBackend.backendName,
          kind: PresentationKind.gpu,
          rasterizationApproach:
              const WebGpuRendererBackend().info.rasterizationApproach,
          backend: const WebGpuRendererBackend(),
          compatibleWindowingBackends: const <String>{'web'},
          experimental: false,
          sharesDevice: false,
          createMeshRenderer: (device) {
            if (device is! WebGpuRenderDevice) {
              throw StateError('webgpu mesh rendering needs a '
                  'WebGpuRenderDevice; got ${device.runtimeType}');
            }
            return WebGpuMeshRenderer(device);
          },
          probe: const WebGpuRendererBackend().probe,
          attach: (window, {devices}) => WebGpuCanvasPresenter.attach(window),
        ),
        PresentationPathEntry(
          name: WebGlRendererBackend.backendName,
          kind: PresentationKind.gpu,
          rasterizationApproach:
              const WebGlRendererBackend().info.rasterizationApproach,
          backend: const WebGlRendererBackend(),
          compatibleWindowingBackends: const <String>{'web'},
          experimental: false,
          sharesDevice: false,
          createMeshRenderer: (device) {
            if (device is! WebGlRenderDevice) {
              throw StateError('webgl2 mesh rendering needs a '
                  'WebGlRenderDevice; got ${device.runtimeType}');
            }
            final WebGlMeshRendererAttempt attempt =
                WebGlMeshRenderer.create(device);
            final MeshSceneRenderer? renderer = attempt.renderer;
            if (renderer != null) return renderer;
            throw StateError('${attempt.diagnostics}');
          },
          probe: const WebGlRendererBackend().probe,
          attach: (window, {devices}) => WebGlCanvasPresenter.attach(window),
        ),
        PresentationPathEntry.cpuRenderer(
          backend: const CpuRendererBackend(),
          name: 'headless-cpu',
        ),
      ];
}
