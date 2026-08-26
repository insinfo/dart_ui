/// CPU display-list presentation for a Win32 DIB surface.
///
/// This is the vertical bridge between the portable renderer and the Win32
/// window backend. The canonical pixels live in the window's DIB; expose
/// events blit those pixels again, while resize and DPI changes replay the
/// retained display list into the replacement surface.
///
/// The portable renderer writes straight into the DIB framebuffer. There is
/// no full-frame staging copy: [rasterizeDisplayList] is shared with the
/// headless memory target, so native presentation and golden tests cannot
/// drift into different CPU rendering implementations.
library;

import 'dart:async';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/display_list.dart';
import '../../platform/window_events.dart';
import '../../rendering/cpu_renderer.dart';
import '../../rendering/present_mode.dart';
import '../../rendering/renderer.dart';
import 'win32_dib_surface.dart';
import 'win32_present_mode.dart';
import 'win32_window.dart';

/// Retains and presents the most recent CPU display list for one window.
///
/// Also the GDI path's [PresentPacer]. `PresentMode` was a contract with no
/// implementation anywhere in this repository - see `win32_present_mode.dart`
/// for what that meant - and this is where the GDI half of it is answered:
/// [PresentMode.fifo] by `DwmFlush`, [PresentMode.immediate] by not blocking,
/// and [PresentMode.mailbox] refused by name because one DIB blitted over in
/// place is not a queue anything can replace a frame in.
final class Win32CpuPresenter with DisposableMixin implements PresentPacer {
  Win32CpuPresenter(Win32Window window)
      : this.withSurfaceProvider(
          surfaceProvider: () => window.dibSurface,
          events: window.events,
          onDiagnostic: window.recordRenderDiagnostic,
          onError: window.reportError,
        );

  /// Dependency-injected constructor for headless tests.
  Win32CpuPresenter.withSurfaceProvider({
    required Win32CpuSurface? Function() surfaceProvider,
    required Stream<PlatformWindowEvent> events,
    void Function(BackendDiagnostic diagnostic)? onDiagnostic,
    void Function(Object error, StackTrace stackTrace)? onError,
  })  : _surfaceProvider = surfaceProvider,
        _onDiagnostic = onDiagnostic,
        _onError = onError {
    _events = events.listen(_onWindowEvent, onError: _reportError);
  }

  final Win32CpuSurface? Function() _surfaceProvider;
  final void Function(BackendDiagnostic diagnostic)? _onDiagnostic;
  final void Function(Object error, StackTrace stackTrace)? _onError;

  late final StreamSubscription<PlatformWindowEvent> _events;
  DisplayList? _displayList;
  int? _clearColor;
  Transform2D? _deviceTransform;
  int _revision = 0;
  bool _hasPresentedFrame = false;
  Future<void> _automaticWork = Future<void>.value();

  /// Completes after resize/DPI-triggered replay already queued by this
  /// presenter. Primarily useful to make lifecycle tests deterministic.
  Future<void> get idle => _automaticWork;

  /// The GDI pacing this presenter delegates [PresentPacer] to.
  ///
  /// Injectable so a test can drive the refusals without a desktop compositor
  /// - which is also what a CI container is.
  late final GdiPresentPacer pacer = _pacer ??
      GdiPresentPacer(
        surfaceDescription: 'the Win32 DIB window surface',
      );
  GdiPresentPacer? _pacer;

  /// Replaces the pacer. For tests; a running application has exactly one.
  set debugPacer(GdiPresentPacer value) => _pacer = value;

  @override
  Set<PresentMode> get supportedPresentModes => pacer.supportedPresentModes;

  @override
  PresentMode get presentMode => pacer.presentMode;

  @override
  PresentModeOutcome requestPresentMode(PresentMode mode) =>
      pacer.requestPresentMode(mode);

  @override
  bool awaitVerticalBlank() => pacer.awaitVerticalBlank();

