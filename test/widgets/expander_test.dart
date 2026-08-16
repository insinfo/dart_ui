/// The expander: what exists when it is shut, what the keyboard does, how the
/// reveal animates on a virtual clock, and what a screen reader is told.
///
/// The load-bearing test in this file is "a collapsed expander is not a tab
/// stop". A panel that is merely invisible still answers Tab, and focus that
/// lands somewhere the user cannot see is an accessibility defect rather than a
/// cosmetic one.
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

  group('what exists', () {
    test('a collapsed expander builds no content at all', () {
      final _Harness harness = _Harness()..frame();

      expect(harness.body, isNull);
      expect(harness.contentButton, isNull);

      harness
        ..expand()
        ..frame();
      expect(harness.body, isNotNull);
      expect(harness.contentButton, isNotNull);
      harness.dispose();
    });

    test('a collapsed expander is not a tab stop for its content', () {
      final _Harness harness = _Harness()..frame();

      List<String?> ring() => <String?>[
            for (final FocusNode node
                in harness.owner.focusManager.traversalRing())
              node.debugLabel,
          ];

      expect(ring(), <String>['Button', 'Expander', 'Button'],
          reason: 'the buttons either side of it, and the header');

      harness
        ..expand()
        ..frame();

      expect(ring(), <String>['Button', 'Expander', 'Button', 'Button'],
          reason: 'the panel button joins the ring only once it is showing');

      harness
        ..collapse()
        ..frame();
      expect(ring(), <String>['Button', 'Expander', 'Button'],
          reason: 'and leaves it again when the panel closes');
      harness.dispose();
    });

    test('the hidden half of a closing panel cannot be clicked', () {
      final AnimationClock clock = AnimationClock();
      final ManualDispatcher dispatcher = ManualDispatcher();
      final _Harness harness = _Harness(clock: clock, expanded: true)..frame();
      clock.tick(dispatcher.elapsed);
      harness.frame();

      final double full = harness.body!.contentHeight;
      expect(full, greaterThan(0));

      harness
        ..collapse()
        ..frame();
      clock.tick(dispatcher.elapsed);
      dispatcher.advance(const Duration(milliseconds: 100));
      clock.tick(dispatcher.elapsed);
      harness.frame();

      final double showing = harness.body!.size.height;
      expect(showing, greaterThan(0));
      expect(showing, lessThan(full), reason: 'it is halfway shut');

      // A click below the clip - where the content still is, but where nothing
      // is drawn - must not reach the button.
      harness
        ..clickInBody(Offset(10, full - 1))
        ..frame();
      expect(harness.contentPresses, 0);
      harness.dispose();
    });
  });

  group('keyboard and pointer', () {
    test('a click on the header toggles it', () {
      final _Harness harness = _Harness()..frame();

      harness
        ..clickHeader()
        ..frame();
      expect(harness.expandedStates, <bool>[true]);

      harness
        ..clickHeader()
        ..frame();
      expect(harness.expandedStates, <bool>[true, false]);
      harness.dispose();
    });

    test('Space and Enter toggle, and the arrows open and close', () {
      final _Harness harness = _Harness()
        ..frame()
        ..focusHeader();

      harness.pressKey(logicalKeySpace);
      expect(harness.expanded, isTrue);
      harness.pressKey(logicalKeyEnter);
      expect(harness.expanded, isFalse);

      harness.pressKey(logicalKeyArrowRight);
      expect(harness.expanded, isTrue);
      harness.pressKey(logicalKeyArrowRight);
      expect(harness.expanded, isTrue, reason: 'open is idempotent');
      harness.pressKey(logicalKeyArrowLeft);
      expect(harness.expanded, isFalse);
      harness.dispose();
    });

    test('a disabled expander answers neither', () {
      final _Harness harness = _Harness(enabled: false)..frame();

      harness
        ..clickHeader()
        ..frame();

      expect(harness.expandedStates, isEmpty);
      expect(harness.expanded, isFalse);
      harness.dispose();
    });
  });

  group('the reveal', () {
    test('with no clock the panel is simply there, at its full height', () {
      final _Harness harness = _Harness(expanded: true)..frame();

      expect(harness.body!.factor, 1);
      expect(harness.body!.size.height, harness.body!.contentHeight);
      harness.dispose();
    });

    test('with a clock the box grows while the content stays put', () {
      final AnimationClock clock = AnimationClock();
      final ManualDispatcher dispatcher = ManualDispatcher();
      final _Harness harness = _Harness(clock: clock)..frame();

      harness
        ..expand()
        ..frame();
      clock.tick(dispatcher.elapsed);
      harness.frame();
      expect(harness.body, isNull,
          reason: 'no time has passed, so the panel is still shut - and a shut '
              'panel is not built at all, not built at zero height');

      dispatcher.advance(const Duration(milliseconds: 100));
      clock.tick(dispatcher.elapsed);
      harness.frame();
      final double full = harness.body!.contentHeight;
      final double half = harness.body!.size.height;
      expect(half, greaterThan(0));
      expect(half, lessThan(full));
      expect(harness.body!.contentHeight, full,
          reason: 'the content is laid out once, at its full height: an '
              'animated *constraint* would re-wrap its text every frame');

      dispatcher.advance(const Duration(milliseconds: 100));
      clock.tick(dispatcher.elapsed);
      harness.frame();
      expect(harness.body!.size.height, full);
      expect(harness.body!.factor, 1);
      harness.dispose();
    });

    test('a reduced-motion theme opens it outright', () {
      final AnimationClock clock = AnimationClock();
      final _Harness harness = _Harness(clock: clock, reducedMotion: true)
        ..frame();

      harness
        ..expand()
        ..frame();

      expect(harness.body!.size.height, harness.body!.contentHeight);
      harness.dispose();
    });
  });

  group('semantics', () {
    test('the header is a button that reports whether it is expanded', () {
      final _Harness harness = _Harness()..frame();

      SemanticsNode header() => harness.owner
          .buildSemantics()
          .nodes
          .firstWhere((SemanticsNode node) => node.label == 'Advanced options');

      expect(header().role, SemanticsRole.button);
      expect(header().states, isNot(contains(SemanticsState.expanded)));
      expect(header().actions, contains(SemanticsAction.activate));

      harness
        ..expand()
        ..frame();
      expect(header().states, contains(SemanticsState.expanded));

      harness
        ..focusHeader()
        ..frame();
      expect(header().states, contains(SemanticsState.focused));
      harness.dispose();
    });

    test('a disabled header says so and offers nothing to do', () {
      final _Harness harness = _Harness(enabled: false)..frame();

      final SemanticsNode header = harness.owner
          .buildSemantics()
          .nodes
          .firstWhere((SemanticsNode node) => node.label == 'Advanced options');

      expect(header.states, contains(SemanticsState.disabled));
      expect(header.actions, isEmpty);
      harness.dispose();
    });
  });

  group('right to left', () {
    test('the arrows mean open and close, not left and right', () {
      final _Harness harness = _Harness(direction: TextDirection.rightToLeft)
        ..frame()
        ..focusHeader();

      // Left is "outward" here, so left opens.
      harness.pressKey(logicalKeyArrowLeft);
      expect(harness.expanded, isTrue);
      harness.pressKey(logicalKeyArrowRight);
      expect(harness.expanded, isFalse);
      harness.dispose();
    });

    test('the content is indented from the start edge, which is the right', () {
      final _Harness rtl = _Harness(
        direction: TextDirection.rightToLeft,
        expanded: true,
      )..frame();
      expect(rtl.contentOffset.dx, 0,
          reason: 'the indent is on the right, so the content starts at zero '
              'and stops short of the right edge');
      expect(rtl.body!.size.width - rtl.contentWidth, 16);
      rtl.dispose();

      final _Harness ltr = _Harness(expanded: true)..frame();
      expect(ltr.contentOffset.dx, 16);
      ltr.dispose();
    });
  });
}

