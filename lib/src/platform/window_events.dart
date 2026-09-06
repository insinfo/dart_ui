/// Events a windowing backend reports upwards.
///
/// These are *platform* events: what the OS said happened. They are not input
/// events for widgets - hit testing, focus and gesture recognition live above
/// this layer and consume these. Keeping the split means a backend never has
/// to know what a widget is, which is section 8.2's dependency rule in
/// practice.
///
/// Every event carries the window it belongs to and a generation. The
/// generation is not decoration: native code goes on delivering callbacks for
/// windows that have already closed, and comparing two integers is the only
/// reliable way to tell a live event from a late one.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';

/// Opaque identity of a window, stable for that window's lifetime.
///
/// Deliberately not the native handle. `HWND`, `xcb_window_t` and
/// `CGSWindowID` have different widths and lifetimes, and letting them leak
/// into common code is how backend-specific assumptions spread.
extension type const NativeWindowId(int value) {}

abstract class PlatformWindowEvent {
  const PlatformWindowEvent({
    required this.windowId,
    required this.generation,
  });

  final NativeWindowId windowId;

  /// The window's lifetime this event belongs to. An event whose generation
  /// no longer matches must be dropped, not processed.
  final int generation;
}

/// The window's client area changed size, in logical units.
final class WindowResizedEvent extends PlatformWindowEvent {
  const WindowResizedEvent({
    required super.windowId,
    required super.generation,
    required this.clientSize,
    required this.renderScale,
  });

  final Size clientSize;

  /// Physical pixels per logical unit for this window's surface. Separate from
  /// the desktop scale because a window can straddle two monitors, and the one
  /// that matters for allocating a framebuffer is this one.
  final double renderScale;
}

/// The window moved on the desktop. Distinct from a resize because it does not
/// invalidate the framebuffer.
final class WindowMovedEvent extends PlatformWindowEvent {
  const WindowMovedEvent({
    required super.windowId,
    required super.generation,
    required this.screenPosition,
  });

  final Offset screenPosition;
}

/// The scale changed without the size changing - the window was dragged to a
/// monitor with a different DPI, or the user changed the display setting.
///
/// Separate from [WindowResizedEvent] because the response differs: the layout
/// is unchanged in logical units, but every rasterised resource is now the
/// wrong resolution.
final class WindowScaleChangedEvent extends PlatformWindowEvent {
  const WindowScaleChangedEvent({
    required super.windowId,
    required super.generation,
    required this.renderScale,
    required this.desktopScale,
  });

  final double renderScale;
  final double desktopScale;
}

/// A region needs repainting. [dirtyRect] is null when the backend could not
/// tell us which part - repaint everything in that case rather than guessing.
final class WindowExposedEvent extends PlatformWindowEvent {
  const WindowExposedEvent({
    required super.windowId,
    required super.generation,
    this.dirtyRect,
  });

  final Rect? dirtyRect;
}

enum WindowActivation { activated, deactivated }

final class WindowActivationEvent extends PlatformWindowEvent {
  const WindowActivationEvent({
    required super.windowId,
    required super.generation,
    required this.activation,
  });

  final WindowActivation activation;
}

/// The user asked to close the window. The framework decides whether to
/// honour it - this is a request, not a notification, which is why it is
/// separate from [WindowClosedEvent].
final class WindowCloseRequestedEvent extends PlatformWindowEvent {
  const WindowCloseRequestedEvent({
    required super.windowId,
    required super.generation,
  });
}

/// The window is gone. Nothing more will arrive for this generation.
final class WindowClosedEvent extends PlatformWindowEvent {
  const WindowClosedEvent({
    required super.windowId,
    required super.generation,
  });
}

/// The user pressed a mouse button on the window's *frame* - its title bar,
/// its border, one of the caption buttons - rather than in its client area.
///
/// This exists for one job: **dismissing a popup that belongs to this window**.
/// A menu is a separate window, so it never sees the click that starts a drag
/// of its owner's title bar; without this event the menu stays open, floating
/// over the desktop, while the window it was anchored to walks away from
/// underneath it. Avalonia subscribes to the same signal for the same reason
/// (`NonClientLeftButtonDown`), and it is one of the five dismissal inputs the
/// popup plan names.
///
/// It is deliberately **not** a `PlatformInputEvent`: there is no position on
/// it and no hit test above this layer would be meaningful, because the pixels
/// under the press belong to the window manager and not to any render object.
/// What the framework needs to know is that the frame was pressed, and which
/// window's frame it was.
///
/// Backends that cannot tell simply never emit it, and the other four
/// dismissal inputs still fire; a missing frame press costs a menu that
/// outlives a title-bar drag, not a stuck popup, because moving the window
/// also produces a [WindowMovedEvent].
final class WindowNonClientPressEvent extends PlatformWindowEvent {
  const WindowNonClientPressEvent({
    required super.windowId,
    required super.generation,
    required this.timestamp,
  });

  /// Monotonic timestamp of the press, as reported by the OS - the same clock
  /// and the same meaning as `PlatformInputEvent.timestamp`, so that a
  /// dismissal can be ordered against the pointer events around it.
  final Duration timestamp;
}

/// The pointer entered the window's client area.
final class WindowPointerEnterEvent extends PlatformWindowEvent {
  const WindowPointerEnterEvent({
    required super.windowId,
    required super.generation,
  });
}

/// The pointer left the window's client area.
final class WindowPointerLeaveEvent extends PlatformWindowEvent {
  const WindowPointerLeaveEvent({
    required super.windowId,
    required super.generation,
  });
}
