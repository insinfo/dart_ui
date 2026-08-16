/// The generation rule, on its own.
///
/// `application_test.dart` proves the rule holds through the whole shell.
/// This file pins the contract itself, because the contract is the part that
/// is easy to weaken by accident: a `present` that draws first and checks
/// afterwards still passes an end-to-end test on a machine where the resize
/// happens to arrive between frames.
///
/// So the presenter here records every call. "Rejected" is asserted as *the
/// presenter was never asked to draw*, not merely as a stale status code.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  late HeadlessWindowingBackend backend;
  late HeadlessWindow window;

  Future<HeadlessWindow> openWindow({
    Size size = const Size(40, 30),
    double renderScale = 1,
  }) async {
    backend = HeadlessWindowingBackend(renderScale: renderScale);
    await backend.initialize();
    return backend.createWindow(WindowOptions(title: 'host', size: size));
  }

  tearDown(() async => backend.shutdown());

  group('generations', () {
    test('a frame begun before a resize is never handed to the presenter',
        () async {
      window = await openWindow();
      final presenter = _RecordingPresenter();
      final host = WindowHost(window: window, presenter: presenter);

      final frame = host.beginFrame();
      expect(frame.generation, host.generation);
      expect(frame.logicalSize, const Size(40, 30));

      host.surfaceChanged(logicalSize: const Size(80, 60));

      final result = await host.present(frame, DisplayList());
      expect(result.status, PresentStatus.stale);
      expect(presenter.presents, 0,
          reason: 'the rejected frame must never reach the surface');
      expect(host.framesRejected, 1);
      expect(host.framesPresented, 0);
      expect(result.diagnostic!.detail,
          contains('reallocated between beginFrame and present'));

      // And a frame begun after it is accepted.
      final fresh = host.beginFrame();
      expect((await host.present(fresh, DisplayList())).isSuccess, isTrue);
      expect(presenter.presents, 1);
      expect(host.framesPresented, 1);

      host.dispose();
    });

    test('a resize during the present is caught after the await', () async {
      window = await openWindow();
      late final WindowHost host;
      final presenter = _RecordingPresenter(
        // The surface moves while the presenter is mid-flight, which is the
        // case a check taken only before the await cannot see.
        onPresent: () => host.surfaceChanged(logicalSize: const Size(80, 60)),
      );
      host = WindowHost(window: window, presenter: presenter);

      final result = await host.present(host.beginFrame(), DisplayList());
      expect(result.status, PresentStatus.stale);
      expect(presenter.presents, 1, reason: 'it did draw');
      expect(host.framesPresented, 0, reason: 'but nobody will ever see it');
      expect(host.framesRejected, 1);

      host.dispose();
    });

    test('the surface is told its new pixel size, scaled', () async {
      window = await openWindow(renderScale: 2);
      final presenter = _RecordingPresenter();
      final host = WindowHost(window: window, presenter: presenter);

      expect(host.pixelWidth, 80);
      expect(host.pixelHeight, 60);

      host.surfaceChanged(logicalSize: const Size(50, 25), renderScale: 3);
      expect(presenter.resizes, <List<num>>[
        <num>[150, 75, 3]
      ]);
      expect(host.pixelWidth, 150);

      host.dispose();
    });

    test('a no-op surfaceChanged does not burn a generation', () async {
      window = await openWindow();
      final host = WindowHost(window: window, presenter: _RecordingPresenter());
      final before = host.generation;

      host.surfaceChanged(logicalSize: const Size(40, 30), renderScale: 1);

      expect(host.generation, before);
      final frame = host.beginFrame();
      expect((await host.present(frame, DisplayList())).isSuccess, isTrue);

      host.dispose();
    });
  });

  group('device loss', () {
    test('recovery invalidates the frame in flight and rebuilds the surface',
        () async {
      window = await openWindow();
      final presenter = _RecordingPresenter()..isDeviceLost = true;
      final host = WindowHost(window: window, presenter: presenter);

      final frame = host.beginFrame();
      expect(await host.recoverFromDeviceLoss(), isTrue);
      expect(presenter.recoveries, 1);
      // The device is new, so the surface is rebuilt against it.
      expect(presenter.resizes, hasLength(1));

      final result = await host.present(frame, DisplayList());
      expect(result.status, PresentStatus.stale,
          reason: 'a frame built against the lost device must not be drawn');
      expect(presenter.presents, 0);

      host.dispose();
    });

    test('a recovery that fails is reported, not retried', () async {
      window = await openWindow();
      final diagnostics = <BackendDiagnostic>[];
      final presenter = _RecordingPresenter()..recoverySucceeds = false;
      final host = WindowHost(
        window: window,
        presenter: presenter,
        onDiagnostic: diagnostics.add,
      );

      expect(await host.recoverFromDeviceLoss(), isFalse);
      expect(diagnostics, hasLength(1));
      expect(diagnostics.single.kind, DiagnosticKind.incompatibleDevice);
      expect(diagnostics.single.message, contains('could not be recreated'));

      host.dispose();
    });
  });

  group('window events', () {
    test('a minimise reports suspension and no frame', () async {
      window = await openWindow();
      final host = WindowHost(window: window, presenter: _RecordingPresenter());

      final outcome = host.handleEvent(WindowResizedEvent(
        windowId: window.id,
        generation: window.generation,
        clientSize: Size.zero,
        renderScale: 1,
      ));

      expect(outcome.suspended, isTrue);
      expect(outcome.needsFrame, isFalse);
      expect(outcome.surfaceInvalidated, isTrue);
      expect(host.isPresentable, isFalse);

      // And a frame is refused rather than drawn into nothing.
      final result = await host.present(host.beginFrame(), DisplayList());
      expect(result.status, PresentStatus.stale);
      expect(result.diagnostic!.message, contains('presentable client area'));

      host.dispose();
    });

    test('an event from a superseded generation is dropped', () async {
      window = await openWindow();
      final host = WindowHost(window: window, presenter: _RecordingPresenter());

      final outcome = host.handleEvent(WindowExposedEvent(
        windowId: window.id,
        generation: window.generation - 1,
      ));

      expect(outcome.ignoredAsStale, isTrue);
      expect(outcome.needsFrame, isFalse);

      host.dispose();
    });

    test('a close request is honoured whatever generation it carries',
        () async {
      window = await openWindow();
      final host = WindowHost(window: window, presenter: _RecordingPresenter());

      // Lifecycle events are deliberately not generation-filtered: a close
      // that arrives late is still a close, and dropping it is how a process
      // fails to exit.
      final outcome = host.handleEvent(WindowCloseRequestedEvent(
        windowId: window.id,
        generation: window.generation - 5,
      ));

      expect(outcome.closeRequested, isTrue);
      host.dispose();
    });
  });

  group('ownership', () {
    test('disposing the host releases the presenter and not the window',
        () async {
      window = await openWindow();
      final presenter = _RecordingPresenter();
      final host = WindowHost(window: window, presenter: presenter);

      host.dispose();

      expect(presenter.isDisposed, isTrue);
      expect(window.isDisposed, isFalse,
          reason: 'the window belongs to the backend that created it');

      // Idempotent, and every operation after it is a loud failure rather
      // than a silent no-op.
      host.dispose();
      expect(host.beginFrame, throwsStateError);
    });
  });

  group('RenderTargetPresenter', () {
    test('binds to the memory surface a headless window offers', () async {
      window = await openWindow(renderScale: 2);
      final presenter = await RenderTargetPresenter.attach(
        backend: const CpuRendererBackend(),
        window: window,
      );

      expect(presenter.info.name, 'cpu');
      expect(presenter.isDeviceLost, isFalse);
      final target = presenter.target as MemoryRenderTarget;
      expect(target.framebuffer.width, 80);
      expect(target.framebuffer.height, 60);

      presenter.surfaceResized(pixelWidth: 100, pixelHeight: 50, scale: 1);
      expect(target.generation, isNot(0),
          reason: 'RenderTarget.resize bumps its own generation too');
      expect(
        (presenter.target as MemoryRenderTarget).framebuffer.width,
        100,
      );

      presenter.dispose();
    });

    test('names the surface kinds it was offered when none fits', () async {
      window = await openWindow();
      Object? thrown;
      try {
        await RenderTargetPresenter.attach(
          backend: const _MemoryHostileBackend(),
          window: window,
        );
      } on Object catch (error) {
        thrown = error;
      }

      expect(thrown, isA<BackendSelectionError>());
      final message = thrown.toString();
      expect(message, contains('picky'));
      expect(message, contains('cannot present to any surface'));
      // The kinds that *were* offered, so the reader can see the mismatch.
      expect(message, contains('memory'));
    });
  });

  group('the synchronous present', () {
    test('obeys the generation rule exactly as the asynchronous one does',
        () async {
      // The temptation is to skip the check here - "nothing yielded, nothing
      // can have changed" - and it is wrong in the one case this method exists
      // for. A live-resize frame lays out while the user is still dragging, and
      // Windows sends the next WM_SIZE from inside SetWindowPos calls that
      // layout itself makes, on this very stack.
      window = await openWindow();
      final presenter = _RecordingPresenter();
      final host = WindowHost(window: window, presenter: presenter);

      final frame = host.beginFrame();
      host.surfaceChanged(logicalSize: const Size(80, 60));

      final result = host.presentNow(frame, DisplayList());
      expect(result.status, PresentStatus.stale);
      expect(
        presenter.presents,
        0,
        reason: 'rejected means the display list never reached the presenter, '
            'not merely that a status code came back',
      );
      expect(host.framesRejected, 1);
      expect(host.framesPresented, 0);

      // A frame begun after the resize goes through.
      expect(
        host.presentNow(host.beginFrame(), DisplayList()).status,
        PresentStatus.presented,
      );
      expect(presenter.synchronousPresents, 1);
      expect(host.framesPresented, 1);
    });

    test('a minimised window rejects a synchronous frame too', () async {
      window = await openWindow();
      final host = WindowHost(
        window: window,
        presenter: _RecordingPresenter(),
      );
      final frame = host.beginFrame();
      host.surfaceChanged(logicalSize: Size.zero);

      expect(host.presentNow(frame, DisplayList()).status, PresentStatus.stale);
    });

    test('a presenter with no synchronous path refuses rather than throws',
        () async {
      // What a backend that cannot draw inside its resize handler looks like.
      // `ApplicationOptions.liveResize` may be on for the whole application, so
      // this has to be an answer rather than a failure.
      window = await openWindow();
      final host = WindowHost(
        window: window,
        presenter: _RecordingPresenter(canPresentNow: false),
      );

      expect(host.canPresentSynchronously, isFalse);
      final result = host.presentNow(host.beginFrame(), DisplayList());
      expect(result.status, PresentStatus.stale);
      expect(result.diagnostic?.message, contains('synchronous'));
    });

    test('a presenter that never claimed the interface is refused as well',
        () async {
      window = await openWindow();
      final host = WindowHost(
        window: window,
        presenter: CallbackSurfacePresenter.retained(
          info: const RendererInfo(name: 'async only', deviceDescription: 'x'),
          presenter: (
            present: (
              DisplayList list, {
              int? clearColor,
              Transform2D? deviceTransform,
              Rect? damage,
            }) async =>
                const PresentResult(status: PresentStatus.presented),
            presentNow: null,
            release: () {},
          ),
        ),
      );

      expect(host.canPresentSynchronously, isFalse);
      expect(
        host.presentNow(host.beginFrame(), DisplayList()).status,
        PresentStatus.stale,
      );
    });

    test('and a retained presenter that has one is used', () async {
      window = await openWindow();
      var synchronous = 0;
      final host = WindowHost(
        window: window,
        presenter: CallbackSurfacePresenter.retained(
          info: const RendererInfo(name: 'both', deviceDescription: 'x'),
          presenter: (
            present: (
              DisplayList list, {
              int? clearColor,
              Transform2D? deviceTransform,
              Rect? damage,
            }) async =>
                const PresentResult(status: PresentStatus.presented),
            presentNow: (
              DisplayList list, {
              int? clearColor,
              Transform2D? deviceTransform,
              Rect? damage,
            }) {
              synchronous++;
              return const PresentResult(status: PresentStatus.presented);
            },
            release: () {},
          ),
        ),
      );

      expect(host.canPresentSynchronously, isTrue);
      expect(
        host.presentNow(host.beginFrame(), DisplayList()).status,
        PresentStatus.presented,
      );
      expect(
        synchronous,
        1,
        reason: 'and it ran before presentNow returned, which is the entire '
            'contract: there is no event loop to come back to',
      );
    });
  });

  group('CallbackSurfacePresenter', () {
    test('forwards a display list and releases exactly what it was given',
        () async {
      var released = 0;
      final seen = <int?>[];
      final presenter = CallbackSurfacePresenter.retained(
        info: const RendererInfo(name: 'fake', deviceDescription: 'test'),
        presenter: (
          present: (
            DisplayList list, {
            int? clearColor,
            Transform2D? deviceTransform,
            Rect? damage,
          }) async {
            seen.add(clearColor);
            return const PresentResult(status: PresentStatus.presented);
          },
          presentNow: null,
          release: () => released++,
        ),
      );

      expect(
        (await presenter.present(DisplayList(), clearColor: 0xFF00FF00))
            .isSuccess,
        isTrue,
      );
      expect(seen, <int?>[0xFF00FF00]);
      expect(presenter.isDeviceLost, isFalse);

      presenter.dispose();
      presenter.dispose();
      expect(released, 1, reason: 'disposal is idempotent');
    });
  });
}

