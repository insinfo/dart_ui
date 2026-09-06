/// The popup host: lifetimes, placement, the submenu chain, and the one rule
/// that is easy to state and easy to get wrong — a click that closes a menu
/// must not also press what is behind it.
///
/// This covers the in-tree host, which is the portable one and the fallback on
/// every backend. The window host lives in the application layer and is
/// covered by `test/app/`; both implement the same [PopupHost] contract, and
/// the cases here are the ones a second implementation has to match.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('the contract', () {
    test('an in-tree host says it cannot leave the window', () {
      // The whole reason the seam exists: a caller that needs the screen as
      // its work area has to be able to ask, and this is the honest answer
      // for anything composited into the owner's display list.
      expect(InTreePopupHost().escapesOwnerWindow, isFalse);
    });

    test('PopupHost.of names the missing ancestor instead of failing quietly',
        () {
      final _Harness harness = _Harness.bare();
      Object? caught;
      harness.owner.updateRoot(_Probe(onBuild: (BuildContext context) {
        try {
          PopupHost.of(context);
        } on Object catch (error) {
          caught = error;
        }
      }));

      expect(caught, isA<StateError>());
      expect('$caught', contains('PopupHostScope'));
      expect('$caught', contains('DartUiApp'));
      harness.dispose();
    });

    test('maybeOf answers null, which is what a tooltip needs', () {
      final _Harness harness = _Harness.bare();
      PopupHost? found = InTreePopupHost();
      harness.owner.updateRoot(_Probe(
        onBuild: (BuildContext context) => found = PopupHost.maybeOf(context),
      ));

      expect(found, isNull);
      harness.dispose();
    });

    test('the kinds disagree about pass-through exactly where they should', () {
      // Two properties, four kinds, and every one of them decides a visible
      // behaviour - so they are asserted rather than trusted.
      expect(PopupKind.menu.dismissalPassesThrough, isFalse);
      expect(PopupKind.submenu.dismissalPassesThrough, isFalse);
      expect(PopupKind.dropdown.dismissalPassesThrough, isTrue);
      expect(PopupKind.tooltip.dismissalPassesThrough, isTrue);

      expect(PopupKind.tooltip.takesPointer, isFalse);
      expect(PopupKind.menu.takesPointer, isTrue);

      expect(PopupKind.menu.windowKind, WindowKind.popup);
      expect(PopupKind.submenu.windowKind, WindowKind.popup);
      expect(PopupKind.dropdown.windowKind, WindowKind.popup);
      expect(PopupKind.tooltip.windowKind, WindowKind.tooltip);
    });
  });

  group('opening and closing', () {
    test('a popup opens, is counted, and reports itself open', () {
      final _Harness harness = _Harness()..frame();
      expect(harness.host.openCount, 0);
      expect(harness.host.topmost, isNull);

      final PopupHandle handle = harness.open();
      harness.frame();

      expect(handle.isOpen, isTrue);
      expect(harness.host.openCount, 1);
      expect(identical(harness.host.topmost, handle), isTrue);
      harness.dispose();
    });

    test('onDismiss fires exactly once, however many times it is closed', () {
      // The routes into dismissal race by design - a click outside and a
      // platform popup_done describe the same dismissal and both arrive - so
      // closing twice has to be a no-op rather than a second notification.
      var dismissed = 0;
      final _Harness harness = _Harness()..frame();
      final PopupHandle handle = harness.open(onDismiss: () => dismissed++);
      harness.frame();

      handle.close();
      handle.close();
      harness.host.closeAll();
      harness.frame();

      expect(dismissed, 1);
      expect(handle.isOpen, isFalse);
      expect(harness.host.openCount, 0);
      harness.dispose();
    });

    test('closeAll empties every chain, deepest first', () {
      final List<String> order = <String>[];
      final _Harness harness = _Harness()..frame();
      final PopupHandle root = harness.open(onDismiss: () => order.add('root'));
      harness.frame();
      harness.open(
        parent: root,
        kind: PopupKind.submenu,
        onDismiss: () => order.add('child'),
      );
      harness.frame();

      harness.host.closeAll();
      harness.frame();

      expect(order, <String>['child', 'root']);
      expect(harness.host.openCount, 0);
      harness.dispose();
    });
  });

  group('placement', () {
    test('the default is directly under the anchor', () {
      final _Harness harness = _Harness()..frame();
      final PopupHandle handle = harness.open(
        anchorRect: const Rect.fromLTWH(10, 10, 50, 20),
        size: const Size(100, 80),
      );

      expect(
        handle.placedRect,
        isNull,
        reason: 'nothing has been measured yet, so any rect would be a guess',
      );

      harness.frame();
      expect(handle.placedRect, const Rect.fromLTWH(10, 30, 100, 80));
      harness.dispose();
    });

    test('it flips above the anchor rather than off the bottom edge', () {
      // The behaviour a cropped overlay cannot produce and the reason the
      // positioner exists: near the bottom the menu opens upward.
      final _Harness harness = _Harness()..frame();
      final PopupHandle handle = harness.open(
        anchorRect: const Rect.fromLTWH(10, 250, 50, 20),
        size: const Size(100, 80),
      );
      harness.frame();

      expect(handle.placedRect, const Rect.fromLTWH(10, 170, 100, 80));
      harness.dispose();
    });

    test('the work area is the window, which is the whole trade', () {
      // An in-tree popup is bounded by the owner's client area, so one that
      // fits nowhere is slid to the edge rather than allowed to leave. This is
      // the case a window host answers differently, and asserting it here is
      // what makes the difference between the two hosts a measured fact.
      final _Harness harness = _Harness()..frame();
      final PopupHandle handle = harness.open(
        anchorRect: const Rect.fromLTWH(380, 10, 10, 10),
        size: const Size(100, 80),
      );
      harness.frame();

      final Rect placed = handle.placedRect!;
      expect(placed.right, lessThanOrEqualTo(400));
      expect(placed.left, greaterThanOrEqualTo(0));
      harness.dispose();
    });

    test('moving the anchor moves the popup', () {
      final _Harness harness = _Harness()..frame();
      final PopupHandle handle = harness.open(
        anchorRect: const Rect.fromLTWH(10, 10, 50, 20),
        size: const Size(100, 80),
      );
      harness.frame();
      expect(handle.placedRect!.left, 10);

      handle.updateAnchor(const Rect.fromLTWH(120, 10, 50, 20));
      harness.frame();

      expect(handle.placedRect, const Rect.fromLTWH(120, 30, 100, 80));
      harness.dispose();
    });
  });

  group('the submenu chain', () {
    test('closing a parent closes its children', () {
      final _Harness harness = _Harness()..frame();
      final PopupHandle root = harness.open();
      harness.frame();
      final PopupHandle child =
          harness.open(parent: root, kind: PopupKind.submenu);
      harness.frame();

      expect(identical(child.parent, root), isTrue);
      expect(harness.host.openCount, 2);

      root.close();
      harness.frame();

      expect(child.isOpen, isFalse,
          reason: 'a submenu cannot outlive its menu');
      expect(root.isOpen, isFalse);
      expect(harness.host.openCount, 0);
      harness.dispose();
    });

    test('a press inside the parent closes only the child', () {
      // The rule that makes a menu bar usable: moving back to the parent menu
      // closes the submenu and leaves the parent open.
      final _Harness harness = _Harness()..frame();
      final PopupHandle root = harness.open(
        anchorRect: const Rect.fromLTWH(10, 10, 10, 10),
        size: const Size(100, 100),
      );
      harness.frame();
      final PopupHandle child = harness.open(
        parent: root,
        kind: PopupKind.submenu,
        anchorRect: const Rect.fromLTWH(200, 10, 10, 10),
        size: const Size(80, 60),
      );
      harness.frame();

      // Inside the parent's rect (10,20)-(110,120), outside the child's.
      harness.pressAt(const Offset(50, 60));
      harness.frame();

      expect(child.isOpen, isFalse);
      expect(root.isOpen, isTrue);
      expect(harness.host.openCount, 1);
      harness.dispose();
    });

    test('a submenu opened from a popup that already closed still opens', () {
      // A race, not a caller error: the pointer reaches a submenu trigger in
      // the same frame its parent was dismissed. Refusing loudly would crash
      // on a legal sequence.
      final _Harness harness = _Harness()..frame();
      final PopupHandle root = harness.open();
      harness.frame();
      root.close();
      harness.frame();

      final PopupHandle orphan =
          harness.open(parent: root, kind: PopupKind.submenu);
      harness.frame();

      expect(orphan.isOpen, isTrue);
      expect(harness.host.openCount, 1);
      harness.dispose();
    });

    test('Escape closes one level at a time', () {
      final _Harness harness = _Harness()..frame();
      final PopupHandle root = harness.open();
      harness.frame();
      final PopupHandle child =
          harness.open(parent: root, kind: PopupKind.submenu);
      harness.frame();

      expect(harness.host.dismissTopmost(), isTrue);
      harness.frame();
      expect(child.isOpen, isFalse);
      expect(root.isOpen, isTrue);

      expect(harness.host.dismissTopmost(), isTrue);
      harness.frame();
      expect(root.isOpen, isFalse);

      expect(harness.host.dismissTopmost(), isFalse);
      harness.dispose();
    });
  });

  group('the press that closes a popup', () {
    test('a menu swallows it: the button behind is not pressed', () {
      // The failure this whole design exists to prevent. Dismissal cannot be
      // decided after delivery, because the hit path is delivered
      // deepest-first and the button would already have fired.
      final _Harness harness = _Harness()..frame();
      final PopupHandle menu = harness.open(
        anchorRect: const Rect.fromLTWH(200, 200, 10, 10),
        size: const Size(100, 80),
      );
      harness.frame();

      harness.pressButton();
      harness.frame();

      expect(menu.isOpen, isFalse, reason: 'the press dismissed the menu');
      expect(harness.presses, 0, reason: 'and must not also press the button');
      harness.dispose();
    });

    test('a dropdown passes it through: the button behind is pressed', () {
      final _Harness harness = _Harness()..frame();
      final PopupHandle list = harness.open(
        kind: PopupKind.dropdown,
        anchorRect: const Rect.fromLTWH(200, 200, 10, 10),
        size: const Size(100, 80),
      );
      harness.frame();

      harness.pressButton();
      harness.frame();

      expect(list.isOpen, isFalse);
      expect(
        harness.presses,
        1,
        reason: 'closing a combo list by clicking a button presses it, which '
            'is what every desktop does and what a menu deliberately does not',
      );
      harness.dispose();
    });

    test('a press inside the popup does not dismiss it', () {
      final _Harness harness = _Harness()..frame();
      final PopupHandle menu = harness.open(
        anchorRect: const Rect.fromLTWH(10, 10, 10, 10),
        size: const Size(100, 80),
      );
      harness.frame();

      harness.pressAt(const Offset(50, 50));
      harness.frame();

      expect(menu.isOpen, isTrue);
      harness.dispose();
    });

    test('a tooltip is transparent: the button under it still gets the press',
        () {
      // A tooltip that swallowed the pointer would dismiss itself the instant
      // it appeared, because the hover that produced it is still happening on
      // the control underneath.
      final _Harness harness = _Harness()..frame();
      harness.open(
        kind: PopupKind.tooltip,
        anchorRect: const Rect.fromLTWH(0, 0, 10, 10),
        size: const Size(400, 300),
      );
      harness.frame();

      harness.pressButton();
      harness.frame();

      expect(harness.presses, 1);
      harness.dispose();
    });
  });

  group('a modal popup with a pass-through region', () {
    test('a press inside the region reaches the content and dismisses nothing',
        () {
      // What a menu bar needs: the strip keeps the pointer while its own
      // dropdown is up, so hovering a sibling can switch menus and clicking
      // the open one can close it. Without this the bar is unreachable, and
      // the only other way to reach it is to make the whole chain non-modal -
      // which gives back the press that presses the button underneath.
      final _Harness harness = _Harness()..frame();
      final PopupHandle menu = harness.open(
        anchorRect: const Rect.fromLTWH(200, 200, 10, 10),
        passThrough: () => harness.buttonRect,
      );
      harness.frame();

      harness.pressButton();
      harness.frame();

      expect(harness.presses, 1, reason: 'the region is still the content');
      expect(menu.isOpen, isTrue, reason: 'and pressing it dismisses nothing');
      harness.dispose();
    });

    test('a press outside the region is swallowed, as any menu press is', () {
      final _Harness harness = _Harness()..frame();
      final PopupHandle menu = harness.open(
        anchorRect: const Rect.fromLTWH(200, 200, 10, 10),
        // A region nowhere near the button or the popup.
        passThrough: () => const Rect.fromLTRB(0, 280, 400, 300),
      );
      harness.frame();

      harness.pressButton();
      harness.frame();

      expect(menu.isOpen, isFalse);
      expect(harness.presses, 0);
      harness.dispose();
    });

    test('the region is read live, so a bar that moved is still reachable', () {
      // A rect captured when the menu opened would leave the hole in the old
      // place after a resize reflowed the bar. The callback is what makes that
      // impossible, and this is the case that would catch a regression to a
      // stored Rect.
      Rect region = const Rect.fromLTRB(0, 280, 400, 300);
      final _Harness harness = _Harness()..frame();
      final PopupHandle menu = harness.open(
        anchorRect: const Rect.fromLTWH(200, 200, 10, 10),
        passThrough: () => region,
      );
      harness.frame();
      region = harness.buttonRect;

      harness.pressButton();
      harness.frame();

      expect(harness.presses, 1);
      expect(menu.isOpen, isTrue);
      harness.dispose();
    });
  });

  group('with no popup open', () {
    test('the layer is invisible to the pointer', () {
      // A host installed in every window must cost nothing in the common case,
      // and the way it could cost something is by swallowing presses that
      // reach nothing.
      final _Harness harness = _Harness()..frame();

      harness.pressButton();
      harness.frame();

      expect(harness.presses, 1);
      expect(harness.host.openCount, 0);
      harness.dispose();
    });
  });
}

