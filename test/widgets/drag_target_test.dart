/// Flutter's in-app drag and drop: a Draggable's feedback follows the
/// pointer in the overlay, and a DragTarget under it is asked, told and
/// given the data.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'input_test_harness.dart';

const Color _red = Color(0xFFE53935);
const Color _green = Color(0xFF43A047);
const Color _blue = Color(0xFF1E88E5);

Widget _square(Color color, [double size = 40]) =>
    SizedBox(width: size, height: size, child: ColoredBox(color: color));

/// A draggable at (20,20)-(60,60) and a target at (200,20)-(300,120).
Widget _scene({
  required List<String> log,
  bool Function(DragTargetDetails<String>)? willAccept,
  Axis? axis,
  int? maxSimultaneousDrags,
  Widget? childWhenDragging,
  bool longPress = false,
}) {
  final Widget draggable = longPress
      ? LongPressDraggable<String>(
          data: 'apple',
          feedback: _square(_blue, 30),
          onDragStarted: () => log.add('started'),
          onDragCompleted: () => log.add('completed'),
          onDraggableCanceled: (Velocity v, Offset o) => log.add('canceled'),
          child: _square(_red),
        )
      : Draggable<String>(
          data: 'apple',
          axis: axis,
          maxSimultaneousDrags: maxSimultaneousDrags,
          feedback: _square(_blue, 30),
          childWhenDragging: childWhenDragging,
          onDragStarted: () => log.add('started'),
          onDragUpdate: (DragUpdateDetails d) => log.add('update'),
          onDragEnd: (DraggableDetails d) => log.add('end ${d.wasAccepted}'),
          onDragCompleted: () => log.add('completed'),
          onDraggableCanceled: (Velocity v, Offset o) => log.add('canceled'),
          child: _square(_red),
        );
  return Stack(children: <Widget>[
    Positioned(left: 20, top: 20, child: draggable),
    Positioned(
      left: 200,
      top: 20,
      child: DragTarget<String>(
        onWillAcceptWithDetails: willAccept,
        onAcceptWithDetails: (DragTargetDetails<String> d) =>
            log.add('accept ${d.data}'),
        onLeave: (String? data) => log.add('leave $data'),
        builder: (BuildContext context, List<String?> candidates,
                List<dynamic> rejected) =>
            SizedBox(
          width: 100,
          height: 100,
          child: ColoredBox(
            color: candidates.isNotEmpty
                ? _green
                : rejected.isNotEmpty
                    ? _red
                    : const Color(0xFFDDDDDD),
          ),
        ),
      ),
    ),
  ]);
}

List<Rect> _boxes(InputHarness h, Color color) => <Rect>[
      for (final RenderColoredBox box in h.find<RenderColoredBox>())
        if (box.color == color) h.rectOf(box),
    ];

