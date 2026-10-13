/// CustomMultiChildLayout with its delegate, and UnconstrainedBox.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A title centred on the whole bar, with a button at each end.
final class _BarDelegate extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final BoxConstraints loose = BoxConstraints.loose(size);
    final Size lead = layoutChild('lead', loose);
    positionChild('lead', Offset(0, (size.height - lead.height) / 2));
    if (hasChild('trail')) {
      final Size trail = layoutChild('trail', loose);
      positionChild('trail',
          Offset(size.width - trail.width, (size.height - trail.height) / 2));
    }
    final Size title = layoutChild('title', loose);
    positionChild(
        'title',
        Offset(
            (size.width - title.width) / 2, (size.height - title.height) / 2));
  }

  @override
  bool shouldRelayout(_BarDelegate oldDelegate) => false;
}

final class _Forgetful extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) => layoutChild('a', BoxConstraints.loose(size));

  @override
  bool shouldRelayout(_Forgetful oldDelegate) => false;
}

void main() {
  late BuildOwner owner;

  RenderBox mount(Widget child, {Size size = const Size(300, 40)}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    )..updateRoot(child);
    owner.buildScope();
    owner.pipelineOwner.drawFrame(DisplayList());
    return owner.renderRoot!;
  }

  T find<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found.single;
  }

  tearDown(() => owner.dispose());

  test('the delegate places each child by its id', () {
    mount(CustomMultiChildLayout(
      delegate: _BarDelegate(),
      children: const <Widget>[
        LayoutId(id: 'lead', child: SizedBox(width: 40, height: 20)),
        LayoutId(id: 'title', child: SizedBox(width: 100, height: 16)),
        LayoutId(id: 'trail', child: SizedBox(width: 80, height: 30)),
      ],
    ));
    final RenderCustomMultiChildLayoutBox box =
        find<RenderCustomMultiChildLayoutBox>();
    expect(box.size, const Size(300, 40));
    expect(box.childAt(0).offsetFromParent, const Offset(0, 10));
    expect(box.childAt(1).offsetFromParent, const Offset(100, 12),
        reason: 'centred on the bar, not between the buttons');
    expect(box.childAt(2).offsetFromParent, const Offset(220, 5));
  });

  test('a child the delegate forgets is a named error', () {
    expect(
      () => mount(CustomMultiChildLayout(
        delegate: _Forgetful(),
        children: const <Widget>[
          LayoutId(id: 'a', child: SizedBox()),
          LayoutId(id: 'b', child: SizedBox()),
        ],
      )),
      throwsA(isA<StateError>()
          .having((StateError e) => e.message, 'message', contains('b'))),
    );
  });

  test('UnconstrainedBox lets a child be its own size inside tight space', () {
    mount(
      const UnconstrainedBox(child: SizedBox(width: 50, height: 10)),
      size: const Size(200, 100),
    );
    final RenderUnconstrainedBox box = find<RenderUnconstrainedBox>();
    expect(box.size, const Size(200, 100));
    expect(box.child!.size, const Size(50, 10), reason: 'not stretched');
    expect(box.child!.offsetFromParent, const Offset(75, 45));
    expect(box.overflow, Size.zero);
  });

  test('a child larger than the box overflows it, and says by how much', () {
    mount(
      const UnconstrainedBox(child: SizedBox(width: 260, height: 10)),
      size: const Size(200, 100),
    );
    expect(find<RenderUnconstrainedBox>().overflow, const Size(60, 0));
  });

  test('the constrained axis keeps the parent\'s constraints', () {
    mount(
      const UnconstrainedBox(
        constrainedAxis: Axis.horizontal,
        child: SizedBox(width: 260, height: 10),
      ),
      size: const Size(200, 100),
    );
    expect(find<RenderUnconstrainedBox>().child!.size, const Size(200, 10));
  });
}
