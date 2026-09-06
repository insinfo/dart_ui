/// The tooltip, asserted through what it actually does to the window.
///
/// Every check here is about a consequence: "it is showing" is a [RenderTooltip]
/// in the render tree carrying the message, "it flipped" is the rect the
/// positioner produced sitting above the control, and "it does not take the
/// pointer" is a button underneath still firing. A test that read a boolean off
/// the state would have passed for the whole time `Tooltip.build` returned its
/// child and displayed nothing, which is the bug this widget was written to
/// end.
///
/// Time is virtual throughout. The waits are armed on a [ManualDispatcher], so
/// nothing here sleeps and the 500 ms boundary can be probed on both sides of
/// itself - which a wall-clock tooltip could not offer, and which is why the
/// dispatcher seam exists at all.
///
/// The font is pinned for the reason every widget test in this directory pins
/// it: the surface is as wide as its shaped label, so an unpinned face would
/// make every placement coordinate machine-dependent.
library;

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/layout/render_box.dart';
import 'package:dart_ui/src/layout/render_constrained_box.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/rendering/text/font_registry.dart';
import 'package:dart_ui/src/scheduler/manual_dispatcher.dart';
import 'package:dart_ui/src/widgets/basic.dart';
import 'package:dart_ui/src/widgets/controls.dart';
import 'package:dart_ui/src/widgets/element.dart';
import 'package:dart_ui/src/widgets/gesture_detector.dart';
import 'package:dart_ui/src/widgets/popup_host.dart';
import 'package:dart_ui/src/widgets/theme.dart';
import 'package:dart_ui/src/widgets/tooltip.dart';
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

  group('showing and hiding', () {
    test('appears only once the wait has elapsed', () {
      final _Harness harness = _Harness.single();
      addTearDown(harness.dispose);

      harness
        ..move(const Offset(50, 30))
        ..frame();
      expect(harness.host.openCount, 0, reason: 'the wait has not started');
      expect(harness.tooltip, isNull);

      // One microsecond short of the wait. A tooltip that appeared here would
      // be a tooltip that appears while the pointer is merely passing over.
      harness.advance(const Duration(milliseconds: 499));
      expect(harness.host.openCount, 0);

      harness.advance(const Duration(milliseconds: 1));
      harness.frame();
      expect(harness.host.openCount, 1);
      expect(harness.tooltip!.message, 'Save');
    });

    test('the pointer leaving hides it', () {
      final _Harness harness = _Harness.single();
      addTearDown(harness.dispose);

      harness
        ..move(const Offset(50, 30))
        ..advance(const Duration(milliseconds: 500))
        ..frame();
      expect(harness.tooltip, isNotNull);

      // Empty space, well away from the trigger: the router diffs the hit path
      // and reports the trigger as left.
      harness
        ..move(const Offset(250, 190))
        ..frame();

      expect(harness.host.openCount, 0);
      expect(harness.tooltip, isNull);
    });

    test('it goes away on its own after showDuration', () {
      final _Harness harness = _Harness.single();
      addTearDown(harness.dispose);

      harness
        ..move(const Offset(50, 30))
        ..advance(const Duration(milliseconds: 500))
        ..frame();
      expect(harness.tooltip, isNotNull);

      harness
        ..advance(const Duration(milliseconds: 1499))
        ..frame();
      expect(harness.tooltip, isNotNull, reason: 'still inside showDuration');

      harness
        ..advance(const Duration(milliseconds: 1))
        ..frame();
      expect(harness.tooltip, isNull);
    });

    test('a second tooltip skips the wait while the first is up', () {
      final _Harness harness = _Harness.pair();
      addTearDown(harness.dispose);

      harness
        ..move(const Offset(50, 30))
        ..advance(const Duration(milliseconds: 500))
        ..frame();
      expect(harness.tooltip!.message, 'Save');

      // Straight onto the neighbour, with no time passing at all. The wait has
      // already been paid once, and a per-widget timer - the implementation
      // this is here to rule out - would start a fresh 500 ms here and show
      // nothing.
      harness
        ..move(const Offset(150, 30))
        ..frame();

      expect(harness.tooltip, isNotNull);
      expect(harness.tooltip!.message, 'Open');
      expect(
        harness.host.openCount,
        1,
        reason: 'the first one went away; two labels at once is never right',
      );
    });
  });

  group('placement', () {
    test('sits below the child by the vertical offset', () {
      final _Harness harness = _Harness.single();
      addTearDown(harness.dispose);

      harness
        ..move(const Offset(50, 30))
        ..advance(const Duration(milliseconds: 500))
        ..frame();

      // The child is 60x20 at (20,20), so its centre is at y = 30 and the
      // default offset of 24 puts the surface's top edge at 54.
      final Rect placed = harness.placedRect!;
      expect(placed.top, 54);
      expect(placed.center.dx, closeTo(50, 0.5));
    });

    test('flips above the child near the bottom edge', () {
      final _Harness harness = _Harness.single(childTop: 170);
      addTearDown(harness.dispose);

      harness
        ..move(const Offset(50, 180))
        ..advance(const Duration(milliseconds: 500))
        ..frame();

      // Centre at y = 180 in a 200-tall window: below would start at 204,
      // outside the work area entirely, so the placement flips and the offset
      // changes sign - the surface's *bottom* lands at 156.
      final Rect placed = harness.placedRect!;
      expect(placed.bottom, 156);
      expect(placed.top, lessThan(170), reason: 'wholly above the child');
    });
  });

  group('the pointer', () {
    test('a button under a showing tooltip still receives its click', () {
      final _Harness harness = _Harness.overBudgetButton();
      addTearDown(harness.dispose);

      harness
        ..move(const Offset(30, 10))
        ..advance(const Duration(milliseconds: 500))
        ..frame();

      // The surface really is over the button; without this the rest of the
      // test would pass against a tooltip that simply missed.
      final Rect placed = harness.placedRect!;
      expect(placed.contains(const Offset(30, 45)), isTrue);

      harness
        ..primaryDown(const Offset(30, 45))
        ..primaryUp(const Offset(30, 45))
        ..frame();

      expect(
        harness.buttonPresses,
        1,
        reason: 'PopupKind.tooltip is not hit-testable, so the press has to '
            'reach the control the tooltip is describing',
      );
    });
  });

  group('no host', () {
    test('renders exactly the child and opens nothing', () {
      final _Harness harness = _Harness.single(withHost: false);
      addTearDown(harness.dispose);

      harness
        ..move(const Offset(50, 30))
        ..advance(const Duration(milliseconds: 2000))
        ..frame();

      expect(harness.tooltip, isNull);
      expect(
        harness.host.openCount,
        0,
        reason: 'the unused host proves nothing leaked into some other scope',
      );
      // The child is still there, which is the half that matters: a tooltip
      // with nowhere to open is a decoration that has to keep decorating.
      expect(harness.find<RenderConstrainedBox>(), isNotNull);
    });
  });
}

