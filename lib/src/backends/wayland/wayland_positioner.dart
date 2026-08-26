/// Translating the framework's [PopupRequest] into `xdg_positioner` values.
///
/// This is the whole reason `widgets/popup.dart` names its adjustments after
/// the Wayland ones: on every other backend the framework computes the popup's
/// rect itself, and on Wayland it *cannot* - a client is not allowed to know
/// where its own window is, so it cannot know where a screen edge is either.
/// The compositor does the flipping and sliding, and the client's job is to
/// describe the request precisely enough that the compositor's answer is the
/// one the framework would have computed.
///
/// So this file is a pure translation, and it is separate from the connection
/// so that every edge case is testable without a compositor:
///
///   * an anchor point becomes `xdg_positioner.anchor`;
///   * the popup's own attachment point becomes `gravity`, **inverted** -
///     Wayland's gravity says which direction the popup extends *away* from
///     the anchor, which is the mirror of "which corner of the popup touches
///     it";
///   * the adjustment set becomes the constraint bitmask, one bit each;
///   * the anchor rect is made parent-surface-relative and clamped to a
///     non-degenerate rect, because a zero-sized anchor rect is a protocol
///     error on some compositors and a silent mis-placement on others.
library;

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../widgets/popup.dart';
import 'wayland_protocol.dart';

/// Everything one `xdg_positioner` needs, in wire units.
///
/// A value object rather than a sequence of calls so a test can assert the
/// translation without a socket, and so the connection's request emission has
/// nothing to decide.
final class WaylandPositionerSpec {
  const WaylandPositionerSpec({
    required this.width,
    required this.height,
    required this.anchorX,
    required this.anchorY,
    required this.anchorWidth,
    required this.anchorHeight,
    required this.anchor,
    required this.gravity,
    required this.constraintAdjustment,
    required this.offsetX,
    required this.offsetY,
  });

  /// The popup's requested size, in surface-local (logical) pixels.
  final int width;
  final int height;

  /// The anchor rectangle, relative to the **parent surface's** origin.
  final int anchorX;
  final int anchorY;
  final int anchorWidth;
  final int anchorHeight;

  /// `xdg_positioner.anchor`: which part of the anchor rect to attach to.
  final int anchor;

  /// `xdg_positioner.gravity`: which way the popup extends from that point.
  final int gravity;

  /// `xdg_positioner.constraint_adjustment` bitmask.
  final int constraintAdjustment;

  final int offsetX;
  final int offsetY;

  /// Translates [request]'s anchor rect from window-local logical coordinates.
  ///
  /// [request.anchorRect] is already in the owner window's coordinate space,
  /// which is exactly what `set_anchor_rect` wants, so no origin arithmetic is
  /// needed - unlike X11, where the same rect has to be turned into root
  /// coordinates first.
  factory WaylandPositionerSpec.fromRequest(PopupRequest request) {
    final anchorRect = request.anchorRect;
    // A degenerate anchor rect (a caret, a zero-width menu item) is legal to
    // the framework and hostile to compositors: some reject width/height 0
    // with a protocol error. One logical pixel preserves the position and the
    // placement is visually identical.
    final anchorWidth = _atLeastOne(anchorRect.width.round());
    final anchorHeight = _atLeastOne(anchorRect.height.round());
    return WaylandPositionerSpec(
      width: _atLeastOne(request.size.width.round()),
      height: _atLeastOne(request.size.height.round()),
      anchorX: anchorRect.left.round(),
      anchorY: anchorRect.top.round(),
      anchorWidth: anchorWidth,
      anchorHeight: anchorHeight,
      anchor: waylandAnchorFor(request.anchorPoint),
      gravity: waylandGravityFor(request.popupPoint),
      constraintAdjustment: waylandConstraintAdjustmentFor(request.adjustments),
      offsetX: request.offset.dx.round(),
      offsetY: request.offset.dy.round(),
    );
  }

  /// The size a compositor-independent caller would expect before any
  /// constraint adjustment, useful for the first frame's allocation.
  Size get unconstrainedSize => Size(width.toDouble(), height.toDouble());

  @override
  bool operator ==(Object other) =>
      other is WaylandPositionerSpec &&
      other.width == width &&
      other.height == height &&
      other.anchorX == anchorX &&
      other.anchorY == anchorY &&
      other.anchorWidth == anchorWidth &&
      other.anchorHeight == anchorHeight &&
      other.anchor == anchor &&
      other.gravity == gravity &&
      other.constraintAdjustment == constraintAdjustment &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY;