final class _Probe extends StatelessWidget {
  const _Probe({required this.onBuild});

  final void Function(BuildContext context) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(context);
    return const SizedBox(width: 10, height: 10);
  }
}

final class _Harness {
  _Harness() : _bare = false {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 300)),
      ),
    );
    _mount();
  }

  _Harness.bare() : _bare = true {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 300)),
      ),
    );
  }

  final bool _bare;
  late final BuildOwner owner;
  final InTreePopupHost host = InTreePopupHost();
  int presses = 0;

  void _mount() {
    if (_bare) return;
    owner.updateRoot(PopupScope(
      host: host,
      child: Column(children: <Widget>[
        Button(label: 'Behind', onPressed: () => presses++),
      ]),
    ));
  }

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  /// Opens a popup whose content is a plain box of a known size, so that a
  /// placement assertion is about the positioner and not about how a menu
  /// happens to measure.
  PopupHandle open({
    Rect? anchorRect,
    Size size = const Size(100, 80),
    PopupKind kind = PopupKind.menu,
    PopupHandle? parent,
    void Function()? onDismiss,
    Rect? Function()? passThrough,
  }) =>
      host.open(PopupSpec(
        anchorRect: anchorRect ?? const Rect.fromLTWH(10, 10, 50, 20),
        kind: kind,
        parent: parent,
        onDismiss: onDismiss,
        passThrough: passThrough,
        builder: (BuildContext context) =>
            SizedBox(width: size.width, height: size.height),
      ));

  RenderButton get button => _find<RenderButton>();

  /// The button's rect in the same space the popup specs use.
  Rect get buttonRect {
    final RenderButton box = button;
    final Offset origin = box.globalOffset;
    return Rect.fromLTWH(
      origin.dx,
      origin.dy,
      box.size.width,
      box.size.height,
    );
  }

  /// A press at the centre of the button behind everything.
  void pressButton() {
    final RenderButton button = _find<RenderButton>();
    final Offset origin = button.globalOffset;
    pressAt(Offset(
      origin.dx + button.size.width / 2,
      origin.dy + button.size.height / 2,
    ));
  }

  void pressAt(Offset position) {
    owner.dispatchPointerEvent(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    ));
    owner.dispatchPointerEvent(PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    ));
  }

  T _find<T extends RenderBox>() {
    T? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is T) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found ?? (throw StateError('no $T in the tree'));
  }

  void dispose() => owner.dispose();
}
