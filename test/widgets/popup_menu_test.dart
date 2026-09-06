/// `showMenu`, `PopupMenuButton` and their entries, asserted through the
/// future they hand back.
///
/// The future *is* the API here, so almost every test ends by awaiting it: a
/// menu that opened, painted and closed without resuming its caller would be
/// useless, and a menu that resumed its caller twice would crash the second
/// time. Both of those are checked, and the second one is checked by dismissing
/// the same menu by three different routes in a row - a choice, a `closeAll`
/// and a click outside - because those routes race in a real window and the
/// completion has to survive all of them.
///
/// Rows are clicked by arithmetic rather than by looking a widget up: the menu
/// puts four pixels of air above the first entry and stacks entries at their
/// declared heights, so the centre of row `i` is computable from the rect the
/// positioner produced. That makes the geometry part of what is asserted
/// instead of something the test works around.
///
/// The font is pinned because the menu is as wide as its widest label.
library;

import 'dart:async';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/relative_rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/rendering/text/font_registry.dart';
import 'package:dart_ui/src/widgets/basic.dart';
import 'package:dart_ui/src/widgets/element.dart';
import 'package:dart_ui/src/widgets/media_query.dart';
import 'package:dart_ui/src/widgets/popup_host.dart';
import 'package:dart_ui/src/widgets/popup_menu.dart';
import 'package:dart_ui/src/widgets/theme.dart';
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

  group('showMenu', () {
    test('completes with the chosen value', () async {
      final _Harness harness = _Harness();
      addTearDown(harness.dispose);

      final Future<String?> chosen = harness.open(<PopupMenuEntry<String>>[
        const PopupMenuItem<String>(value: 'a', child: Text('Alpha')),
        const PopupMenuItem<String>(value: 'b', child: Text('Beta')),
      ]);
      harness.frame();
      expect(harness.host.openCount, 1, reason: 'the menu is up');

      harness.click(harness.rowCentre(1));
      harness.frame();

      expect(await chosen, 'b');
      expect(harness.host.openCount, 0, reason: 'choosing closes it');
    });

    test('completes with null when dismissed without a choice', () async {
      final _Harness harness = _Harness();
      addTearDown(harness.dispose);

      final Future<String?> chosen = harness.open(<PopupMenuEntry<String>>[
        const PopupMenuItem<String>(value: 'a', child: Text('Alpha')),
      ]);
      harness.frame();

      // A long way from the menu, and from the probe in the corner.
      harness.click(const Offset(280, 190));
      harness.frame();

      expect(await chosen, isNull);
      expect(harness.host.openCount, 0);
    });

    test('completes exactly once when three routes dismiss it', () async {
      final _Harness harness = _Harness();
      addTearDown(harness.dispose);

      final Future<String?> chosen = harness.open(<PopupMenuEntry<String>>[
        const PopupMenuItem<String>(value: 'a', child: Text('Alpha')),
      ]);
      int completions = 0;
      unawaited(chosen.then((String? _) => completions++));
      harness.frame();

      // The choice closes the popup. The next two are what a real window does
      // in the same frame - the window deactivating, and the press that chose
      // the item also being seen as a press outside by a layer that has
      // already forgotten the menu.
      harness
        ..click(harness.rowCentre(0))
        ..frame()
        ..host.closeAll();
      harness
        ..click(const Offset(280, 190))
        ..frame();

      expect(await chosen, 'a');
      await Future<void>.delayed(Duration.zero);
      expect(completions, 1);
    });

    test('a disabled item cannot be chosen', () async {
      final _Harness harness = _Harness();
      addTearDown(harness.dispose);

      final Future<String?> chosen = harness.open(<PopupMenuEntry<String>>[
        const PopupMenuItem<String>(
          value: 'a',
          enabled: false,
          child: Text('Alpha'),
        ),
        const PopupMenuItem<String>(value: 'b', child: Text('Beta')),
      ]);
      harness.frame();

      harness.click(harness.rowCentre(0));
      harness.frame();
      expect(
        harness.host.openCount,
        1,
        reason: 'a press on a disabled row is not a choice and not a dismissal',
      );

      harness.click(const Offset(280, 190));
      harness.frame();
      expect(await chosen, isNull, reason: 'the disabled value never escaped');
    });

    test('a divider is not selectable', () async {
      final _Harness harness = _Harness();
      addTearDown(harness.dispose);

      final Future<String?> chosen = harness.open(<PopupMenuEntry<String>>[
        const PopupMenuItem<String>(value: 'a', child: Text('Alpha')),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(value: 'b', child: Text('Beta')),
      ]);
      harness.frame();

      // Straight through the middle of the divider's own band.
      harness.click(harness.rowCentre(1, heights: _mixedHeights));
      harness.frame();
      expect(harness.host.openCount, 1);

      harness.click(harness.rowCentre(2, heights: _mixedHeights));
      harness.frame();
      expect(
        await chosen,
        'b',
        reason: 'the entry after the divider is still where the arithmetic '
            'says it is, so the divider really did occupy its 16 pixels',
      );
    });

    test('an initial value lines its entry up with the position', () async {
      final _Harness harness = _Harness();
      addTearDown(harness.dispose);

      final Future<String?> chosen = harness.open(
        <PopupMenuEntry<String>>[
          const PopupMenuItem<String>(value: 'a', child: Text('Alpha')),
          const PopupMenuItem<String>(value: 'b', child: Text('Beta')),
        ],
        initialValue: 'b',
        // Far enough down the window that the lift has room: asked for at
        // y = 10 the menu would be pulled off the top edge, and flipY would
        // then legitimately undo the alignment - which is the positioner
        // preferring "visible" over "aligned", and the right preference.
        position: const RelativeRect.fromLTRB(10, 100, 200, 60),
      );
      harness.frame();

      // The second row's centre sits 72 below the menu's top edge, so lining
      // it up with y = 100 pulls the whole menu up by that much.
      expect(harness.placedRect!.top, 100 - 72);

      harness.click(const Offset(280, 190));
      harness.frame();
      await chosen;
    });
  });

  group('PopupMenuButton', () {
    test('calls onSelected with the chosen value', () async {
      final _ButtonHarness harness = _ButtonHarness();
      addTearDown(harness.dispose);

      harness
        ..click(const Offset(60, 32))
        ..frame();
      expect(harness.host.openCount, 1, reason: 'the button opened its menu');

      harness
        ..click(harness.rowCentre(0))
        ..frame();
      await Future<void>.delayed(Duration.zero);

      expect(harness.selected, <String>['x']);
      expect(harness.canceled, 0);
    });

    test('calls onCanceled when the menu is dismissed', () async {
      final _ButtonHarness harness = _ButtonHarness();
      addTearDown(harness.dispose);

      harness
        ..click(const Offset(60, 32))
        ..frame()
        ..click(const Offset(280, 190))
        ..frame();
      await Future<void>.delayed(Duration.zero);

      expect(harness.selected, isEmpty);
      expect(harness.canceled, 1);
    });

    test('a disabled button opens nothing', () async {
      final _ButtonHarness harness = _ButtonHarness(enabled: false);
      addTearDown(harness.dispose);

      harness
        ..click(const Offset(60, 32))
        ..frame();
      await Future<void>.delayed(Duration.zero);

      expect(harness.host.openCount, 0);
      expect(harness.canceled, 0);
    });
  });

  group('RelativeRect', () {
    test('round-trips through a container', () {
      const Rect container = Rect.fromLTWH(0, 0, 300, 200);
      const Rect rect = Rect.fromLTRB(10, 20, 100, 50);
      final RelativeRect relative = RelativeRect.fromSize(rect, container.size);
      expect(relative, const RelativeRect.fromLTRB(10, 20, 200, 150));
      expect(relative.toRect(container), rect);
    });

    test('fromRect subtracts the container origin', () {
      final RelativeRect relative = RelativeRect.fromRect(
        const Rect.fromLTRB(0, 0, 50, 50),
        const Rect.fromLTRB(100, 100, 200, 200),
      );
      expect(relative, const RelativeRect.fromLTRB(-100, -100, 150, 150));
    });

    test('shift moves rather than inflates', () {
      const RelativeRect start = RelativeRect.fromLTRB(10, 10, 10, 10);
      final RelativeRect moved = start.shift(const Offset(5, 0));
      expect(moved, const RelativeRect.fromLTRB(15, 10, 5, 10));
      expect(
        moved.toSize(const Size(100, 100)),
        start.toSize(const Size(100, 100)),
        reason: 'a shifted rectangle is the same size it was',
      );
    });

    test('inflate, deflate and intersect', () {
      const RelativeRect base = RelativeRect.fromLTRB(10, 10, 10, 10);
      expect(base.inflate(4), const RelativeRect.fromLTRB(6, 6, 6, 6));
      expect(base.deflate(4), const RelativeRect.fromLTRB(14, 14, 14, 14));
      expect(
        base.intersect(const RelativeRect.fromLTRB(0, 20, 20, 0)),
        const RelativeRect.fromLTRB(10, 20, 20, 10),
      );
      expect(RelativeRect.fill.hasInsets, isFalse);
      expect(base.hasInsets, isTrue);
    });
  });
}

