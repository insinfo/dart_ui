/// CPU presentation for the in-process macOS backends.
///
/// SkyLight and the AppKit signal hijack draw in this process, so there is no
/// IOSurface pool shared with a host and no Metal layer to attach: the window
/// owns a [Framebuffer], the rasterizer fills it, and [MacosCpuSurface.present]
/// hands it to the WindowServer as an image. The native host keeps its own
/// path (`macos-iosurface` and Metal); these windows never offer a
/// `MacosSurfaceDescriptor`, which is what keeps those paths off them.
library;

import 'dart:async';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/display_list.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import '../../rendering/cpu_renderer.dart';
import '../../rendering/framebuffer.dart';
import '../../rendering/renderer.dart';

/// A retained BGRA framebuffer that a window shows when asked.
abstract interface class MacosCpuSurface implements NativeSurfaceDescriptor {
  /// The window generation this surface belongs to.
  int get generation;

  Framebuffer get framebuffer;

  /// Shows the framebuffer's current pixels, or returns why it could not.
  BackendDiagnostic? present({Rect? damage});
}

/// A window whose pixels are a [MacosCpuSurface].
abstract interface class MacosCpuWindow implements NativeWindow {
  MacosCpuSurface? get cpuSurface;

  void recordRenderDiagnostic(BackendDiagnostic diagnostic);
}

/// The `kind` every in-process macOS CPU surface reports.
const String macosCpuSurfaceKind = 'macos-cpu';

/// Rasterizes the retained display list into a [MacosCpuWindow] and presents
/// it, re-presenting on expose and re-rendering on resize - the X11 and
/// Win32 presenters' contract.
final class MacosCpuPresenter with DisposableMixin {
  MacosCpuPresenter(this._window) {
    _events = _window.events.listen(_onWindowEvent, onError: (_, __) {});
  }

  final MacosCpuWindow _window;
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
    final MacosCpuSurface? surface = _window.cpuSurface;
    if (list == null || surface == null) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'CPU frame skipped because the macOS window has no surface',
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
    final MacosCpuSurface? current = _window.cpuSurface;
    if (isDisposed ||
        revision != _revision ||
        !identical(current, surface) ||
        current!.generation != surface.generation) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'CPU frame belonged to a replaced macOS surface',
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
    final MacosCpuSurface? surface = _window.cpuSurface;
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
