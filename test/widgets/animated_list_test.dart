/// AnimatedList: items told to arrive grow in, items told to leave shrink
/// away built by the caller's builder, and with no clock both happen at once.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

final class _List {
  _List({this.withClock = true, int initial = 2}) {
    items = <String>[for (int i = 0; i < initial; i++) 'item $i'];
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(200, 300))),
    )..updateRoot(_root());
    _pump();
  }

  final bool withClock;
  final GlobalKey<AnimatedListState> key = GlobalKey<AnimatedListState>();
  final AnimationClock clock = AnimationClock();
  final ManualDispatcher dispatcher = ManualDispatcher();
  late final BuildOwner owner;
  late final List<String> items;

  Widget _root() {
    final Widget list = Theme(
      data: ThemeData.neutralLight,
      child: AnimatedList(
        key: key,
        initialItemCount: items.length,
        estimatedItemExtent: 20,
        itemBuilder: (BuildContext context, int index, Animation<double> a) =>
            SizeTransition(
          sizeFactor: a,
          child: SizedBox(height: 20, child: Text(items[index])),
        ),
      ),
    );
    return withClock ? AnimationScope(clock: clock, child: list) : list;
  }

  AnimatedListState get state => key.currentState!;

  void advance(Duration delta) {
    dispatcher.advance(delta);
    clock.tick(dispatcher.elapsed);
    _pump();
  }

  void tickNow() {
    clock.tick(dispatcher.elapsed);
    _pump();
  }

  void _pump() {
    for (int pass = 0; pass < 8; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  /// The height each row takes now, in order.
  List<double> get heights {
    final List<double> found = <double>[];
    void walk(RenderBox node) {
      if (node is RenderClipRect) {
        found.add(node.size.height);
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  void dispose() => owner.dispose();
}

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  const Duration ms100 = Duration(milliseconds: 100);

  test('an inserted item grows in, the others stay', () {
    final _List list = _List();
    expect(list.heights, <double>[20, 20]);
    list.items.insert(1, 'new');
    list.state.insertItem(1, duration: ms100);
    list
      ..tickNow()
      ..advance(const Duration(milliseconds: 50));
    expect(list.heights, <double>[20, 10, 20]);
    list.advance(const Duration(milliseconds: 50));
    expect(list.heights, <double>[20, 20, 20]);
    expect(list.state.itemCount, 3);
    list.dispose();
  });

  test('a removed item shrinks away, drawn by the builder it was given', () {
    final _List list = _List(initial: 3);
    final String gone = list.items.removeAt(1);
    list.state.removeItem(
      1,
      (BuildContext context, Animation<double> a) => SizeTransition(
          sizeFactor: a, child: SizedBox(height: 20, child: Text(gone))),
      duration: ms100,
    );
    expect(list.state.itemCount, 2, reason: 'out of the data at once');
    list
      ..tickNow()
      ..advance(const Duration(milliseconds: 50));
    expect(list.heights, <double>[20, 10, 20]);
    list.advance(const Duration(milliseconds: 60));
    expect(list.heights, <double>[20, 20], reason: 'gone when it has shrunk');
    list.dispose();
  });

  test('without a clock both happen at once', () {
    final _List list = _List(withClock: false);
    list.items.add('last');
    list.state.insertItem(2);
    list._pump();
    expect(list.heights, <double>[20, 20, 20]);
    list.items.removeAt(0);
    list.state.removeItem(
        0, (BuildContext context, Animation<double> a) => const SizedBox());
    list._pump();
    expect(list.heights, <double>[20, 20]);
    list.dispose();
  });

  test('an index past the end is a range error', () {
    final _List list = _List();
    expect(() => list.state.insertItem(5), throwsRangeError);
    list.dispose();
  });
}
