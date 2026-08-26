import 'package:dart_ui/src/backends/wayland/wayland_positioner.dart';
import 'package:dart_ui/src/backends/wayland/wayland_protocol.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/widgets/popup.dart';
import 'package:test/test.dart';

void main() {
  group('anchor translation', () {
    test('every corner and edge maps to its xdg_positioner value', () {
      expect(waylandAnchorFor(PopupAnchorPoint.topLeft),
          xdgPositionerAnchorTopLeft);
      expect(
          waylandAnchorFor(PopupAnchorPoint.topCenter), xdgPositionerAnchorTop);
      expect(waylandAnchorFor(PopupAnchorPoint.topRight),
          xdgPositionerAnchorTopRight);
      expect(waylandAnchorFor(PopupAnchorPoint.centerLeft),
          xdgPositionerAnchorLeft);
      expect(
          waylandAnchorFor(PopupAnchorPoint.center), xdgPositionerAnchorNone);
      expect(waylandAnchorFor(PopupAnchorPoint.centerRight),
          xdgPositionerAnchorRight);
      expect(waylandAnchorFor(PopupAnchorPoint.bottomLeft),
          xdgPositionerAnchorBottomLeft);
      expect(waylandAnchorFor(PopupAnchorPoint.bottomCenter),
          xdgPositionerAnchorBottom);
      expect(waylandAnchorFor(PopupAnchorPoint.bottomRight),
          xdgPositionerAnchorBottomRight);
    });
  });

  group('gravity translation', () {
    test('gravity is the inverse of the popup attachment point', () {
      // The framework says "the popup's top-left touches the anchor"; Wayland
      // says "the popup extends down and right", which is bottom_right. Every
      // direction flips, and this is the line most implementations get wrong.
      expect(waylandGravityFor(PopupAnchorPoint.topLeft),
          xdgPositionerAnchorBottomRight);
      expect(waylandGravityFor(PopupAnchorPoint.bottomRight),
          xdgPositionerAnchorTopLeft);
      expect(waylandGravityFor(PopupAnchorPoint.topRight),
          xdgPositionerAnchorBottomLeft);
      expect(waylandGravityFor(PopupAnchorPoint.bottomLeft),
          xdgPositionerAnchorTopRight);
      expect(waylandGravityFor(PopupAnchorPoint.topCenter),
          xdgPositionerAnchorBottom);
      expect(waylandGravityFor(PopupAnchorPoint.bottomCenter),
          xdgPositionerAnchorTop);
      expect(waylandGravityFor(PopupAnchorPoint.centerLeft),
          xdgPositionerAnchorRight);
      expect(waylandGravityFor(PopupAnchorPoint.centerRight),
          xdgPositionerAnchorLeft);
    });

    test('centre has no direction, so it has no gravity', () {
      expect(
          waylandGravityFor(PopupAnchorPoint.center), xdgPositionerAnchorNone);
    });

    test('flipping an attachment point flips its gravity too', () {
      // A property the compositor relies on when it applies flip_y itself.
      for (final point in PopupAnchorPoint.values) {
        final flipped = point.flippedVertically;
        if (flipped == point) continue;
        expect(
          waylandGravityFor(flipped),
          isNot(waylandGravityFor(point)),
          reason: '$point and $flipped must not share a gravity',
        );
      }
    });
  });

  group('constraint adjustment translation', () {
    test('each adjustment sets exactly its own bit', () {
      expect(
        waylandConstraintAdjustmentFor(
            <PopupAdjustment>{PopupAdjustment.flipX}),
        xdgPositionerConstraintAdjustmentFlipX,
      );
      expect(
        waylandConstraintAdjustmentFor(
            <PopupAdjustment>{PopupAdjustment.flipY}),
        xdgPositionerConstraintAdjustmentFlipY,
      );
      expect(
        waylandConstraintAdjustmentFor(
            <PopupAdjustment>{PopupAdjustment.slideX}),
        xdgPositionerConstraintAdjustmentSlideX,
      );
      expect(
        waylandConstraintAdjustmentFor(
            <PopupAdjustment>{PopupAdjustment.slideY}),
        xdgPositionerConstraintAdjustmentSlideY,
      );
      expect(
        waylandConstraintAdjustmentFor(
            <PopupAdjustment>{PopupAdjustment.resizeX}),
        xdgPositionerConstraintAdjustmentResizeX,
      );
      expect(
        waylandConstraintAdjustmentFor(
            <PopupAdjustment>{PopupAdjustment.resizeY}),
        xdgPositionerConstraintAdjustmentResizeY,
      );
    });

    test('an empty set is "none", not a default', () {
      expect(
        waylandConstraintAdjustmentFor(const <PopupAdjustment>{}),
        xdgPositionerConstraintAdjustmentNone,
      );
    });

    test('adjustments combine into one mask', () {
      final mask = waylandConstraintAdjustmentFor(<PopupAdjustment>{
        PopupAdjustment.flipY,
        PopupAdjustment.slideX,
      });
      expect(mask & xdgPositionerConstraintAdjustmentFlipY, isNonZero);
      expect(mask & xdgPositionerConstraintAdjustmentSlideX, isNonZero);
      expect(mask & xdgPositionerConstraintAdjustmentFlipX, 0);
      expect(mask & xdgPositionerConstraintAdjustmentResizeY, 0);
    });

    test('the framework default is flipY plus slideX, the menu behaviour', () {
      const request = PopupRequest(
        anchorRect: Rect.fromLTWH(0, 0, 10, 10),
        size: Size(100, 200),
      );
      final spec = WaylandPositionerSpec.fromRequest(request);
      expect(
        spec.constraintAdjustment,
        xdgPositionerConstraintAdjustmentFlipY |
            xdgPositionerConstraintAdjustmentSlideX,
      );
    });
  });

  group('WaylandPositionerSpec.fromRequest', () {
    test('carries the anchor rect through parent-relative and unscaled', () {
      const request = PopupRequest(
        anchorRect: Rect.fromLTWH(30, 40, 120, 24),
        size: Size(200, 300),
        anchorPoint: PopupAnchorPoint.bottomLeft,
        popupPoint: PopupAnchorPoint.topLeft,
        offset: Offset(0, 4),
      );
      final spec = WaylandPositionerSpec.fromRequest(request);

      expect(spec.anchorX, 30);
      expect(spec.anchorY, 40);
      expect(spec.anchorWidth, 120);
      expect(spec.anchorHeight, 24);
      expect(spec.width, 200);
      expect(spec.height, 300);
      expect(spec.anchor, xdgPositionerAnchorBottomLeft);
      expect(spec.gravity, xdgPositionerAnchorBottomRight);
      expect(spec.offsetX, 0);
      expect(spec.offsetY, 4);
    });

    test('a degenerate anchor rect is widened to one pixel', () {
      // A caret or a zero-width menu item: legal to the framework, a protocol
      // error on some compositors.
      const request = PopupRequest(
        anchorRect: Rect.fromLTWH(15, 25, 0, 0),
        size: Size(100, 100),
      );
      final spec = WaylandPositionerSpec.fromRequest(request);

      expect(spec.anchorX, 15);
      expect(spec.anchorY, 25);
      expect(spec.anchorWidth, 1);
      expect(spec.anchorHeight, 1);
    });

    test('a zero-sized popup is widened rather than sent as zero', () {
      const request = PopupRequest(
        anchorRect: Rect.fromLTWH(0, 0, 10, 10),
        size: Size(0, 0),
      );
      final spec = WaylandPositionerSpec.fromRequest(request);
      expect(spec.width, 1);
      expect(spec.height, 1);
    });

    test('fractional geometry is rounded, not truncated', () {
      const request = PopupRequest(
        anchorRect: Rect.fromLTWH(10.6, 20.4, 30.5, 40.5),
        size: Size(99.5, 100.4),
      );
      final spec = WaylandPositionerSpec.fromRequest(request);
      expect(spec.anchorX, 11);
      expect(spec.anchorY, 20);
      expect(spec.width, 100);
      expect(spec.height, 100);
    });

    test('negative anchor coordinates survive (a popup above its parent)', () {
      const request = PopupRequest(
        anchorRect: Rect.fromLTWH(-40, -10, 20, 20),
        size: Size(50, 50),
      );
      final spec = WaylandPositionerSpec.fromRequest(request);
      expect(spec.anchorX, -40);
      expect(spec.anchorY, -10);
    });

    test('a submenu anchors to the right edge and grows rightwards', () {
      // The canonical nested-menu request: attach to the item's right edge,
      // popup's left edge meets it.
      const request = PopupRequest(
        anchorRect: Rect.fromLTWH(0, 100, 180, 28),
        size: Size(180, 240),
        anchorPoint: PopupAnchorPoint.topRight,
        popupPoint: PopupAnchorPoint.topLeft,
        adjustments: <PopupAdjustment>{
          PopupAdjustment.flipX,
          PopupAdjustment.slideY,
        },
      );
      final spec = WaylandPositionerSpec.fromRequest(request);

      expect(spec.anchor, xdgPositionerAnchorTopRight);
      expect(spec.gravity, xdgPositionerAnchorBottomRight);
      expect(
        spec.constraintAdjustment,
        xdgPositionerConstraintAdjustmentFlipX |
            xdgPositionerConstraintAdjustmentSlideY,
        reason: 'a submenu flips across the parent when it hits the edge',
      );
    });

    test('equal requests produce equal specs', () {
      const request = PopupRequest(
        anchorRect: Rect.fromLTWH(1, 2, 3, 4),
        size: Size(5, 6),
      );
      expect(
        WaylandPositionerSpec.fromRequest(request),
        WaylandPositionerSpec.fromRequest(request),
      );
      expect(
        WaylandPositionerSpec.fromRequest(request).hashCode,
        WaylandPositionerSpec.fromRequest(request).hashCode,
      );
    });
  });

  group('WaylandPopupPlacement', () {
    test('exposes the compositor answer as framework geometry', () {
      const placement =
          WaylandPopupPlacement(x: 12, y: 34, width: 100, height: 200);
      expect(placement.rect, const Rect.fromLTWH(12, 34, 100, 200));
      expect(placement.origin, const Offset(12, 34));
      expect(placement.size, const Size(100, 200));
    });

    test('compares by value, so a repeat configure is detectable', () {
      const a = WaylandPopupPlacement(x: 1, y: 2, width: 3, height: 4);
      const b = WaylandPopupPlacement(x: 1, y: 2, width: 3, height: 4);
      const c = WaylandPopupPlacement(x: 9, y: 2, width: 3, height: 4);
      expect(a, b);
      expect(a, isNot(c));
    });
  });
}
