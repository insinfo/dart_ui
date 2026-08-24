/// The scrollbar: geometry in pixels, dragging in content units, and a
/// visibility policy that is a policy rather than a feeling.
///
/// The thumb is asserted by reading the display list, so these are assertions
/// about what was drawn and not about what a field says. The fade runs on a
/// [ManualDispatcher]: nothing here waits for a real 600 milliseconds.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('the thumb', () {
    test('is the viewport as a fraction of the content', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position);

      final RenderScrollbar bar = harness.bar;
      expect(bar.trackExtent, 100);
      // The viewport fraction is widened to the modern 36 px grab target.
      expect(bar.thumbMetrics!.extent, 36);
      expect(bar.thumbMetrics!.start, 0);

      position.jumpTo(150);
      harness.frame();

      // The thumb travels through the 24 px left after margins, arrow buttons
      // and its minimum. The channel and both line-step buttons remain drawn.
      expect(bar.thumbMetrics!.start, 12);
      expect(harness.rects.last, const Rect.fromLTRB(191, 32, 197, 68));
      harness.dispose();
    });

    test('reaches the end of the track exactly when the content does', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position);

      position.jumpTo(position.maxScrollExtent);
      harness.frame();

      final RenderScrollbar bar = harness.bar;
      expect(bar.thumbMetrics!.start + bar.thumbMetrics!.extent,
          bar.usableTrackExtent);
      harness.dispose();
    });

    test('is never smaller than a thumb can be grabbed at', () {
      // A hundred screens of content: the honest thumb would be one pixel.
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 10000);
      final harness = _Harness(position);

      final RenderScrollbar bar = harness.bar;
      expect(bar.thumbMetrics!.extent, 36, reason: 'the themed minimum');

      // And the widened thumb still reaches the end exactly at the end, which
      // is what a naive `start = fraction * track` gets wrong.
      position.jumpTo(position.maxScrollExtent);
      harness.frame();
      expect(bar.thumbMetrics!.start, 24);
      harness.dispose();
    });

    test('is absent entirely when the content fits', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 80);
      final harness = _Harness(position);

      expect(harness.bar.thumbMetrics, isNull);
      expect(harness.rects, isEmpty, reason: 'not even a track');
      // And it does not quietly eat presses along the right edge either.
      expect(harness.pointer(_down(const Offset(196, 50))), isFalse);
      harness.dispose();
    });
  });

  group('dragging the thumb', () {
    test('moves the content by the scrollable space, not by the pointer', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position);

      // The inset, widened thumb has 24 px to travel for 300 content pixels.
      expect(harness.bar.dragScale, closeTo(300 / 24, 1e-9));

      harness.pointer(_down(const Offset(196, 25)));
      harness.pointer(_move(const Offset(196, 35)));

      expect(position.pixels, closeTo(125, 1e-9));

      // And the whole track is exactly the whole content.
      harness.pointer(_move(const Offset(196, 85)));
      expect(position.pixels, position.maxScrollExtent);
      harness.dispose();
    });

    test('a press on the track pages towards the pointer', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position);

      harness.pointer(_down(const Offset(196, 70)));
      // One page is a viewport minus a line of context, kept by ScrollPosition.
      expect(position.pixels, 100 - defaultLineExtent);

      harness.pointer(_up(const Offset(196, 90)));
      harness.pointer(_down(const Offset(196, 21)));
      expect(position.pixels, 0);
      harness.dispose();
    });

    test('start and end buttons move by one desktop wheel step', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position);

      harness.pointer(_down(const Offset(196, 90)));
      harness.pointer(_up(const Offset(196, 90)));
      expect(position.pixels, defaultLineExtent);

      harness.pointer(_down(const Offset(196, 10)));
      harness.pointer(_up(const Offset(196, 10)));
      expect(position.pixels, 0);
      harness.dispose();
    });

    test('thumb interaction does not leak into an ancestor gesture surface',
        () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      var ancestorTaps = 0;
      final BuildOwner owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(200, 100)),
        ),
      );
      addTearDown(owner.dispose);
      owner.updateRoot(
        GestureDetector(
          onTap: () => ancestorTaps++,
          child: Scrollbar(
            position: position,
            child: const SizedBox(width: 200, height: 100),
          ),
        ),
      );
      owner.pipelineOwner.flushLayout();

      owner.dispatchPointerEvent(_down(const Offset(196, 25)));
      owner.dispatchPointerEvent(_move(const Offset(196, 35)));
      owner.dispatchPointerEvent(_up(const Offset(196, 35)));

      expect(position.pixels, greaterThan(0));
      expect(ancestorTaps, 0,
          reason: 'the scrollbar is an opaque pointer interaction');
    });

    test('a release ends the drag rather than leaving it armed', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position);

      harness.pointer(_down(const Offset(196, 25)));
      harness.pointer(_move(const Offset(196, 35)));
      harness.pointer(_up(const Offset(196, 35)));
      harness.pointer(_move(const Offset(196, 60)));

      expect(position.pixels, closeTo(125, 1e-9),
          reason: 'the move after the release is not '
              'part of the drag');
      harness.dispose();
    });

    test('a non-interactive scrollbar is not a hit target at all', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position, interactive: false);

      harness.pointer(_down(const Offset(196, 10)));
      harness.pointer(_move(const Offset(196, 20)));

      expect(position.pixels, 0);
      expect(harness.rects, hasLength(4),
          reason: 'channel, buttons and thumb are still drawn, just inert');
      harness.dispose();
    });
  });

  group('the visibility policy', () {
    test('always: on screen from the first frame', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position);

      expect(harness.rects, hasLength(4));
      harness.dispose();
    });

    test('never: nothing drawn and nothing to grab', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(
        position,
        visibility: ScrollbarVisibility.never,
      );

      harness.pointer(_down(const Offset(196, 10)));
      harness.pointer(_move(const Offset(196, 20)));

      expect(harness.rects, isEmpty);
      expect(position.pixels, 0);
      harness.dispose();
    });

    test('whenScrolling: appears on a scroll and fades out afterwards', () {
      final dispatcher = ManualDispatcher();
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(
        position,
        visibility: ScrollbarVisibility.whenScrolling,
        dispatcher: dispatcher,
      );

      expect(harness.rects, isEmpty, reason: 'nothing has moved yet');

      position.jumpTo(50);
      harness.frame();
      expect(harness.rects, hasLength(4), reason: 'it appeared');

      // Still up while the delay runs, because a scrollbar that vanished the
      // instant the finger stopped would be gone before it was read.
      dispatcher.advance(const Duration(milliseconds: 500));
      harness.frame();
      expect(harness.rects, hasLength(4));

      // The delay expires and the fade runs to zero.
      dispatcher.advance(const Duration(milliseconds: 400));
      harness.frame();
      expect(harness.rects, isEmpty, reason: 'it faded');

      // And a second scroll brings it back.
      position.jumpTo(80);
      harness.frame();
      expect(harness.rects, hasLength(4));
      expect(dispatcher.pendingTimerCount, 1, reason: 'one fade armed');
      harness.dispose();
    });

    test('whenScrolling with no clock stays up rather than hiding forever', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(
        position,
        visibility: ScrollbarVisibility.whenScrolling,
      );

      // No dispatcher was supplied and none is in scope, so there is no way to
      // schedule the fade - and the safe failure is a bar that is visible.
      expect(harness.rects, hasLength(4));
      harness.dispose();
    });
  });

  group('two-dimensional stage', () {
    test('both tracks stay on the outer viewport edges', () {
      final horizontal = ScrollPosition(
        axis: ScrollAxis.horizontal,
        viewportExtent: 200,
        contentExtent: 500,
      );
      final vertical = ScrollPosition(
        viewportExtent: 100,
        contentExtent: 800,
      );
      final owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(200, 100)),
        ),
      );
      addTearDown(owner.dispose);
      owner.updateRoot(
        TwoDimensionalScrollbar(
          horizontalPosition: horizontal,
          verticalPosition: vertical,
          child: const SizedBox(width: 200, height: 100),
        ),
      );
      owner.pipelineOwner.drawFrame(DisplayList());

      final bars = <RenderScrollbar>[];
      void collect(RenderBox node) {
        if (node is RenderScrollbar) bars.add(node);
        node.visitChildren(collect);
      }

      collect(owner.renderRoot!);
      expect(bars, hasLength(2));
      final verticalBar =
          bars.singleWhere((bar) => bar.position.axis == ScrollAxis.vertical);
      final horizontalBar = bars.singleWhere(
        (bar) => bar.position.axis == ScrollAxis.horizontal,
      );
      final verticalOrigin = verticalBar.localToGlobal(Offset.zero);
      final horizontalOrigin = horizontalBar.localToGlobal(Offset.zero);

      expect(verticalOrigin.dy, 0);
      expect(verticalBar.size.height, 100);
      expect(verticalOrigin.dx + verticalBar.size.width, 200);
      expect(horizontalOrigin.dx, 0);
      expect(horizontalBar.size.width, 200);
      expect(horizontalOrigin.dy + horizontalBar.size.height, 100);

      horizontal.jumpTo(150);
      owner.pipelineOwner.drawFrame(DisplayList());
      expect(
        verticalBar.localToGlobal(Offset.zero),
        verticalOrigin,
        reason: 'horizontal canvas movement must not move the vertical track',
      );
    });
  });

  group('the default configuration', () {
    test('draws a bare thumb: no stepper arrows and no resting track', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(200, 100)),
        ),
      );
      owner.updateRoot(
        Scrollbar(
          position: position,
          child: const SizedBox(width: 200, height: 100),
        ),
      );
      DisplayList display = DisplayList();
      for (int pass = 0; pass < 8; pass++) {
        if (owner.hasScheduledBuilds) owner.buildScope();
        display = DisplayList();
        owner.pipelineOwner.drawFrame(display);
        if (!owner.hasScheduledBuilds) break;
      }

      // One shape, and it is the thumb: a groove down the edge of every
      // scrollable and a pair of two-pixel arrows at its ends are the 1995
      // drawing of this control. Both remain available through
      // [ScrollbarThemeData], and the geometry group above asks for them.
      expect(_rectsIn(display), hasLength(1));
      expect(ThemeData.neutralLight.scrollbarTheme.showButtons, isFalse);
      expect(ThemeData.neutralLight.scrollbarTheme.trackVisibility, isFalse);
      owner.dispose();
    });
  });

  group('inside a list', () {
    test('a long list gets the minimum thumb, at the top', () {
      final owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(200, 100)),
        ),
      );
      final ScrollPosition position = ScrollPosition();
      owner.updateRoot(
        ListView.builder(
          itemCount: 1000,
          itemExtent: 20,
          controller: position,
          itemBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 20),
        ),
      );
      DisplayList display = DisplayList();
      for (int pass = 0; pass < 8; pass++) {
        if (owner.hasScheduledBuilds) owner.buildScope();
        display = DisplayList();
        owner.pipelineOwner.drawFrame(display);
        if (!owner.hasScheduledBuilds) break;
      }

      expect(position.contentExtent, 20000);
      final List<Rect> rects = _rectsIn(display);
      // Only the rounded thumb is visible until the pointer enters the track,
      // and it starts at the top of the bar rather than 16 px down it: the
      // default theme draws no stepper arrows, so the track is the whole
      // height minus its margins.
      expect(rects.last, const Rect.fromLTRB(191, 4, 197, 40));
      owner.dispose();
    });
  });
}

