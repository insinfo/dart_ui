import 'dart:async';

import 'package:dart_ui/dart_ui.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() => verifyBuildDuringPresentation();

/// Exercises the production application with an explicitly suspended presenter.
/// No timer, platform input or subsequent notification may request the next frame.
Future<void> verifyBuildDuringPresentation() async {
  final key = GlobalKey<_ChangingState>();
  final presenter = _PendingPresenter();
  final app = await Application.start(
    rootWidget: _ChangingWidget(key: key),
    backends: const <WindowingBackendEntry>[
      WindowingBackendEntry(
        name: 'headless',
        create: HeadlessWindowingBackend.new,
      ),
    ],
    presentations: <PresentationPathEntry>[
      PresentationPathEntry(
        name: 'pending-test',
        kind: PresentationKind.cpu,
        rasterizationApproach: RasterizationApproach.custom,
        probe: () => BackendProbeResult(
          backendName: 'pending-test',
          supported: true,
          capabilities: <Capability>{Capability.cpuPresentation},
        ),
        attach: (NativeWindow window, {RenderDeviceProvider? devices}) async =>
            presenter,
      ),
    ],
    options: const ApplicationOptions(size: Size(8, 8)),
  );
  try {
    final window = app.primaryWindow;
    final first = window.drawFrame();
    await presenter.entered.future;
    final state = key.currentState!;
    _check(
        state.builtValues.join(',') == '0', 'initial build must finish first');
    _check(!window.needsFrame, 'the in-flight frame consumed its request');
    _check(!window.buildOwner.hasScheduledBuilds, 'initial build settled');

    // This is after build/layout/paint, while only presentation is pending.
    state.changeTo(1);
    _check(window.buildOwner.hasScheduledBuilds, 'mutation must queue a build');
    _check(!window.needsFrame, 'in-frame requests remain coalesced');
    presenter.release.complete();
    await first;

    _check(window.needsFrame, 'pending build lost its next-frame request');
    final next = await app.drawPendingFrames();
    _check(next.length == 1 && next.single.isSuccess,
        'pending build must present without another input event');
    _check(state.builtValues.join(',') == '0,1', 'new state must reach build');
    _check(!window.buildOwner.hasScheduledBuilds, 'next build must settle');
    _check(!window.needsFrame, 'settled frame must not perpetually re-arm');
    _check((await app.drawPendingFrames()).isEmpty, 'no redundant third frame');
    _check(presenter.presents == 2, 'exactly two presentations expected');
    print('pending presentation rebuild validated');
  } finally {
    if (!presenter.release.isCompleted) presenter.release.complete();
    app.dispose();
    await app.closed;
  }
}

class _ChangingWidget extends StatefulWidget {
  const _ChangingWidget({super.key});

  @override
  State<_ChangingWidget> createState() => _ChangingState();
}

class _ChangingState extends State<_ChangingWidget> {
  int value = 0;
  final List<int> builtValues = <int>[];

  void changeTo(int next) => setState(() => value = next);

  @override
  Widget build(BuildContext context) {
    builtValues.add(value);
    return ColoredBox(color: Color(value == 0 ? 0xFF102030 : 0xFF405060));
  }
}

final class _PendingPresenter with DisposableMixin implements SurfacePresenter {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  int presents = 0;

  @override
  RendererInfo get info => const RendererInfo(
        name: 'pending-test',
        deviceDescription: 'controlled asynchronous presentation',
        rasterizationApproach: RasterizationApproach.custom,
      );

  @override
  bool get isDeviceLost => false;

  @override
  Future<PresentResult> present(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  }) async {
    presents++;
    if (presents == 1) {
      entered.complete();
      await release.future;
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  @override
  void surfaceResized({
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
  }) {}

  @override
  Future<bool> recoverFromDeviceLoss() async => false;

  @override
  void onDispose() {}
}
