import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const PopupPositioner positioner = PopupPositioner();
const Rect screen = Rect.fromLTWH(0, 0, 800, 600);

void main() {
  group('placement', () {
    test('a popup that fits lands exactly where it asked to', () {
      final PopupPlacement placement = positioner.place(
        const PopupRequest(
          anchorRect: Rect.fromLTWH(100, 100, 80, 24),
          size: Size(120, 90),
        ),
        screen,
      );

      expect(placement.rect, const Rect.fromLTWH(100, 124, 120, 90));
      expect(placement.isUnadjusted, isTrue);
    });

    test('a menu near the bottom flips above its anchor', () {
      final PopupPlacement placement = positioner.place(
        const PopupRequest(
          anchorRect: Rect.fromLTWH(100, 560, 80, 24),
          size: Size(120, 200),
        ),
        screen,
      );

      expect(placement.flippedY, isTrue);
      // Flipping preserves the relationship to the anchor: the popup's bottom
      // now meets the anchor's top.
      expect(placement.rect.bottom, 560);
      expect(placement.rect.top, 360);
    });

    test('a flip is rejected when it would make the fit worse', () {
      // Taller than the screen, anchored near the top: it overflows either
      // way, but flipping it upward would put almost all of it off-screen.
      final PopupPlacement placement = positioner.place(
        const PopupRequest(
          anchorRect: Rect.fromLTWH(100, 20, 80, 24),
          size: Size(120, 900),
        ),
        screen,
      );

      expect(placement.flippedY, isFalse);
      expect(placement.rect.top, 44);
    });

    test('a popup past the right edge slides back into the work area', () {
      final PopupPlacement placement = positioner.place(
        const PopupRequest(
          anchorRect: Rect.fromLTWH(760, 100, 30, 24),
          size: Size(200, 90),
        ),
        screen,
      );

      expect(placement.slidX, isTrue);
      expect(placement.rect.right, 800);
      expect(placement.rect.width, 200, reason: 'sliding preserves the size');
    });

    test('flip is tried before slide', () {
      final PopupPlacement placement = positioner.place(
        const PopupRequest(
          anchorRect: Rect.fromLTWH(100, 560, 80, 24),
          size: Size(120, 200),
          adjustments: <PopupAdjustment>{
            PopupAdjustment.flipY,
            PopupAdjustment.slideY,
          },
        ),
        screen,
      );

      // Flipping alone solved it, so no slide was needed - a menu that slid
      // would no longer point at the control that opened it.
      expect(placement.flippedY, isTrue);
      expect(placement.slidY, isFalse);
    });

    test('resize is the last resort and only when allowed', () {
      const PopupRequest request = PopupRequest(
        anchorRect: Rect.fromLTWH(100, 550, 80, 24),
        size: Size(120, 400),
        anchorPoint: PopupAnchorPoint.bottomLeft,
        popupPoint: PopupAnchorPoint.topLeft,
        adjustments: <PopupAdjustment>{PopupAdjustment.resizeY},
      );

      final PopupPlacement placement = positioner.place(request, screen);
      expect(placement.resized, isTrue);
      expect(placement.rect.bottom, 600);

      final PopupPlacement unresized = positioner.place(
        const PopupRequest(
          anchorRect: Rect.fromLTWH(100, 550, 80, 24),
          size: Size(120, 400),
          adjustments: <PopupAdjustment>{},
        ),
        screen,
      );
      expect(unresized.resized, isFalse);
      expect(unresized.rect.bottom, greaterThan(600),
          reason: 'with no adjustment allowed, it overflows honestly');
    });

    test('anchor and popup points place a submenu to the side', () {
      final PopupPlacement placement = positioner.place(
        const PopupRequest(
          anchorRect: Rect.fromLTWH(100, 100, 80, 24),
          size: Size(120, 90),
          anchorPoint: PopupAnchorPoint.topRight,
          popupPoint: PopupAnchorPoint.topLeft,
        ),
        screen,
      );

      expect(placement.rect.left, 180);
      expect(placement.rect.top, 100);
    });
  });

  group('surface choice', () {
    test('a popup inside the owner is composited into its surface', () {
      const Rect client = Rect.fromLTWH(0, 0, 400, 300);
      final PopupPlacement placement = positioner.place(
        const PopupRequest(
          anchorRect: Rect.fromLTWH(50, 50, 80, 24),
          size: Size(120, 90),
        ),
        screen,
      );

      expect(
        positioner.surfaceFor(placement, client),
        PopupSurfaceKind.sameSurface,
      );
    });

    test('a popup escaping the owner needs a window of its own', () {
      const Rect client = Rect.fromLTWH(0, 0, 200, 120);
      final PopupPlacement placement = positioner.place(
        const PopupRequest(
          anchorRect: Rect.fromLTWH(50, 90, 80, 24),
          size: Size(120, 200),
        ),
        screen,
      );

      expect(
        positioner.surfaceFor(placement, client),
        PopupSurfaceKind.nativeWindow,
      );
      expect(
        positioner.surfaceFor(placement, client, nativeWindowsAvailable: false),
        PopupSurfaceKind.sameSurface,
        reason: 'a platform without child windows must still show the popup',
      );
    });
  });

  group('the open popup stack', () {
    PopupPlacement at(double left, double top) => PopupPlacement(
          rect: Rect.fromLTWH(left, top, 100, 60),
          flippedX: false,
          flippedY: false,
          slidX: false,
          slidY: false,
          resized: false,
        );

    test('closing a menu closes its submenus, deepest first', () {
      final closed = <String>[];
      final stack = PopupStack();
      final int menu = stack.open(
        placement: at(0, 0),
        surfaceKind: PopupSurfaceKind.sameSurface,
        onDismiss: () => closed.add('menu'),
      );
      final int submenu = stack.open(
        placement: at(100, 0),
        surfaceKind: PopupSurfaceKind.sameSurface,
        ownerId: menu,
        onDismiss: () => closed.add('submenu'),
      );
      stack.open(
        placement: at(200, 0),
        surfaceKind: PopupSurfaceKind.sameSurface,
        ownerId: submenu,
        onDismiss: () => closed.add('subsubmenu'),
      );

      final List<int> ids = stack.close(menu);

      expect(ids, hasLength(3));
      expect(closed, <String>['subsubmenu', 'submenu', 'menu']);
      expect(stack.isEmpty, isTrue);
    });

    test('a click outside dismisses light popups and reports consuming it', () {
      final stack = PopupStack()
        ..open(
          placement: at(100, 100),
          surfaceKind: PopupSurfaceKind.sameSurface,
        );

      expect(stack.handleOutsideClick(const Offset(120, 120)), isFalse,
          reason: 'a click inside the popup is not a dismissal');
      expect(stack.handleOutsideClick(const Offset(10, 10)), isTrue);
      expect(stack.isEmpty, isTrue);
    });

    test('a click in a parent menu closes only what is above it', () {
      final stack = PopupStack();
      final int menu = stack.open(
        placement: at(0, 0),
        surfaceKind: PopupSurfaceKind.sameSurface,
      );
      stack.open(
        placement: at(200, 0),
        surfaceKind: PopupSurfaceKind.sameSurface,
        ownerId: menu,
      );

      expect(stack.handleOutsideClick(const Offset(50, 30)), isTrue);
      expect(stack.entries, hasLength(1));
      expect(stack.topmost!.id, menu);
    });

    test('a modal popup swallows an outside click without closing', () {
      final stack = PopupStack()
        ..open(
          placement: at(100, 100),
          surfaceKind: PopupSurfaceKind.nativeWindow,
          dismissPolicy: PopupDismissPolicy.explicit,
          grabsInput: true,
        );

      expect(stack.handleOutsideClick(const Offset(10, 10)), isTrue);
      expect(stack.entries, hasLength(1),
          reason: 'a modal does not light-dismiss');
      expect(stack.hasInputGrab, isTrue);
    });

    test('Escape closes one level, and never a modal', () {
      final stack = PopupStack();
      final int menu = stack.open(
        placement: at(0, 0),
        surfaceKind: PopupSurfaceKind.sameSurface,
      );
      stack.open(
        placement: at(200, 0),
        surfaceKind: PopupSurfaceKind.sameSurface,
        ownerId: menu,
      );

      expect(stack.dismissTopmost(), isTrue);
      expect(stack.entries, hasLength(1));

      stack.closeAll();
      stack.open(
        placement: at(0, 0),
        surfaceKind: PopupSurfaceKind.nativeWindow,
        dismissPolicy: PopupDismissPolicy.explicit,
      );
      expect(stack.dismissTopmost(), isFalse);
    });

    test('closing an unknown id is a no-op', () {
      final stack = PopupStack();
      expect(stack.close(99), isEmpty);
    });
  });
}
