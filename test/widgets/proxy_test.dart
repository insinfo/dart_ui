/// The widget faces of the proxy render nodes.
///
/// The nodes themselves are tested in `test/layout/render_proxy_box_test.dart`,
/// which is where the exact composite values, the inverse-transform arithmetic
/// and the corner geometry live. What is asserted here is the part only the
/// widget layer can be wrong about: that the spelling reaches the node with the
/// configuration it was given, that an update reconfigures the *same* node
/// rather than quietly replacing it, and that the effects still hold when they
/// are stacked on top of each other through a real element tree and a real
/// frame.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/layout/render_proxy_box.dart' as layout;
import 'package:dart_ui/src/widgets/proxy.dart';
import 'package:test/test.dart';

// `pixelAt` and `memoryTarget` rather than a second copy of each here: a test
// helper that reads a framebuffer in two places is a test helper that can
// disagree with itself about channel order.
import '../layout/helpers.dart';

const int _background = 0xFF204060;
const int _content = 0xFFCC3311;

const (int, int, int, int) _backgroundPixel = (0x20, 0x40, 0x60, 0xFF);
const (int, int, int, int) _contentPixel = (0xCC, 0x33, 0x11, 0xFF);

void main() {
  (BuildOwner, PipelineOwner) mounted(Widget root, Size viewport) {
    final PipelineOwner pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(viewport),
    );
    final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
      ..updateRoot(root);
    pipeline.flushLayout();
    return (owner, pipeline);
  }

  /// One whole frame of [root] on a [side]-square surface over [_background].
  Future<Framebuffer> frame(Widget root, {int side = 32}) async {
    final PipelineOwner pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(
        Size(side.toDouble(), side.toDouble()),
      ),
    );
    BuildOwner(pipelineOwner: pipeline).updateRoot(root);
    final DisplayList list = DisplayList();
    pipeline.drawFrame(list);

    final MemoryRenderTarget target = await memoryTarget(side, side);
    addTearDown(target.dispose);
    await target.renderDisplayList(list, clearColor: _background);
    return target.framebuffer;
  }

  List<DisplayListCommand> commandsFor(Widget root, {int side = 32}) {
    final PipelineOwner pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(
        Size(side.toDouble(), side.toDouble()),
      ),
    );
    BuildOwner(pipelineOwner: pipeline).updateRoot(root);
    final DisplayList list = DisplayList();
    pipeline.drawFrame(list);
    return expandDisplayList(list);
  }

  group('Opacity', () {
    test('composites a whole frame to the exact half-opacity value', () async {
      final Framebuffer buffer = await frame(
        const Opacity(opacity: 0.5, child: ColoredBox(color: _content)),
        side: 16,
      );

      // The same arithmetic the render test derives by hand, reached this time
      // through an element tree and PipelineOwner.drawFrame rather than by
      // calling paint directly.
      expect(pixelAt(buffer, 8, 8), (118, 58, 57, 0xFF));
    });

    test('at 1 no layer is pushed anywhere in the frame', () {
      final List<DisplayListCommand> commands = commandsFor(
        const Opacity(opacity: 1.0, child: ColoredBox(color: _content)),
        side: 16,
      );

      expect(commands.whereType<SaveLayerCommand>(), isEmpty);
      expect(commands.whereType<DrawRectCommand>(), hasLength(1));
    });

    test('at 0 the box still occupies its space and still takes the hit', () {
      final (BuildOwner owner, _) = mounted(
        const Opacity(opacity: 0.0, child: ColoredBox(color: _content)),
        const Size(16, 16),
      );

      final RenderBox root = owner.renderRoot!;
      expect(root.size, const Size(16, 16));
      expect(root.hitTest(const Offset(8, 8)), isNotNull,
          reason: 'a fade must not change what is clickable partway through');
    });

    test('an update reconfigures the same render node', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(16, 16)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          const Opacity(opacity: 1.0, child: ColoredBox(color: _content)),
        );
      pipeline.flushLayout();
      final layout.RenderOpacity node =
          owner.renderRoot! as layout.RenderOpacity;

      owner.updateRoot(
        const Opacity(opacity: 0.25, child: ColoredBox(color: _content)),
      );
      pipeline.flushLayout();

      expect(owner.renderRoot, same(node), reason: 'reconciled, not replaced');
      expect(node.opacity, 0.25);
      expect(node.alpha, 64);
    });
  });

  group('Transform', () {
    test('rotate turns about the centre, which moves what is clickable', () {
      // A horizontal bar across the middle of a 20x20 box. Turned a quarter
      // turn it becomes a vertical bar, so the two probe points swap: the one
      // above the bar starts missing and ends hitting, and vice versa.
      Widget tree({required bool rotated}) {
        const Widget bar = Center(
          child: SizedBox(
            width: 20,
            height: 4,
            child: ColoredBox(color: _content),
          ),
        );
        return rotated ? Transform.rotate(angle: math.pi / 2, child: bar) : bar;
      }

      final (BuildOwner plain, _) = mounted(
        tree(rotated: false),
        const Size(20, 20),
      );
      expect(plain.renderRoot!.hitTest(const Offset(2, 10)), isNotNull);
      expect(plain.renderRoot!.hitTest(const Offset(10, 2)), isNull);

      final (BuildOwner turned, _) = mounted(
        tree(rotated: true),
        const Size(20, 20),
      );
      expect(turned.renderRoot!.hitTest(const Offset(10, 2)), isNotNull,
          reason: 'the bar is vertical now, so the top of the box is on it');
      expect(turned.renderRoot!.hitTest(const Offset(2, 10)), isNull,
          reason: 'and the left edge no longer is');
    });

    test('rotate does not change the space the widget takes', () {
      final (BuildOwner owner, _) = mounted(
        Transform.rotate(
          angle: math.pi / 4,
          child: const ColoredBox(color: _content),
        ),
        const Size(20, 20),
      );

      expect(owner.renderRoot!.size, const Size(20, 20),
          reason: 'a paint-time transform never reflows a row');
    });

    test('translate moves the pixels and folds into the offset', () async {
      // Not const: the factories compute a matrix from their arguments, which
      // a const initializer cannot do.
      Widget tree() => Center(
            child: SizedBox(
              width: 8,
              height: 8,
              child: Transform.translate(
                offset: const Offset(8, 0),
                child: const ColoredBox(color: _content),
              ),
            ),
          );

      final Framebuffer buffer = await frame(tree(), side: 32);

      // The 8x8 box is centred at (12..20, 12..20) and then moved 8 to the
      // right, so the ink is at (20..28, 12..20).
      expect(pixelAt(buffer, 24, 16), _contentPixel);
      expect(pixelAt(buffer, 16, 16), _backgroundPixel);

      expect(
        commandsFor(tree()).whereType<TransformCommand>(),
        isEmpty,
        reason: 'a translation needs no matrix in the stream',
      );
    });

    test('scale refuses ambiguous arguments', () {
      expect(
        () => Transform.scale(scale: 2, scaleX: 3),
        throwsArgumentError,
        reason: 'two sources for one axis is a silent winner',
      );
      expect(() => Transform.scale(), throwsArgumentError);
      expect(
          Transform.scale(scale: 2).transform, const Transform2D.scaling(2, 2));
      expect(Transform.scale(scaleX: 2).transform,
          const Transform2D.scaling(2, 1));
    });

    test('a zero scale paints nothing and refuses the hit', () async {
      final (BuildOwner owner, _) = mounted(
        Transform.scale(scale: 0, child: const ColoredBox(color: _content)),
        const Size(16, 16),
      );
      expect(owner.renderRoot!.hitTest(const Offset(8, 8)), isNull);

      final Framebuffer buffer = await frame(
        Transform.scale(scale: 0, child: const ColoredBox(color: _content)),
        side: 16,
      );
      expect(pixelAt(buffer, 8, 8), _backgroundPixel);
    });

    test('an update reconfigures the same render node', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(16, 16)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          const Transform(
            transform: Transform2D.identity,
            child: ColoredBox(color: _content),
          ),
        );
      pipeline.flushLayout();
      final layout.RenderTransform node =
          owner.renderRoot! as layout.RenderTransform;

      owner.updateRoot(
        const Transform(
          transform: Transform2D.translation(4, 4),
          alignment: Alignment.center,
          transformHitTests: false,
          child: ColoredBox(color: _content),
        ),
      );
      pipeline.flushLayout();

      expect(owner.renderRoot, same(node));
      expect(node.transform, const Transform2D.translation(4, 4));
      expect(node.alignment, Alignment.center);
      expect(node.transformHitTests, isFalse);
    });
  });

  group('ClipRect', () {
    test('cuts a child that its sibling transform pushed out of the box',
        () async {
      // Three of these widgets at once, because the interesting failure is at
      // the join: the clip has to be applied in the same device space the
      // transform already moved the child into.
      final Widget tree = Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: ClipRect(
            child: Transform.translate(
              offset: const Offset(8, 0),
              child: const ColoredBox(color: _content),
            ),
          ),
        ),
      );

      final Framebuffer buffer = await frame(tree, side: 32);

      // The clip is the 16x16 box at (8..24, 8..24). Its child is moved 8 to
      // the right, so it inks (16..32, 8..24) and the clip keeps (16..24).
      expect(pixelAt(buffer, 20, 12), _contentPixel);
      expect(pixelAt(buffer, 26, 12), _backgroundPixel, reason: 'clipped');
      expect(pixelAt(buffer, 12, 12), _backgroundPixel, reason: 'moved away');
    });

    test('and refuses a pointer everywhere it refused a pixel', () {
      final (BuildOwner owner, _) = mounted(
        const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: ClipRect(child: ColoredBox(color: _content)),
          ),
        ),
        const Size(32, 32),
      );

      final RenderBox root = owner.renderRoot!;
      expect(root.hitTest(const Offset(16, 16)), isNotNull);
      expect(root.hitTest(const Offset(25, 16)), isNull);
    });
  });

  group('ClipRRect', () {
    test('reaches the node with its radius and rounds the hit region', () {
      final (BuildOwner owner, _) = mounted(
        const ClipRRect(radius: 6, child: ColoredBox(color: _content)),
        const Size(20, 20),
      );

      final layout.RenderClipRRect node =
          owner.renderRoot! as layout.RenderClipRRect;
      expect(node.radius, 6);
      expect(node.hitTest(const Offset(10, 0.5)), isNotNull);
      expect(node.hitTest(const Offset(0.5, 0.5)), isNull, reason: 'corner');
    });

    test('DECLARED ABSENT: no path clip is emitted, so paint stays square', () {
      // The widget layer inherits the gap the node documents: `opClipPath` has
      // no rasterizer, so this emits a rectangle. Asserted here as well as on
      // the node so that a reader who only opens the widget test still finds
      // out.
      final List<DisplayListCommand> commands = commandsFor(
        const ClipRRect(radius: 8, child: ColoredBox(color: _content)),
        side: 16,
      );

      expect(commands.whereType<ClipPathCommand>(), isEmpty);
      expect(commands.whereType<ClipRectCommand>(), hasLength(1));
    });
  });

  group('DecoratedBox', () {
    test('paints a rounded, bordered card behind its child', () async {
      final Framebuffer buffer = await frame(
        const DecoratedBox(
          decoration: BoxDecoration(
            color: 0xFF3366CC,
            border: BoxBorder(color: _content, width: 2),
          ),
          child: SizedBox(width: 16, height: 16),
        ),
        side: 16,
      );

      expect(pixelAt(buffer, 8, 1), _contentPixel, reason: 'the border');
      expect(pixelAt(buffer, 8, 8), (0x33, 0x66, 0xCC, 0xFF));
    });

    test('carries the decoration through an update without replacing the node',
        () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(16, 16)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          const DecoratedBox(decoration: BoxDecoration(color: _content)),
        );
      pipeline.flushLayout();
      final layout.RenderDecoratedBox node =
          owner.renderRoot! as layout.RenderDecoratedBox;

      owner.updateRoot(
        const DecoratedBox(
          decoration: BoxDecoration(color: 0xFF00FF00, radius: 4),
        ),
      );
      pipeline.flushLayout();

      expect(owner.renderRoot, same(node));
      expect(node.decoration.color, 0xFF00FF00);
      expect(node.decoration.radius, 4);
    });

    test('an equal decoration is not a change', () {
      const BoxDecoration a = BoxDecoration(
        color: _content,
        border: BoxBorder(color: 0xFF000000, width: 1),
        radius: 3,
      );
      const BoxDecoration b = BoxDecoration(
        color: _content,
        border: BoxBorder(color: 0xFF000000, width: 1),
        radius: 3,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(const BoxDecoration().isEmpty, isTrue);
    });
  });

  group('Center', () {
    test('fills the viewport and centres its child in it', () {
      final (BuildOwner owner, _) = mounted(
        const Center(
          child: SizedBox(
            width: 10,
            height: 6,
            child: ColoredBox(color: _content),
          ),
        ),
        const Size(30, 20),
      );

      final RenderBox root = owner.renderRoot!;
      expect(root.size, const Size(30, 20));
      final RenderBox child = (root as RenderSingleChildBox).child!;
      expect(child.size, const Size(10, 6));
      expect(child.offsetFromParent, const Offset(10, 7));
    });
  });

  group('IgnorePointer and AbsorbPointer in a real Stack', () {
    /// A stack of two full-size coloured boxes, the front one wrapped by
    /// [wrap]. The sibling behind is the whole point: without it the two
    /// widgets are indistinguishable.
    (BuildOwner, RenderBox, RenderBox) build(Widget Function(Widget) wrap) {
      final (BuildOwner owner, _) = mounted(
        Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const ColoredBox(color: _background),
            wrap(const ColoredBox(color: _content)),
          ],
        ),
        const Size(20, 20),
      );
      final RenderBoxContainer<BoxParentData> stack =
          owner.renderRoot! as RenderBoxContainer<BoxParentData>;
      return (owner, stack.childAt(0), stack.childAt(1));
    }

    test('IgnorePointer hands the event to the box behind it', () {
      final (BuildOwner owner, RenderBox back, _) =
          build((Widget child) => IgnorePointer(child: child));

      expect(owner.renderRoot!.hitTest(const Offset(5, 5)), same(back));
    });

    test('AbsorbPointer keeps it, and the box behind gets nothing', () {
      final (BuildOwner owner, RenderBox back, RenderBox front) =
          build((Widget child) => AbsorbPointer(child: child));

      final RenderBox? hit = owner.renderRoot!.hitTest(const Offset(5, 5));

      expect(hit, isNot(same(back)),
          reason: 'this is the entire difference from IgnorePointer');
      expect(hit, same(front),
          reason: 'the absorber itself is the target, not its child');
      expect(hit, isA<layout.RenderAbsorbPointer>());
    });

    test('both forward normally when their flag is off', () {
      final (BuildOwner ignoring, RenderBox back, RenderBox front) =
          build((Widget child) => IgnorePointer(ignoring: false, child: child));
      expect(
          ignoring.renderRoot!.hitTest(const Offset(5, 5)), isNot(same(back)));
      expect(
        (front as RenderSingleChildBox).child,
        same(ignoring.renderRoot!.hitTest(const Offset(5, 5))),
      );

      final (BuildOwner absorbing, RenderBox behind, RenderBox above) = build(
        (Widget child) => AbsorbPointer(absorbing: false, child: child),
      );
      expect(
        absorbing.renderRoot!.hitTest(const Offset(5, 5)),
        same((above as RenderSingleChildBox).child),
      );
      expect(behind, isNotNull);
    });

    test('an update flips the flag on the node that is already there', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(20, 20)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(const IgnorePointer(child: ColoredBox(color: _content)));
      pipeline.flushLayout();
      final layout.RenderIgnorePointer node =
          owner.renderRoot! as layout.RenderIgnorePointer;
      expect(node.hitTest(const Offset(5, 5)), isNull);

      owner.updateRoot(
        const IgnorePointer(
          ignoring: false,
          child: ColoredBox(color: _content),
        ),
      );
      pipeline.flushLayout();

      expect(owner.renderRoot, same(node));
      expect(node.hitTest(const Offset(5, 5)), isNotNull);
    });
  });

  group('RepaintBoundary', () {
    test('is invisible to layout, paint and hit testing', () async {
      final Framebuffer buffer = await frame(
        const RepaintBoundary(child: ColoredBox(color: _content)),
        side: 16,
      );

      expect(pixelAt(buffer, 8, 8), _contentPixel);
      expect(
        commandsFor(
          const RepaintBoundary(child: ColoredBox(color: _content)),
          side: 16,
        ),
        hasLength(1),
      );
    });

    test('NO CACHE: a second frame re-walks the subtree all the same', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(16, 16)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          const RepaintBoundary(child: ColoredBox(color: _content)),
        );

      for (int i = 0; i < 3; i++) {
        pipeline.drawFrame(DisplayList());
      }

      final layout.RenderRepaintBoundary node =
          owner.renderRoot! as layout.RenderRepaintBoundary;
      expect(node.paintCount, 3,
          reason: 'flushPaint walks the whole tree every frame; this widget '
              'buys nothing until a layer cache exists');
    });
  });

  group('Visibility', () {
    test('hidden with the size kept holds the layout still', () {
      final (BuildOwner owner, _) = mounted(
        const Center(
          child: Visibility(
            visible: false,
            child: SizedBox(
              width: 10,
              height: 6,
              child: ColoredBox(color: _content),
            ),
          ),
        ),
        const Size(30, 20),
      );

      final RenderBox centre = owner.renderRoot!;
      final RenderBox hidden = (centre as RenderSingleChildBox).child!;
      expect(hidden.size, const Size(10, 6), reason: 'the space is reserved');
      expect(hidden.offsetFromParent, const Offset(10, 7),
          reason: 'and nothing around it moved');
      expect(centre.hitTest(const Offset(15, 10)), isNull);
    });

    test('hidden without it gives the space back', () {
      final (BuildOwner owner, _) = mounted(
        const Center(
          child: Visibility(
            visible: false,
            maintainSize: false,
            child: SizedBox(
              width: 10,
              height: 6,
              child: ColoredBox(color: _content),
            ),
          ),
        ),
        const Size(30, 20),
      );

      final RenderBox hidden =
          (owner.renderRoot! as RenderSingleChildBox).child!;
      expect(hidden.size, Size.zero);
    });

    test('toggling it back restores both the space and the pixels', () async {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(16, 16)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          const Visibility(
            visible: false,
            child: ColoredBox(color: _content),
          ),
        );
      pipeline.flushLayout();
      final layout.RenderVisibility node =
          owner.renderRoot! as layout.RenderVisibility;

      final DisplayList hiddenFrame = DisplayList();
      pipeline.drawFrame(hiddenFrame);
      expect(expandDisplayList(hiddenFrame), isEmpty);

      owner.updateRoot(
        const Visibility(child: ColoredBox(color: _content)),
      );
      pipeline.flushLayout();

      expect(owner.renderRoot, same(node));
      expect(node.size, const Size(16, 16));
      final Framebuffer buffer = await frame(
        const Visibility(child: ColoredBox(color: _content)),
        side: 16,
      );
      expect(pixelAt(buffer, 8, 8), _contentPixel);
    });
  });
}
