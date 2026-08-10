/// CPU display-list presentation for an X11 PutImage surface.
///
/// The canonical pixels live in the window's retained native buffer. Expose
/// events upload those pixels again, while resize events replay the retained
/// display list into the replacement surface created for the new generation.
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
import 'x11_surface.dart';
import 'x11_window.dart';

/// Retains and presents the most recent CPU display list for one X11 window.
final class X11CpuPresenter with DisposableMixin {
  X11CpuPresenter(
    X11Window window, {
    void Function(BackendDiagnostic diagnostic)? onDiagnostic,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) : this.withSurfaceProvider(
          surfaceProvider: () => window.cpuSurface,
          events: window.events,
          onDiagnostic: onDiagnostic ?? window.recordRenderDiagnostic,
          onError: onError ?? window.reportError,
        );

  /// Dependency-injected constructor for tests that have no X server.
  X11CpuPresenter.withSurfaceProvider({
    required X11CpuSurface? Function() surfaceProvider,
    required Stream<PlatformWindowEvent> events,
    void Function(BackendDiagnostic diagnostic)? onDiagnostic,
    void Function(Object error, StackTrace stackTrace)? onError,
  })  : _surfaceProvider = surfaceProvider,
        _onDiagnostic = onDiagnostic,
        _onError = onError {
    _events = events.listen(_onWindowEvent, onError: _reportError);
  }

  final X11CpuSurface? Function() _surfaceProvider;
  final void Function(BackendDiagnostic diagnostic)? _onDiagnostic;
  final void Function(Object error, StackTrace stackTrace)? _onError;

  late final StreamSubscription<PlatformWindowEvent> _events;
  DisplayList? _displayList;
  int? _clearColor;
  Transform2D? _deviceTransform;
  int _revision = 0;
  bool _hasPresentedFrame = false;
  Future<void> _automaticWork = Future<void>.value();

  /// Completes after queued resize-triggered replay work.
  Future<void> get idle => _automaticWork;

  /// Rasterises [list] directly into the current X11 buffer and uploads it.
  ///
  /// The display list is retained so the replacement surface produced by a
  /// resize can be populated without asking framework code to rebuild it.
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
          'CPU frame skipped because the X11 surface is unavailable',
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

    // Rasterisation is synchronous today, but keep both identity and
    // generation checks: either can change once the renderer yields or gains
    // worker-isolate rasterisation.
    final current = _surfaceProvider();
    if (isDisposed ||
        revision != _revision ||
        current == null ||
        !identical(current, surface) ||
        current.generation != surface.generation) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'CPU frame belonged to a replaced X11 PutImage surface',
        ),
      );
    }

    _hasPresentedFrame = true;
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
      if (!_hasPresentedFrame) return;
      try {
        final failure = surface.present(damage: event.dirtyRect);
        if (failure != null) _onDiagnostic?.call(failure);
      } catch (error, stackTrace) {
        _reportError(error, stackTrace);
      }
      return;
    }
    if (event is WindowResizedEvent) {
      _hasPresentedFrame = false;
      final revision = _revision;
      if (_displayList == null) return;
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
