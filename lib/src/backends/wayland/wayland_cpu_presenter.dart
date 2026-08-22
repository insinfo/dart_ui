/// CPU display-list presentation for a Wayland shm surface.
///
/// The canonical pixels live in the window's retained shm buffer. Exposed
/// events (which on Wayland are locally generated - the first configure, a
/// redraw request) re-commit those pixels, while resize events replay the
/// retained display list into the replacement surface created for the new
/// configure generation. The class is a structural twin of `X11CpuPresenter`;
/// the differences live entirely behind [WaylandCpuSurface].
library;

import 'dart:async';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/display_list.dart';
import '../../platform/window_events.dart';
import '../../rendering/cpu_renderer.dart';
import '../../rendering/renderer.dart';
import 'wayland_shm.dart';
import 'wayland_window.dart';

/// Retains and presents the most recent CPU display list for one window.
final class WaylandCpuPresenter with DisposableMixin {
  WaylandCpuPresenter(
    WaylandWindow window, {
    void Function(BackendDiagnostic diagnostic)? onDiagnostic,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) : this.withSurfaceProvider(
          surfaceProvider: () => window.cpuSurface,
          events: window.events,
          onDiagnostic: onDiagnostic ?? window.recordRenderDiagnostic,
          onError: onError ?? window.reportError,
        );

  /// Dependency-injected constructor for tests that have no compositor.
  WaylandCpuPresenter.withSurfaceProvider({
    required WaylandCpuSurface? Function() surfaceProvider,
    required Stream<PlatformWindowEvent> events,
    void Function(BackendDiagnostic diagnostic)? onDiagnostic,
    void Function(Object error, StackTrace stackTrace)? onError,
  })  : _surfaceProvider = surfaceProvider,
        _onDiagnostic = onDiagnostic,
        _onError = onError {
    _events = events.listen(_onWindowEvent, onError: _reportError);
  }

  final WaylandCpuSurface? Function() _surfaceProvider;
  final void Function(BackendDiagnostic diagnostic)? _onDiagnostic;
  final void Function(Object error, StackTrace stackTrace)? _onError;

  late final StreamSubscription<PlatformWindowEvent> _events;
  DisplayList? _displayList;
  int? _clearColor;
  Transform2D? _deviceTransform;
  int _revision = 0;
  int? _presentedGeneration;
  Future<void> _automaticWork = Future<void>.value();

  /// Completes after queued resize-triggered replay work.
  Future<void> get idle => _automaticWork;

  /// Rasterises [list] directly into the current shm buffer and commits it.
  ///
  /// The display list is retained so the replacement surface produced by a
  /// configure can be populated without asking framework code to rebuild it.
  Future<PresentResult> renderDisplayList(
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

  Future<PresentResult> _renderRetained(
    int revision, {
    Rect? damage,
  }) async {
    final list = _displayList;
    final surface = _surfaceProvider();
    if (list == null || surface == null) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'CPU frame skipped because the Wayland surface is unavailable',
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

    // Rasterisation is synchronous today; both checks stay anyway, exactly as
    // in the X11 twin, because either can start failing the day rasterisation
    // yields or moves to a worker isolate.
    final current = _surfaceProvider();
    if (isDisposed ||
        revision != _revision ||
        current == null ||
        !identical(current, surface) ||
        current.generation != surface.generation) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'CPU frame belonged to a replaced Wayland shm surface',
        ),
      );
    }

    _presentedGeneration = surface.generation;
    final failure = surface.present(damage: damage);
    if (failure != null) {
      return PresentResult(status: PresentStatus.failed, diagnostic: failure);
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  void _onWindowEvent(PlatformWindowEvent event) {
    if (isDisposed) return;
    final surface = _surfaceProvider();
    if (surface == null || surface.generation != event.generation) return;

    if (event is WindowExposedEvent) {
      if (_presentedGeneration != surface.generation) {
        // The first expose after a configure has nothing retained to
        // re-commit; the application's first frame will arrive through
        // renderDisplayList. Replaying here would commit stale pixels.
        if (_displayList == null) return;
        _scheduleReplay();
        return;
      }
      try {
        final failure = surface.present(damage: event.dirtyRect);
        if (failure != null) _onDiagnostic?.call(failure);
      } catch (error, stackTrace) {
        _reportError(error, stackTrace);
      }
      return;
    }
    if (event is WindowResizedEvent || event is WindowScaleChangedEvent) {
      _presentedGeneration = null;
      if (_displayList == null) return;
      _scheduleReplay();
    }
  }

  void _scheduleReplay() {
    final revision = _revision;
    _automaticWork = _automaticWork.then((_) async {
      if (isDisposed || revision != _revision) return;
      final result = await _renderRetained(revision);
      final diagnostic = result.diagnostic;
      if (!result.isSuccess && diagnostic != null) {
        _onDiagnostic?.call(diagnostic);
      }
    }).catchError((Object error, StackTrace stackTrace) {
      _reportError(error, stackTrace);
    });
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
