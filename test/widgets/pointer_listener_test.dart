/// The raw-pointer escape hatch, and the gap it closes.
///
/// Before [PointerListener] there was no way for an ordinary widget to see a
/// wheel notch, a middle-button press or a right-button drag: recognizers are
/// never offered a [PointerScrollEvent], and every drag recognizer here refuses
/// a button it was not built for. The only widgets that could read those were
/// the four that had written their own render object. The concrete failure was
/// a 3D model viewer with no scroll-wheel zoom, which is why each case below is
/// named for the input it recovers rather than for the method it calls.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('PointerListener', () {
    test('a wheel notch reaches an ordinary widget', () {
      final List<PointerScrollEvent> wheel = <PointerScrollEvent>[];
      final _Harness harness = _Harness(
        PointerListener(
          onPointerScroll: wheel.add,
          child: const SizedBox(width: 200, height: 100),
        ),
      );

      harness.pointer(_wheel(const Offset(100, 50), -120));

      expect(wheel, hasLength(1));
      expect(wheel.single.scrollDelta.dy, -120);
      harness.dispose();
    });

    test('the innermost listener gets the notch, and only it', () {
      // Two nested listeners are the shape of a zoomable view inside a
      // scrolling page. Both must not act on the same notch: the view would
      // zoom and the page would scroll out from under it.
      final List<double> outer = <double>[];
      final List<double> inner = <double>[];
      final _Harness harness = _Harness(
        PointerListener(
          onPointerScroll: (PointerScrollEvent e) =>
              outer.add(e.scrollDelta.dy),
          child: PointerListener(
            onPointerScroll: (PointerScrollEvent e) =>
                inner.add(e.scrollDelta.dy),
            child: const SizedBox(width: 200, height: 100),
          ),
        ),
      );

      harness.pointer(_wheel(const Offset(100, 50), 40));

      expect(inner, <double>[40]);
      expect(outer, isEmpty);
      harness.dispose();
    });

    test('the middle and right buttons arrive, which no gesture reports', () {
      final List<PointerButton> pressed = <PointerButton>[];
      final _Harness harness = _Harness(
        PointerListener(
          onPointerDown: (PointerDownEvent e) => pressed.add(e.button),
          child: const SizedBox(width: 200, height: 100),
        ),
      );

      harness.pointer(_down(const Offset(20, 20), PointerButton.middle));
      harness.pointer(_up(const Offset(20, 20), PointerButton.middle));
      harness.pointer(_down(const Offset(20, 20), PointerButton.secondary));
      harness.pointer(_up(const Offset(20, 20), PointerButton.secondary));

      expect(pressed, <PointerButton>[
        PointerButton.middle,
        PointerButton.secondary,
      ]);
      harness.dispose();
    });

    test('a drag that leaves the box keeps reporting', () {
      // The property that makes an orbit usable: a pointer that went down here
      // belongs here until it is released, however far outside it travels.
      final List<Offset> moves = <Offset>[];
      final _Harness harness = _Harness(
        PointerListener(
          onPointerDown: (PointerDownEvent e) {},
          onPointerMove: (PointerMoveEvent e) => moves.add(e.logicalPosition),
          child: const SizedBox(width: 200, height: 100),
        ),
      );

      harness.pointer(_down(const Offset(100, 50), PointerButton.primary));
      harness.pointer(_move(const Offset(140, 60)));
      harness.pointer(_move(const Offset(900, 900)));

      expect(moves, <Offset>[const Offset(140, 60), const Offset(900, 900)]);
      harness.dispose();
    });

    test('deferToChild leaves the events to whatever is under them', () {
      final List<PointerScrollEvent> wheel = <PointerScrollEvent>[];
      final _Harness harness = _Harness(
        PointerListener(
          behavior: GestureHitTestBehavior.deferToChild,
          onPointerScroll: wheel.add,
          child: const SizedBox(width: 200, height: 100),
        ),
      );

      // A SizedBox paints nothing and absorbs nothing, so nothing is hit and
      // the listener is not on the path. This is the reason the default is
      // opaque: a viewport that answered the wheel over its content and
      // ignored it over its margin would read as an intermittent bug.
      harness.pointer(_wheel(const Offset(100, 50), 40));

      expect(wheel, isEmpty);
      harness.dispose();
    });

    test('a listener with no scroll callback does not swallow the notch', () {
      final List<double> outer = <double>[];
      final _Harness harness = _Harness(
        PointerListener(
          onPointerScroll: (PointerScrollEvent e) =>
              outer.add(e.scrollDelta.dy),
          child: PointerListener(
            onPointerDown: (PointerDownEvent e) {},
            child: const SizedBox(width: 200, height: 100),
          ),
        ),
      );

      harness.pointer(_wheel(const Offset(100, 50), 40));

      expect(outer, <double>[40]);
      harness.dispose();
    });
  });
}

final class _Harness {
  _Harness(Widget widget, {Size size = const Size(200, 100)}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );
    owner.updateRoot(widget);
    frame();
  }

  late final BuildOwner owner;

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      if (owner.hasScheduledBuilds) owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  bool pointer(PointerEvent event) => owner.dispatchPointerEvent(event);

  void dispose() => owner.dispose();
}

const NativeWindowId _window = NativeWindowId(1);

PointerDownEvent _down(Offset at, PointerButton button) => PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: button,
    );

PointerMoveEvent _move(Offset at) => PointerMoveEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
    );

PointerUpEvent _up(Offset at, PointerButton button) => PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: button,
    );

PointerScrollEvent _wheel(Offset at, double delta) => PointerScrollEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      scrollDelta: Offset(0, delta),
      scrollDeltaUnit: ScrollDeltaUnit.pixels,
    );