void main() {
  test('dropping on a target that accepts hands it the data', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(_scene(log: log));
    h.down(const Offset(30, 30));
    for (int i = 1; i <= 10; i++) {
      h.move(Offset(30 + i * 22.0, 30 + i * 4.0));
    }
    // The feedback follows the pointer, keeping where it was grabbed.
    final List<Rect> feedback = _boxes(h, _blue);
    expect(feedback, hasLength(1));
    expect(feedback.single.topLeft, const Offset(240, 60));
    expect(_boxes(h, _green), hasLength(1), reason: 'the target highlights');
    h.up(const Offset(250, 70));
    expect(log.where((String e) => e != 'update'), <String>[
      'started',
      'accept apple',
      'end true',
      'completed',
    ]);
    expect(_boxes(h, _blue), isEmpty, reason: 'the feedback is gone');
    h.dispose();
  });

  test('a target that will not accept is told, and the drop is canceled', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(_scene(
      log: log,
      willAccept: (DragTargetDetails<String> d) => false,
    ));
    h.drag(const Offset(30, 30), const Offset(250, 70), steps: 10);
    expect(log.where((String e) => e != 'update'), <String>[
      'started',
      'leave apple',
      'end false',
      'canceled',
    ]);
    h.dispose();
  });

  test('leaving the target tells it so', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(_scene(log: log));
    h.drag(const Offset(30, 30), const Offset(250, 70),
        steps: 10, release: false);
    for (int i = 1; i <= 5; i++) {
      h.move(Offset(250, 70 + i * 40.0));
    }
    h.up(const Offset(250, 270));
    expect(log.where((String e) => e != 'update'), <String>[
      'started',
      'leave apple',
      'end false',
      'canceled',
    ]);
    h.dispose();
  });

  test('childWhenDragging takes the child\'s place during the drag', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(_scene(
      log: log,
      childWhenDragging: _square(const Color(0xFF888888)),
    ));
    expect(_boxes(h, _red), hasLength(1));
    h.drag(const Offset(30, 30), const Offset(120, 30), release: false);
    expect(_boxes(h, _red), isEmpty);
    expect(_boxes(h, const Color(0xFF888888)), hasLength(1));
    h.up(const Offset(120, 30));
    expect(_boxes(h, _red), hasLength(1));
    h.dispose();
  });

  test('axis keeps the feedback on one line', () {
    final List<String> log = <String>[];
    final InputHarness h =
        InputHarness(_scene(log: log, axis: Axis.horizontal));
    h.drag(const Offset(30, 30), const Offset(130, 90), release: false);
    expect(_boxes(h, _blue).single.top, 20);
    expect(_boxes(h, _blue).single.left, 120);
    h.up(const Offset(130, 90));
    h.dispose();
  });

  test('maxSimultaneousDrags 0 does not drag', () {
    final List<String> log = <String>[];
    final InputHarness h =
        InputHarness(_scene(log: log, maxSimultaneousDrags: 0));
    h.drag(const Offset(30, 30), const Offset(250, 70));
    expect(log, isEmpty);
    h.dispose();
  });

  test('LongPressDraggable starts after the delay, not on a quick drag', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(_scene(log: log, longPress: true));
    h.drag(const Offset(30, 30), const Offset(250, 70));
    expect(log, isEmpty, reason: 'moved before the long press fired');

    h.down(const Offset(30, 30));
    h.pump(const Duration(milliseconds: 600));
    expect(log, <String>['started']);
    for (int i = 1; i <= 10; i++) {
      h.move(Offset(30 + i * 22.0, 30 + i * 4.0));
    }
    h.up(const Offset(250, 70));
    expect(log, <String>['started', 'accept apple', 'completed']);
    h.dispose();
  });

  test('a target only sees drags whose data it can take', () {
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(Stack(children: <Widget>[
      Positioned(
        left: 20,
        top: 20,
        child: Draggable<int>(
          data: 7,
          feedback: _square(_blue, 30),
          onDraggableCanceled: (_, __) => log.add('canceled'),
          child: _square(_red),
        ),
      ),
      Positioned(
        left: 200,
        top: 20,
        child: DragTarget<String>(
          onAcceptWithDetails: (_) => log.add('accepted'),
          builder: (_, __, ___) => _square(_green, 100),
        ),
      ),
    ]));
    h.drag(const Offset(30, 30), const Offset(250, 70), steps: 10);
    expect(log, <String>['canceled']);
    h.dispose();
  });

  test('pointerDragAnchorStrategy puts the feedback at the pointer', () {
    final InputHarness h = InputHarness(Stack(children: <Widget>[
      Positioned(
        left: 20,
        top: 20,
        child: Draggable<String>(
          data: 'x',
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: _square(_blue, 30),
          child: _square(_red),
        ),
      ),
    ]));
    h.drag(const Offset(40, 40), const Offset(140, 90), release: false);
    expect(_boxes(h, _blue).single.topLeft, const Offset(140, 90));
    h.up(const Offset(140, 90));
    h.dispose();
  });

  test('a Draggable with no Overlay above it fails with a clear error', () {
    final ErrorReporter reporter = ErrorReporter();
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(50, 50))),
    )..errorReporter = reporter;
    owner.updateRoot(const Draggable<String>(
      feedback: SizedBox(),
      child: SizedBox(),
    ));
    expect(reporter.errors.map((FrameworkError e) => e.cause),
        contains(isA<StateError>()));
    owner.dispose();
  });
}