/// The heights of the divider menu's three entries, in order.
const List<double> _mixedHeights = <double>[
  kMinInteractiveDimension,
  16,
  kMinInteractiveDimension,
];

const NativeWindowId _window = NativeWindowId(1);

/// A widget that hands its build context out and draws almost nothing.
final class _Probe extends StatelessWidget {
  const _Probe({required this.onBuild});

  final void Function(BuildContext context) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(context);
    return const SizedBox(width: 10, height: 10);
  }
}

/// Shared pointer plumbing and render-tree walking for both harnesses.
mixin _WindowHarness {
  BuildOwner get owner;
  InTreePopupHost get host;

  static const Size windowSize = Size(300, 200);

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  Rect? get placedRect =>
      host.handles.isEmpty ? null : host.handles.last.placedRect;

  /// The centre of entry [index], from the rect the positioner produced.
  ///
  /// Four pixels of air, then the entries at their declared heights - the
  /// surface's own layout, restated here so that a change to it fails a test
  /// rather than quietly moving where the clicks land.
  Offset rowCentre(int index, {List<double>? heights}) {
    final Rect menu = placedRect!;
    final List<double> extents =
        heights ?? List<double>.filled(index + 1, kMinInteractiveDimension);
    double y = menu.top + 4;
    for (int i = 0; i < index; i++) {
      y += extents[i];
    }
    return Offset(menu.center.dx, y + extents[index] / 2);
  }

  /// A whole click: the press captures, the release activates.
  void click(Offset position) {
    owner.dispatchPointerEvent(PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    ));
    owner.dispatchPointerEvent(PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    ));
  }

  void dispose() => owner.dispose();
}

