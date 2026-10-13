/// Flutter's `Listener`: events in the listener's own coordinates, moves
/// told from hovers, and Flutter's button bits.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'input_test_harness.dart';

void main() {
  Widget placed(Widget child) => Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 50, top: 40),
          child: SizedBox(width: 100, height: 80, child: child),
        ),
      );

  test('positions are local to the listener, and deltas are measured', () {
    final List<PointerEvent> events = <PointerEvent>[];
    final InputHarness h = InputHarness(
      placed(Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: events.add,
        onPointerMove: events.add,
        onPointerUp: events.add,
      )),
      overlay: false,
    );
    h.down(const Offset(60, 50));
    h.move(const Offset(70, 55));
    h.up(const Offset(70, 55));

    expect(events.map((PointerEvent e) => e.runtimeType),
        <Type>[PointerDownEvent, PointerMoveEvent, PointerUpEvent]);
    expect(events[0].localPosition, const Offset(10, 10));
    expect(events[0].position, const Offset(60, 50));
    expect(events[0].buttons, kPrimaryButton);
    expect(events[1].localPosition, const Offset(20, 15));
    expect(events[1].delta, const Offset(10, 5));
    expect(events[1].localDelta, const Offset(10, 5));
    expect(events[1].buttons, kPrimaryButton, reason: 'a drag holds a button');
    expect(events[1].down, isTrue);
    expect(events[2].buttons, 0);
    h.dispose();
  });

  test('a move with nothing pressed is a hover', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(
      placed(Listener(
        behavior: HitTestBehavior.opaque,
        onPointerHover: (PointerHoverEvent e) =>
            log.add('hover ${e.localPosition.dx}'),
        onPointerMove: (PointerMoveEvent e) => log.add('move'),
      )),
      overlay: false,
    );
    h.move(const Offset(60, 50));
    h.down(const Offset(60, 50));
    h.move(const Offset(65, 50));
    h.up(const Offset(65, 50));
    expect(log, <String>['hover 10.0', 'move']);
    h.dispose();
  });

  test('deferToChild is hit only where the child is; opaque everywhere', () {
    int hits = 0;
    final InputHarness h = InputHarness(
      placed(Listener(
        onPointerDown: (_) => hits++,
        child: const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
              width: 10,
              height: 10,
              child: ColoredBox(color: Color(0xFF000000))),
        ),
      )),
      overlay: false,
    );
    h.down(const Offset(55, 45));
    h.up(const Offset(55, 45));
    h.down(const Offset(120, 100));
    h.up(const Offset(120, 100));
    expect(hits, 1);
    h.dispose();
  });

  test('translucent is a Flutter name that is hit like opaque', () {
    int hits = 0;
    final InputHarness h = InputHarness(
      placed(Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => hits++,
      )),
      overlay: false,
    );
    h.down(const Offset(120, 100));
    expect(hits, 1);
    h.dispose();
  });

  test('the wheel reaches onPointerSignal with its scroll delta', () {
    final List<Offset> deltas = <Offset>[];
    final InputHarness h = InputHarness(
      placed(Listener(
        behavior: HitTestBehavior.opaque,
        onPointerSignal: (PointerSignalEvent e) {
          if (e is PointerScrollEvent) deltas.add(e.scrollDelta);
        },
      )),
      overlay: false,
    );
    h.wheel(const Offset(70, 70), const Offset(0, 120));
    expect(deltas, <Offset>[const Offset(0, 120)]);
    h.dispose();
  });

  test('a trackpad pinch arrives as start, update and end', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(
      placed(Listener(
        behavior: HitTestBehavior.opaque,
        onPointerPanZoomStart: (_) => log.add('start'),
        onPointerPanZoomUpdate: (PointerPanZoomUpdateEvent e) =>
            log.add('update ${e.scale}'),
        onPointerPanZoomEnd: (_) => log.add('end'),
      )),
      overlay: false,
    );
    h.panZoom(const Offset(70, 70), PanZoomPhase.start);
    h.panZoom(const Offset(70, 70), PanZoomPhase.update, scale: 2);
    h.panZoom(const Offset(70, 70), PanZoomPhase.end, scale: 2);
    expect(log, <String>['start', 'update 2.0', 'end']);
    h.dispose();
  });

  test('a secondary press reports its bit, and the bits combine', () {
    final List<int> buttons = <int>[];
    final InputHarness h = InputHarness(
      placed(Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (PointerDownEvent e) => buttons.add(e.buttons),
      )),
      overlay: false,
    );
    h.down(const Offset(60, 50), button: PointerButton.secondary);
    h.up(const Offset(60, 50), button: PointerButton.secondary);
    expect(buttons, <int>[kSecondaryButton]);
    expect(
        const PointerDownEvent(
          windowId: inputTestWindow,
          generation: 1,
          timestamp: Duration.zero,
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: Offset.zero,
          button: PointerButton.middle,
        ).buttons,
        kMiddleMouseButton);
    h.dispose();
  });
}
