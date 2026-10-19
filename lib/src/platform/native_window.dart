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
import '../foundation/value_notifier.dart';
import '../geometry/offset.dart';
import '../geometry/popup_request.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../rendering/renderer.dart';
import 'window_events.dart';

export '../geometry/popup_request.dart';

// Re-exported rather than merely imported so that `ScreenInfo` and
// `ScreenProvider` are nameable from the same import that names
// `WindowingBackend`. A caller that has a backend and wants to know where the
// monitors are must be able to write down the type it pattern-matches on, and
// the umbrella library exports this file; a seam that cannot be spelled is a
// seam nobody uses.
export 'screen_info.dart';

enum WindowState { normal, minimised, maximised, fullscreen }

/// What a window *is*, which decides far more than how it is decorated.
///
/// A desktop application is not a set of equal top-level windows: it is a few
/// real windows plus a stream of short-lived surfaces - menus, tooltips,
/// completion popups - that happen to be windows because they must be able to
/// leave their owner's bounds. Modelling them as "a window with `decorated:
/// false`" is what produces the two failures every toolkit hits:
///
///   * **the popup counts as a window**, so dismissing a menu closes the
///     application. The exit policy has to be about top-level windows, not
///     about the last window of any kind - see
///     [WindowKind.isTopLevel];
///   * **the popup takes activation**, so opening a menu deactivates the
///     window behind it, the caret stops blinking and the selection dims. A
///     popup must be shown without activating.
///
/// So the kind is declared at creation and every layer reads it.
enum WindowKind {
  /// An ordinary top-level window: decorated, in the taskbar, activatable, and
  /// counted by [ApplicationOptions.exitWhenLastWindowClosed].
  normal,

  /// A decorated, activatable window that belongs to another one. Dialogs and
  /// inspectors. Closing the last of these does *not* end the application.
  dialog,

  /// A menu or completion list: undecorated, never activated, dismissed when
  /// focus goes anywhere that is not it or its owner.
  popup,

  /// A tooltip: like [popup], and additionally never focusable at all.
  tooltip;

  /// Whether closing this window can end the application.
  bool get isTopLevel => this == WindowKind.normal;

  /// Whether the platform should be asked to activate this window when it is
  /// shown.
  bool get takesActivation =>
      this == WindowKind.normal || this == WindowKind.dialog;

  /// Whether the window manager should draw a frame around it.
  bool get isDecoratedByDefault => takesActivation;

  /// Whether this window disappears when focus moves elsewhere.
  bool get isDismissable =>
      this == WindowKind.popup || this == WindowKind.tooltip;
}

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

/// Positions a popup relative to its parent surface. Compositor backends use
/// the measured content size and anchor before assigning a native popup role.
abstract interface class PositionedPopupWindow {
  void configurePopup(PopupRequest request);
}

/// What happens to a decorated window's title bar.
enum WindowTitleBar {
  /// The platform's own title bar, above the client area.
  standard,

  /// No title bar: the client area reaches the top of the window and the
  /// application draws what the title bar held - tabs, a toolbar - there,
  /// as Finder, Safari and Windows 11's File Explorer do. Where the platform
  /// keeps its own window buttons (macOS's close, minimise and zoom) they
  /// stay, over the client area; see [HiddenTitleBarWindow].
  hidden,
}

/// What the application asks for when creating a window.
final class WindowOptions {
  const WindowOptions({
    required this.size,
    this.title = 'dart_ui',
    this.position,
    this.minimumSize,
    this.maximumSize,
    this.resizable = true,
    this.decorated = true,
    this.titleBar = WindowTitleBar.standard,
    this.visible = true,
    this.backgroundColor,
    this.owner,
    this.kind = WindowKind.normal,
  });

  /// In logical units. The backend multiplies by the scale of whichever
  /// monitor the window lands on.
  final Size size;

  final String title;

  /// Null means "let the platform decide", which is usually what a first
  /// window should do.
  final Offset? position;

  /// The smallest client area the user may drag this window down to, in
  /// logical units, or null for the platform's own floor.
  ///
  /// Null is not the same as "no minimum" in practice, and that is the point of
  /// stating it: the platform floor is about the *frame* - Windows will not let
  /// the caption buttons be clipped - and it says nothing at all about the
  /// client area, so a window with no minimum can be dragged to a client area a
  /// few pixels tall. Every layout below then runs against constraints it was
  /// never designed for: scroll offsets collapse, text measures to zero lines,
  /// and a `SizedBox` that no longer fits overflows into a diagnostic on every
  /// frame of the drag. The fix is a number, declared once by whoever knows
  /// what the tree needs, and enforced by the window manager rather than
  /// repaired afterwards.
  ///
  /// A backend that cannot express one ignores it, which degrades to today's
  /// behaviour rather than to a broken window.
  final Size? minimumSize;