  @override
  int get hashCode => Object.hash(width, height, anchorX, anchorY, anchorWidth,
      anchorHeight, anchor, gravity, constraintAdjustment, offsetX, offsetY);

  @override
  String toString() => 'WaylandPositionerSpec(${width}x$height, '
      'anchorRect: $anchorX,$anchorY ${anchorWidth}x$anchorHeight, '
      'anchor: $anchor, gravity: $gravity, '
      'adjust: 0x${constraintAdjustment.toRadixString(16)}, '
      'offset: $offsetX,$offsetY)';

  static int _atLeastOne(int value) => value < 1 ? 1 : value;
}

/// The `xdg_positioner.anchor` value for the point on the anchor rect.
int waylandAnchorFor(PopupAnchorPoint point) => switch (point) {
      PopupAnchorPoint.topLeft => xdgPositionerAnchorTopLeft,
      PopupAnchorPoint.topCenter => xdgPositionerAnchorTop,
      PopupAnchorPoint.topRight => xdgPositionerAnchorTopRight,
      PopupAnchorPoint.centerLeft => xdgPositionerAnchorLeft,
      PopupAnchorPoint.center => xdgPositionerAnchorNone,
      PopupAnchorPoint.centerRight => xdgPositionerAnchorRight,
      PopupAnchorPoint.bottomLeft => xdgPositionerAnchorBottomLeft,
      PopupAnchorPoint.bottomCenter => xdgPositionerAnchorBottom,
      PopupAnchorPoint.bottomRight => xdgPositionerAnchorBottomRight,
    };

/// The `xdg_positioner.gravity` value for the point on the *popup* that meets
/// the anchor.
///
/// Inverted on purpose, and this is the single most error-prone line in a
/// Wayland popup implementation. The framework says "the popup's top-left
/// corner touches the anchor point"; Wayland says "the popup hangs down and to
/// the right of the anchor point", which is gravity `bottom_right`. They
/// describe the same placement from opposite ends, so every direction flips.
int waylandGravityFor(PopupAnchorPoint popupPoint) => switch (popupPoint) {
      PopupAnchorPoint.topLeft => xdgPositionerAnchorBottomRight,
      PopupAnchorPoint.topCenter => xdgPositionerAnchorBottom,
      PopupAnchorPoint.topRight => xdgPositionerAnchorBottomLeft,
      PopupAnchorPoint.centerLeft => xdgPositionerAnchorRight,
      PopupAnchorPoint.center => xdgPositionerAnchorNone,
      PopupAnchorPoint.centerRight => xdgPositionerAnchorLeft,
      PopupAnchorPoint.bottomLeft => xdgPositionerAnchorTopRight,
      PopupAnchorPoint.bottomCenter => xdgPositionerAnchorTop,
      PopupAnchorPoint.bottomRight => xdgPositionerAnchorTopLeft,
    };

/// The constraint bitmask for a set of framework adjustments.
int waylandConstraintAdjustmentFor(Set<PopupAdjustment> adjustments) {
  var mask = xdgPositionerConstraintAdjustmentNone;
  for (final adjustment in adjustments) {
    mask |= switch (adjustment) {
      PopupAdjustment.flipX => xdgPositionerConstraintAdjustmentFlipX,
      PopupAdjustment.flipY => xdgPositionerConstraintAdjustmentFlipY,
      PopupAdjustment.slideX => xdgPositionerConstraintAdjustmentSlideX,
      PopupAdjustment.slideY => xdgPositionerConstraintAdjustmentSlideY,
      PopupAdjustment.resizeX => xdgPositionerConstraintAdjustmentResizeX,
      PopupAdjustment.resizeY => xdgPositionerConstraintAdjustmentResizeY,
    };
  }
  return mask;
}

/// The placement the compositor reported through `xdg_popup.configure`.
///
/// Wayland answers a positioner with the rect it actually chose, relative to
/// the parent surface. That answer is authoritative - it already includes any
/// flip, slide or resize - so the framework's own [PopupPositioner] result is
/// only ever a prediction on this backend, and this is what replaces it.
final class WaylandPopupPlacement {
  const WaylandPopupPlacement({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  Rect get rect => Rect.fromLTWH(
        x.toDouble(),
        y.toDouble(),
        width.toDouble(),
        height.toDouble(),
      );

  Offset get origin => Offset(x.toDouble(), y.toDouble());

  Size get size => Size(width.toDouble(), height.toDouble());

  @override
  bool operator ==(Object other) =>
      other is WaylandPopupPlacement &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'WaylandPopupPlacement($x, $y, ${width}x$height)';
}
