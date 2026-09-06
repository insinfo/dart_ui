/// The monitors of the desktop, as much of them as a popup has to know.
///
/// A menu that opens near the bottom of the screen has to flip upwards, and a
/// menu that opens near the taskbar has to stop above it. Neither decision can
/// be made from inside the owner window: the window knows its own client area
/// and nothing else, and the two rectangles that decide the answer - the whole
/// monitor and the part of it the shell has not claimed - belong to the
/// display, not to the window. Until this file existed the framework had no
/// name for either, which is why every popup was composed inside its owner's
/// surface and was clipped by it.
///
/// ## Logical, and at *whose* scale
///
/// Both rectangles are logical, each at its **own** monitor's scale, and that
/// sentence has a sharp edge worth stating once: on a mixed-DPI desktop there
/// is no single logical screen space, so the logical rectangles of two
/// monitors do not tile the desktop the way their physical rectangles do -
/// they can overlap, or leave a gap, depending on the two scales. This is the
/// same reasoning `Win32CoordinateSpace` already writes down for
/// `clientToScreen`: a logical screen position is only exact on the monitor
/// whose scale it was expressed at.
///
/// That is not a defect to be fixed by inventing a global logical space; it is
/// the reason [ScreenInfo.scale] is carried per screen. A popup lives on one
/// monitor, is laid out at that monitor's scale, and converts its anchor
/// across the boundary through the physical pixels the two windows agree on.
///
/// ## What is deliberately absent
///
///   * *A refresh rate, a colour profile, an orientation.* Nothing above this
///     layer would read them, and a field nobody reads is a field nobody
///     notices is wrong.
///   * *A change notification.* Monitors are hot-plugged, and every backend
///     reports it differently (`WM_DISPLAYCHANGE`, RandR events, an
///     `NSApplication` notification). An implementation is free to answer
///     [ScreenProvider.screens] freshly on every read - which is what both of
///     today's implementations do - and a portable event can be added when a
///     caller exists that would subscribe to one.
///   * *Wayland.* There are no screen coordinates there at all: the compositor
///     places the popup from an anchor rectangle and never says where it went.
///     A Wayland backend therefore does not implement [ScreenProvider], and
///     the caller falls back to handing the anchor to `xdg_positioner`. This
///     is precisely why the contract below is an optional interface.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';

/// One monitor of the desktop.
final class ScreenInfo {
  const ScreenInfo({
    required this.bounds,
    required this.workArea,
    required this.scale,
    required this.isPrimary,
    this.name,
  });

  /// The whole monitor, in logical units at this monitor's [scale].
  ///
  /// The origin is the desktop's, not the monitor's: a secondary monitor to
  /// the left of the primary one has a negative [Rect.left], which is
  /// ordinary and must survive every conversion (see `win32SignedLoWord` for
  /// the same trap one layer down).
  final Rect bounds;

  /// [bounds] minus whatever the shell has reserved - the taskbar, a dock, a
  /// panel - and therefore the rectangle a popup must actually fit inside.
  ///
  /// Always contained in [bounds], and equal to it exactly when nothing is
  /// reserved: a backend that cannot find out what the shell took reports the
  /// two as equal, which is the truthful answer and not a guess. A caller that
  /// treats the two as interchangeable is the bug this field exists to
  /// prevent - it is what puts the last item of a menu underneath the
  /// taskbar.
  final Rect workArea;

  /// This monitor's device pixel ratio: its DPI divided by 96.
  ///
  /// Per monitor rather than per desktop, because that is the number a popup
  /// crossing onto this screen has to be rasterised at.
  final double scale;

  /// Whether this is the monitor the shell treats as the origin of the
  /// desktop. Exactly one screen of a live desktop is primary.
  final bool isPrimary;

  /// The platform's own name for the display (`\\.\DISPLAY1`), when it has
  /// one. For diagnostics only: it is not stable across replugs and must
  /// never be used as an identity.
  final String? name;

