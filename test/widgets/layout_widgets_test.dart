/// Container, FittedBox, RotatedBox, IndexedStack, Offstage, Placeholder.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  late BuildOwner owner;

  void mount(Widget root, {Size size = const Size(300, 200)}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    )..updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: Align(alignment: Alignment.topLeft, child: root)));
    owner.buildScope();
    owner.pipelineOwner.drawFrame(DisplayList());
  }

  T find<T extends RenderBox>() {
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
    return found!;
  }

  tearDown(() => owner.dispose());

  test('Container: margin outside, padding inside, the size it is given', () {
    mount(Container(
      width: 100,
      height: 60,
      margin: const EdgeInsets.all(10),
      padding: const EdgeInsets.all(5),
      color: const Color(0xFFFF0000),
      child: const SizedBox(width: 20, height: 20),
    ));
    final RenderColoredBox colored = find<RenderColoredBox>();
    expect(colored.size, const Size(100, 60));
    expect(colored.localToGlobal(Offset.zero), const Offset(10, 10));
  });

  test('an empty Container fills bounded space', () {
    mount(const SizedBox(
        width: 120, height: 80, child: Center(child: _EmptyContainer())));
    expect(find<RenderColoredBox>().size, const Size(120, 80));
  });

  test('RotatedBox takes the turned size and turns the hit test too', () {
    var taps = 0;
    mount(RotatedBox(
      quarterTurns: 1,
      child: GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: () => taps++,
        child: const SizedBox(width: 80, height: 20),
      ),
    ));
    final RenderRotatedBox box = find<RenderRotatedBox>();
    expect(box.size, const Size(20, 80));
    // Inside the turned box, outside the unturned one.
    expect(box.hitTest(const Offset(10, 70)), isNotNull);
    expect(box.hitTest(const Offset(70, 10)), isNull);
    expect(taps, 0);
  });

  test('FittedBox scales its child to fit, keeping the aspect', () {
    mount(SizedBox(
      width: 200,
      height: 100,
      child: FittedBox(
        child: GestureDetector(
          behavior: GestureHitTestBehavior.opaque,
          onTap: () {},
          child: const SizedBox(width: 40, height: 40),
        ),
      ),
    ));
    final RenderFittedBox fitted = find<RenderFittedBox>();
    expect(fitted.size, const Size(200, 100));
    // The 40x40 child scales by 2.5 to 100x100, centred: its centre hits.
    expect(fitted.hitTest(const Offset(100, 50)), isNotNull);
    expect(fitted.hitTest(const Offset(20, 50)), isNull,
        reason: 'left of the scaled child');
  });

  test('IndexedStack shows one child, sized by the largest', () {
    mount(const IndexedStack(index: 1, children: <Widget>[
      SizedBox(width: 50, height: 90),
      SizedBox(width: 120, height: 30),
    ]));
    final RenderStack stack = find<RenderStack>();
    expect(stack.size, const Size(120, 90));
    final List<RenderVisibility> layers = <RenderVisibility>[];
    void walk(RenderBox node) {
      if (node is RenderVisibility) layers.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    expect(layers.map((RenderVisibility v) => v.visible), <bool>[false, true]);
  });

  test('Offstage lays out, takes no space and is not hit', () {
    mount(const Offstage(child: SizedBox(width: 50, height: 50)));
    final RenderVisibility v = find<RenderVisibility>();
    expect(v.size, Size.zero);
    expect(v.hitTest(Offset.zero), isNull);
  });

  test('Placeholder fills its space, or its fallback where unbounded', () {
    mount(const SizedBox(width: 90, height: 40, child: Placeholder()));
    final RenderBox box = find<RenderLimitedBox>();
    expect(box.size, const Size(90, 40));
  });
}

final class _EmptyContainer extends StatelessWidget {
  const _EmptyContainer();

  @override
  Widget build(BuildContext context) =>
      Container(color: const Color(0xFF00FF00));
}
