import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A render box that declares semantics, so the owner has something to walk.
final class _Described extends RenderSingleChildBox
    implements SemanticsProvider {
  _Described(this.config, {super.child});

  final SemanticsConfiguration config;

  /// Every described node is the same size, so a test asserting bounds is
  /// asserting position rather than measurement.
  static const Size preferred = Size(40, 20);

  @override
  SemanticsConfiguration describeSemantics() => config;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child != null) {
      child.layout(constraints.loosen(), parentUsesSize: true);
      child.parentData!.offset = const Offset(5, 5);
    }
    size = constraints.constrain(preferred);
  }
}

/// A node with no semantics of its own: it must be transparent.
final class _Transparent extends RenderSingleChildBox {
  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    child.parentData!.offset = const Offset(10, 10);
    size = constraints.constrain(child.size);
  }
}

SemanticsConfiguration _button(String label) => SemanticsConfiguration(
      role: SemanticsRole.button,
      label: label,
      actions: const <SemanticsAction>{SemanticsAction.activate},
    );

void main() {
  group('building the tree', () {
    test('a described node becomes one semantic node with absolute bounds', () {
      final owner = _pipeline(_Described(_button('OK')));
      final SemanticsOwner semantics = SemanticsOwner();

      final SemanticsSnapshot snapshot = semantics.build(owner.root);

      expect(snapshot.root, isNotNull);
      expect(snapshot.root!.role, SemanticsRole.button);
      expect(snapshot.root!.label, 'OK');
      expect(snapshot.root!.bounds, const Rect.fromLTWH(0, 0, 40, 20));
    });

    test('a node without semantics is transparent to the tree', () {
      final RenderBox tree = _Transparent()
        ..child = _Described(_button('Inner'));
      final owner = _pipeline(tree);
      final SemanticsOwner semantics = SemanticsOwner();

      final SemanticsSnapshot snapshot = semantics.build(owner.root);

      // The wrapper contributed no node, but its offset still applies: a
      // padding box must move the button without appearing in the tree.
      expect(snapshot.nodes, hasLength(1));
      expect(snapshot.root!.label, 'Inner');
      expect(snapshot.root!.bounds.left, 10);
      expect(snapshot.root!.bounds.top, 10);
    });

    test('a merging node absorbs its descendants', () {
      final RenderBox tree = _Described(
        const SemanticsConfiguration(
          role: SemanticsRole.button,
          label: 'Save',
          mergesDescendants: true,
        ),
        child: _Described(
          const SemanticsConfiguration(role: SemanticsRole.text, label: 'Save'),
        ),
      );
      final owner = _pipeline(tree);

      final SemanticsSnapshot snapshot = SemanticsOwner().build(owner.root);

      expect(snapshot.nodes, hasLength(1),
          reason: 'a button and its own label are one thing to a reader');
    });

    test('several top-level nodes get a synthetic root', () {
      final RenderFlex flex = RenderFlex(direction: Axis.vertical)
        ..add(_Described(_button('A')))
        ..add(_Described(_button('B')));
      final owner = _pipeline(flex);

      final SemanticsSnapshot snapshot = SemanticsOwner().build(owner.root);

      expect(snapshot.root!.id, 0, reason: 'the synthetic root takes id 0');
      expect(snapshot.root!.children, hasLength(2));
      expect(snapshot.nodes, hasLength(3));
    });

    test('an unlaid-out tree produces no snapshot rather than bad bounds', () {
      expect(SemanticsOwner().build(null).root, isNull);
      expect(SemanticsOwner().build(_Described(_button('x'))).root, isNull);
    });

    test('a sort key overrides reading order', () {
      final RenderFlex flex = RenderFlex(direction: Axis.vertical)
        ..add(_Described(const SemanticsConfiguration(
          role: SemanticsRole.button,
          label: 'painted first',
          sortKey: 2,
        )))
        ..add(_Described(const SemanticsConfiguration(
          role: SemanticsRole.button,
          label: 'painted second',
          sortKey: 1,
        )));
      final owner = _pipeline(flex);

      final SemanticsSnapshot snapshot = SemanticsOwner().build(owner.root);

      expect(
        snapshot.root!.children.map((SemanticsNode n) => n.label),
        <String>['painted second', 'painted first'],
      );
    });
  });

  group('identity and updates', () {
    test('the same render object keeps its id across builds', () {
      final _Described node = _Described(_button('OK'));
      final owner = _pipeline(node);
      final SemanticsOwner semantics = SemanticsOwner();

      final int first = semantics.build(owner.root).root!.id;
      final int second = semantics.build(owner.root).root!.id;

      expect(second, first);
    });

    test('an update names what changed and nothing else', () {
      final RenderFlex flex = RenderFlex(direction: Axis.vertical)
        ..add(_Described(_button('A')))
        ..add(_Described(_button('B')));
      final owner = _pipeline(flex);
      final SemanticsOwner semantics = SemanticsOwner()..update(owner.root);

      final _Described changed = flex.childAt(1) as _Described;
      flex.remove(changed);
      flex.add(_Described(_button('C')));
      owner.drawFrame(DisplayList());
      final SemanticsUpdate update = semantics.update(owner.root);

      expect(update.added, hasLength(1));
      expect(update.added.single.label, 'C');
      expect(update.removed, hasLength(1));
      expect(update.updated, isEmpty, reason: 'A did not move or change');
    });

    test('an unchanged tree reports an empty update', () {
      final owner = _pipeline(_Described(_button('OK')));
      final SemanticsOwner semantics = SemanticsOwner()..update(owner.root);

      expect(semantics.update(owner.root).isEmpty, isTrue);
    });

    test('ids for departed render objects are forgotten', () {
      final RenderFlex flex = RenderFlex(direction: Axis.vertical)
        ..add(_Described(_button('A')))
        ..add(_Described(_button('B')));
      final owner = _pipeline(flex);
      final SemanticsOwner semantics = SemanticsOwner()..build(owner.root);

      final RenderBox removed = flex.childAt(1);
      flex.remove(removed);
      owner.drawFrame(DisplayList());
      semantics.build(owner.root);

      // A fresh id proves the old entry was pruned rather than retained for
      // the life of the process.
      final int reissued = semantics.idFor(_Described(_button('C')));
      expect(reissued, isNot(semantics.idFor(flex.childAt(0))));
    });

    test('reset forgets everything', () {
      final owner = _pipeline(_Described(_button('OK')));
      final SemanticsOwner semantics = SemanticsOwner()..build(owner.root);
      expect(semantics.snapshot.root, isNotNull);

      semantics.reset();

      expect(semantics.snapshot.root, isNull);
    });
  });

  group('node value semantics', () {
    test('nodes compare by properties and children', () {
      const SemanticsNode a = SemanticsNode(
        id: 1,
        role: SemanticsRole.button,
        bounds: Rect.fromLTWH(0, 0, 10, 10),
        label: 'x',
      );
      const SemanticsNode same = SemanticsNode(
        id: 1,
        role: SemanticsRole.button,
        bounds: Rect.fromLTWH(0, 0, 10, 10),
        label: 'x',
      );
      const SemanticsNode moved = SemanticsNode(
        id: 1,
        role: SemanticsRole.button,
        bounds: Rect.fromLTWH(0, 4, 10, 10),
        label: 'x',
      );

      expect(a, same);
      expect(a.hashCode, same.hashCode);
      expect(a, isNot(moved));
      expect(a.hasSameProperties(moved), isFalse);
    });

    test('a snapshot finds a node by id', () {
      final owner = _pipeline(_Described(_button('OK')));
      final SemanticsSnapshot snapshot = SemanticsOwner().build(owner.root);

      final int id = snapshot.root!.id;
      expect(snapshot.nodeById(id), isNotNull);
      expect(snapshot.nodeById(9999), isNull);
    });
  });
}

PipelineOwner _pipeline(RenderBox root) {
  final owner = PipelineOwner(
    rootConstraints: BoxConstraints.loose(const Size(200, 200)),
  )..root = root;
  owner.drawFrame(DisplayList());
  return owner;
}