  /// The screen containing [screenPoint], or the nearest one.
  ///
  /// Null only when [screens] is empty. **Never null for a point outside
  /// every screen**, and that is the whole point of the rule: a popup anchored
  /// just past the right edge of a monitor - a menu opened on the last pixel
  /// of a window, a tooltip following a pointer that left the desktop - still
  /// has to be placed somewhere, and "nowhere" is not a placement. Returning
  /// null
  /// would push that decision into every caller, and each caller would invent
  /// its own fallback, most of them the primary screen, which is the wrong
  /// monitor whenever the user is working on the other one.
  ///
  /// Distance is measured to the [bounds] rectangle, so a point in the gap
  /// between two logical screen rectangles (see the library comment - mixed
  /// DPI makes those gaps real) resolves to the one it is nearest to rather
  /// than to whichever happens to be first in the list.
  static ScreenInfo? nearest(List<ScreenInfo> screens, Offset screenPoint) {
    if (screens.isEmpty) return null;
    ScreenInfo? best;
    var bestDistance = double.infinity;
    for (final screen in screens) {
      if (screen.bounds.contains(screenPoint)) return screen;
      final distance = _squaredDistanceToBounds(screen.bounds, screenPoint);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = screen;
      }
    }
    return best;
  }

  /// Squared, not rooted: only the ordering is used, and a square root per
  /// screen per popup buys nothing.
  static double _squaredDistanceToBounds(Rect bounds, Offset point) {
    final dx = point.dx < bounds.left
        ? bounds.left - point.dx
        : point.dx > bounds.right
            ? point.dx - bounds.right
            : 0.0;
    final dy = point.dy < bounds.top
        ? bounds.top - point.dy
        : point.dy > bounds.bottom
            ? point.dy - bounds.bottom
            : 0.0;
    return dx * dx + dy * dy;
  }

  @override
  bool operator ==(Object other) =>
      other is ScreenInfo &&
      other.bounds == bounds &&
      other.workArea == workArea &&
      other.scale == scale &&
      other.isPrimary == isPrimary &&
      other.name == name;

  @override
  int get hashCode => Object.hash(bounds, workArea, scale, isPrimary, name);

  @override
  String toString() => 'ScreenInfo(${name ?? 'unnamed'}, bounds: $bounds, '
      'workArea: $workArea, scale: $scale'
      '${isPrimary ? ', primary' : ''})';
}

/// A windowing backend that can describe the monitors it puts windows on.
///
/// ## Why an extra interface instead of members on `WindowingBackend`
///
/// The same reason `ClipboardProvider` is one, and it is worth repeating
/// because the mistake it avoids is silent: `WindowingBackend` is implemented
/// by six backends *and by every test double in the suite*, and adding
/// `screens` and `screenAt` to it would break all of them at once for a
/// capability most of them cannot honour. Wayland genuinely has no screen
/// coordinates (see the library comment), a remote or offscreen backend has no
/// monitor at all, and a fake in a widget test has no business inventing one.
///
/// So a backend that knows declares it, and a caller asks with a pattern:
///
/// ```dart
/// final ScreenInfo? screen = switch (backend) {
///   final ScreenProvider provider => provider.screenAt(anchor),
///   _ => null,
/// };
/// ```
///
/// A null answer is a real answer: it means "place this popup relative to its
/// owner, because nobody here can say where the monitors are", which is
/// exactly the fallback the Wayland path needs anyway.
abstract interface class ScreenProvider {
  /// Every monitor currently attached, primary included.
  ///
  /// Empty is legal and means the backend could not enumerate any - a headless
  /// run configured with none, a display server that answered nothing. It is
  /// not an error and must not throw: a popup with no screen falls back to its
  /// owner's bounds.
  List<ScreenInfo> get screens;

  /// The screen [screenPoint] is on, or the nearest one; null only when
  /// [screens] is empty.
  ///
  /// See [ScreenInfo.nearest] for why the answer for an outside point is the
  /// nearest screen rather than null, and for which logical space the point is
  /// expected to be in.
  ScreenInfo? screenAt(Offset screenPoint);
}