/// A 300x200 window with a virtual clock and, usually, a popup host.
final class _Harness {
  _Harness._(Widget content, {required bool withHost}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(300, 200)),
      ),
    );
    final Widget themed = Theme(
      data: ThemeData.neutralLight,
      child: withHost ? PopupScope(host: host, child: content) : content,
    );
    owner.updateRoot(GestureScope(dispatcher: dispatcher, child: themed));
    frame();
  }

  /// One tooltip over a 60x20 box at (20, [childTop]).
  factory _Harness.single({double childTop = 20, bool withHost = true}) =>
      _Harness._(
        Stack(
          children: <Widget>[
            Positioned(
              left: 20,
              top: childTop,
              width: 60,
              height: 20,
              child: const Tooltip(
                message: 'Save',
                child: SizedBox(width: 60, height: 20),
              ),
            ),
          ],
        ),
        withHost: withHost,
      );

  /// Two tooltips side by side, for the shared wait.
  factory _Harness.pair() => _Harness._(
        const Stack(
          children: <Widget>[
            Positioned(
              left: 20,
              top: 20,
              width: 60,
              height: 20,
              child: Tooltip(
                message: 'Save',
                child: SizedBox(width: 60, height: 20),
              ),
            ),
            Positioned(
              left: 120,
              top: 20,
              width: 60,
              height: 20,
              child: Tooltip(
                message: 'Open',
                child: SizedBox(width: 60, height: 20),
              ),
            ),
          ],
        ),
        withHost: true,
      );

  /// A tooltip whose surface lands on top of a button.
  factory _Harness.overBudgetButton() {
    late final _Harness harness;
    harness = _Harness._(
      Stack(
        children: <Widget>[
          const Positioned(
            left: 0,
            top: 0,
            width: 60,
            height: 20,
            child: Tooltip(
              message: 'Tip',
              child: SizedBox(width: 60, height: 20),
            ),
          ),
          Positioned(
            left: 0,
            top: 30,
            width: 200,
            height: 40,
            child: Button(
              label: 'Behind',
              onPressed: () => harness.buttonPresses++,
            ),
          ),
        ],
      ),
      withHost: true,
    );
    return harness;
  }

  final ManualDispatcher dispatcher = ManualDispatcher();
  final InTreePopupHost host = InTreePopupHost();
  late final BuildOwner owner;
  int buttonPresses = 0;

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  /// Moves virtual time, then rebuilds: a timer that fired usually opened or
  /// closed a popup, and the render tree only reflects that after a frame.
  void advance(Duration delta) {
    dispatcher.advance(delta);
    frame();
  }

  RenderTooltip? get tooltip => find<RenderTooltip>();

  Rect? get placedRect =>
      host.handles.isEmpty ? null : host.handles.single.placedRect;

  T? find<T extends RenderBox>() {
    T? found;
    void walk(RenderBox node) {
      if (found == null && node is T) found = node;
      node.visitChildren(walk);
    }

    final RenderBox? root = owner.renderRoot;
    if (root != null) walk(root);
    return found;
  }

  void move(Offset position) => owner.dispatchPointerEvent(PointerMoveEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
      ));

  void primaryDown(Offset position) =>
      owner.dispatchPointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: PointerButton.primary,
      ));

  void primaryUp(Offset position) => owner.dispatchPointerEvent(PointerUpEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: PointerButton.primary,
      ));

  void dispose() => owner.dispose();
}