final class _Harness {
  _Harness({
    this.direction = TextDirection.leftToRight,
    this.expanded = false,
    this.enabled = true,
    this.clock,
    this.reducedMotion = false,
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(240, 300)),
      ),
    );
    owner.updateRoot(_root());
  }

  final TextDirection direction;
  final bool enabled;
  final AnimationClock? clock;
  final bool reducedMotion;

  late final BuildOwner owner;
  bool expanded;
  final List<bool> expandedStates = <bool>[];
  int contentPresses = 0;
  bool _rootIsStale = false;

  Widget _root() => Directionality(
        textDirection: direction,
        child: Theme(
          data: ThemeData.neutralLight.copyWith(reducedMotion: reducedMotion),
          child: Column(
            children: <Widget>[
              Button(label: 'Above', onPressed: () {}),
              Expander(
                header: 'Advanced options',
                expanded: expanded,
                clock: clock,
                contentIndent: 16,
                onExpandedChanged: enabled
                    ? (bool next) {
                        expandedStates.add(next);
                        expanded = next;
                        _rootIsStale = true;
                      }
                    : null,
                content: SizedBox(
                  height: 60,
                  child: Button(
                    label: 'Inside',
                    onPressed: () => contentPresses++,
                  ),
                ),
              ),
              Button(label: 'Below', onPressed: () {}),
            ],
          ),
        ),
      );

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      if (_rootIsStale) {
        _rootIsStale = false;
        owner.updateRoot(_root());
      }
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds && !_rootIsStale) return;
    }
    throw StateError('the tree never settled');
  }

  void expand() {
    expanded = true;
    _rootIsStale = true;
  }

  void collapse() {
    expanded = false;
    _rootIsStale = true;
  }

  RenderExpanderHeader get header => _all<RenderExpanderHeader>().single;

  RenderExpanderBody? get body {
    final List<RenderExpanderBody> found = _all<RenderExpanderBody>();
    return found.isEmpty ? null : found.single;
  }

  /// The button inside the panel, or null when the panel is not built.
  RenderButton? get contentButton {
    final RenderExpanderBody? panel = body;
    if (panel == null) return null;
    final List<RenderButton> found = _within<RenderButton>(panel);
    return found.isEmpty ? null : found.first;
  }

  Offset get contentOffset => body!.child!.offsetFromParent;

  double get contentWidth => body!.child!.size.width;

  void focusHeader() {
    header.focusNode!.requestFocus(FocusChangeReason.traversal);
    frame();
  }

  void clickHeader() => _click(header.localToGlobal(const Offset(4, 4)));

  /// Clicks a point given in the body's own coordinates - including points
  /// below the clip, which is the whole reason this exists.
  void clickInBody(Offset position) => _click(body!.localToGlobal(position));

  void _click(Offset global) {
    _pointer(global, down: true);
    _pointer(global, down: false);
  }

  void _pointer(Offset position, {required bool down}) =>
      owner.dispatchPointerEvent(down
          ? PointerDownEvent(
              windowId: const NativeWindowId(1),
              generation: 1,
              timestamp: Duration.zero,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: position,
              button: PointerButton.primary,
            )
          : PointerUpEvent(
              windowId: const NativeWindowId(1),
              generation: 1,
              timestamp: Duration.zero,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: position,
              button: PointerButton.primary,
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

  List<T> _all<T extends RenderBox>() {
    final RenderBox? root = owner.renderRoot;
    return root == null ? <T>[] : _within<T>(root);
  }

  List<T> _within<T extends RenderBox>(RenderBox from) {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(from);
    return found;
  }

  void dispose() => owner.dispose();
}
