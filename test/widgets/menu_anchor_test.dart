/// The Flutter-shaped menu widgets: opening, the chain, the menu bar and the
/// actions they publish.
///
/// Every assertion is about a *consequence* rather than a flag. "The menu is
/// open" is asserted as a panel existing in the render tree and as the host's
/// open count; "the whole chain closed" is asserted as the host holding nothing
/// afterwards; "the action works" is asserted by the callback that action was
/// supposed to reach having run. A test that read `controller.isOpen` alone
/// would pass against a menu that never painted.
///
/// The font is pinned for the reason every widget test in this directory pins
/// it: a row's width comes from a shaped label, so an unpinned face would make
/// every coordinate machine-dependent. Nothing here hard-codes a coordinate
/// anyway - points come from the render objects themselves through
/// [_Harness.centreOf] - but layout still has to be deterministic for a popup
/// to land in the same place twice.
library;

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/layout/render_box.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/rendering/text/font_registry.dart';
import 'package:dart_ui/src/semantics/semantics.dart';
import 'package:dart_ui/src/widgets/basic.dart';
import 'package:dart_ui/src/widgets/controls.dart';
import 'package:dart_ui/src/widgets/element.dart';
import 'package:dart_ui/src/widgets/focus.dart';
import 'package:dart_ui/src/widgets/menu_anchor.dart';
import 'package:dart_ui/src/widgets/popup_host.dart';
import 'package:dart_ui/src/widgets/widget.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('MenuAnchor', () {
    test('the controller opens and closes it, and each end fires once', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      expect(harness.host.openCount, 0);
      expect(harness.panels, isEmpty);

      harness.controller.open();
      harness.frame();

      expect(harness.host.openCount, 1);
      expect(harness.panels, hasLength(1));
      expect(harness.labelsOf(harness.panels.single),
          <String>['Cut', 'Copy', 'Paste']);
      expect(harness.opened, 1);
      expect(harness.closed, 0);

      harness.controller.close();
      harness.frame();

      expect(harness.host.openCount, 0);
      expect(harness.panels, isEmpty);
      expect(harness.opened, 1, reason: 'onOpen fires once per opening');
      expect(harness.closed, 1, reason: 'onClose fires once per closing');
      harness.dispose();
    });

    test('opening twice while already open does nothing', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();
      harness.controller.open();
      harness.frame();

      expect(harness.host.openCount, 1);
      expect(harness.opened, 1);
      harness.dispose();
    });

    test('a click on the anchor opens it', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      final RenderButton button = harness.buttonLabelled('Open');

      harness
        ..click(harness.centreOf(button))
        ..frame();

      expect(harness.host.openCount, 1);
      expect(harness.controller.isOpen, isTrue);
      // The menu hangs below the anchor it was opened from, which is the whole
      // point of measuring the anchor rather than taking the pointer position.
      final Rect placed = harness.host.handles.single.placedRect!;
      expect(placed.top, greaterThanOrEqualTo(button.size.height));
      harness.dispose();
    });

    test('a click outside dismisses it and does not reach what is behind', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();

      harness
        ..click(harness.centreOf(harness.buttonLabelled('Behind')))
        ..frame();

      expect(harness.host.openCount, 0);
      expect(harness.closed, 1);
      expect(
        harness.behindPresses,
        0,
        reason: 'the press that closes a menu must not also press the button '
            'under it - that is what consumeOutsideTap means',
      );
      harness.dispose();
    });

    test('Escape closes it', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();

      harness
        ..pressKey(logicalKeyEscape)
        ..frame();

      expect(harness.host.openCount, 0);
      expect(harness.closed, 1);
      harness.dispose();
    });
  });

  group('MenuItemButton', () {
    test('a click runs onPressed and closes the whole chain', () {
      final _ChainHarness harness = _ChainHarness()..frame();
      harness.controller.open();
      harness.frame();
      harness
        ..hover(harness.centreOf(harness.submenuRow))
        ..frame();
      expect(harness.host.openCount, 2, reason: 'the submenu is showing');

      final RenderMenuItemButton deep = harness.rowLabelled('Deep');
      harness
        ..click(harness.centreOf(deep))
        ..frame();

      expect(harness.chosen, <String>['Deep']);
      expect(
        harness.host.openCount,
        0,
        reason: 'a chosen command closes the menu it came from and every menu '
            'above it, not only its own',
      );
      harness.dispose();
    });

    test('a disabled item declares no activate and refuses one', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();

      final RenderMenuItemButton paste = harness.rowLabelled('Paste');
      final SemanticsConfiguration config = paste.describeSemantics();

      expect(config.role, SemanticsRole.menuItem);
      expect(config.states, contains(SemanticsState.disabled));
      expect(config.actions, isNot(contains(SemanticsAction.activate)));
      expect(
        paste.performSemanticsAction(SemanticsAction.activate),
        isFalse,
        reason: 'refused, rather than reported as done having done nothing',
      );
      expect(harness.chosen, isEmpty);
      // Still open: a refused activation is not a dismissal either.
      expect(harness.host.openCount, 1);
      harness.dispose();
    });

    test('a disabled item is inert to a click as well', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();

      final RenderMenuItemButton paste = harness.rowLabelled('Paste');
      harness
        ..click(harness.centreOf(paste))
        ..frame();

      expect(harness.chosen, isEmpty);
      expect(harness.host.openCount, 1);
      harness.dispose();
    });

    test('the accelerator is published as the row value', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();

      expect(harness.rowLabelled('Cut').describeSemantics().value, 'Ctrl+X');
      harness.dispose();
    });
  });

  group('SubmenuButton', () {
    test('hover opens a second popup parented to the first', () {
      final _ChainHarness harness = _ChainHarness()..frame();
      harness.controller.open();
      harness.frame();
      expect(harness.host.openCount, 1);

      harness
        ..hover(harness.centreOf(harness.submenuRow))
        ..frame();

      expect(harness.host.openCount, 2);
      final List<InTreePopupHandle> handles = harness.host.handles;
      expect(handles[1].kind, PopupKind.submenu);
      expect(
        handles[1].parent,
        same(handles[0]),
        reason: 'the submenu hangs off the popup it was opened from, which is '
            'what makes the stack close it with its parent',
      );
      // Beside the parent, not under it.
      expect(
        handles[1].placedRect!.left,
        greaterThanOrEqualTo(handles[0].placedRect!.right - 1),
      );
      harness.dispose();
    });

    test('closing the parent closes the child', () {
      final _ChainHarness harness = _ChainHarness()..frame();
      harness.controller.open();
      harness.frame();
      harness
        ..hover(harness.centreOf(harness.submenuRow))
        ..frame();
      expect(harness.host.openCount, 2);

      harness.controller.close();
      harness.frame();

      expect(harness.host.openCount, 0);
      expect(harness.panels, isEmpty);
      harness.dispose();
    });

    test('a press in the parent menu closes only the submenu', () {
      final _ChainHarness harness = _ChainHarness()..frame();
      harness.controller.open();
      harness.frame();
      harness
        ..hover(harness.centreOf(harness.submenuRow))
        ..frame();
      final InTreePopupHandle parent = harness.host.handles[0];

      // The parent panel's own frame, above its first row: inside the parent
      // popup and inside nothing else.
      final Rect parentRect = parent.placedRect!;
      harness
        ..press(Offset(parentRect.left + 2, parentRect.top + 2))
        ..release(Offset(parentRect.left + 2, parentRect.top + 2))
        ..frame();

      expect(
        harness.host.openCount,
        1,
        reason: 'PopupStack closes everything above the popup that was pressed '
            'and stops there',
      );
      expect(harness.host.handles.single, same(parent));
      harness.dispose();
    });

    test('Right opens the submenu and Left closes it again', () {
      final _ChainHarness harness = _ChainHarness()..frame();
      harness.controller.open();
      harness.frame();

      // Down twice to reach the submenu row past the plain command above it,
      // then Right into it.
      harness
        ..pressKey(logicalKeyArrowDown)
        ..pressKey(logicalKeyArrowDown)
        ..pressKey(logicalKeyArrowRight)
        ..frame();
      expect(harness.host.openCount, 2);

      harness
        ..pressKey(logicalKeyArrowLeft)
        ..frame();
      expect(harness.host.openCount, 1,
          reason: 'Left goes back to the parent, it does not close the parent');
      harness.dispose();
    });

    test(
        'showMenu expands, dismiss collapses, and neither is declared when '
        'it would change nothing', () {
      final _ChainHarness harness = _ChainHarness()..frame();
      harness.controller.open();
      harness.frame();

      final RenderSubmenuButton row = harness.submenuRow;
      SemanticsConfiguration config = row.describeSemantics();
      expect(config.role, SemanticsRole.menuItem);
      expect(config.actions, contains(SemanticsAction.showMenu));
      expect(config.actions, isNot(contains(SemanticsAction.dismiss)));
      expect(config.states, isNot(contains(SemanticsState.expanded)));

      expect(row.performSemanticsAction(SemanticsAction.showMenu), isTrue);
      harness.frame();
      expect(harness.host.openCount, 2);

      config = row.describeSemantics();
      expect(config.states, contains(SemanticsState.expanded));
      expect(config.actions, contains(SemanticsAction.dismiss));
      expect(config.actions, isNot(contains(SemanticsAction.showMenu)));
      expect(
        row.performSemanticsAction(SemanticsAction.showMenu),
        isFalse,
        reason: 'expanding what is already expanded changes nothing, so it is '
            'refused rather than reported as done',
      );

      expect(row.performSemanticsAction(SemanticsAction.dismiss), isTrue);
      harness.frame();
      expect(harness.host.openCount, 1);
      expect(row.performSemanticsAction(SemanticsAction.dismiss), isFalse);
      harness.dispose();
    });
  });

  group('MenuBar', () {
    test('a click opens a top-level menu and a second click closes it', () {
      final _BarHarness harness = _BarHarness()..frame();

      harness
        ..click(harness.centreOf(harness.barButton('File')))
        ..frame();
      expect(harness.host.openCount, 1);
      expect(harness.openMenuLabels, <String>['New', 'Open']);

      harness
        ..click(harness.centreOf(harness.barButton('File')))
        ..frame();
      expect(
        harness.host.openCount,
        0,
        reason: 'clicking the open menu\'s own button closes it instead of '
            'dismissing and immediately reopening',
      );
      harness.dispose();
    });

    test('hovering a sibling while open switches menus without closing the bar',
        () {
      final _BarHarness harness = _BarHarness()..frame();
      harness
        ..click(harness.centreOf(harness.barButton('File')))
        ..frame();
      expect(harness.openMenuLabels, <String>['New', 'Open']);

      harness
        ..hover(harness.centreOf(harness.barButton('Edit')))
        ..frame();

      expect(
        harness.host.openCount,
        1,
        reason: 'exactly one dropdown, not zero and not two',
      );
      expect(harness.openMenuLabels, <String>['Undo', 'Redo']);
      expect(harness.bar.childCount, 2, reason: 'the bar itself is untouched');
      harness.dispose();
    });

    test('hovering a sibling while nothing is open opens nothing', () {
      final _BarHarness harness = _BarHarness()..frame();

      harness
        ..hover(harness.centreOf(harness.barButton('Edit')))
        ..frame();

      expect(
        harness.host.openCount,
        0,
        reason: 'a bar that dropped a menu at every passing pointer would be '
            'unusable; it is only live once one is open',
      );
      harness.dispose();
    });

    test('Right moves between top-level menus while a dropdown is open', () {
      final _BarHarness harness = _BarHarness()..frame();
      harness
        ..click(harness.centreOf(harness.barButton('File')))
        ..frame();

      harness
        ..pressKey(logicalKeyArrowRight)
        ..frame();

      expect(harness.host.openCount, 1);
      expect(harness.openMenuLabels, <String>['Undo', 'Redo']);

      harness
        ..pressKey(logicalKeyArrowLeft)
        ..frame();
      expect(harness.openMenuLabels, <String>['New', 'Open']);
      harness.dispose();
    });

    test('Escape closes the dropdown and hands the keyboard back to the bar',
        () {
      final _BarHarness harness = _BarHarness()..frame();
      harness
        ..click(harness.centreOf(harness.barButton('File')))
        ..frame();
      expect(harness.host.openCount, 1);

      harness
        ..pressKey(logicalKeyEscape)
        ..frame();

      expect(harness.host.openCount, 0);
      expect(
        harness.owner.focusManager.primaryFocus?.debugLabel,
        'MenuBar',
        reason: 'a menu is a detour; dismissing one puts the user back where '
            'they were',
      );
      harness.dispose();
    });

    test('a press elsewhere dismisses the dropdown and is swallowed', () {
      final _BarHarness harness = _BarHarness()..frame();
      harness
        ..click(harness.centreOf(harness.barButton('File')))
        ..frame();

      harness
        ..click(harness.centreOf(harness.buttonLabelled('Behind')))
        ..frame();

      expect(harness.host.openCount, 0);
      // And it did **not** press the button it landed on. A menu bar's
      // dropdown is a menu, so the press that closes it stops there - the
      // user was aiming at "not the menu".
      //
      // This is the half that a non-modal bar cannot have. The bar keeps the
      // pointer through [PopupSpec.passThrough], which names the strip's rect
      // and nothing else, so the layer is modal to the window and transparent
      // to the bar. An earlier revision made the whole chain non-modal to keep
      // the bar reachable and paid for it here, with a press that closed the
      // menu and pressed the button underneath.
      expect(harness.behindPresses, 0);
      harness.dispose();
    });

    test('a press on the bar itself still reaches it while a menu is open', () {
      // The other half, and the reason the pass-through region exists at all:
      // a layer that were modal everywhere would swallow this press, and the
      // bar could neither switch menus nor close the open one.
      final _BarHarness harness = _BarHarness()..frame();
      harness
        ..click(harness.centreOf(harness.barButton('File')))
        ..frame();
      expect(harness.openMenuLabels, <String>['New', 'Open']);

      harness
        ..click(harness.centreOf(harness.barButton('Edit')))
        ..frame();

      expect(harness.host.openCount, 1, reason: 'switched, did not close');
      expect(harness.openMenuLabels, <String>['Undo', 'Redo']);
      harness.dispose();
    });

    test('the bar publishes the menu role and its buttons the menuItem one',
        () {
      final _BarHarness harness = _BarHarness()..frame();

      final SemanticsConfiguration bar = harness.bar.describeSemantics();
      expect(bar.role, SemanticsRole.menu);
      expect(bar.value, '2 items');
      expect(
        bar.states,
        isNot(contains(SemanticsState.modal)),
        reason: 'a menu bar is window chrome, not a surface that blocks what '
            'is behind it',
      );

      final RenderSubmenuButton file = harness.barButton('File');
      expect(file.describeSemantics().role, SemanticsRole.menuItem);
      expect(file.describeSemantics().label, 'File');
      harness.dispose();
    });

    test('showMenu on a bar button opens its dropdown', () {
      final _BarHarness harness = _BarHarness()..frame();

      expect(
        harness.barButton('Edit').performSemanticsAction(
              SemanticsAction.showMenu,
            ),
        isTrue,
      );
      harness.frame();

      expect(harness.host.openCount, 1);
      expect(harness.openMenuLabels, <String>['Undo', 'Redo']);
      harness.dispose();
    });
  });

  group('semantics of an open menu', () {
    test(
        'the panel is a modal menu that can be dismissed, and dismissing it '
        'closes the popup', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();

      final RenderMenuPanel panel = harness.panels.single;
      final SemanticsConfiguration config = panel.describeSemantics();
      expect(config.role, SemanticsRole.menu);
      expect(config.value, '3 items');
      expect(config.states, contains(SemanticsState.modal));
      expect(config.actions, contains(SemanticsAction.dismiss));

      expect(panel.performSemanticsAction(SemanticsAction.dismiss), isTrue);
      harness.frame();
      expect(harness.host.openCount, 0);
      harness.dispose();
    });

    test('focus on a row moves the keyboard cursor, and activate runs it', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();

      final RenderMenuItemButton copy = harness.rowLabelled('Copy');
      expect(copy.describeSemantics().label, 'Copy');
      expect(copy.describeSemantics().states,
          isNot(contains(SemanticsState.focused)));

      expect(copy.performSemanticsAction(SemanticsAction.focus), isTrue);
      expect(
        copy.describeSemantics().states,
        contains(SemanticsState.focused),
        reason: 'the highlight *is* the keyboard cursor, and that is what an '
            'assistive client needs to be told',
      );
      expect(harness.panels.single.highlightedIndex, 1);

      expect(copy.performSemanticsAction(SemanticsAction.activate), isTrue);
      harness.frame();
      expect(harness.chosen, <String>['Copy']);
      expect(harness.host.openCount, 0);
      harness.dispose();
    });

    test('the panel refuses activate when the cursor is nowhere', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();

      expect(
        harness.panels.single.performSemanticsAction(SemanticsAction.activate),
        isFalse,
      );
      expect(harness.chosen, isEmpty);
      harness.dispose();
    });

    test('the whole tree carries the menu and its items', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();

      final List<SemanticsNode> nodes = harness.owner.buildSemantics().nodes;
      expect(
        nodes.where((SemanticsNode n) => n.role == SemanticsRole.menu),
        hasLength(1),
      );
      expect(
        nodes
            .where((SemanticsNode n) => n.role == SemanticsRole.menuItem)
            .map((SemanticsNode n) => n.label),
        <String>['Cut', 'Copy', 'Paste'],
      );
      harness.dispose();
    });
  });

  group('keyboard navigation', () {
    test('Down and Up walk the enabled rows and skip the disabled one', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();
      final RenderMenuPanel panel = harness.panels.single;
      expect(panel.highlightedIndex, -1, reason: 'nothing is preselected');

      harness.pressKey(logicalKeyArrowDown);
      expect(panel.highlightedIndex, 0);
      harness.pressKey(logicalKeyArrowDown);
      expect(panel.highlightedIndex, 1);
      harness.pressKey(logicalKeyArrowDown);
      expect(
        panel.highlightedIndex,
        0,
        reason: 'Paste is disabled, so Down wraps past it back to Cut',
      );
      harness.pressKey(logicalKeyArrowUp);
      expect(panel.highlightedIndex, 1);
      harness.dispose();
    });

    test('Enter runs the highlighted command', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();

      harness
        ..pressKey(logicalKeyArrowDown)
        ..pressKey(logicalKeyEnter)
        ..frame();

      expect(harness.chosen, <String>['Cut']);
      expect(harness.host.openCount, 0);
      harness.dispose();
    });

    test('hover and the arrow keys share one cursor', () {
      final _AnchorHarness harness = _AnchorHarness()..frame();
      harness.controller.open();
      harness.frame();
      final RenderMenuPanel panel = harness.panels.single;

      harness
        ..hover(harness.centreOf(harness.rowLabelled('Copy')))
        ..frame();
      expect(panel.highlightedIndex, 1);

      harness.pressKey(logicalKeyArrowUp);
      expect(
        panel.highlightedIndex,
        0,
        reason: 'the arrows continue from where the pointer left the cursor, '
            'not from a second cursor of their own',
      );
      harness.dispose();
    });
  });
}