/// A presenter that draws nothing and remembers everything.
final class _RecordingPresenter
    with DisposableMixin
    implements SurfacePresenter, SynchronousSurfacePresenter {
  _RecordingPresenter({this.onPresent, this.canPresentNow = true});

  /// Runs inside [present], which is how a test simulates an event arriving
  /// while a frame is in flight.
  final void Function()? onPresent;

  /// Whether this double claims the synchronous path. False is the shape of a
  /// backend that has no live-resize support, which must be a refusal rather
  /// than a crash.
  @override
  final bool canPresentNow;

  int presents = 0;
  int synchronousPresents = 0;
  int recoveries = 0;
  final List<List<num>> resizes = <List<num>>[];

  @override
  bool isDeviceLost = false;
  bool recoverySucceeds = true;

  @override
  RendererInfo get info =>
      const RendererInfo(name: 'recording', deviceDescription: 'test double');

  @override
  Future<PresentResult> present(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  }) async {
    presents++;
    onPresent?.call();
    return const PresentResult(status: PresentStatus.presented);
  }

  @override
  PresentResult presentNow(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  }) {
    presents++;
    synchronousPresents++;
    onPresent?.call();
    return const PresentResult(status: PresentStatus.presented);
  }

  @override
  void surfaceResized({
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
  }) =>
      resizes.add(<num>[pixelWidth, pixelHeight, scale]);

  @override
  Future<bool> recoverFromDeviceLoss() async {
    recoveries++;
    if (!recoverySucceeds) return false;
    isDeviceLost = false;
    return true;
  }

  @override
  void onDispose() {}
}

/// A renderer backend that refuses every surface, which is what a GPU backend
/// looks like to a window that only offers CPU memory.
final class _MemoryHostileBackend implements RendererBackend {
  const _MemoryHostileBackend();

  @override
  RendererInfo get info => const RendererInfo(
        name: 'picky',
        deviceDescription: 'wants a swapchain and will not take memory',
      );

  @override
  BackendProbeResult probe() => BackendProbeResult(
        backendName: 'picky',
        supported: true,
        capabilities: const <Capability>{},
      );

  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) => false;

  @override
  Future<RenderDevice> createDevice() async =>
      throw StateError('createDevice must never be reached');
}
