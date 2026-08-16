import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A box of a fixed size, so a viewport has something taller than itself.
final class _FixedBox extends RenderBox {
  _FixedBox(this.preferred);

  final Size preferred;

  @override
  void performLayout() => size = constraints.constrain(preferred);

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final int paint = list.addPaint(colorArgb: 0xFF00FF00, antiAlias: false);
    list.drawRectangle(
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      paint,
    );
  }
}

void main() {
  group('ScrollPosition arithmetic', () {
    test('content that fits cannot scroll', () {
      final position = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 60);

      expect(position.maxScrollExtent, 0);
      expect(position.canScroll, isFalse);
      expect(position.thumb, isNull, reason: 'nothing to scroll, no scrollbar');
      expect(position.applyDelta(50), 50, reason: 'the whole delta is unused');
    });

    test('an offset is clamped into range', () {
      final position = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 300);

      expect(position.jumpTo(-40), isFalse);
      expect(position.pixels, 0);
      position.jumpTo(1000);
      expect(position.pixels, 200);
      expect(position.atEnd, isTrue);
    });

    test('an unconsumed delta is returned, which is what chains scrolls', () {
      final position = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 150)
        ..jumpTo(40);

      // 10 px of room left, 30 px requested: the outer scrollable gets 20.
      expect(position.applyDelta(30), 20);
      expect(position.pixels, 50);
    });

    test('line deltas become pixels', () {
      final position = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 1000);

      position.applyScrollDelta(3, inLines: true);
      expect(position.pixels, 3 * defaultLineExtent);
    });

    test('a page step leaves a line of context', () {
      final position = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 1000);

      position.pageBy(1);
      expect(position.pixels, 100 - defaultLineExtent);
    });

    test('overscroll is allowed only when a slack is configured', () {
      final hard = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 200);
      hard.applyDelta(500, allowOverscroll: true);
      expect(hard.pixels, 100);

      final rubber = ScrollPosition(overscrollAllowance: 30)
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 200);
      rubber.applyDelta(500, allowOverscroll: true);
      expect(rubber.pixels, 130);
    });

    test('a shrinking viewport pulls the offset back into range', () {
      final position = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 500)
        ..jumpTo(400);

      // The window grew, so there is less to scroll - and the old offset now
      // points past the end of the content.
      position.applyViewportGeometry(viewportExtent: 300, contentExtent: 500);

      expect(position.pixels, 200);
    });

    test('the thumb describes the visible fraction and where it is', () {
      final position = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 400)
        ..jumpTo(150);

      final thumb = position.thumb!;
      expect(thumb.extent, closeTo(0.25, 1e-9));
      expect(thumb.start, closeTo(0.375, 1e-9));
    });

    test('revealing a range scrolls the least amount that works', () {
      final position = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 1000);

      expect(position.revealRange(20, 30), isFalse, reason: 'already visible');
      expect(position.revealRange(120, 20), isTrue);
      expect(position.pixels, 40, reason: 'just enough to show the bottom');
      expect(position.revealRange(10, 10), isTrue);
      expect(position.pixels, 10, reason: 'just enough to show the top');
    });

    test('a fling decays and stops at an edge', () {
      final position = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 10000)
        ..fling(2000);

      expect(position.velocity, 2000);
      final bool keepGoing =
          position.tickMomentum(const Duration(milliseconds: 16));
      expect(keepGoing, isTrue);
      expect(position.pixels, greaterThan(0));

      position
        ..jumpTo(position.maxScrollExtent)
        ..fling(2000);
      expect(
        position.tickMomentum(const Duration(milliseconds: 16)),
        isFalse,
        reason: 'a fling into the end stops rather than grinding',
      );
      expect(position.velocity, 0);
    });

    test('a fling runs to a standstill, not to the second tick', () {
      // The regression this pins: `applyDelta` used to return
      // `delta - consumed`, and `(pixels + delta) - pixels` is not exactly
      // `delta` in binary floating point. A step that consumed everything left
      // about -1.8e-15 behind, `tickMomentum` read any non-zero remainder as
      // "hit an edge", and every fling died on its second tick - 31 px of a
      // 265 px throw. The momentum written for `fling` was unreachable in
      // practice, and the previous test could not see it: one tick is all it
      // checks, and the first tick was the one that worked.
      final position = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 10000)
        ..fling(1000);

      var ticks = 0;
      while (position.tickMomentum(const Duration(milliseconds: 16))) {
        ticks++;
        // A guard, not an expectation: without it a regression that never
        // decays hangs the suite instead of failing it.
        if (ticks > 500) break;
      }

      // 1000 px/s decaying by 0.94 per 16 ms step is a geometric series, so
      // the total is arithmetic rather than a recorded number:
      //   16 * (1 - 0.94^79) / 0.06 = 264.66
      expect(ticks, 78);
      expect(position.pixels, closeTo(264.657, 0.01));
    });

    test('a step that consumes everything reports no remainder', () {
      // The property underneath the test above, stated on its own: chaining
      // (section 27.8) hands the *unconsumed* part to the outer scrollable, so
      // a residue here would scroll an ancestor by 1e-15 on every step of a
      // gesture that was in fact fully consumed.
      final position = ScrollPosition()
        ..applyViewportGeometry(viewportExtent: 100, contentExtent: 10000);

      // Deliberately values whose sum is not representable exactly.
      expect(position.applyDelta(0.1), 0.0);
      expect(position.applyDelta(0.2), 0.0);
      expect(position.applyDelta(15.999999), 0.0);

      // And at the edge the remainder is the genuine overflow, not zero.
      position.jumpTo(position.maxScrollExtent);
      expect(position.applyDelta(25), 25.0);
    });
  });

  group('RenderViewport', () {
    test('a viewport fills its constraints and measures its child freely', () {
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 100)),
      );
      final position = ScrollPosition();
      final viewport = RenderViewport(
        position: position,
        child: _FixedBox(const Size(100, 400)),
      );
      owner.root = viewport;
      owner.drawFrame(DisplayList());

      expect(viewport.size, const Size(100, 100));
      expect(position.contentExtent, 400);
      expect(position.maxScrollExtent, 300);
    });

    test('scrolling moves the child by a negative offset', () {
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 100)),
      );
      final position = ScrollPosition();
      final child = _FixedBox(const Size(100, 400));
      owner.root = RenderViewport(position: position, child: child);
      owner.drawFrame(DisplayList());

      position.jumpTo(120);
      owner.drawFrame(DisplayList());

      expect(child.offsetFromParent, const Offset(0, -120));
    });

    test('painting is clipped to the viewport', () {
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 100)),
      );
      final list = DisplayList();
      owner.root = RenderViewport(
        position: ScrollPosition(),
        child: _FixedBox(const Size(100, 400)),
      );
      owner.drawFrame(list);

      final reader = DisplayListReader(list);
      var sawClip = false;
      while (reader.moveNext()) {
        if (reader.opcode == opClipRect) sawClip = true;
      }
      // Without the clip the child paints over its siblings: the frame is
      // wrong, not merely untidy.
      expect(sawClip, isTrue);
    });

    test('a hit outside the viewport misses even when the child is there', () {
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 100)),
      );
      final viewport = RenderViewport(
        position: ScrollPosition(),
        child: _FixedBox(const Size(100, 400)),
      );
      owner.root = viewport;
      owner.drawFrame(DisplayList());

      expect(viewport.hitTest(const Offset(50, 50)), isNotNull);
      expect(viewport.hitTest(const Offset(50, 300)), isNull);
    });

    test('a horizontal viewport measures the other axis', () {
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 100)),
      );
      final position = ScrollPosition(axis: ScrollAxis.horizontal);
      owner.root = RenderViewport(
        position: position,
        child: _FixedBox(const Size(600, 100)),
      );
      owner.drawFrame(DisplayList());

      expect(position.contentExtent, 600);
      expect(position.maxScrollExtent, 500);
    });
  });
}
