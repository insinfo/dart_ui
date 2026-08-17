import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  // Anything that measures or draws text needs a known face; the machine's own
  // UI font would make these assertions mean something different per platform.
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('widget/render integration', () {
    test('mounts a real RenderBox tree under a stable pipeline root', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(20, 10)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);
      final RenderBox stableRoot = pipeline.root!;

      owner.updateRoot(
        const ColoredBox(
          color: Color(0xFF112233),
          child: ColoredBox(color: Color(0xFF445566)),
        ),
      );

      final RenderBox outer = owner.renderRoot!;
      expect(outer, isA<RenderColoredBox>());
      expect(outer.parent, same(stableRoot));
      expect(outer.owner, same(pipeline));
      expect((outer as RenderSingleChildBox).child, isA<RenderColoredBox>());

      final DisplayList displayList = DisplayList();
      pipeline.drawFrame(displayList);
      expect(displayList.commandCount, 2);
      expect(displayList.paintCount, 2);
    });

    test('padding widget drives the existing layout and paint pipeline',
        () async {
      final BuildOwner owner = _owner();
      owner.updateRoot(
        const ColoredBox(
          color: Color(0xFF000000),
          child: Padding(
            padding: EdgeInsets.all(4),
            child: ColoredBox(color: Color(0xFFFFFFFF)),
          ),
        ),
      );

      final DisplayList displayList = DisplayList();
      owner.pipelineOwner.drawFrame(displayList);
      final MemoryRenderTarget target = MemoryRenderTarget(
        const MemorySurfaceDescriptor(pixelWidth: 20, pixelHeight: 10),
      );
      await target.renderDisplayList(displayList, clearColor: 0);

      expect(target.framebuffer.pixels[target.framebuffer.offsetOf(2, 5)], 0);
      expect(
        target.framebuffer.pixels[target.framebuffer.offsetOf(5, 5)],
        255,
      );
      target.dispose();
    });

    test('align widget positions its child and updates in place', () {
      final BuildOwner owner = _owner();
      final Element root = owner.updateRoot(
        const Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          ),
        ),
      )!;
      final RenderAlign render =
          (root as RenderObjectElement).renderObject as RenderAlign;

      owner.pipelineOwner.flushLayout();

      expect(render.size, const Size(20, 10));
      expect(render.child!.size, const Size(4, 2));
      expect(render.child!.offsetFromParent, const Offset(16, 8));

      owner.updateRoot(
        const Align(
          alignment: Alignment.topLeft,
          widthFactor: 2,
          heightFactor: 3,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          ),
        ),
      );
      owner.pipelineOwner.flushLayout();

      expect(owner.rootElement, same(root));
      expect(owner.renderRoot, same(render));
      expect(render.alignment, Alignment.topLeft);
      expect(render.widthFactor, 2);
      expect(render.heightFactor, 3);
      expect(render.child!.offsetFromParent, Offset.zero);
    });

    test('same type and key preserve elements and render objects', () {
      final BuildOwner owner = _owner();
      final Element root = owner.updateRoot(
        const ColoredBox(
          key: ValueKey<String>('outer'),
          color: Color(0xFF000001),
          child: ColoredBox(
            key: ValueKey<String>('inner'),
            color: Color(0xFF000002),
          ),
        ),
      )!;
      final Element child = _onlyChild(root);
      final RenderBox rootRender = (root as RenderObjectElement).renderObject;
      final RenderBox childRender = (child as RenderObjectElement).renderObject;

      owner.updateRoot(
        const ColoredBox(
          key: ValueKey<String>('outer'),
          color: Color(0xFF000003),
          child: ColoredBox(
            key: ValueKey<String>('inner'),
            color: Color(0xFF000004),
          ),
        ),
      );

      expect(owner.rootElement, same(root));
      expect(_onlyChild(root), same(child));
      expect(owner.renderRoot, same(rootRender));
      expect((rootRender as RenderSingleChildBox).child, same(childRender));
      expect((rootRender as RenderColoredBox).color, const Color(0xFF000003));
      expect((childRender as RenderColoredBox).color, const Color(0xFF000004));
    });

    test('a changed key replaces and fully detaches the old subtree', () {
      final BuildOwner owner = _owner();
      final Element root = owner.updateRoot(
        const ColoredBox(
          color: Color(1),
          child: ColoredBox(key: ValueKey<int>(1), color: Color(2)),
        ),
      )!;
      final Element oldChild = _onlyChild(root);
      final RenderBox oldRender =
          (oldChild as RenderObjectElement).renderObject;

      owner.updateRoot(
        const ColoredBox(
          color: Color(1),
          child: ColoredBox(key: ValueKey<int>(2), color: Color(3)),
        ),
      );

      final Element newChild = _onlyChild(root);
      final RenderBox newRender =
          (newChild as RenderObjectElement).renderObject;
      expect(newChild, isNot(same(oldChild)));
      expect(oldChild.lifecycle, ElementLifecycle.defunct);
      expect(oldRender.parent, isNull);
      expect(oldRender.owner, isNull);
      expect(newRender.parent, same(owner.renderRoot));
      expect(newRender.owner, same(owner.pipelineOwner));
    });

    test('component widgets are transparent to render-tree wiring', () {
      final BuildOwner owner = _owner();
      owner.updateRoot(
        const ColoredBox(
          color: Color(1),
          child: _Passthrough(
            child: ColoredBox(color: Color(2)),
          ),
        ),
      );

      final RenderSingleChildBox root =
          owner.renderRoot! as RenderSingleChildBox;
      expect(root.child, isA<RenderColoredBox>());
      expect(root.child!.parent, same(root));
    });

    test('changing the first render widget keeps the pipeline host stable', () {
      final BuildOwner owner = _owner();
      final _SwitchingWidget widget = _SwitchingWidget();
      owner.updateRoot(widget);
      final RenderBox pipelineRoot = owner.pipelineOwner.root!;
      final RenderBox oldRender = owner.renderRoot!;

      widget.state!.showText();
      owner.buildScope();

      expect(owner.pipelineOwner.root, same(pipelineRoot));
      expect(owner.renderRoot, isA<RenderText>());
      expect(owner.renderRoot, isNot(same(oldRender)));
      expect(oldRender.parent, isNull);
      expect(oldRender.owner, isNull);
    });

    test('text shapes one run and draws the glyphs it measured', () {
      final BuildOwner owner = _owner();
      owner.updateRoot(const Text('TEXT'));

      final list = DisplayList();
      owner.pipelineOwner.drawFrame(list);

      // One run for four characters, and the ids in it are the ones the shaper
      // produces for the same string in the same face - which is what fails if
      // layout and paint ever stop going through the same font.
      final ScaledTypeface font = FontRegistry.instance.uiFont(12)!;
      final GlyphRun expected = LatinShaper().shape('TEXT', font);
      final reader = DisplayListReader(list);
      final List<List<int>> runs = <List<int>>[];
      while (reader.moveNext()) {
        if (reader.opcode != opDrawGlyphRun) continue;
        final int count = reader.intAt(2);
        runs.add(<int>[for (int i = 0; i < count; i++) reader.intAt(3 + i)]);
      }

      expect(runs, hasLength(1));
      expect(runs.single, <int>[
        for (int i = 0; i < expected.length; i++) expected.glyphIds[i],
      ]);
      // Tight 20x10 constraints, so the box is the constraint and not the text.
      expect(owner.renderRoot!.size.width, 20);
    });

    test('text with no font reserves its box and draws nothing', () {
      final FontRegistry installed = FontRegistry.instance;
      FontRegistry.instance = FontRegistry(search: () => null);
      addTearDown(() => FontRegistry.instance = installed);

      final BuildOwner owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints(maxWidth: 200, maxHeight: 50),
        ),
      );
      owner.updateRoot(const Text('TEXT'));
      final list = DisplayList();
      owner.pipelineOwner.drawFrame(list);

      // The failure this guards against is a machine with no usable font
      // collapsing every text node to nothing, which reflows the whole tree
      // and looks like a layout bug rather than a missing font.
      expect(owner.renderRoot!.size.width, greaterThan(0));
      expect(owner.renderRoot!.size.height, greaterThan(0));
      expect(list.commandCount, 0);
      owner.dispose();
    });

    test('gesture callbacks mount a render-tree pointer target', () {
      final BuildOwner owner = _owner();

      owner.updateRoot(
        GestureDetector(
          onTap: () {},
          child: const ColoredBox(color: Color(1)),
        ),
      );

      expect(owner.renderRoot, isA<RenderGestureDetector>());
      expect(
        (owner.renderRoot as RenderSingleChildBox).child,
        isA<RenderColoredBox>(),
      );
    });

    test('Button paints its label and routes a click through Dart widgets', () {
      var clicks = 0;
      final BuildOwner owner = _owner();
      owner.updateRoot(Button(label: 'OK', onPressed: () => clicks++));

      final list = DisplayList();
      owner.pipelineOwner.drawFrame(list);
      expect(list.commandCount, greaterThan(0));

      const windowId = NativeWindowId(1);
      const down = PointerDownEvent(
        windowId: windowId,
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: Offset(2, 2),
        button: PointerButton.primary,
      );
      const up = PointerUpEvent(
        windowId: windowId,
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: Offset(2, 2),
        button: PointerButton.primary,
      );
      expect(owner.dispatchPointerEvent(down), isTrue);
      expect(owner.dispatchPointerEvent(up), isTrue);
      expect(clicks, 1);
    });
  });

  group('BuildOwner and State lifecycle', () {
    test('coalesces setState and rebuilds only when buildScope runs', () {
      int scheduled = 0;
      final BuildOwner owner = _owner(onBuildScheduled: () => scheduled++);
      final _CounterWidget widget = _CounterWidget();
      owner.updateRoot(widget);
      final _CounterState state = widget.state!;
      expect(state.buildCount, 1);
      scheduled = 0;

      state.increment();
      state.increment();

      expect(state.value, 2);
      expect(state.buildCount, 1);
      expect(owner.hasScheduledBuilds, isTrue);
      expect(scheduled, 1);
      owner.buildScope();
      expect(state.buildCount, 2);
      expect(owner.hasScheduledBuilds, isFalse);
    });

    test('dirty elements rebuild shallowest first', () {
      final List<String> builds = <String>[];
      final _NestedWidget rootWidget = _NestedWidget(builds);
      final BuildOwner owner = _owner();
      owner.updateRoot(rootWidget);
      builds.clear();

      rootWidget.childState!.touch();
      rootWidget.state!.touch();
      owner.buildScope();

      expect(builds, <String>['parent', 'child']);
    });

    test('update and dispose run once and setState after dispose throws', () {
      final List<String> lifecycle = <String>[];
      final BuildOwner owner = _owner();
      final _LifecycleWidget first = _LifecycleWidget('first', lifecycle);
      owner.updateRoot(first);
      final _LifecycleState state = first.state!;

      final _LifecycleWidget second = _LifecycleWidget('second', lifecycle);
      owner.updateRoot(second);
      owner.updateRoot(null);

      expect(
        lifecycle,
        <String>[
          'init:first',
          'build:first',
          'update:first->second',
          'build:second',
          'dispose:second',
        ],
      );
      expect(state.mounted, isFalse);
      expect(state.disposeSetStateError, isA<StateError>());
      bool mutated = false;
      expect(
        () => state.setState(() => mutated = true),
        throwsStateError,
      );
      expect(mutated, isFalse);
      expect(() => state.context, throwsStateError);
      expect(() => state.widget, throwsStateError);
    });

    test('disposing BuildOwner tears down both trees idempotently', () {
      final BuildOwner owner = _owner();
      owner.updateRoot(const ColoredBox(color: Color(1)));
      final Element element = owner.rootElement!;
      final RenderBox render = owner.renderRoot!;

      owner.dispose();
      owner.dispose();

      expect(element.lifecycle, ElementLifecycle.defunct);
      expect(render.parent, isNull);
      expect(render.owner, isNull);
      expect(owner.pipelineOwner.root, isNull);
      expect(
        () => owner.updateRoot(const ColoredBox(color: Color(2))),
        throwsStateError,
      );
    });
  });
}

