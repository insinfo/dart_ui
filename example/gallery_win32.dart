/// The gallery, in a real Win32 window, rasterized on the CPU.
///
/// This is the other half of the Fase 6 gate. The headless suite proves the
/// gallery builds, lays out and paints; this proves the *same widget tree*,
/// unchanged, drives a real window - real `WM_PAINT`, real mouse and keyboard
/// messages, real pixels through a DIB section - with no native control
/// anywhere in it.
///
/// Nothing here is Windows-specific except the four lines that create the
/// backend and hand the display list to the presenter. That is the point: if
/// this file needed a Win32 concept to describe a button, the layering would
/// have failed.
///
/// ```
/// dart run example/gallery_win32.dart
/// dart compile exe example/gallery_win32.dart -o gallery.exe
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr.writeln('This example needs Windows; the same gallery runs '
        'headless in test/gallery/gallery_test.dart on every platform.');
    exitCode = 2;
    return;
  }

  final bool showOverlay = !arguments.contains('--no-overlay');
  // A frame budget makes this runnable in CI: open a real window, present a
  // few real frames, report, exit. An example that only ever blocks forever
  // cannot be part of a gate.
  final int frameBudget = _intArgument(arguments, '--frames') ?? 0;
  final ThemeData theme = arguments.contains('--dark')
      ? ThemeData.neutralDark
      : arguments.contains('--high-contrast')
          ? ThemeData.highContrastDark
          : ThemeData.neutralLight;

  final backend = Win32WindowingBackend();
  final BackendProbeResult probe = backend.probe();
  if (!probe.supported) {
    stderr.writeln('Win32 backend unavailable:');
    for (final BackendDiagnostic diagnostic in probe.diagnostics) {
      stderr.writeln('  ${diagnostic.kind.name}: ${diagnostic.message}');
    }
    exitCode = 1;
    return;
  }

  await backend.initialize();
  final NativeWindow window = await backend.createWindow(const WindowOptions(
    title: 'dart_ui gallery - Win32 CPU',
    size: galleryDesignSize,
  ));

  final app = _GalleryApp(
    window: window,
    theme: theme,
    showOverlay: showOverlay,
    frameBudget: frameBudget,
  );
  await app.run(backend);

  await backend.shutdown();

  if (frameBudget > 0) {
    stdout
      ..writeln('WIN32_GALLERY=PASS')
      ..writeln('frames=${app.framesPresented} '
          'median=${app.statistics.percentileTotal(50)}us '
          'p99=${app.statistics.percentileTotal(99)}us')
      ..writeln('controls=${app.controlCount} '
          'semantics=${app.semanticNodeCount} '
          'theme=${theme.name}');
    if (app.framesPresented < frameBudget) exitCode = 1;
  }
}

int? _intArgument(List<String> arguments, String name) {
  final int index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return int.tryParse(arguments[index + 1]);
}