  /// Rasterises [list], copies it into the current DIB, and presents it.
  ///
  /// The list is retained so a replacement surface can be repainted after a
  /// resize or DPI transition. It must therefore not be reset or mutated until
  /// the next call. Frame producers that reuse one arena should alternate two
  /// display lists, which also prevents recording over a frame in flight.
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  }) =>
      Future<PresentResult>.value(
        renderDisplayListNow(
          list,
          clearColor: clearColor,
          deviceTransform: deviceTransform,
          damage: damage,
        ),
      );

  /// [renderDisplayList] with the future taken off.
  ///
  /// Not an optimisation and not a second implementation: the body was always
  /// synchronous - there is no `await` anywhere between recording and the
  /// `BitBlt` - and the `async` only ever deferred the *answer*. That is
  /// harmless in the frame loop and fatal during a border drag, where the
  /// isolate is inside `DispatchMessageW` for the whole gesture and nothing
  /// waiting on a microtask will run until it ends. See
  /// [SynchronousDisplayListPresentCallback].
  PresentResult renderDisplayListNow(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  }) {
    throwIfDisposed();
    _displayList = list;
    _clearColor = clearColor;
    _deviceTransform = deviceTransform;
    final revision = ++_revision;
    return _renderRetained(revision, damage: damage);
  }

  PresentResult _renderRetained(
    int revision, {
    Rect? damage,
  }) {
    final list = _displayList;
    final surface = _surfaceProvider();
    if (list == null || surface == null) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'CPU frame skipped because the Win32 surface is unavailable',
        ),
      );
    }

    final transform =
        _deviceTransform ?? Transform2D.scaling(surface.scale, surface.scale);
    rasterizeDisplayList(
      list,
      surface.framebuffer,
      clearColor: _clearColor,
      deviceTransform: transform,
    );

    final current = _surfaceProvider();
    if (isDisposed ||
        revision != _revision ||
        current == null ||
        !identical(current, surface) ||
        current.generation != surface.generation) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'CPU frame belonged to a replaced Win32 DIB surface',
        ),
      );
    }

    _hasPresentedFrame = true;
    final failure = surface.present(damage: damage);
    if (failure != null) {
      return PresentResult(status: PresentStatus.failed, diagnostic: failure);
    }
    // The pacing, and the only place in this class that knows there is any.
    // Under `PresentMode.fifo` this blocks until the desktop compositor's next
    // present; under `immediate` it returns false without waiting, which is
    // the mode's whole meaning. The wait is *after* the blit, not before it,
    // so the frame just produced is the one the compositor picks up.
    pacer.awaitVerticalBlank();
    return const PresentResult(status: PresentStatus.presented);
  }

  void _onWindowEvent(PlatformWindowEvent event) {
    if (isDisposed) return;
    final surface = _surfaceProvider();
    if (surface == null || surface.generation != event.generation) return;

    if (event is WindowExposedEvent) {
      if (!_hasPresentedFrame) return;
      try {
        final failure = surface.present(damage: event.dirtyRect);
        if (failure != null) _onDiagnostic?.call(failure);
      } catch (error, stackTrace) {
        _reportError(error, stackTrace);
      }
      return;
    }
    if (event is WindowResizedEvent || event is WindowScaleChangedEvent) {
      _hasPresentedFrame = false;
      final revision = _revision;
      if (_displayList == null) return;
      _automaticWork = _automaticWork.then((_) async {
        if (isDisposed || revision != _revision) return;
        final result = _renderRetained(revision);
        final diagnostic = result.diagnostic;
        if (!result.isSuccess && diagnostic != null) {
          _onDiagnostic?.call(diagnostic);
        }
      }).catchError((Object error, StackTrace stackTrace) {
        _reportError(error, stackTrace);
      });
    }
  }

  void _reportError(Object error, StackTrace stackTrace) {
    final handler = _onError;
    if (handler != null) {
      handler(error, stackTrace);
    } else {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }

  @override
  void onDispose() {
    _revision++;
    unawaited(_events.cancel());
    _displayList = null;
  }
}
