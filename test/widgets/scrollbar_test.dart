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
      // A quarter of the content is visible, so the thumb is a quarter of the
      // track, and it starts at the top because the offset is zero.
      expect(bar.thumbMetrics!.extent, 25);
      expect(bar.thumbMetrics!.start, 0);

      position.jumpTo(150);
      harness.frame();

      // 150 of 400 content units is 37.5 of 100 track units.
      expect(bar.thumbMetrics!.start, 37.5);
      expect(harness.rects, <Rect>[
        const Rect.fromLTRB(192, 0, 200, 100),
        const Rect.fromLTRB(192, 37.5, 200, 62.5),
      ]);
      harness.dispose();
    });

    test('reaches the end of the track exactly when the content does', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position);

      position.jumpTo(position.maxScrollExtent);
      harness.frame();

      final RenderScrollbar bar = harness.bar;
      expect(bar.thumbMetrics!.start + bar.thumbMetrics!.extent, 100);
      harness.dispose();
    });

    test('is never smaller than a thumb can be grabbed at', () {
      // A hundred screens of content: the honest thumb would be one pixel.
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 10000);
      final harness = _Harness(position);

      final RenderScrollbar bar = harness.bar;
      expect(bar.thumbMetrics!.extent, 16, reason: 'the declared minimum');

      // And the widened thumb still reaches the end exactly at the end, which
      // is what a naive `start = fraction * track` gets wrong.
      position.jumpTo(position.maxScrollExtent);
      harness.frame();
      expect(bar.thumbMetrics!.start, 84);
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

      // The thumb is 25 long in a 100 track, so it has 75 to travel while the
      // content has 300. One pixel of thumb is four pixels of content.
      expect(harness.bar.dragScale, 4);

      harness.pointer(_down(const Offset(196, 10)));
      harness.pointer(_move(const Offset(196, 20)));

      expect(position.pixels, 40, reason: 'ten pixels of thumb, four each');

      // And the whole track is exactly the whole content.
      harness.pointer(_move(const Offset(196, 85)));
      expect(position.pixels, position.maxScrollExtent);
      harness.dispose();
    });

    test('a press on the track pages towards the pointer', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position);

      harness.pointer(_down(const Offset(196, 90)));
      // One page is a viewport minus a line of context, kept by ScrollPosition.
      expect(position.pixels, 100 - defaultLineExtent);

      harness.pointer(_up(const Offset(196, 90)));
      harness.pointer(_down(const Offset(196, 2)));
      expect(position.pixels, 0);
      harness.dispose();
    });

    test('a release ends the drag rather than leaving it armed', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position);

      harness.pointer(_down(const Offset(196, 10)));
      harness.pointer(_move(const Offset(196, 20)));
      harness.pointer(_up(const Offset(196, 20)));
      harness.pointer(_move(const Offset(196, 60)));

      expect(position.pixels, 40,
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
      expect(harness.rects, hasLength(2), reason: 'still drawn, just inert');
      harness.dispose();
    });
  });

  group('the visibility policy', () {
    test('always: on screen from the first frame', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final harness = _Harness(position);

      expect(harness.rects, hasLength(2));
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
      expect(harness.rects, hasLength(2), reason: 'it appeared');

      // Still up while the delay runs, because a scrollbar that vanished the
      // instant the finger stopped would be gone before it was read.
      dispatcher.advance(const Duration(milliseconds: 500));
      harness.frame();
      expect(harness.rects, hasLength(2));

      // The delay expires and the fade runs to zero.
      dispatcher.advance(const Duration(milliseconds: 400));
      harness.frame();
      expect(harness.rects, isEmpty, reason: 'it faded');

      // And a second scroll brings it back.
      position.jumpTo(80);
      harness.frame();
      expect(harness.rects, hasLength(2));
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
      expect(harness.rects, hasLength(2));
      harness.dispose();
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
      // The track and the thumb, drawn over the list.
      expect(rects.last, const Rect.fromLTRB(192, 0, 200, 16));
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
    owner.updateRoot(
      Scrollbar(
        position: position,
        visibility: visibility,
        interactive: interactive,
        dispatcher: dispatcher,
        child: const SizedBox(width: 200, height: 100),
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
    if (reader.opcode != opDrawRect) continue;
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
