/// `LayoutBuilder`, and the two smaller callback widgets next to it.
///
/// The load-bearing tests here are the two about *counting*. A `LayoutBuilder`
/// that runs its callback every frame produces a correct picture and a
/// performance bug: the whole subtree below it is discarded and rebuilt sixty
/// times a second, and nothing on screen says so. So both halves are asserted -
/// it rebuilds when the constraints change, and it does not when layout merely
/// visits it again.
///
/// The other one that cannot be seen in a picture is the `Expanded` case. The
/// child is reconciled from inside `performLayout`, and a parent-data widget's
/// configuration is written only when a build scope settles; skipping that
/// settle leaves the flex factor queued forever and the column silently
/// shrink-wraps.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('LayoutBuilder', () {
    test('the builder is handed the constraints this node was given', () {
      final _Harness harness = _Harness(const Size(120, 80));

      expect(harness.seen, hasLength(1));
      expect(harness.seen.single, BoxConstraints.tight(const Size(120, 80)));
      harness.dispose();
    });

    test('the child it returns is really in the tree', () {
      final _Harness harness = _Harness(const Size(120, 80));

      expect(harness.box.size, const Size(120, 80));
      harness.dispose();
    });

    test('changed constraints rebuild it', () {
      final _Harness harness = _Harness(const Size(120, 80));

      harness.resize(const Size(300, 80));

      expect(harness.seen, hasLength(2));
      expect(harness.seen.last.maxWidth, 300);
      harness.dispose();
    });

    test('layout visiting it again with the same constraints does not', () {
      final _Harness harness = _Harness(const Size(120, 80));

      // The node is dirtied directly, which is what a descendant's relayout
      // does when this node is not a relayout boundary. `performLayout` runs;
      // the callback must not.
      harness.renderObject.markNeedsLayout();
      harness.frame();
      harness.renderObject.markNeedsLayout();
      harness.frame();

      expect(harness.seen, hasLength(1),
          reason: 'two more layout passes, no rebuild: the constraints never '
              'changed and nothing dirtied the element');
      harness.dispose();
    });

    test('the same size handed in twice does not rebuild it either', () {
      final _Harness harness = _Harness(const Size(120, 80))
        ..resize(const Size(120, 80))
        ..frame();

      expect(harness.seen, hasLength(1));
      harness.dispose();
    });

    test('an inherited dependency that changes rebuilds it', () {
      final _Harness harness = _Harness(const Size(120, 80));

      // The LayoutBuilder widget instance is deliberately reused, so the only
      // path left is the dirty mark an InheritedWidget puts on its dependents.
      // Without `performRebuild` invalidating, that mark is cleared and the
      // child keeps the theme it was built with until the window is resized.
      harness.recolour(const Color(0xFFAA0000));

      expect(harness.seen, hasLength(2));
      expect(harness.builtColour, const Color(0xFFAA0000));
      harness.dispose();
    });

    test('a new builder closure rebuilds it', () {
      final _Harness harness = _Harness(const Size(120, 80))..reclose();

      expect(harness.seen, hasLength(2),
          reason: 'a closure is opaque; there is no way to know it would build '
              'the same tree');
      harness.dispose();
    });

    test('an Expanded inside the callback gets its flex factor', () {
      // The case that decided how the build reaches the tree: parent data is
      // written when a build scope settles, and the scope for this subtree only
      // exists because `BuildOwner.buildDuringLayout` opens one. Without it the
      // flex is queued, the column shrink-wraps, and the box is zero high.
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 200)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                const Column(
              children: <Widget>[
                Expanded(child: ColoredBox(color: Color(0xFF001122))),
              ],
            ),
          ),
        );
      pipeline.drawFrame(DisplayList());

      RenderColoredBox? found;
      void walk(RenderBox node) {
        if (node is RenderColoredBox) found = node;
        node.visitChildren(walk);
      }

      walk(owner.renderRoot!);
      expect(found!.size, const Size(100, 200));
      owner.dispose();
    });

    test('a nested LayoutBuilder sees the inner constraints', () {
      final List<BoxConstraints> inner = <BoxConstraints>[];
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 100)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints outer) => Padding(
              padding: const EdgeInsets.all(10),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  inner.add(constraints);
                  return const ColoredBox(color: Color(0xFF334455));
                },
              ),
            ),
          ),
        );
      pipeline.drawFrame(DisplayList());

      expect(inner.single.maxWidth, 180);
      expect(inner.single.maxHeight, 80);
      owner.dispose();
    });

    test('an intrinsic query is a named refusal, not a wrong number', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 100)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          // Under an `Align`, which loosens: a tight width would make
          // IntrinsicWidth skip the query, and the test would pass by never
          // asking the question.
          Align(
            child: IntrinsicWidth(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) =>
                    const ColoredBox(color: Color(0xFF334455)),
              ),
            ),
          ),
        );

      expect(
        () => pipeline.flushLayout(),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('cannot answer an intrinsic query'),
          ),
        ),
      );
      owner.dispose();
    });

    test('removing it unmounts the child it built during layout', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 100)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                const _Disposable(),
          ),
        );
      pipeline.drawFrame(DisplayList());
      expect(_Disposable.live, 1);

      owner.updateRoot(const ColoredBox(color: Color(0xFF000000)));
      pipeline.drawFrame(DisplayList());
      expect(_Disposable.live, 0,
          reason: 'an element built inside layout is an ordinary element and '
              'has to be unmounted like one');
      owner.dispose();
    });
  });

  group('Builder', () {
    test('builds with a context below its own position', () {
      late final ThemeData seen;
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(50, 50)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          Theme(
            data: ThemeData.neutralLight
                .copyWith(border: const Color(0xFF123456)),
            child: Builder(
              builder: (BuildContext context) {
                seen = Theme.of(context);
                return const ColoredBox(color: Color(0xFF000000));
              },
            ),
          ),
        );
      pipeline.drawFrame(DisplayList());

      expect(seen.border, const Color(0xFF123456),
          reason: 'the theme installed immediately above is exactly what a '
              'Builder exists to reach');
      owner.dispose();
    });
  });

  group('StatefulBuilder', () {
    test('its setState rebuilds the fragment and nothing above it', () {
      int outer = 0;
      int inner = 0;
      void Function(void Function())? mutate;
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(50, 50)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          Builder(
            builder: (BuildContext context) {
              outer++;
              return StatefulBuilder(
                builder: (
                  BuildContext context,
                  void Function(void Function()) setState,
                ) {
                  inner++;
                  mutate = setState;
                  return const ColoredBox(color: Color(0xFF000000));
                },
              );
            },
          ),
        );
      pipeline.drawFrame(DisplayList());
      expect(<int>[outer, inner], <int>[1, 1]);

      mutate!(() {});
      owner.buildScope();

      expect(<int>[outer, inner], <int>[1, 2]);
      owner.dispose();
    });
  });
}