BuildOwner _owner({void Function()? onBuildScheduled}) => BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(20, 10)),
      ),
      onBuildScheduled: onBuildScheduled,
    );

Element _onlyChild(Element element) {
  Element? result;
  element.visitChildren((Element child) => result = child);
  return result!;
}

final class _Passthrough extends StatelessWidget {
  const _Passthrough({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

final class _CounterWidget extends StatefulWidget {
  _CounterState? state;

  @override
  _CounterState createState() => state = _CounterState();
}

final class _CounterState extends State<_CounterWidget> {
  int value = 0;
  int buildCount = 0;

  void increment() => setState(() => value++);

  @override
  Widget build(BuildContext context) {
    buildCount++;
    return ColoredBox(color: Color(value));
  }
}

final class _SwitchingWidget extends StatefulWidget {
  _SwitchingState? state;

  @override
  _SwitchingState createState() => state = _SwitchingState();
}

final class _SwitchingState extends State<_SwitchingWidget> {
  bool text = false;

  void showText() => setState(() => text = true);

  @override
  Widget build(BuildContext context) =>
      text ? const Text('now text') : const ColoredBox(color: Color(1));
}

final class _NestedWidget extends StatefulWidget {
  _NestedWidget(this.builds);

  final List<String> builds;
  _NestedState? state;
  _NestedChildState? childState;

  @override
  _NestedState createState() => state = _NestedState('parent');
}

final class _NestedState extends State<_NestedWidget> {
  _NestedState(this.name);

  final String name;

  void touch() => setState(() {});

  @override
  Widget build(BuildContext context) {
    widget.builds.add(name);
    return _NestedChild(widget);
  }
}

final class _NestedChild extends StatefulWidget {
  const _NestedChild(this.owner);

  final _NestedWidget owner;

  @override
  _NestedChildState createState() => owner.childState = _NestedChildState();
}

final class _NestedChildState extends State<_NestedChild> {
  void touch() => setState(() {});

  @override
  Widget build(BuildContext context) {
    widget.owner.builds.add('child');
    return const ColoredBox(color: Color(1));
  }
}

final class _LifecycleWidget extends StatefulWidget {
  _LifecycleWidget(this.label, this.log);

  final String label;
  final List<String> log;
  _LifecycleState? state;

  @override
  _LifecycleState createState() => state = _LifecycleState();
}

final class _LifecycleState extends State<_LifecycleWidget> {
  Object? disposeSetStateError;

  @override
  void initState() => widget.log.add('init:${widget.label}');

  @override
  void didUpdateWidget(covariant _LifecycleWidget oldWidget) {
    widget.log.add('update:${oldWidget.label}->${widget.label}');
  }

  @override
  Widget build(BuildContext context) {
    widget.log.add('build:${widget.label}');
    return const ColoredBox(color: Color(1));
  }

  @override
  void dispose() {
    try {
      setState(() {});
    } on Object catch (error) {
      disposeSetStateError = error;
    }
    widget.log.add('dispose:${widget.label}');
  }
}