// ---------------------------------------------------------------------------
// Harnesses
// ---------------------------------------------------------------------------

/// A 400x300 window with a popup host a test can look inside.
abstract class _Harness {
  _Harness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 300)),
      ),
    );
    owner.updateRoot(PopupScope(host: host, child: buildContent()));
  }

  late final BuildOwner owner;
  final InTreePopupHost host = InTreePopupHost();

  Widget buildContent();

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  /// Every decorated panel, outermost first: the popups, never the menu bar.
  List<RenderMenuPanel> get panels => <RenderMenuPanel>[
        for (final RenderMenuPanel panel in findAll<RenderMenuPanel>())
          if (panel.decorated) panel,
      ];

  List<String> labelsOf(RenderMenuPanel panel) => <String>[
        for (final RenderBox child in panel.children)
          if (child is MenuRowBehavior) child.rowLabel ?? '',
      ];

  /// The centre of [box] in the window's coordinates.
  ///
  /// Derived rather than written down, so a change to the theme's row height
  /// cannot turn a behavioural test into a coordinate test that fails for the
  /// wrong reason.
  Offset centreOf(RenderBox box) {
    final Offset topLeft = box.localToGlobal(Offset.zero);
    return Offset(
      topLeft.dx + box.size.width / 2,
      topLeft.dy + box.size.height / 2,
    );
  }

  T? find<T extends RenderBox>() {
    final List<T> all = findAll<T>();
    return all.isEmpty ? null : all.first;
  }

  List<T> findAll<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    final RenderBox? root = owner.renderRoot;
    if (root != null) walk(root);
    return found;
  }

  RenderButton buttonLabelled(String label) => findAll<RenderButton>()
      .firstWhere((RenderButton button) => button.label == label);

  RenderMenuItemButton rowLabelled(String label) =>
      findAll<RenderMenuItemButton>()
          .firstWhere((RenderMenuItemButton row) => row.rowLabel == label);

  /// A whole click: press and release.
  ///
  /// Both halves, because the release is what ends the pointer capture the
  /// press took, and because a menu deliberately splits its work across the
  /// two - the popup layer dismisses on the press, the row activates on the
  /// release.
  void click(Offset position) {
    press(position);
    release(position);
  }

  void press(Offset position) => owner.dispatchPointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: PointerButton.primary,
      ));

  void release(Offset position) => owner.dispatchPointerEvent(PointerUpEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: PointerButton.primary,
      ));

  void hover(Offset position) => owner.dispatchPointerEvent(PointerMoveEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
      ));

  void pressKey(int logicalKey) {
    owner.dispatchKeyEvent(KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    ));
    frame();
  }

  void dispose() => owner.dispose();
}

