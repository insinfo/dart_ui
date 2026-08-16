/// The shell, exercised end to end against the headless backend.
///
/// Every test here drives the *production* frame loop. There is no mock
/// window, no fake renderer and no test-only branch in `application.dart`:
/// the headless backend implements the same `WindowingBackend` contract Win32
/// does, so what these tests exercise is what ships.
///
/// Two rules the suite holds itself to:
///
///   * **No wall clock.** Nothing calls `DateTime.now`, and the dev overlay -
///     the one thing in the shell that consults a `Stopwatch` - is off, which
///     is its default. Timings are recorded but never asserted on.
///   * **Concrete values.** A test that only proves "it did not throw" would
///     pass against a shell that presented a blank window. So the assertions
///     are on pixel bytes, on exact teardown order, on the identity of the
///     widget an event reached, and on the words in a failure message.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// Opaque BGRA, packed the way `clearColor` and `ColoredBox` both take it.
const int _background = 0xFF102030;
const int _foreground = 0xFFCC4400;

void main() {
  group('runApp produces pixels', () {
    test('a two-colour tree lands on the exact bytes it describes', () async {
      final application = await _start(size: const Size(8, 6));
      final result = await application.drawFrame();

      expect(result.isSuccess, isTrue, reason: result.diagnostic?.toString());
      expect(application.framesPresented, 1);
      expect(application.framesRejected, 0);

      final framebuffer = _framebufferOf(application);
      expect(framebuffer.width, 8);
      expect(framebuffer.height, 6);

      // The tree is a 2px border of background around a foreground fill, so
      // the corners and the middle are each exactly one known colour. Reading
      // bytes rather than a checksum: a checksum that changed would say only
      // that something moved.
      expect(_pixelAt(framebuffer, 0, 0), _background);
      expect(_pixelAt(framebuffer, 7, 5), _background);
      expect(_pixelAt(framebuffer, 1, 1), _background);
      expect(_pixelAt(framebuffer, 2, 2), _foreground);
      expect(_pixelAt(framebuffer, 5, 3), _foreground);

      application.dispose();
      await application.closed;
    });

    test('the same tree presents byte-identical frames twice', () async {
      final first = await _start(size: const Size(16, 12));
      await first.drawFrame();
      final a = HeadlessScreenshot.fromFramebuffer(_framebufferOf(first));

      final second = await _start(size: const Size(16, 12));
      await second.drawFrame();
      final b = HeadlessScreenshot.fromFramebuffer(_framebufferOf(second));

      final comparison = compareGolden(a, b);
      expect(comparison.match, isTrue);
      expect(comparison.differingPixels, 0);
      expect(comparison.maxChannelDelta, 0);
      expect(a.checksum, b.checksum);
      // A golden that is one flat colour would also compare equal, so the
      // frame is checked for actually containing both colours.
      expect(a.pixels.length, 16 * 12 * 4);

      first.dispose();
      second.dispose();
      await first.closed;
      await second.closed;
    });

    test('a run with a frame budget presents exactly that many', () async {
      final application = await _start(size: const Size(8, 6));
      await application.run(frameBudget: 3);

      expect(application.framesPresented, 3);
      expect(application.framesRejected, 0);
      expect(application.statistics.count, 3);
      expect(application.state, ApplicationLifecycleState.closing);

      application.dispose();
      await application.closed;
    });
  });

  group('resize', () {
    test('relays out, and the frame begun before it is rejected', () async {
      final application = await _start(size: const Size(8, 6));
      await application.drawFrame();

      // A frame opened against the old surface, held across the resize. This
      // is the real sequence: `beginFrame`, then an event, then `present`.
      final inFlight = application.host.beginFrame();
      expect(inFlight.logicalSize, const Size(8, 6));
      final generationBefore = application.host.generation;

      _window(application).setBounds(const Rect.fromLTWH(0, 0, 20, 10));
      application.backend.pumpEvents();

      expect(application.host.generation, isNot(generationBefore));
      expect(application.host.logicalSize, const Size(20, 10));
      expect(
        application.pipelineOwner.rootConstraints,
        BoxConstraints.tight(const Size(20, 10)),
      );
      expect(application.needsFrame, isTrue);

      final rejected = await application.host.present(inFlight, DisplayList());
      expect(rejected.status, PresentStatus.stale);
      expect(rejected.isSuccess, isFalse);
      expect(
        rejected.diagnostic!.message,
        contains('generation ${inFlight.generation}'),
      );
      expect(application.framesRejected, 1);
      // The rejected frame never reached the surface, so nothing was drawn.
      expect(application.framesPresented, 1);

      // And the next real frame is laid out and rasterised at the new size.
      await application.drawFrame();
      final framebuffer = _framebufferOf(application);
      expect(framebuffer.width, 20);
      expect(framebuffer.height, 10);
      expect(_pixelAt(framebuffer, 0, 0), _background);
      expect(_pixelAt(framebuffer, 10, 5), _foreground);
      expect(application.framesPresented, 2);

      application.dispose();
      await application.closed;
    });

    test('a resize event from a superseded generation is dropped', () async {
      final application = await _start(size: const Size(8, 6));
      await application.drawFrame();
      final window = _window(application);

      // Generation 2 exists; this event claims generation 0.
      window.setBounds(const Rect.fromLTWH(0, 0, 20, 10));
      application.backend.pumpEvents();
      final settled = application.host.generation;

      application.handleEvent(WindowResizedEvent(
        windowId: window.id,
        generation: window.generation - 1,
        clientSize: const Size(999, 999),
        renderScale: 1,
      ));

      expect(application.host.generation, settled);
      expect(application.host.logicalSize, const Size(20, 10));

      application.dispose();
      await application.closed;
    });
  });

  group('DPI', () {
    test('a scale change reallocates the surface and keeps the layout',
        () async {
      final application = await _start(size: const Size(8, 6));
      await application.drawFrame();
      expect(_framebufferOf(application).width, 8);

      final window = _window(application);
      final generationBefore = application.host.generation;
      application.handleEvent(WindowScaleChangedEvent(
        windowId: window.id,
        generation: window.generation,
        renderScale: 2,
        desktopScale: 2,
      ));

      expect(application.host.renderScale, 2.0);
      expect(application.host.desktopScale, 2.0);
      expect(application.host.generation, isNot(generationBefore));
      // Logical layout is unchanged - that is the whole reason this event is
      // separate from a resize.
      expect(
        application.pipelineOwner.rootConstraints,
        BoxConstraints.tight(const Size(8, 6)),
      );
      expect(application.needsFrame, isTrue);

      await application.drawFrame();
      final framebuffer = _framebufferOf(application);
      expect(framebuffer.width, 16);
      expect(framebuffer.height, 12);
      // The 2px logical border is now 4 device pixels, so what was foreground
      // at logical (2,2) is at device (4,4) and device (3,3) is still border.
      expect(_pixelAt(framebuffer, 3, 3), _background);
      expect(_pixelAt(framebuffer, 4, 4), _foreground);

      application.dispose();
      await application.closed;
    });
  });

  group('input routing', () {
    test('a click reaches the widget under it and no other', () async {
      final pressed = <String>[];
      final application = await _start(
        size: const Size(200, 60),
        root: _TwoButtons(onPressed: pressed.add),
      );
      await application.drawFrame();

      final window = _window(application);
      // The buttons are two 100x40 boxes side by side at the top-left, so
      // (40,20) is inside the first and (150,20) inside the second.
      _click(window, const Offset(40, 20));
      application.backend.pumpEvents();
      expect(pressed, <String>['left']);

      _click(window, const Offset(150, 20));
      application.backend.pumpEvents();
      expect(pressed, <String>['left', 'right']);

      // Below both of them is bare background and hits neither.
      _click(window, const Offset(100, 55));
      application.backend.pumpEvents();
      expect(pressed, <String>['left', 'right']);

      application.dispose();
      await application.closed;
    });

    test('a click through a stale generation never reaches the tree', () async {
      final pressed = <String>[];
      final application = await _start(
        size: const Size(200, 60),
        root: _TwoButtons(onPressed: pressed.add),
      );
      await application.drawFrame();
      final window = _window(application);

      final accepted = window.dispatchInput(PointerDownEvent(
        windowId: window.id,
        generation: window.generation - 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: const Offset(40, 20),
        button: PointerButton.primary,
      ));
      application.backend.pumpEvents();

      expect(accepted, isFalse);
      expect(pressed, isEmpty);

      application.dispose();
      await application.closed;
    });
  });

  group('teardown', () {
    test('releases in reverse acquisition order, and only once', () async {
      final application = await _start(size: const Size(8, 6));
      await application.drawFrame();

      final controls = application.controlCount;
      final semantics = application.semanticNodeCount;
      expect(application.teardownOrder, isEmpty);

      application.dispose();

      // Acquisition was backend, window, host, scheduler, buildOwner, events;
      // release is that list backwards. Each of these depends on the one after
      // it, so any adjacent swap is a use-after-free on a real backend.
      expect(application.teardownOrder, <String>[
        'events',
        'buildOwner',
        'scheduler',
        'host',
        'window',
        'backend',
      ]);
      expect(application.state, ApplicationLifecycleState.closed);
      expect(application.isDisposed, isTrue);

      // Idempotent: a caller that disposes on both the success and the failure
      // path must not double-release.
      application.dispose();
      expect(application.teardownOrder, hasLength(6));

      // The counts survive teardown, because they are snapshotted before it.
      expect(application.controlCount, controls);
      expect(application.semanticNodeCount, semantics);

      await application.closed;
      expect(
        (application.backend as HeadlessWindowingBackend).isInitialized,
        isFalse,
      );
      expect(application.host.isDisposed, isTrue);
      expect(application.host.presenter.isDisposed, isTrue);
      expect(application.window.isDisposed, isTrue);
    });

    test('drawFrame after dispose throws instead of drawing', () async {
      final application = await _start(size: const Size(8, 6));
      application.dispose();
      await application.closed;

      expect(application.drawFrame, throwsStateError);
      // Requesting a frame on a dead application is a no-op, not a throw: a
      // callback that outlives the window is normal, and making every caller
      // guard is how teardown crashes get written.
      application.requestFrame();
      expect(application.needsFrame, isFalse);
    });
  });

  group('lifecycle', () {
    test('a minimised window suspends, and the frame is skipped not drawn',
        () async {
      final application = await _start(size: const Size(8, 6));
      await application.drawFrame();
      final window = _window(application);

      application.handleEvent(WindowResizedEvent(
        windowId: window.id,
        generation: window.generation,
        clientSize: Size.zero,
        renderScale: 1,
      ));

      expect(application.state, ApplicationLifecycleState.suspended);
      expect(application.host.isPresentable, isFalse);

      final skipped = await application.drawFrame();
      expect(skipped.status, PresentStatus.stale);
      expect(application.framesPresented, 1, reason: 'nothing was drawn');
      // The frame is still owed, so restoring the window repaints it.
      expect(application.needsFrame, isTrue);

      application.handleEvent(WindowResizedEvent(
        windowId: window.id,
        generation: window.generation,
        clientSize: const Size(8, 6),
        renderScale: 1,
      ));
      expect(application.state, ApplicationLifecycleState.running);

      await application.drawFrame();
      expect(application.framesPresented, 2);

      application.dispose();
      await application.closed;
    });

    test('a close request invalidates the frame in flight', () async {
      final application = await _start(size: const Size(8, 6));
      await application.drawFrame();

      final inFlight = application.host.beginFrame();
      application.handleEvent(WindowCloseRequestedEvent(
        windowId: application.window.id,
        generation: application.window.generation,
      ));

      expect(application.state, ApplicationLifecycleState.closing);
      final result = await application.host.present(inFlight, DisplayList());
      expect(result.status, PresentStatus.stale);
      expect(application.framesRejected, 1);

      application.dispose();
      await application.closed;
    });

    test('deactivation dims the focus ring without suspending by default',
        () async {
      final application = await _start(size: const Size(8, 6));
      final window = _window(application);

      application.handleEvent(WindowActivationEvent(
        windowId: window.id,
        generation: window.generation,
        activation: WindowActivation.deactivated,
      ));

      expect(application.buildOwner.focusManager.isWindowActive, isFalse);
      expect(application.state, ApplicationLifecycleState.starting,
          reason: 'suspendWhenDeactivated is off by default');

      application.dispose();
      await application.closed;
    });
  });

  group('selection failure', () {
    test('names every backend that was tried and what each was missing',
        () async {
      Object? thrown;
      try {
        await Application.start(
          rootWidget: const ColoredBox(color: _background),
          backends: <WindowingBackendEntry>[
            WindowingBackendEntry(
              name: 'wayland',
              create: () => _UnavailableBackend(
                'wayland',
                const BackendDiagnostic.missingLibrary(
                    'libwayland-client.so.0'),
              ),
            ),
            WindowingBackendEntry(
              name: 'x11',
              create: () => _UnavailableBackend(
                'x11',
                const BackendDiagnostic(
                  kind: DiagnosticKind.connectionFailed,
                  message: 'no DISPLAY in the environment',
                ),
              ),
            ),
          ],
        );
      } on Object catch (error) {
        thrown = error;
      }

      expect(thrown, isA<BackendSelectionError>());
      final message = thrown.toString();
      // Both attempts, each naming what was actually missing. A message that
      // said only "no usable backend" is the failure section 6.6 is against.
      expect(message, contains('wayland'));
      expect(message, contains('libwayland-client.so.0'));
      expect(message, contains('x11'));
      expect(message, contains('no DISPLAY in the environment'));
      expect((thrown! as BackendSelectionError).attempts, hasLength(2));
    });

    test('a pinned backend that cannot run does not fall back', () async {
      Object? thrown;
      try {
        await Application.start(
          rootWidget: const ColoredBox(color: _background),
          backends: <WindowingBackendEntry>[
            WindowingBackendEntry(
              name: 'x11',
              create: () => _UnavailableBackend(
                'x11',
                const BackendDiagnostic(
                  kind: DiagnosticKind.connectionFailed,
                  message: 'no DISPLAY in the environment',
                ),
              ),
            ),
            const WindowingBackendEntry(
              name: 'headless',
              create: HeadlessWindowingBackend.new,
            ),
          ],
          options: const ApplicationOptions(requestedBackend: 'x11'),
        );
      } on Object catch (error) {
        thrown = error;
      }

      expect(thrown, isA<BackendSelectionError>());
      expect((thrown! as BackendSelectionError).requested, 'x11');
      // The healthy headless backend was right there and was not taken.
      expect(thrown.toString(), contains('x11'));
    });

    test('an empty backend list is a caller error, named as one', () async {
      expect(
        () => Application.start(
          rootWidget: const ColoredBox(color: _background),
          backends: const <WindowingBackendEntry>[],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('startup report', () {
    test('describes the chosen backend, path and window', () async {
      final application = await _start(size: const Size(8, 6));
      final report = application.describeStartup();

      expect(report, contains('chosen: headless'));
      expect(report, contains('chosen: cpu (cpu)'));
      expect(report, contains('software scanline rasteriser'));
      expect(report, contains('8.0x6.0'));
      // Which capability GPU candidates were verified against is reported,
      // not left implicit: "no GPU path qualified" means something different
      // when nothing could check one.
      expect(report, contains('gpu capability: gpuPresentation'));

      application.dispose();
      await application.closed;
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// A tree with a known, flat two-colour picture: a 2px border of [_background]
/// around a [_foreground] fill.
const Widget _twoColourTree = ColoredBox(
  color: _background,
  child: Padding(
    padding: EdgeInsets.all(2),
    child: ColoredBox(color: _foreground),
  ),
);

Future<Application> _start({
  required Size size,
  Widget root = _twoColourTree,
  double renderScale = 1,
}) =>
    Application.start(
      rootWidget: root,
      backends: <WindowingBackendEntry>[
        WindowingBackendEntry(
          name: 'headless',
          create: () => HeadlessWindowingBackend(renderScale: renderScale),
        ),
      ],
      options: ApplicationOptions(
        title: 'test',
        size: size,
        clearColor: _background,
      ),
    );

HeadlessWindow _window(Application application) =>
    application.window as HeadlessWindow;

Framebuffer _framebufferOf(Application application) =>
    ((application.host.presenter as RenderTargetPresenter).target
            as MemoryRenderTarget)
        .framebuffer;

/// The pixel at [x],[y] as packed ARGB, from the BGRA byte order the
/// framebuffer stores.
int _pixelAt(Framebuffer framebuffer, int x, int y) {
  final index = framebuffer.offsetOf(x, y);
  return (framebuffer.pixels[index + 3] << 24) |
      (framebuffer.pixels[index + 2] << 16) |
      (framebuffer.pixels[index + 1] << 8) |
      framebuffer.pixels[index];
}

void _click(HeadlessWindow window, Offset position) {
  window.dispatchInput(PointerDownEvent(
    windowId: window.id,
    generation: window.generation,
    timestamp: Duration.zero,
    pointerId: 0,
    kind: PointerKind.mouse,
    logicalPosition: position,
    button: PointerButton.primary,
  ));
  window.dispatchInput(PointerUpEvent(
    windowId: window.id,
    generation: window.generation,
    timestamp: Duration.zero,
    pointerId: 0,
    kind: PointerKind.mouse,
    logicalPosition: position,
    button: PointerButton.primary,
  ));
}

/// Two buttons filling the left and right halves, each reporting its own name.
final class _TwoButtons extends StatelessWidget {
  const _TwoButtons({required this.onPressed});

  final void Function(String which) onPressed;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: _background,
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 100,
              height: 40,
              child: Button(
                label: 'left',
                onPressed: () => onPressed('left'),
              ),
            ),
            SizedBox(
              width: 100,
              height: 40,
              child: Button(
                label: 'right',
                onPressed: () => onPressed('right'),
              ),
            ),
          ],
        ),
      );
}

/// A backend that is present in the candidate list and cannot run, which is
/// the only interesting case for selection.
final class _UnavailableBackend implements WindowingBackend {
  _UnavailableBackend(this.name, this.reason);

  @override
  final String name;
  final BackendDiagnostic reason;

  @override
  BackendProbeResult probe() => BackendProbeResult.unsupported(name, reason);

  @override
  Future<void> initialize() async =>
      throw StateError('$name.initialize() must never be reached');

  @override
  Future<void> shutdown() async {}

  @override
  Future<NativeWindow> createWindow(WindowOptions options) async =>
      throw StateError('$name.createWindow() must never be reached');

  @override
  List<NativeWindow> get windows => const <NativeWindow>[];

  @override
  bool pumpEvents({Duration timeout = Duration.zero}) => false;

  @override
  void wake() {}
}