  /// The largest client area the user may drag this window up to, or null for
  /// the platform's own ceiling (the work area of the monitor).
  final Size? maximumSize;

  final bool resizable;
  final bool decorated;

  /// Whether a decorated window keeps its title bar. A backend that cannot
  /// hide it keeps it, and does not implement [HiddenTitleBarWindow].
  final WindowTitleBar titleBar;

  final bool visible;

  /// What the platform should put in the client area when *nobody has drawn
  /// there yet*: the strip a window grows into before the first frame at the
  /// new size arrives, and the whole client area between the window appearing
  /// and its first frame.
  ///
  /// Premultiplied BGRA packed into a 32-bit int - the same encoding as
  /// [ApplicationOptions.clearColor] - or null to let the backend use the
  /// system's window colour.
  ///
  /// This exists because "the backend never paints, every pixel comes from the
  /// framebuffer" is only true once there *is* a framebuffer covering the
  /// pixel. During a resize there is not: the window grows first and the frame
  /// follows, and whatever the platform leaves in the gap is what the user
  /// sees. On Windows that is uninitialised video memory, which reads as black.
  final int? backgroundColor;

  /// The window this one belongs to, or null for a top-level window.
  ///
  /// An owned window stays in front of its owner, minimises and restores with
  /// it, and is destroyed when the owner is - which is what a dialog, an
  /// inspector or a tool palette needs and what an unrelated second top-level
  /// window must *not* have. Backends that have no concept of ownership ignore
  /// it; the application layer still enforces its half (modal input blocking)
  /// so the behaviour degrades to "correct but not integrated with the window
  /// manager" rather than to "modal dialogs do not work".
  ///
  /// The window itself rather than its [NativeWindowId], because turning an id
  /// back into a native handle is a lookup only the backend can do, and a
  /// backend that was handed an id from *another* backend could not tell.
  final NativeWindow? owner;

  /// What this window is for. See [WindowKind]; the default is an ordinary
  /// top-level window, so no existing caller changes behaviour.
  final WindowKind kind;
}

/// A window that can ask the platform for keyboard focus.
///
/// Separate from [NativeWindow] rather than a method on it, because a backend
/// that cannot honour the request must be able to say so by not implementing
/// this - and because adding a method to the window contract would break every
/// backend at once for a capability only some of them have. Test with a
/// pattern, the way `ClipboardProvider` is tested for:
///
/// ```dart
/// if (window case final ActivatableWindow window) window.activate();
/// ```
abstract interface class ActivatableWindow {
  /// Raises the window and gives it the keyboard, if the platform allows it.
  ///
  /// Best effort by nature: Windows refuses foreground activation to a process
  /// the user is not interacting with, and X11 window managers may honour or
  /// ignore the request. The application's own focus bookkeeping is therefore
  /// driven by the *activation event that comes back*, never by the fact that
  /// this was called.
  void activate();
}

/// What a [LiveResizeWindow] hands its owner when the geometry has already
/// changed and nothing has drawn yet.
///
/// Called **synchronously, from inside the platform's own resize handler**, so
/// the implementation may not await anything: see [LiveResizeWindow].
typedef LiveResizeCallback = void Function({
  required Size logicalSize,
  required double renderScale,
});

/// A window that can have one whole frame produced from inside its resize
/// handler.
///
/// ## The problem this exists for
///
/// Dragging a window border on Windows enters a *modal loop inside the OS*:
/// `DispatchMessageW` does not return between `WM_ENTERSIZEMOVE` and
/// `WM_EXITSIZEMOVE`, and the loop delivers `WM_SIZE` and `WM_PAINT` from in
/// there. Every event this framework normally produces travels through a
/// broadcast `StreamController`, whose listeners run on a *later* turn of the
/// Dart event loop - a turn that cannot happen, because the isolate is parked
/// inside a native call. So the window grows, no layout runs, no frame is
/// painted, nothing is presented, and the area the window just grew into stays
/// whatever the platform put there. On Windows that reads as black.
///
/// It is not a scheduling bug that a faster frame loop would fix. The Dart
/// queue is not slow, it is *unreachable*, and the only code that runs while it
/// is unreachable is code the OS calls directly. Hence a callback invoked from
/// the handler itself, which is exactly what POC-01 does in twelve lines:
/// resize the framebuffer, call the paint callback, invalidate.
///
/// ## What an implementer of the callback must obey
///
///   * **Never await.** An `await` inside the callback hands control to a
///     microtask queue that will not be drained until the drag is over, so the
///     work would land after the modal loop rather than during it - which is
///     the very failure being fixed. Anything after the first suspension point
///     is dead code for the duration of the drag.
///   * **Never re-enter.** The callback runs while a platform handler is on the
///     stack, and a frame that starts a second frame is exactly the reentrancy
///     `ManualDispatcher` already throws on. Guard and return.
///   * **Adopt the size that was passed**, rather than waiting for the resize
///     *event*: that event is queued on the stream nobody is draining.
abstract interface class LiveResizeWindow {
  /// Installs (or removes, with null) the callback the window invokes from
  /// inside its resize handler.
  ///
  /// One callback, replaced rather than added to: a second subscriber would be
  /// a second frame per resize message, which is the cost this whole feature is
  /// optional to avoid.
  void setLiveResizeCallback(LiveResizeCallback? callback);

