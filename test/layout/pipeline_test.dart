/// The render tree meets the renderer.
///
/// Everything above these tests could compile and still emit nothing. What
/// makes the layer real is that a tree laid out here, painted into a display
/// list, and rasterised by the CPU backend puts colour on the pixels the
/// layout arithmetic predicted - with no window, no GPU and no display server
/// anywhere in the path.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  const int red = 0xFFFF0000;
  const int green = 0xFF00FF00;
  const int blue = 0xFF0000FF;

  group('pixels', () {
    test('a padded coloured box paints where layout put it', () async {
      // 8x8 blue, with a 4x4 red square inset by 2 on every side.
      final inner = RenderColoredBox(color: red);
      final root = RenderColoredBox(
        color: blue,
        child: RenderPadding(padding: const EdgeInsets.all(2), child: inner),
      );
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(8, 8)),
      );
      owner.root = root;

      final list = DisplayList();
      owner.drawFrame(list);
      final target = await memoryTarget(8, 8);
      final result = await target.renderDisplayList(list, clearColor: 0);

      expect(result.isSuccess, isTrue);
      expect(inner.size, const Size(4, 4));
      expect(inner.offsetFromParent, const Offset(2, 2));

      final Framebuffer pixels = target.framebuffer;
      expect(pixelAt(pixels, 0, 0), (0, 0, 255, 255), reason: 'corner');
      expect(pixelAt(pixels, 1, 1), (0, 0, 255, 255), reason: 'in the pad');
      expect(pixelAt(pixels, 2, 2), (255, 0, 0, 255), reason: 'first red row');
      expect(pixelAt(pixels, 5, 5), (255, 0, 0, 255), reason: 'last red row');
      // Half-open on the far edges, so column 6 is back to blue.
      expect(pixelAt(pixels, 6, 5), (0, 0, 255, 255));
      expect(pixelAt(pixels, 7, 7), (0, 0, 255, 255));
    });

    test('a flex row splits the surface between two children', () async {
      final left = RenderColoredBox(color: red);
      final right = RenderColoredBox(color: green);
      final row = RenderFlex(crossAxisAlignment: CrossAxisAlignment.stretch)
        ..add(left, flex: 1)
        ..add(right, flex: 1);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(8, 4)),
      );
      owner.root = row;

      final list = DisplayList();
      owner.drawFrame(list);
      final target = await memoryTarget(8, 4);
      await target.renderDisplayList(list, clearColor: 0);

      expect(left.size, const Size(4, 4));
      expect(right.offsetFromParent, const Offset(4, 0));

      final Framebuffer pixels = target.framebuffer;
      expect(pixelAt(pixels, 0, 0), (255, 0, 0, 255));
      expect(pixelAt(pixels, 3, 3), (255, 0, 0, 255));
      expect(pixelAt(pixels, 4, 0), (0, 255, 0, 255));
      expect(pixelAt(pixels, 7, 3), (0, 255, 0, 255));
    });

    test('a colour change repaints without moving anything', () async {
      final inner = RenderColoredBox(color: red);
      final root = RenderColoredBox(
        color: blue,
        child: RenderPadding(padding: const EdgeInsets.all(2), child: inner),
      );
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(8, 8)),
      );
      owner.root = root;
      final list = DisplayList();
      owner.drawFrame(list);

      inner.color = green;
      expect(owner.needsLayout, isFalse);
      expect(owner.needsPaint, isTrue);

      list.reset();
      owner.drawFrame(list);
      final target = await memoryTarget(8, 8);
      await target.renderDisplayList(list, clearColor: 0);

      expect(pixelAt(target.framebuffer, 3, 3), (0, 255, 0, 255));
    });
  });

  group('the display list it produces', () {
    test('emits one command per painting node, in paint order', () {
      final row = RenderFlex(crossAxisAlignment: CrossAxisAlignment.stretch)
        ..add(RenderColoredBox(color: red), flex: 1)
        ..add(RenderColoredBox(color: green), flex: 1);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(10, 10)),
      );
      owner.root = row;

      final list = DisplayList();
      owner.drawFrame(list);

      // The flex paints nothing itself, so two coloured boxes are two
      // commands and two interned paints.
      expect(list.commandCount, 2);
      expect(list.paintCount, 2);
    });

    test('the arena stops growing across steady-state frames', () {
      final root = RenderColoredBox(
        color: blue,
        child: RenderPadding(
          padding: const EdgeInsets.all(2),
          child: RenderColoredBox(color: red),
        ),
      );
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(64, 64)),
      );
      owner.root = root;
      final list = DisplayList();

      for (int i = 0; i < 4; i++) {
        list.reset();
        owner.drawFrame(list);
      }
      final int settled = list.bufferGrowths;
      for (int i = 0; i < 20; i++) {
        list.reset();
        owner.drawFrame(list);
      }

      expect(list.bufferGrowths, settled);
    });
  });

  group('the owner', () {
    test('painting a dirty layout is refused, not guessed at', () {
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(10, 10)),
      );
      owner.root = FillBox();

      expect(
        () => owner.flushPaint(DisplayList()),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('flushLayout first'),
          ),
        ),
      );
    });

    test('a clean tree costs no layout work', () {
      final leaf = FillBox();
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(10, 10)),
      );
      owner.root = leaf;
      owner.flushLayout();

      owner.flushLayout();
      owner.flushLayout();

      expect(leaf.layoutCount, 1);
      expect(owner.needsLayout, isFalse);
    });

    test('new root constraints relayout the tree', () {
      final leaf = FillBox();
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(10, 10)),
      );
      owner.root = leaf;
      owner.flushLayout();

      owner.rootConstraints = BoxConstraints.tight(const Size(20, 30));
      expect(owner.needsLayout, isTrue);
      owner.flushLayout();

      expect(leaf.size, const Size(20, 30));
      expect(leaf.layoutCount, 2);
    });

    test('it asks for a frame the moment the tree is dirtied', () {
      int requests = 0;
      final leaf = FixedBox(const Size(5, 5));
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(50, 50)),
        onNeedsVisualUpdate: () => requests++,
      );
      owner.root = leaf;
      owner.flushLayout();
      final int before = requests;

      leaf.preferredSize = const Size(6, 6);

      // Synchronous with the mutation: a frame request one microtask late is
      // a frame of latency on every interaction.
      expect(requests, greaterThan(before));
    });

    test('replacing the root detaches the old tree', () {
      final first = FillBox();
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(10, 10)),
      );
      owner.root = first;
      owner.flushLayout();

      final second = FillBox();
      owner.root = second;
      owner.flushLayout();

      expect(first.owner, isNull);
      expect(second.owner, same(owner));
      expect(first.layoutCount, 1);
    });

    test('an empty owner is a no-op rather than an error', () {
      final owner = PipelineOwner();
      final list = DisplayList();

      expect(() => owner.drawFrame(list), returnsNormally);
      expect(list.commandCount, 0);
    });

    test('layout that never settles is reported instead of hanging', () {
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(10, 10)),
      );
      owner.root = _RestlessBox();

      // Was `isA<StateError>()`. Section 25.7 asks this failure to be
      // *named* and to carry a reduced diagnostic tree, which a StateError
      // cannot do: a caller wanting to tell this apart from the twenty other
      // StateErrors the render tree throws had to match on words in a message.
      // The message still says "did not settle", so the assertion below is the
      // old one plus the type. See `layout_cycle_test.dart` for the rest.
      expect(
        () => owner.flushLayout(),
        throwsA(
          isA<LayoutCycleError>().having(
            (LayoutCycleError e) => e.message,
            'message',
            contains('did not settle'),
          ),
        ),
      );
    });
  });
}

/// Re-dirties itself the instant the driver marks it clean, which cannot
/// converge.
///
/// It hooks [markNeedsPaint] because that is what the driver calls right after
/// clearing the layout flag - the one moment where a real node could
/// accidentally do the same thing by reacting to its own new size.
final class _RestlessBox extends RenderBox {
  @override
  void performLayout() {
    size = constraints.largestFinite;
  }

  @override
  void markNeedsPaint() {
    super.markNeedsPaint();
    markNeedsLayout();
  }
}
