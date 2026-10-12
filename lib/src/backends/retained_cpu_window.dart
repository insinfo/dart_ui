/// CPU presentation for backends that show a framebuffer they own.
///
/// The window owns a [Framebuffer], the rasterizer fills it, and
/// [RetainedCpuSurface.present] hands it to whatever shows pixels on that
/// platform - a CGImage for the in-process macOS backends, a shared buffer the
/// Android host copies to its surface. Started as the macOS in-process path
/// and moved here when Android needed the same contract.
library;

import 'dart:async';

import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
import '../geometry/rect.dart';
import '../geometry/transform2d.dart';
import '../graphics/display_list.dart';
import '../platform/native_window.dart';
import '../platform/window_events.dart';
import '../rendering/cpu_renderer.dart';
import '../rendering/framebuffer.dart';
import '../rendering/renderer.dart';

/// A retained framebuffer that a window shows when asked.
abstract interface class RetainedCpuSurface implements NativeSurfaceDescriptor {
  /// The window generation this surface belongs to.
  int get generation;

  Framebuffer get framebuffer;

  /// Shows the framebuffer's current pixels, or returns why it could not.
  BackendDiagnostic? present({Rect? damage});
}

/// A window whose pixels are a [RetainedCpuSurface].
abstract interface class RetainedCpuWindow implements NativeWindow {
  RetainedCpuSurface? get cpuSurface;

  void recordRenderDiagnostic(BackendDiagnostic diagnostic);
}

/// Rasterizes the retained display list into a [RetainedCpuWindow] and presents
/// it, re-presenting on expose and re-rendering on resize - the X11 and
/// Win32 presenters' contract.
final class RetainedCpuPresenter with DisposableMixin {
  RetainedCpuPresenter(this._window) {
    _events = _window.events.listen(_onWindowEvent, onError: (_, __) {});
  }

  final RetainedCpuWindow _window;
  late final StreamSubscription<PlatformWindowEvent> _events;
  DisplayList? _displayList;
  int? _clearColor;
  Transform2D? _deviceTransform;
  int _revision = 0;
  bool _hasPresentedFrame = false;

  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  }) =>
      Future<PresentResult>.value(renderDisplayListNow(list,
          clearColor: clearColor,
          deviceTransform: deviceTransform,
          damage: damage));

  /// Synchronous, so a resize can draw before it returns.
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
    return _renderRetained(++_revision, damage: damage);
  }

  PresentResult _renderRetained(int revision, {Rect? damage}) {
    final DisplayList? list = _displayList;
    final RetainedCpuSurface? surface = _window.cpuSurface;
    if (list == null || surface == null) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'CPU frame skipped because the window has no surface',
        ),
      );
    }
    rasterizeDisplayList(
      list,
      surface.framebuffer,
      clearColor: _clearColor,
      deviceTransform:
          _deviceTransform ?? Transform2D.scaling(surface.scale, surface.scale),
    );
    final RetainedCpuSurface? current = _window.cpuSurface;
    if (isDisposed ||
        revision != _revision ||
        !identical(current, surface) ||
        current!.generation != surface.generation) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'CPU frame belonged to a replaced surface',
        ),
      );
    }
    _hasPresentedFrame = true;
    final BackendDiagnostic? failure = surface.present(damage: damage);
    if (failure != null) {
      return PresentResult(status: PresentStatus.failed, diagnostic: failure);
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  void _onWindowEvent(PlatformWindowEvent event) {
    if (isDisposed) return;
    final RetainedCpuSurface? surface = _window.cpuSurface;
    if (surface == null || surface.generation != event.generation) return;
    if (event is WindowExposedEvent && _hasPresentedFrame) {
      final BackendDiagnostic? failure =
          surface.present(damage: event.dirtyRect);
      if (failure != null) _window.recordRenderDiagnostic(failure);
    } else if (event is WindowResizedEvent) {
      _hasPresentedFrame = false;
      if (_displayList == null) return;
      final PresentResult result = _renderRetained(_revision);
      final BackendDiagnostic? diagnostic = result.diagnostic;
      if (!result.isSuccess && diagnostic != null) {
        _window.recordRenderDiagnostic(diagnostic);
      }
    }
  }

  @override
  void onDispose() {
    _revision++;
    unawaited(_events.cancel());
    _displayList = null;
  }
}
