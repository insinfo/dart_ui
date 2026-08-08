/// The unit conversions of section 13.5, kept as pure functions.
///
/// Two reasons this is not inlined into the window.
///
/// First, the model `logical = physical / scale`, `physical = round(logical *
/// scale)` has to be *deterministic*: the same logical size must produce the
/// same pixel count every time it is asked, or a resize round-trip drifts by a
/// pixel per pass. That is a property worth testing directly.
///
/// Second, everything here runs on Linux and macOS CI. A backend whose only
/// testable part needs a real HWND is a backend whose arithmetic is never
/// tested, and DPI arithmetic is exactly where the bugs are.
library;

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import 'win32_constants.dart';

/// The mapping between one window's client area and the desktop.
///
/// [clientOriginX] / [clientOriginY] are the client area's top-left corner in
/// **physical** screen pixels, which is what `ClientToScreen` reports. [scale]
/// is that window's own `dpi / 96`.
///
/// Screen positions in the framework's API are logical, expressed at *this
/// window's* scale. On a mixed-DPI desktop no single logical screen space
/// exists, and inventing one would make a menu placed next to a window land in
/// the wrong place; anchoring to the window's own scale is exact for every
/// point on the window's monitor, which is what callers actually anchor to.
final class Win32CoordinateSpace {
  const Win32CoordinateSpace({
    required this.clientOriginX,
    required this.clientOriginY,
    required this.scale,
  }) : assert(scale > 0);

  /// The identity space, for a window that does not exist yet.
  static const Win32CoordinateSpace identity = Win32CoordinateSpace(
    clientOriginX: 0,
    clientOriginY: 0,
    scale: 1,
  );

  final int clientOriginX;
  final int clientOriginY;
  final double scale;

  /// Logical screen position of the client area's origin.
  Offset get logicalOrigin =>
      Offset(clientOriginX / scale, clientOriginY / scale);

  /// Screen (logical) to client (logical).
  Offset screenToClient(Offset screenPosition) =>
      screenPosition - logicalOrigin;

  /// Client (logical) to screen (logical). Exactly inverts [screenToClient],
  /// which the round-trip test pins.
  Offset clientToScreen(Offset clientPosition) =>
      clientPosition + logicalOrigin;

  /// Physical pixels to logical units, for a position inside the client area.
  Offset physicalToLogical(int x, int y) => Offset(x / scale, y / scale);

  /// Logical units to physical pixels, rounded once so that two calls with the
  /// same input can never disagree.
  int logicalToPhysical(double value) => (value * scale).round();

  Size physicalSizeToLogical(int width, int height) =>
      Size(width / scale, height / scale);

  /// The pixel extent a framebuffer must be allocated at.
  ///
  /// Clamped to at least one pixel in each axis when the logical size is
  /// positive: a window can be dragged to one logical pixel at 50% scale, and
  /// a zero-sized DIB is a failed `CreateDIBSection`, not a small one.
  ({int width, int height}) logicalSizeToPhysical(Size size) {
    final width = logicalToPhysical(size.width);
    final height = logicalToPhysical(size.height);
    return (
      width: width <= 0 ? (size.width > 0 ? 1 : 0) : width,
      height: height <= 0 ? (size.height > 0 ? 1 : 0) : height,
    );
  }

  /// A logical dirty rectangle as physical pixel edges.
  ///
  /// Rounded outwards, never to nearest: a repaint region that is one pixel
  /// short leaves a stale seam on screen, and one pixel too generous costs
  /// nothing but a few blended pixels.
  ({int left, int top, int right, int bottom}) logicalRectToPhysical(
    Rect rect,
  ) =>
      (
        left: (rect.left * scale).floor(),
        top: (rect.top * scale).floor(),
        right: (rect.right * scale).ceil(),
        bottom: (rect.bottom * scale).ceil(),
      );

  /// A physical dirty rectangle as logical units, rounded outwards for the
  /// same reason.
  Rect physicalRectToLogical(int left, int top, int right, int bottom) =>
      Rect.fromLTRB(
        (left / scale).floorToDouble(),
        (top / scale).floorToDouble(),
        (right / scale).ceilToDouble(),
        (bottom / scale).ceilToDouble(),
      );

  Win32CoordinateSpace copyWith({
    int? clientOriginX,
    int? clientOriginY,
    double? scale,
  }) =>
      Win32CoordinateSpace(
        clientOriginX: clientOriginX ?? this.clientOriginX,
        clientOriginY: clientOriginY ?? this.clientOriginY,
        scale: scale ?? this.scale,
      );

  @override
  String toString() => 'Win32CoordinateSpace(origin: '
      '($clientOriginX, $clientOriginY)px, scale: $scale)';
}

/// `dpi / 96`, the only place the framework's scale is derived from a DPI.
double win32ScaleForDpi(int dpi) =>
    dpi <= 0 ? 1.0 : dpi / defaultScreenDpi.toDouble();

/// The low 16 bits of an `LPARAM`, unsigned. For sizes and DPI values.
int win32LoWord(int value) => value & 0xFFFF;

/// The high 16 bits of an `LPARAM`, unsigned.
int win32HiWord(int value) => (value >> 16) & 0xFFFF;

/// The low 16 bits as a signed coordinate.
///
/// Sign extension is not optional: on a multi-monitor desktop the primary
/// monitor is not necessarily top-left, so a client x of -40 is ordinary and
/// reading it unsigned gives 65496 - a coordinate 65 thousand pixels to the
/// right, which is how "the window jumps when I drag it onto the left
/// monitor" bugs are born.
int win32SignedLoWord(int value) {
  final low = value & 0xFFFF;
  return low > 0x7FFF ? low - 0x10000 : low;
}

/// The high 16 bits as a signed coordinate.
int win32SignedHiWord(int value) {
  final high = (value >> 16) & 0xFFFF;
  return high > 0x7FFF ? high - 0x10000 : high;
}
