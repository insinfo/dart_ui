/// Popup geometry shared by widgets and native window positioning.
library;

import 'offset.dart';
import 'rect.dart';
import 'size.dart';

/// Which edge or corner of the anchor the popup attaches to.
enum PopupAnchorPoint {
  topLeft,
  topCenter,
  topRight,
  centerLeft,
  center,
  centerRight,
  bottomLeft,
  bottomCenter,
  bottomRight;

  /// The point in [rect] this constant names.
  Offset resolve(Rect rect) {
    final double x = switch (this) {
      PopupAnchorPoint.topLeft ||
      PopupAnchorPoint.centerLeft ||
      PopupAnchorPoint.bottomLeft =>
        rect.left,
      PopupAnchorPoint.topCenter ||
      PopupAnchorPoint.center ||
      PopupAnchorPoint.bottomCenter =>
        rect.left + rect.width / 2,
      PopupAnchorPoint.topRight ||
      PopupAnchorPoint.centerRight ||
      PopupAnchorPoint.bottomRight =>
        rect.right,
    };
    final double y = switch (this) {
      PopupAnchorPoint.topLeft ||
      PopupAnchorPoint.topCenter ||
      PopupAnchorPoint.topRight =>
        rect.top,
      PopupAnchorPoint.centerLeft ||
      PopupAnchorPoint.center ||
      PopupAnchorPoint.centerRight =>
        rect.top + rect.height / 2,
      PopupAnchorPoint.bottomLeft ||
      PopupAnchorPoint.bottomCenter ||
      PopupAnchorPoint.bottomRight =>
        rect.bottom,
    };
    return Offset(x, y);
  }

  /// This point mirrored across the anchor's centre, used when a flip is
  /// applied.
  PopupAnchorPoint get flippedVertically => switch (this) {
        PopupAnchorPoint.topLeft => PopupAnchorPoint.bottomLeft,
        PopupAnchorPoint.topCenter => PopupAnchorPoint.bottomCenter,
        PopupAnchorPoint.topRight => PopupAnchorPoint.bottomRight,
        PopupAnchorPoint.bottomLeft => PopupAnchorPoint.topLeft,
        PopupAnchorPoint.bottomCenter => PopupAnchorPoint.topCenter,
        PopupAnchorPoint.bottomRight => PopupAnchorPoint.topRight,
        PopupAnchorPoint.centerLeft ||
        PopupAnchorPoint.center ||
        PopupAnchorPoint.centerRight =>
          this,
      };

  PopupAnchorPoint get flippedHorizontally => switch (this) {
        PopupAnchorPoint.topLeft => PopupAnchorPoint.topRight,
        PopupAnchorPoint.centerLeft => PopupAnchorPoint.centerRight,
        PopupAnchorPoint.bottomLeft => PopupAnchorPoint.bottomRight,
        PopupAnchorPoint.topRight => PopupAnchorPoint.topLeft,
        PopupAnchorPoint.centerRight => PopupAnchorPoint.centerLeft,
        PopupAnchorPoint.bottomRight => PopupAnchorPoint.bottomLeft,
        PopupAnchorPoint.topCenter ||
        PopupAnchorPoint.center ||
        PopupAnchorPoint.bottomCenter =>
          this,
      };
}

/// What the positioner may do when the popup does not fit.
///
/// Named after the `xdg_positioner` constraint adjustments deliberately: the
/// Wayland backend can pass these through untranslated, and every other
/// backend implements the same semantics rather than each inventing its own.
enum PopupAdjustment { flipX, flipY, slideX, slideY, resizeX, resizeY }

/// One placement request.
final class PopupRequest {
  const PopupRequest({
    required this.anchorRect,
    required this.size,
    this.anchorPoint = PopupAnchorPoint.bottomLeft,
    this.popupPoint = PopupAnchorPoint.topLeft,
    this.offset = Offset.zero,
    this.adjustments = const <PopupAdjustment>{
      PopupAdjustment.flipY,
      PopupAdjustment.slideX,
    },
  });

  /// The owner's rect, in the same space as the work area.
  final Rect anchorRect;

  /// The popup's desired size.
  final Size size;

  /// The point on [anchorRect] to attach to.
  final PopupAnchorPoint anchorPoint;

  /// The point on the popup that meets [anchorPoint].
  final PopupAnchorPoint popupPoint;

  /// A nudge applied after attachment, for a menu's shadow gap.
  final Offset offset;

  final Set<PopupAdjustment> adjustments;
}