final class _Harness {
  _Harness(
    this.position, {
    ScrollbarVisibility visibility = ScrollbarVisibility.always,
    bool interactive = true,
    UiDispatcher? dispatcher,
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 100)),
      ),
    );
    // Stepper arrows and a resting track are off by default now - no current
    // desktop draws either - so the geometry group below, which is *about*
    // those two, asks for them explicitly. The default configuration has its
    // own test at the end of this file.
    owner.updateRoot(
      Theme(
        data: ThemeData.neutralLight.copyWith(
          scrollbarTheme: const ScrollbarThemeData(
            trackVisibility: true,
            showButtons: true,
          ),
        ),
        child: Scrollbar(
          position: position,
          visibility: visibility,
          interactive: interactive,
          dispatcher: dispatcher,
          child: const SizedBox(width: 200, height: 100),
        ),
      ),
    );
    frame();
  }

  final ScrollPosition position;
  late final BuildOwner owner;
  DisplayList display = DisplayList();

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      if (owner.hasScheduledBuilds) owner.buildScope();
      display = DisplayList();
      owner.pipelineOwner.drawFrame(display);
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the scrollbar never settled');
  }

  bool pointer(PointerEvent event) => owner.dispatchPointerEvent(event);

  RenderScrollbar get bar {
    RenderScrollbar? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is RenderScrollbar) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    if (found == null) throw StateError('no scrollbar in the tree');
    return found!;
  }

  List<Rect> get rects => _rectsIn(display);

  void dispose() => owner.dispose();
}

List<Rect> _rectsIn(DisplayList list) {
  final reader = DisplayListReader(list);
  final List<Rect> rects = <Rect>[];
  while (reader.moveNext()) {
    if (reader.opcode != opDrawRect && reader.opcode != opDrawRRect) continue;
    rects.add(
      Rect.fromLTRB(
        reader.floatAt(0),
        reader.floatAt(1),
        reader.floatAt(2),
        reader.floatAt(3),
      ),
    );
  }
  return rects;
}

const NativeWindowId _window = NativeWindowId(1);

PointerDownEvent _down(Offset at) => PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerMoveEvent _move(Offset at) => PointerMoveEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
    );

PointerUpEvent _up(Offset at) => PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );
