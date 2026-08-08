/// The one place in this backend that knows X talks in device pixels and the
/// framework talks in logical units.
///
/// The units above this layer are settled by two facts already in the
/// contract: `WindowOptions.size` is documented as logical, and
/// `WindowResizedEvent.clientSize` is documented as logical. Screen positions
/// follow them - `NativeWindow.screenToClient` takes and
/// `NativeWindow.clientToScreen` returns **logical** coordinates - because a
/// caller that has to remember which of two doubles is scaled will eventually
/// get it wrong, and nothing in the type system would catch it.
///
/// The X server, meanwhile, deals only in device pixels: ConfigureNotify sizes,
/// TranslateCoordinates replies, ConfigureWindow requests, PutImage rectangles.
/// Every one of those conversions happens here, so that the rest of the backend
/// can be read without asking which space a number is in.
///
/// Nothing here allocates beyond the returned [Offset], and the conversions are
/// two multiplies - section 6.5 lists coordinate conversion as a hot path
/// because hit testing runs it per pointer sample.
library;

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';

/// Maps between the window's client space and the root window's space.
///
/// Immutable: a move or a scale change makes a new one rather than mutating,
/// so a conversion that is already in flight cannot see half of an update.
final class X11CoordinateSpace {
  const X11CoordinateSpace({
    required this.originX,
    required this.originY,
    required this.scale,
  }) : assert(scale > 0);

  static const X11CoordinateSpace identity = X11CoordinateSpace(
    originX: 0,
    originY: 0,
    scale: 1.0,
  );

  /// Top-left of the client area in root-window device pixels, as
  /// TranslateCoordinates or a synthetic ConfigureNotify reported it.
  final int originX;
  final int originY;

  /// Device pixels per logical unit.
  final double scale;

  X11CoordinateSpace withOrigin(int x, int y) =>
      X11CoordinateSpace(originX: x, originY: y, scale: scale);

  X11CoordinateSpace withScale(double newScale) =>
      X11CoordinateSpace(originX: originX, originY: originY, scale: newScale);

  /// Logical position of the window on the desktop.
  Offset get logicalOrigin => Offset(originX / scale, originY / scale);

  Offset screenToClient(Offset screenPosition) => Offset(
        screenPosition.dx - originX / scale,
        screenPosition.dy - originY / scale,
      );

  Offset clientToScreen(Offset clientPosition) => Offset(
        clientPosition.dx + originX / scale,
        clientPosition.dy + originY / scale,
      );

  /// Device pixels to logical units, for a position already relative to the
  /// client area - what a ButtonPress event carries.
  Offset devicePixelsToLogical(int x, int y) => Offset(x / scale, y / scale);

  Size deviceSizeToLogical(int width, int height) =>
      Size(width / scale, height / scale);

  /// Logical units to device pixels, rounding outward.
  ///
  /// Outward, not nearest: this converts damage rectangles, and a rectangle
  /// that rounds inward leaves a one-pixel seam of stale pixels along an edge
  /// at any fractional scale. Repainting a pixel that did not need it is
  /// invisible; failing to repaint one is a permanent artefact.
  Rect logicalRectToDevice(Rect rect) => Rect.fromLTRB(
        (rect.left * scale).floorToDouble(),
        (rect.top * scale).floorToDouble(),
        (rect.right * scale).ceilToDouble(),
        (rect.bottom * scale).ceilToDouble(),
      );

  Rect deviceRectToLogical(int x, int y, int width, int height) =>
      Rect.fromLTWH(
        x / scale,
        y / scale,
        width / scale,
        height / scale,
      );

  /// Logical extent to the device extent a framebuffer must be allocated at.
  ///
  /// Rounded up and floored at one pixel: a window can legitimately be dragged
  /// to zero height, and a zero-sized surface is an X `BadValue` rather than an
  /// empty frame.
  int logicalToDevicePixels(double logical) {
    final pixels = (logical * scale).ceil();
    return pixels < 1 ? 1 : pixels;
  }

  @override
  String toString() =>
      'X11CoordinateSpace(origin: $originX,$originY, scale: $scale)';
}