/// Owns the widget tree, the frame loop and the translation of platform events
/// into framework input for one window.
final class _GalleryApp {
  _GalleryApp({
    required this.window,
    required this.theme,
    required this.showOverlay,
    this.frameBudget = 0,
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(galleryDesignSize),
      ),
      // A build scheduled outside a frame - a setState from a callback - marks
      // the next frame dirty rather than painting immediately. Painting inline
      // would produce two frames for one user action.
      onBuildScheduled: () => _needsFrame = true,
    )..errorReporter = ErrorReporter(
        onError: (FrameworkError error) => stderr.writeln(error.describe()),
      );
    presenter = Win32CpuPresenter(window as Win32Window);
  }

  final NativeWindow window;
  final ThemeData theme;
  final bool showOverlay;

  /// Stop after this many presented frames; 0 runs until the window closes.
  final int frameBudget;

  late final BuildOwner owner;
  late final Win32CpuPresenter presenter;

  final GalleryModel model = GalleryModel();
  final FrameStatistics statistics = FrameStatistics();

  // Two display lists, alternated. The presenter retains the list it was given
  // so it can repaint after a resize, so recording over it would corrupt a
  // frame that is still in flight.
  final List<DisplayList> _lists = <DisplayList>[DisplayList(), DisplayList()];
  int _listIndex = 0;

  bool _needsFrame = true;
  bool _rootMounted = false;
  bool _running = true;
  Size _logicalSize = galleryDesignSize;
  int framesPresented = 0;

  /// Snapshotted before teardown, because the report is printed after the
  /// window and the tree are gone.
  int controlCount = 0;
  int semanticNodeCount = 0;

  /// How many framework-owned controls the tree actually mounted, which is
  /// what makes "no native control" a checkable claim rather than a promise.
  int _countControls() {
    int count = 0;
    void walk(RenderBox node) {
      if (node is ControlBehavior) count++;
      node.visitChildren(walk);
    }

    final RenderBox? root = owner.renderRoot;
    if (root != null) walk(root);
    return count;
  }

  Future<void> run(Win32WindowingBackend backend) async {
    final StreamSubscription<PlatformWindowEvent> subscription =
        window.events.listen(_onEvent);
    window.show();

    while (_running) {
      // Block until something happens when there is nothing to draw.
      //
      // This is the difference between an idle application and one that pegs a
      // core: `pumpEvents` returns the moment a message arrives, so a long
      // timeout costs no latency at all - it only stops the loop from spinning
      // through millions of empty iterations while the window sits still.
      final Duration wait = _needsFrame || _forcedFrames
          ? Duration.zero
          : const Duration(milliseconds: 250);
      if (!backend.pumpEvents(timeout: wait)) break;

      // WndProc adds to a broadcast StreamController, which delivers on a
      // later turn of the *Dart* event loop. Pumping native messages without
      // ever returning to that loop would queue every click and keystroke and
      // deliver none of them - the window would repaint but never respond.
      await Future<void>.delayed(Duration.zero);

      if (_needsFrame || _overlayIsStale) {
        _needsFrame = false;
        await _drawFrame();
      }
      if (frameBudget > 0 && framesPresented >= frameBudget) break;
    }

    // Read while the tree is still alive; the summary is printed afterwards.
    controlCount = _countControls();
    semanticNodeCount = owner.buildSemantics().nodes.length;

    await subscription.cancel();
    owner.dispose();
    window.close();
  }

  /// Whether the loop is deliberately running flat out, which only the
  /// `--frames` smoke run does.
  bool get _forcedFrames => frameBudget > 0;

  /// Whether the overlay's numbers are old enough to be worth a repaint.
  ///
  /// The overlay is the one thing on screen that changes without any input, so
  /// it needs its own cadence. Refreshing it every frame - which is what this
  /// example did first - turns a static window into a busy loop that repaints
  /// forever *because* it is measuring how long repainting takes.
  bool get _overlayIsStale =>
      showOverlay &&
      _sinceOverlayRefresh.elapsed >= const Duration(milliseconds: 500);

  final Stopwatch _sinceOverlayRefresh = Stopwatch()..start();

  Future<void> _drawFrame() async {
    final Stopwatch stopwatch = Stopwatch()..start();

    if (_rootMounted) {
      // Only the elements that a setState marked dirty are rebuilt. Calling
      // updateRoot every frame instead would rebuild the whole gallery to
      // repaint one hovered button.
      owner.buildScope();
    } else {
      owner.updateRoot(Gallery(model: model, theme: theme));
      _rootMounted = true;
    }
    final int build = stopwatch.elapsedMicroseconds;

    final DisplayList list = _lists[_listIndex]..reset();
    _listIndex = (_listIndex + 1) % _lists.length;
    owner.pipelineOwner.drawFrame(list);
    final int paint = stopwatch.elapsedMicroseconds - build;

    if (showOverlay) {
      DevOverlay(statistics: statistics).paint(
        list,
        Rect.fromLTWH(0, 0, _logicalSize.width, _logicalSize.height),
        extraLine: 'SEL ${model.listSelection}',
      );
    }

    final PresentResult result = await presenter.renderDisplayList(list);
    stopwatch.stop();
    if (!result.isSuccess) {
      stderr.writeln('present failed: $result');
      return;
    }

    framesPresented++;
    statistics.record(FrameTiming(
      build: build,
      paint: paint,
      raster: stopwatch.elapsedMicroseconds - build - paint,
    ));
    if (showOverlay) _sinceOverlayRefresh.reset();
    // The smoke run wants frames as fast as it can get them; an interactive
    // one waits for something to actually change.
    if (_forcedFrames) _needsFrame = true;
  }

  void _onEvent(PlatformWindowEvent event) {
    switch (event) {
      case WindowCloseRequestedEvent():
        _running = false;
      case WindowResizedEvent(clientSize: final Size size):
        _logicalSize = size;
        owner.pipelineOwner.rootConstraints = BoxConstraints.tight(size);
        _needsFrame = true;
      case WindowExposedEvent():
        _needsFrame = true;
      case WindowActivationEvent(activation: final WindowActivation state):
        // Keeps the focus assignment but dims the ring, per section 28.3's
        // window-inactive pseudo-class.
        owner.focusManager.isWindowActive = state == WindowActivation.activated;
        _needsFrame = true;
      case PointerEvent():
        // Layout must be current before hit testing, or the pointer is tested
        // against the previous frame's geometry.
        owner.dispatchPointerEvent(event);
        _needsFrame = true;
      case KeyEvent():
        owner.dispatchKeyEvent(event);
        _needsFrame = true;
      default:
        break;
    }
  }
}
