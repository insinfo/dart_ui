/// Hero: a widget tagged on two routes flies between their rectangles while
/// the transition runs, with both originals hidden, and lands.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const Duration _frame = Duration(milliseconds: 10);
const Duration _transition = Duration(milliseconds: 100);
const Color _red = Color(0xFFFF0000);
const Color _blue = Color(0xFF0000FF);

void main() {
  late ManualDispatcher dispatcher;
  late PipelineOwner pipeline;
  late BuildOwner owner;
  late NavigatorState nav;

  void mount() {
    dispatcher = ManualDispatcher();
    pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(300, 300)));
    final FrameScheduler scheduler = FrameScheduler(
      dispatcher: dispatcher,
      pipelineOwner: pipeline,
      frameInterval: _frame,
      onFrame: (DisplayList list) {},
    );
    final AnimationClock clock = AnimationClock()..attachTo(scheduler);
    owner = BuildOwner(
      pipelineOwner: pipeline,
      onBuildScheduled: scheduler.scheduleFrame,
    );
    addTearDown(owner.dispose);
    final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
    owner.updateRoot(Navigator(
      key: key,
      clock: clock,
      transitionDuration: _transition,
      routes: <String, WidgetBuilder>{
        '/': (BuildContext context) => const Align(
              alignment: Alignment.topLeft,
              child: Hero(
                tag: 'photo',
                child: SizedBox(
                    width: 20, height: 20, child: ColoredBox(color: _red)),
              ),
            ),
      },
    ));
    pipeline.flushLayout();
    nav = key.currentState!;
  }

  void pump([int frames = 1]) {
    dispatcher.advance(_frame * frames);
    owner.buildScope();
    pipeline.flushLayout();
  }

  /// Every coloured box in the tree, with where it is on the window.
  List<(Color, Rect)> boxes() {
    owner.buildScope();
    pipeline.drawFrame(DisplayList());
    final List<(Color, Rect)> found = <(Color, Rect)>[];
    void walk(RenderBox node) {
      if (node is RenderColoredBox) {
        final Offset at = node.localToGlobal(Offset.zero);
        found.add((
          node.color,
          Rect.fromLTWH(at.dx, at.dy, node.size.width, node.size.height),
        ));
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  /// How many coloured boxes paint something.
  int painted() {
    owner.buildScope();
    final DisplayList list = DisplayList();
    pipeline.drawFrame(list);
    return expandDisplayList(list).whereType<DrawRectCommand>().length;
  }

  void pushDetail() => nav.push<void>(PageRouteBuilder<void>(
        transitionDuration: _transition,
        pageBuilder:
            (BuildContext context, Animation<double> a, Animation<double> b) =>
                const Align(
          alignment: Alignment.bottomRight,
          child: Hero(
            tag: 'photo',
            child: SizedBox(
                width: 40, height: 40, child: ColoredBox(color: _blue)),
          ),
        ),
      ));

  test('pushing flies the hero from its place to the new one', () {
    mount();
    pushDetail();
    pump();
    pump(5);
    final List<(Color, Rect)> all = boxes();
    final Iterable<Rect> flying = all
        .where(((Color, Rect) b) =>
            b.$2 != const Rect.fromLTWH(0, 0, 20, 20) &&
            b.$2 != const Rect.fromLTWH(260, 260, 40, 40))
        .map(((Color, Rect) b) => b.$2);
    expect(flying, hasLength(1), reason: 'one copy in the air');
    final Rect mid = flying.single;
    expect(mid.left, greaterThan(0));
    expect(mid.left, lessThan(260));
    expect(mid.width, greaterThan(20));
    expect(mid.width, lessThan(40));
    expect(all.where(((Color, Rect) b) => b.$1 == _blue), hasLength(2),
        reason: 'the destination flies');

    pump(20);
    expect(
        boxes().map(((Color, Rect) b) => b.$2),
        <Rect>[
          const Rect.fromLTWH(0, 0, 20, 20),
          const Rect.fromLTWH(260, 260, 40, 40),
        ],
        reason:
            'landed: the flight is gone, the originals are where they were');
  });

  test('both originals are hidden while it flies', () {
    mount();
    final int before = painted();
    pushDetail();
    pump(3);
    // The leaving hero and the arriving one paint nothing; the copy paints.
    expect(painted(), lessThanOrEqualTo(before + 1));
    pump(20);
  });

  test('popping flies it back', () {
    mount();
    pushDetail();
    pump(20);
    nav.pop();
    pump(5);
    final List<(Color, Rect)> all = boxes();
    expect(
        all.where(((Color, Rect) b) =>
            b.$2.left > 0 && b.$2.left < 260 && b.$2.width < 40),
        hasLength(1),
        reason: 'on its way back to the top left');
    pump(20);
    expect(boxes().map(((Color, Rect) b) => b.$2),
        <Rect>[const Rect.fromLTWH(0, 0, 20, 20)],
        reason: 'the detail page is gone, and so is the flight');
  });
}