/// A [MenuAnchor] with three commands, one of them disabled, and a button
/// behind it that must not be pressed by a dismissing click.
final class _AnchorHarness extends _Harness {
  final MenuController controller = MenuController();
  final List<String> chosen = <String>[];
  int opened = 0;
  int closed = 0;
  int behindPresses = 0;

  @override
  Widget buildContent() => Column(
        children: <Widget>[
          MenuAnchor(
            controller: controller,
            onOpen: () => opened++,
            onClose: () => closed++,
            builder: (BuildContext context, MenuController controller,
                    Widget? child) =>
                Button(label: 'Open', onPressed: controller.open),
            menuChildren: <Widget>[
              MenuItemButton(
                shortcut: 'Ctrl+X',
                onPressed: () => chosen.add('Cut'),
                child: const Text('Cut'),
              ),
              MenuItemButton(
                shortcut: 'Ctrl+C',
                onPressed: () => chosen.add('Copy'),
                child: const Text('Copy'),
              ),
              const MenuItemButton(child: Text('Paste')),
            ],
          ),
          // Clear of where the menu lands, so a press aimed at this button is
          // unambiguously a press *outside* the popup rather than one the popup
          // happened to be covering.
          const SizedBox(height: 140),
          Button(label: 'Behind', onPressed: () => behindPresses++),
        ],
      );
}

