/// A parent that rebuilds must not drag an unchanged child with it, and a
/// render object marked dirty must actually be updated.
///
/// The two are one change and they were found together. `Element.updateChild`
/// had no identity short circuit, so every rebuild cascaded to the whole
/// subtree; that made the cascade the *only* way a render object element ever
/// reached `updateRenderObject`, which in turn hid that
/// `RenderObjectElement.performRebuild` was empty. Adding the short circuit
/// exposed the second bug immediately: an ambient `Directionality` flip marked
/// every dependent `Flex` dirty, the elements rebuilt, and nothing pushed the
/// new direction into the render objects.
///
/// So both halves are pinned here. Removing either one fails a test in this
/// file rather than a test somewhere that happens to count builds.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('a rebuilt parent', () {
    test('does not rebuild a child it did not change', () {
      final host = _Host();
      final counts = _Counts();
      final owner = _mount(_Root(host: host, counts: counts));
      addTearDown(owner.dispose);

      expect(counts.constant, 1);
      expect(counts.varying, 1);

      // A setState on the parent. The varying child is a fresh widget each
      // time; the constant one is the same instance.
      host.bump();
      owner.buildScope();

      expect(counts.varying, 2, reason: 'a changed child rebuilds');
      expect(
        counts.constant,
        1,
        reason: 'an identical child is skipped, which is the whole point',
      );
    });

    test('still rebuilds a child that is dirty for its own reasons', () {
      // The one thing the short circuit must not swallow. The child is const -
      // so `updateChild` skips it - but it marked itself dirty, which puts it
      // in the owner's list independently. Skipping the parent-driven update
      // must not cancel that.
      final host = _Host();
      final counts = _Counts();
      final owner = _mount(_Root(host: host, counts: counts));
      addTearDown(owner.dispose);

      expect(counts.constant, 1);

      _ConstantChildState.instance!.poke();
      host.bump();
      owner.buildScope();

      expect(
        counts.constant,
        2,
        reason: 'its own setState survives the parent skipping it',
      );
    });
  });

  group('a render object element marked dirty', () {
    test('pushes its widget into its render object', () {
      // Directionality registers a dependency, so flipping it marks the Flex
      // dirty without the parent touching the const Row. Before
      // `performRebuild` did anything, the element rebuilt and the render
      // object kept the direction it was born with.
      final host = _Host();
      final owner = _mount(_DirectionRoot(host: host));
      addTearDown(owner.dispose);

      expect(_rowDirection(owner), TextDirection.leftToRight);
      expect(_firstChildLeft(owner), 0);

      host.bump();
      owner.buildScope();
      owner.pipelineOwner.flushLayout();

      expect(_rowDirection(owner), TextDirection.rightToLeft);
      expect(
        _firstChildLeft(owner),
        170,
        reason: 'a direction that reached the render object also moved pixels',
      );
    });
  });
}

BuildOwner _mount(Widget root) {
  final pipeline = PipelineOwner(
    rootConstraints: BoxConstraints.tight(const Size(200, 100)),
  );
  final owner = BuildOwner(pipelineOwner: pipeline)..updateRoot(root);
  pipeline.flushLayout();
  return owner;
}

RenderFlex _flex(BuildOwner owner) {
  final found = <RenderFlex>[];
  void visit(RenderBox node) {
    if (node is RenderFlex) found.add(node);
    node.visitChildren(visit);
  }

  visit(owner.pipelineOwner.root!);
  return found.first;
}

TextDirection? _rowDirection(BuildOwner owner) => _flex(owner).textDirection;

double _firstChildLeft(BuildOwner owner) {
  final children = <RenderBox>[];
  _flex(owner).visitChildren(children.add);
  return children.first.parentData!.offset.dx;
}

/// Something a parent can change without changing its children.
final class _Host extends ValueNotifier<int> {
  _Host() : super(0);

  void bump() => value = value + 1;
}

final class _Counts {
  int constant = 0;
  int varying = 0;
}

final class _Root extends StatefulWidget {
  const _Root({required this.host, required this.counts});

  final _Host host;
  final _Counts counts;

  @override
  State<_Root> createState() => _RootState();
}

final class _RootState extends State<_Root> {
  /// Built once and handed back by every `build`.
  ///
  /// A `const` literal would be tidier and is not available: the widget needs
  /// `widget.counts`, which is not a compile-time constant. Holding the
  /// instance is the same thing the short circuit is written for - what
  /// matters is that the child is *identical* across rebuilds, not how it came
  /// to be.
  late final Widget _constantChild = _ConstantChild(counts: widget.counts);

  @override
  void initState() {
    super.initState();
    widget.host.addListener(_onBump);
  }

  @override
  void dispose() {
    widget.host.removeListener(_onBump);
    super.dispose();
  }

  void _onBump(int _) => setState(() {});

  @override
  Widget build(BuildContext context) => Column(
        children: <Widget>[
          // Rebuilt into a new instance every pass.
          _VaryingChild(counts: widget.counts, generation: widget.host.value),
          // The same instance every pass, by construction.
          _constantChild,
        ],
      );
}

final class _VaryingChild extends StatelessWidget {
  const _VaryingChild({required this.counts, required this.generation});

  final _Counts counts;
  final int generation;

  @override
  Widget build(BuildContext context) {
    counts.varying++;
    return const SizedBox(width: 1, height: 1);
  }
}

final class _ConstantChild extends StatefulWidget {
  const _ConstantChild({required this.counts});

  final _Counts counts;

  @override
  State<_ConstantChild> createState() => _ConstantChildState();
}

final class _ConstantChildState extends State<_ConstantChild> {
  static _ConstantChildState? instance;

  @override
  void initState() {
    super.initState();
    instance = this;
  }

  void poke() => setState(() {});

  @override
  Widget build(BuildContext context) {
    widget.counts.constant++;
    return const SizedBox(width: 1, height: 1);
  }
}

/// A `Directionality` that flips, over a `const` `Row` the parent never
/// changes.
final class _DirectionRoot extends StatefulWidget {
  const _DirectionRoot({required this.host});

  final _Host host;

  @override
  State<_DirectionRoot> createState() => _DirectionRootState();
}

final class _DirectionRootState extends State<_DirectionRoot> {
  @override
  void initState() {
    super.initState();
    widget.host.addListener(_onBump);
  }

  @override
  void dispose() {
    widget.host.removeListener(_onBump);
    super.dispose();
  }

  void _onBump(int _) => setState(() {});

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: widget.host.value.isEven
            ? TextDirection.leftToRight
            : TextDirection.rightToLeft,
        child: const Row(
          children: <Widget>[
            SizedBox(width: 30, height: 10),
            SizedBox(width: 50, height: 10),
          ],
        ),
      );
}