  /// Whether the platform is currently inside its own modal resize/move loop.
  bool get isLiveResizing;
}

/// A window whose drawing surface is, for a moment, being replaced.
///
/// On the macOS host a resize means new `IOSurface`s at the new pixel size
/// and a handshake with the host process to hand them over. A frame drawn in
/// between is drawn for surfaces that are about to be released and is thrown
/// away as stale - and the measurement that put this here was worse than
/// waste: during a live resize every step started a frame, the frame's layout
/// and paint (tens of milliseconds) held up the handshake's replies behind
/// it, and the five round trips of one handoff took 50 to 140 ms. No frame
/// of the new size reached the window for the whole drag. The application
/// skips drawing a window while this is false and draws it as soon as the
/// surfaces are attached, which is announced as a resize.
abstract interface class SurfaceReadinessWindow {
  /// False between a size change and the moment surfaces of the new size can
  /// be presented.
  bool get surfaceReady;
}

/// A window whose input the platform can be told to refuse.
///
/// This is the half of modality the platform owns: a disabled window does not
/// receive mouse or keyboard input, its title bar flashes when clicked, and
/// the window manager knows it is blocked. The other half - refusing to route
/// events that reach the framework anyway - belongs to the application layer,
/// which enforces it whether or not the backend implements this.
abstract interface class EnableableWindow {
  bool get isEnabled;

  void setEnabled(bool value);
}

/// A window whose [WindowState] the application can ask for.
///
/// Every desktop backend reports the state; this is the other direction - the
/// "full screen" menu item of a video player, the maximise button of a frame
/// the application draws itself. Each platform spells it differently:
/// `xdg_toplevel.set_maximized` and friends on Wayland, `_NET_WM_STATE` and
/// `WM_CHANGE_STATE` on X11, `ShowWindow` and a borderless window over the
/// monitor on Win32, `zoom:`/`miniaturize:`/`toggleFullScreen:` on macOS.
///
/// A capability, tested for with a pattern, for the reason
/// [ActivatableWindow] gives.
abstract interface class WindowStateControl {
  /// Asks the window system to put the window in [state].
  ///
  /// Returns whether the request was sent, not whether it was honoured: the
  /// window manager may refuse it (a tiling one maximising nothing), carry it
  /// out after an animation (macOS full screen) or not report it at all
  /// (Wayland has no minimised state). The outcome arrives as a
  /// [WindowStateChangedEvent] and in [NativeWindow.state].
  ///
  /// [WindowState.normal] leaves maximised and fullscreen and restores a
  /// minimised window where the platform lets a client do that.
  bool requestState(WindowState state);
}

/// Which edge or corner an interactive resize is dragged from.
enum WindowResizeEdge {
  top,
  bottom,
  left,
  right,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// A window whose title bar and borders the application may have to draw,
/// and which the windowing system still moves and resizes.
///
/// The Wayland case: a compositor without `zxdg_decoration_manager_v1` - GNOME,
/// Weston - draws no frame at all, so a window that is not decorated by the
/// application has no title, no close button and no way to be moved. The
/// framework answers by drawing one (`ClientDecorationFrame`) and handing the
/// gestures back here, because only the compositor can move a window: the
/// client asks, quoting the pointer press that started the drag.
///
/// A capability, tested for with a pattern, for the reason
/// [ActivatableWindow] gives.
abstract interface class ClientDecoratedWindow {
  /// Whether the application must draw this window's frame now. It can change
  /// after the window opens - a compositor answers the decoration request
  /// asynchronously - which is why it is a notifier and not a getter.
  ValueNotifier<bool> get clientDecorations;