/// A [MenuAnchor] whose menu holds a [SubmenuButton], for the chain tests.
final class _ChainHarness extends _Harness {
  final MenuController controller = MenuController();
  final List<String> chosen = <String>[];

  @override
  Widget buildContent() => Column(
        children: <Widget>[
          MenuAnchor(
            controller: controller,
            menuChildren: <Widget>[
              MenuItemButton(
                onPressed: () => chosen.add('Top'),
                child: const Text('Top'),
              ),
              SubmenuButton(
                menuChildren: <Widget>[
                  MenuItemButton(
                    onPressed: () => chosen.add('Deep'),
                    child: const Text('Deep'),
                  ),
                ],
                child: const Text('More'),
              ),
            ],
            child: const SizedBox(width: 60, height: 24),
          ),
        ],
      );

  RenderSubmenuButton get submenuRow => findAll<RenderSubmenuButton>()
      .firstWhere((RenderSubmenuButton row) => row.rowLabel == 'More');
}

/// A [MenuBar] with two top-level menus.
final class _BarHarness extends _Harness {
  final List<String> chosen = <String>[];
  int behindPresses = 0;

  @override
  Widget buildContent() => Column(
        children: <Widget>[
          MenuBar(
            children: <Widget>[
              SubmenuButton(
                menuChildren: <Widget>[
                  MenuItemButton(
                    onPressed: () => chosen.add('New'),
                    child: const Text('New'),
                  ),
                  MenuItemButton(
                    onPressed: () => chosen.add('Open'),
                    child: const Text('Open'),
                  ),
                ],
                child: const Text('File'),
              ),
              SubmenuButton(
                menuChildren: <Widget>[
                  MenuItemButton(
                    onPressed: () => chosen.add('Undo'),
                    child: const Text('Undo'),
                  ),
                  MenuItemButton(
                    onPressed: () => chosen.add('Redo'),
                    child: const Text('Redo'),
                  ),
                ],
                child: const Text('Edit'),
              ),
            ],
          ),
          const SizedBox(height: 140),
          Button(label: 'Behind', onPressed: () => behindPresses++),
        ],
      );

  /// The strip itself: the one panel that is not a popup.
  RenderMenuPanel get bar => findAll<RenderMenuPanel>()
      .firstWhere((RenderMenuPanel panel) => !panel.decorated);

  RenderSubmenuButton barButton(String label) => findAll<RenderSubmenuButton>()
      .firstWhere((RenderSubmenuButton row) => row.rowLabel == label);

  List<String> get openMenuLabels => labelsOf(panels.single);
}
