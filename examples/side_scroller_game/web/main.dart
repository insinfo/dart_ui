import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/web/web_gl_presenter.dart';
import 'package:dart_ui/src/backends/web/web_gpu_presenter.dart';
import 'package:dart_ui/src/backends/web/web_window.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_backend.dart';

import '../game/actors.dart';
import '../game/shell.dart';

Future<void> main() async {
  FrameworkFonts.install();
  final session = GameSession();
  const options = ApplicationOptions(
    title: 'dart_ui · Corrida do Lobo',
    size: Size(1120, 700),
    minimumSize: Size(760, 480),
    theme: ThemeData.neutralDark,
    clearColor: Color(Palette.sky),
    frameLoop: FrameLoopOptions.continuous(),
  );
  final application = await Application.start(
    rootWidget: SideScrollerGame(session: session),
    backends: <WindowingBackendEntry>[
      const WindowingBackendEntry(
        name: WebWindowingBackend.backendName,
        create: WebWindowingBackend.new,
      ),
    ],
    presentations: webPresentations(),
    options: options,
  );
  session.application = application;
  await application.run();
}

List<PresentationPathEntry> webPresentations() => <PresentationPathEntry>[
      PresentationPathEntry(
        name: WebGpuRendererBackend.backendName,
        kind: PresentationKind.gpu,
        probe: const WebGpuRendererBackend().probe,
        attach: (window, {devices}) => WebGpuCanvasPresenter.attach(window),
        rasterizationApproach:
            const WebGpuRendererBackend().info.rasterizationApproach,
      ),
      PresentationPathEntry(
        name: WebGlRendererBackend.backendName,
        kind: PresentationKind.gpu,
        probe: const WebGlRendererBackend().probe,
        attach: (window, {devices}) => WebGlCanvasPresenter.attach(window),
        rasterizationApproach:
            const WebGlRendererBackend().info.rasterizationApproach,
      ),
    ];
