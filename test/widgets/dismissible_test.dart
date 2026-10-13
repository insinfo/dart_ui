/// Flutter's `Dismissible`: swiped past the threshold it slides out, its
/// space closes and it reports the direction; short of it, it comes back.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'input_test_harness.dart';

const Color _item = Color(0xFF3949AB);
const Color _bg = Color(0xFF43A047);
const Color _bg2 = Color(0xFFE53935);

/// Three 50-high rows in a 200-wide column; the middle one is dismissible.
Widget _list({
  required List<String> log,
  DismissDirection direction = DismissDirection.horizontal,
  ConfirmDismissCallback? confirm,
  Duration? resize = const Duration(milliseconds: 300),
  Map<DismissDirection, double> thresholds = const <DismissDirection, double>{},
  List<DismissUpdateDetails>? updates,
}) =>
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 200,
        child: Column(children: <Widget>[
          const SizedBox(height: 50),
          Dismissible(
            key: const ValueKey<String>('row'),
            direction: direction,
            confirmDismiss: confirm,
            resizeDuration: resize,
            dismissThresholds: thresholds,
            onUpdate: updates?.add,
            onDismissed: (DismissDirection d) => log.add('dismissed ${d.name}'),
            background: const ColoredBox(color: _bg),
            secondaryBackground: const ColoredBox(color: _bg2),
            child: const SizedBox(height: 50, child: ColoredBox(color: _item)),
          ),
          const SizedBox(height: 50),
        ]),
      ),
    );

/// How far the item is slid, in fractions of its width.
double _slide(InputHarness h) =>
    h.find<RenderFractionalTranslation>().single.translation.dx;

