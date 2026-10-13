/// Flutter's focus traversal groups and policies: a group is visited as one
/// block, in its policy's order.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'input_test_harness.dart';

Widget _box(FocusNode node, {double width = 40, double height = 20}) => Focus(
      focusNode: node,
      child: SizedBox(width: width, height: height),
    );

List<String> _tabRing(InputHarness h, FocusNode first, int count) {
  first.requestFocus();
  final List<String> visited = <String>[
    h.owner.focusManager.primaryFocus!.debugLabel!,
  ];
  for (int i = 1; i < count; i++) {
    h.key(LogicalKeyboardKey.tab);
    visited.add(h.owner.focusManager.primaryFocus!.debugLabel!);
  }
  return visited;
}

void main() {
  test('OrderedTraversalPolicy follows NumericFocusOrder', () {
    final FocusNode a = FocusNode(debugLabel: 'a');
    final FocusNode b = FocusNode(debugLabel: 'b');
    final FocusNode c = FocusNode(debugLabel: 'c');
    final InputHarness h = InputHarness(
      FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Row(children: <Widget>[
          FocusTraversalOrder(
              order: const NumericFocusOrder(3), child: _box(a)),
          FocusTraversalOrder(
              order: const NumericFocusOrder(1), child: _box(b)),
          FocusTraversalOrder(
              order: const NumericFocusOrder(2), child: _box(c)),
        ]),
      ),
      overlay: false,
    );
    expect(_tabRing(h, b, 4), <String>['b', 'c', 'a', 'b']);
    h.dispose();
  });

  test('ReadingOrderTraversalPolicy reads rows, then left to right', () {
    final FocusNode topRight = FocusNode(debugLabel: 'top right');
    final FocusNode topLeft = FocusNode(debugLabel: 'top left');
    final FocusNode bottom = FocusNode(debugLabel: 'bottom');
    final InputHarness h = InputHarness(
      FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Stack(children: <Widget>[
          // Built in an order unlike the reading order.
          Positioned(left: 10, top: 100, child: _box(bottom)),
          Positioned(left: 200, top: 10, child: _box(topRight)),
          Positioned(left: 10, top: 12, child: _box(topLeft)),
        ]),
      ),
      overlay: false,
    );
    expect(_tabRing(h, topLeft, 4),
        <String>['top left', 'top right', 'bottom', 'top left']);
    h.dispose();
  });

  test('a group is visited as one block', () {
    final FocusNode before = FocusNode(debugLabel: 'before');
    final FocusNode g1 = FocusNode(debugLabel: 'g1');
    final FocusNode g2 = FocusNode(debugLabel: 'g2');
    final FocusNode after = FocusNode(debugLabel: 'after');
    final InputHarness h = InputHarness(
      Column(children: <Widget>[
        _box(before),
        FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Row(children: <Widget>[
            FocusTraversalOrder(
                order: const NumericFocusOrder(2), child: _box(g1)),
            FocusTraversalOrder(
                order: const NumericFocusOrder(1), child: _box(g2)),
          ]),
        ),
        _box(after),
      ]),
      overlay: false,
    );
    expect(_tabRing(h, before, 5),
        <String>['before', 'g2', 'g1', 'after', 'before']);
    h.dispose();
  });

  test('inDirection moves to the nearest node on screen', () {
    final FocusNode left = FocusNode(debugLabel: 'left');
    final FocusNode right = FocusNode(debugLabel: 'right');
    final FocusNode below = FocusNode(debugLabel: 'below');
    final InputHarness h = InputHarness(
      Stack(children: <Widget>[
        Positioned(left: 0, top: 0, child: _box(left)),
        Positioned(left: 100, top: 0, child: _box(right)),
        Positioned(left: 0, top: 100, child: _box(below)),
      ]),
      overlay: false,
    );
    final FocusTraversalPolicy policy = ReadingOrderTraversalPolicy();
    left.requestFocus();
    expect(policy.inDirection(left, TraversalDirection.right), isTrue);
    expect(right.hasPrimaryFocus, isTrue);
    expect(policy.inDirection(right, TraversalDirection.down), isTrue);
    expect(below.hasPrimaryFocus, isTrue);
    expect(policy.inDirection(below, TraversalDirection.down), isFalse);
    expect(policy.findFirstFocus(below), isNotNull);
    h.dispose();
  });

  test('descendantsAreTraversable false keeps a group out of the tab ring', () {
    final FocusNode a = FocusNode(debugLabel: 'a');
    final FocusNode hidden = FocusNode(debugLabel: 'hidden');
    final InputHarness h = InputHarness(
      Column(children: <Widget>[
        _box(a),
        FocusTraversalGroup(
          descendantsAreTraversable: false,
          child: _box(hidden),
        ),
      ]),
      overlay: false,
    );
    expect(_tabRing(h, a, 2), <String>['a', 'a']);
    expect(hidden.requestFocus(), isTrue, reason: 'still focusable by code');
    h.dispose();
  });

  test('FocusTraversalGroup.of finds the policy', () {
    FocusTraversalPolicy? found;
    final OrderedTraversalPolicy policy = OrderedTraversalPolicy();
    final InputHarness h = InputHarness(
      FocusTraversalGroup(
        policy: policy,
        child: Builder(builder: (BuildContext context) {
          found = FocusTraversalGroup.of(context);
          return const SizedBox();
        }),
      ),
      overlay: false,
    );
    expect(found, same(policy));
    h.dispose();
  });
}
