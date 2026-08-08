/// The window contract of section 9.3.
///
/// Every backend implements this and nothing above it knows which one is
/// running. The shape is deliberately narrow: a window is a rectangle that
/// receives events and owns one or more surfaces a renderer can present to.
/// Menus, popups and modality are built in Dart on top of this, not delegated
/// to the platform, which is what keeps them identical everywhere.
library;

import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../rendering/renderer.dart';
import 'window_events.dart';

enum WindowState { normal, minimised, maximised, fullscreen }

enum SystemCursor {
  arrow,
  text,
  hand,
  resizeHorizontal,
  resizeVertical,
  resizeDiagonalDown,
  resizeDiagonalUp,
  wait,
  crosshair,
  notAllowed,
}

/// What the application asks for when creating a window.
final class WindowOptions {
  const WindowOptions({
    required this.size,
    this.title = 'dart_ui',
    this.position,
    this.resizable = true,
    this.decorated = true,
    this.visible = true,
  });

  /// In logical units. The backend multiplies by the scale of whichever
  /// monitor the window lands on.
  final Size size;

  final String title;

  /// Null means "let the platform decide", which is usually what a first
  /// window should do.
  final Offset? position;

  final bool resizable;
  final bool decorated;
  final bool visible;
}

/// A live window.
///
/// The two scales are separate on purpose. [renderScale] is what a framebuffer
/// must be allocated at; [desktopScale] is what the user's text-size setting
/// says. They differ on mixed-DPI desktops, and conflating them is how a
/// window ends up sharp on one monitor and blurry on the next.
abstract interface class NativeWindow implements Disposable {
  NativeWindowId get id;

  /// Bumped whenever the window's surfaces are invalidated - a resize, a
  /// scale change, a device loss. Events and frames carry it so late work can
  /// be dropped rather than applied to a surface that moved.
  int get generation;

  Size get clientSize;
  double get renderScale;
  double get desktopScale;
  WindowState get state;

  /// What a renderer can present into. More than one when a backend offers a
  /// choice - a CPU framebuffer and a GPU swapchain over the same window - so
  /// the renderer picks rather than the window deciding for it.
  List<NativeSurfaceDescriptor> get surfaces;

  Stream<PlatformWindowEvent> get events;

  void show();
  void hide();
  void close();

  void setTitle(String value);
  void setBounds(Rect bounds);
  void setCursor(SystemCursor cursor);

  /// Asks for a repaint. A null rect means the whole window.
  void requestRedraw([Rect? dirtyRect]);

  Offset screenToClient(Offset screenPosition);
  Offset clientToScreen(Offset clientPosition);
}

/// Creating and owning windows on one platform.
abstract interface class WindowingBackend {
  String get name;

  /// Whether this backend can run here, and if not, exactly what was missing.
  /// Never a bare bool - section 6.6 forbids trying the next backend without
  /// recording what was wrong with this one.
  BackendProbeResult probe();

  Future<void> initialize();
  Future<void> shutdown();

  Future<NativeWindow> createWindow(WindowOptions options);

  /// Every window this backend currently owns, so a shutdown can be orderly
  /// and a diagnostic can name what was still open.
  List<NativeWindow> get windows;

  /// Drains pending platform events into the window streams.
  ///
  /// Returns false when the platform asked the application to stop - the last
  /// window closed on a platform where that means quit, or the session is
  /// ending. Backends must NOT call exit() themselves: deciding to stop is the
  /// application's, and a backend that exits takes the teardown with it.
  bool pumpEvents({Duration timeout = Duration.zero});

  /// Wakes a blocked [pumpEvents] from another thread or isolate.
  void wake();
}