void main() {
  test('swiped past the threshold, it slides out, shrinks and is dismissed',
      () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(_list(log: log), overlay: false);
    h.drag(const Offset(20, 75), const Offset(140, 75),
        steps: 12, release: false);
    expect(_slide(h), closeTo(0.55, 0.03), reason: 'follows the drag');
    final List<RenderColoredBox> painted = h.find<RenderColoredBox>();
    expect(painted.map((RenderColoredBox b) => b.color), contains(_bg),
        reason: 'the background shows in the space uncovered');
    h.up(const Offset(140, 75));
    h.pump(const Duration(milliseconds: 250));
    expect(log, isEmpty, reason: 'still closing the space');
    h.pump(const Duration(milliseconds: 400));
    expect(log, <String>['dismissed startToEnd']);
    h.dispose();
  });

  test('released short of the threshold, it comes back', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(_list(log: log), overlay: false);
    // Slow enough not to be a fling.
    h.down(const Offset(20, 75));
    for (int i = 1; i <= 6; i++) {
      h.move(Offset(20 + i * 6.0, 75));
      h.pump(const Duration(milliseconds: 50));
    }
    h.up(const Offset(56, 75));
    h.pump(const Duration(milliseconds: 400));
    expect(log, isEmpty);
    expect(_slide(h), 0);
    h.dispose();
  });

  test(
      'towards the start it reports endToStart and shows the secondary '
      'background', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(_list(log: log), overlay: false);
    h.drag(const Offset(180, 75), const Offset(40, 75),
        steps: 12, release: false);
    expect(h.find<RenderColoredBox>().map((RenderColoredBox b) => b.color),
        contains(_bg2));
    h.up(const Offset(40, 75));
    h.pump(const Duration(seconds: 1));
    expect(log, <String>['dismissed endToStart']);
    h.dispose();
  });

  test('a direction it does not allow does not move it', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(
      _list(log: log, direction: DismissDirection.startToEnd),
      overlay: false,
    );
    h.drag(const Offset(180, 75), const Offset(20, 75), steps: 12);
    h.pump(const Duration(seconds: 1));
    expect(log, isEmpty);
    expect(_slide(h), 0);
    h.dispose();
  });

  test('confirmDismiss false puts it back; true lets it go', () async {
    final List<String> log = <String>[];
    Completer<bool?> answer = Completer<bool?>();
    final InputHarness h = InputHarness(
      _list(
          log: log,
          confirm: (DismissDirection d) {
            log.add('confirm ${d.name}');
            return answer.future;
          }),
      overlay: false,
    );
    h.drag(const Offset(20, 75), const Offset(160, 75), steps: 12);
    h.pump(const Duration(milliseconds: 400));
    expect(log, <String>['confirm startToEnd']);
    answer.complete(false);
    await Future<void>.delayed(Duration.zero);
    h.pump(const Duration(milliseconds: 400));
    expect(_slide(h), 0, reason: 'refused: back in place');

    answer = Completer<bool?>();
    h.drag(const Offset(20, 75), const Offset(160, 75), steps: 12);
    h.pump(const Duration(milliseconds: 400));
    answer.complete(true);
    await Future<void>.delayed(Duration.zero);
    h.pump(const Duration(seconds: 1));
    expect(log.last, 'dismissed startToEnd');
    h.dispose();
  });

  test('onUpdate reports progress and the threshold being reached', () {
    final List<String> log = <String>[];
    final List<DismissUpdateDetails> updates = <DismissUpdateDetails>[];
    final InputHarness h = InputHarness(
      _list(log: log, updates: updates),
      overlay: false,
    );
    h.drag(const Offset(20, 75), const Offset(140, 75),
        steps: 12, release: false);
    expect(updates, isNotEmpty);
    expect(updates.first.reached, isFalse);
    expect(updates.last.reached, isTrue);
    // 120 dragged, less the slop the recognizer takes before it starts.
    expect(updates.last.progress, closeTo(0.55, 0.03));
    expect(updates.last.direction, DismissDirection.startToEnd);
    expect(
        updates
            .any((DismissUpdateDetails u) => u.reached && !u.previousReached),
        isTrue);
    h.up(const Offset(140, 75));
    h.pump(const Duration(seconds: 1));
    h.dispose();
  });

  test('a threshold of 1 never dismisses', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(
      _list(log: log, thresholds: const <DismissDirection, double>{
        DismissDirection.startToEnd: 1.0,
      }),
      overlay: false,
    );
    h.drag(const Offset(20, 75), const Offset(190, 75), steps: 12);
    h.pump(const Duration(seconds: 1));
    expect(log, isEmpty);
    h.dispose();
  });

  test('without resizeDuration it is dismissed as soon as it is out', () {
    final List<String> log = <String>[];
    final InputHarness h =
        InputHarness(_list(log: log, resize: null), overlay: false);
    h.drag(const Offset(20, 75), const Offset(160, 75), steps: 12);
    h.pump(const Duration(milliseconds: 300));
    expect(log, <String>['dismissed startToEnd']);
    h.dispose();
  });

  test('without an animation clock it dismisses at once', () {
    final List<String> log = <String>[];
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(400, 300))),
    );
    owner.updateRoot(_list(log: log));
    owner.pipelineOwner.drawFrame(DisplayList());
    PointerEvent at(Offset p, int kind) => switch (kind) {
          0 => PointerDownEvent(
              windowId: inputTestWindow,
              generation: 1,
              timestamp: Duration.zero,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: p,
              button: PointerButton.primary),
          1 => PointerMoveEvent(
              windowId: inputTestWindow,
              generation: 1,
              timestamp: Duration(milliseconds: p.dx.round()),
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: p),
          _ => PointerUpEvent(
              windowId: inputTestWindow,
              generation: 1,
              timestamp: const Duration(seconds: 1),
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: p,
              button: PointerButton.primary),
        };
    owner.dispatchPointerEvent(at(const Offset(20, 75), 0));
    for (int i = 1; i <= 12; i++) {
      owner.dispatchPointerEvent(at(Offset(20 + i * 12.0, 75), 1));
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
    }
    owner.dispatchPointerEvent(at(const Offset(164, 75), 2));
    owner.buildScope();
    owner.pipelineOwner.drawFrame(DisplayList());
    expect(log, <String>['dismissed startToEnd']);
    owner.dispose();
  });
}