/// A leaf that counts how many of itself are mounted, so an unmount is
/// observable without reaching into element internals.
final class _Disposable extends StatefulWidget {
  const _Disposable();

  static int live = 0;

  @override
  State<_Disposable> createState() => _DisposableState();
}

final class _DisposableState extends State<_Disposable> {
  @override
  void initState() {
    super.initState();
    _Disposable.live++;
  }

  @override
  void dispose() {
    _Disposable.live--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0xFF667788));
}

final class _Harness {
  _Harness(Size size) {
    pipeline = PipelineOwner(rootConstraints: BoxConstraints.tight(size));
    owner = BuildOwner(pipelineOwner: pipeline);
    _remakeBuilder();
    _remakeRoot();
    frame();
  }

  late final PipelineOwner pipeline;
  late final BuildOwner owner;

  /// Every set of constraints the callback has actually run under.
  final List<BoxConstraints> seen = <BoxConstraints>[];

  Color _colour = const Color(0xFF00FF00);
  Color? builtColour;

  /// Both widgets are held rather than rebuilt per frame, and that is the whole
  /// point of this harness. `Theme.updateShouldNotify` compares its styles by
  /// identity, so a fresh `Theme` every frame would notify every dependent
  /// every frame - and the two tests that assert *no* rebuild would be
  /// measuring the harness instead of the widget.
  late Widget _layoutBuilder;
  late Widget _root;

  void _remakeBuilder() {
    _layoutBuilder = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        seen.add(constraints);
        builtColour = Theme.of(context).border;
        return const ColoredBox(color: Color(0xFF224466));
      },
    );
  }

  void _remakeRoot() {
    _root = Theme(
      data: ThemeData.neutralLight.copyWith(border: _colour),
      child: _layoutBuilder,
    );
  }

  void frame() {
    owner.updateRoot(_root);
    pipeline.drawFrame(DisplayList());
  }

  void resize(Size size) {
    pipeline.rootConstraints = BoxConstraints.tight(size);
    frame();
  }

  void recolour(Color colour) {
    _colour = colour;
    _remakeRoot();
    frame();
  }

  /// Replaces the builder closure without changing anything else about it.
  void reclose() {
    _remakeBuilder();
    _remakeRoot();
    frame();
  }

  RenderLayoutBuilder get renderObject =>
      owner.renderRoot! as RenderLayoutBuilder;

  RenderColoredBox get box => renderObject.child! as RenderColoredBox;

  void dispose() => owner.dispose();
}