  /// The window's title, for the frame to show.
  String get title;

  /// Starts the compositor's interactive move from the latest pointer press.
  /// False when it cannot: there was no recent press to quote.
  bool beginMove();

  /// Starts an interactive resize from [edge], as [beginMove] does.
  bool beginResize(WindowResizeEdge edge);

  /// Opens the window system's own menu for this window - move, resize,
  /// always on top, close - at [position] in client coordinates, the way a
  /// right click on a server-drawn title bar does. False when the platform
  /// has none or refused.
  bool showWindowMenu(Offset position);

  /// Whether [minimize] can do anything. False where minimising would
  /// leave the window with no way back - SkyLight has no Dock - and the
  /// frame then shows no minimise button.
  bool get canMinimize;

  void minimize();

  void setMaximized(bool maximized);

  bool get isMaximized;

  /// What the close button of a frame does: the same request the window
  /// manager's close button sends, which the application may refuse.
  void requestClose();
}

/// A window opened with [WindowTitleBar.hidden] whose title bar the
/// platform really took away.
///
/// The client area then starts at the top of the window, and the
/// application owns that strip: it draws its tabs or toolbar there, keeps
/// clear of [systemButtons] and makes its empty parts a handle - a press
/// there calls [beginMove], a double click [toggleMaximized] - which is
/// what `WindowDragArea` does.
abstract interface class HiddenTitleBarWindow {
  /// Whether this window was opened with its title bar hidden. A backend
  /// type implements the interface for every window it makes; only the
  /// ones that asked for it answer true.
  bool get isTitleBarHidden;

  /// Where the window's caption controls belong over the client area, in
  /// logical client coordinates - macOS at the top left, Windows at the right -
  /// or [Rect.zero] where there are none (in full screen, or on a platform
  /// whose application must draw its own).
  ValueNotifier<Rect> get systemButtons;

  /// The height of the strip the title bar used to occupy - where a
  /// toolbar centred on the window buttons goes.
  double get titleBarHeight;

  /// Starts the platform's own window move from the latest primary press.
  /// False when there was no press to start it from.
  bool beginMove();

  /// What a double click on a title bar does: zoom, or restore.
  void toggleMaximized();
}

/// A hidden title bar whose caption controls are painted by the framework.
///
/// `WindowDragArea` paints and activates controls inside
/// [HiddenTitleBarWindow.systemButtons]. Backends may retain native caption hit
/// codes for system features such as Snap and translate those presses to the
/// framework's pointer route.
abstract interface class ClientCaptionWindow implements HiddenTitleBarWindow {
  ValueListenable<WindowState> get captionState;
  bool get canMinimize;
  bool get canMaximize;
  bool showWindowMenu(Offset position);
  void minimize();
  void requestClose();
}

/// A window whose operating-system handle can be passed to native UI.
///
/// This is deliberately a capability separate from [NativeWindow]: an HWND,
/// XID or NSWindow pointer has platform-specific meaning. Callers use it only
/// as an opaque owner for APIs such as a certificate provider's secure PIN
/// dialog and must never assume a particular handle type.
abstract interface class NativeHandleWindow {
  int get nativeHandle;
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
///
/// Capabilities a backend may or may not have are **not** members here, and
/// that is a rule rather than an accident: this contract is implemented by
/// every backend and by every test double in the suite, so a member added for
/// something only two of them can do breaks all of them at once. They are
/// separate interfaces a backend also implements, and a caller asks with a
/// pattern - `ClipboardProvider` for the clipboard, `ScreenProvider` for the
/// monitors and their work areas (`screen_info.dart`, re-exported above),
/// `DragDropProvider`, `TextInputProvider`. Wayland has no screen coordinates
/// at all, and a fake backend in a widget test has no monitor to describe;
/// both stay whole by simply not declaring the interface.
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

/// A backend whose platform events reach this isolate through its own event
/// loop - UIKit calling back on the isolate's thread, a socket `dart:io`
/// reads - so [WindowingBackend.pumpEvents] has nothing to block on.
///
/// Blocking there is not merely useless for such a backend but wrong: on iOS
/// the isolate runs on the main thread, and a pump that slept would stop UIKit
/// delivering the very events it waits for. The application loop therefore
/// awaits [waitForEvents] instead of sleeping in the pump, and a backend
/// that is not one of these keeps the synchronous wait it always had.
abstract interface class EventLoopWaitingBackend {
  /// Completes when an event arrived or [wake] was called, or after
  /// [timeout], whichever is first. Never blocks the isolate.
  Future<void> waitForEvents(Duration timeout);
}