/// A 300x200 window whose only content is a probe holding a build context, so
/// `showMenu` can be called the way an application calls it.
final class _Harness with _WindowHarness {
  _Harness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(_WindowHarness.windowSize),
      ),
    );
    owner.updateRoot(MediaQuery(
      data: const MediaQueryData(size: _WindowHarness.windowSize),
      child: Theme(
        data: ThemeData.neutralLight,
        child: PopupScope(
          host: host,
          child: _Probe(onBuild: (BuildContext c) => _context = c),
        ),
      ),
    ));
    frame();
  }

  @override
  late final BuildOwner owner;

  @override
  final InTreePopupHost host = InTreePopupHost();

  BuildContext? _context;

  /// Opens a menu whose top-left corner is at (10, 10).
  Future<String?> open(
    List<PopupMenuEntry<String>> items, {
    String? initialValue,
    RelativeRect position = const RelativeRect.fromLTRB(10, 10, 200, 150),
  }) =>
      showMenu<String>(
        context: _context!,
        position: position,
        items: items,
        initialValue: initialValue,
      );
}

/// A 300x200 window holding one [PopupMenuButton] at (20, 20), 80x24.
final class _ButtonHarness with _WindowHarness {
  _ButtonHarness({bool enabled = true}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(_WindowHarness.windowSize),
      ),
    );
    owner.updateRoot(MediaQuery(
      data: const MediaQueryData(size: _WindowHarness.windowSize),
      child: Theme(
        data: ThemeData.neutralLight,
        child: PopupScope(
          host: host,
          child: Stack(
            children: <Widget>[
              Positioned(
                left: 20,
                top: 20,
                width: 80,
                height: 24,
                child: PopupMenuButton<String>(
                  enabled: enabled,
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(value: 'x', child: Text('Ex')),
                  ],
                  onSelected: selected.add,
                  onCanceled: () => canceled++,
                  child: const SizedBox(width: 80, height: 24),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    frame();
  }

  @override
  late final BuildOwner owner;

  @override
  final InTreePopupHost host = InTreePopupHost();

  final List<String> selected = <String>[];
  int canceled = 0;
}
