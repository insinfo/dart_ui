/// Pointer capture: the rule that makes a drag survive leaving the control.
///
/// Section 27.4 asks for implicit capture, capture-lost, and validation when a
/// target unmounts. The reason it is worth a file of its own is that the
/// failure is invisible in a screenshot: everything looks right, and then a
/// slider stops tracking the moment the mouse leaves its track - which is
/// exactly what a person dragging one does.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('a slider keeps tracking outside its own bounds', () {
    test('a drag that leaves the track vertically keeps setting the value', () {
      final _SliderHarness harness = _SliderHarness();
      final RenderSlider slider = harness.slider;
      final Offset origin = slider.globalOffset;

      // A third of the way along the track, so there is room to move either
      // way and the assertion is about direction rather than clamping.
      harness.pointerDown(
        Offset(origin.dx + slider.size.width / 3, origin.dy + 4),
      );
      final double atPress = harness.value;
      expect(atPress, greaterThan(0));
      expect(atPress, lessThan(1));

      // Further right, and far above the slider entirely - the normal thing a
      // hand does while dragging. Hit testing would hand this to whatever is
      // above, and the value would freeze.
      harness.pointerMove(Offset(origin.dx + slider.size.width * 0.75, 0));

      expect(harness.value, greaterThan(atPress));
      harness.dispose();
    });

    test('a drag past the end clamps to the maximum instead of stopping', () {
      final _SliderHarness harness = _SliderHarness()
        ..pointerDown(const Offset(20, 60))
        ..pointerMove(const Offset(9000, -400));

      expect(harness.value, 1.0);
      harness.dispose();
    });

    test('a drag back past the start clamps to the minimum', () {
      final _SliderHarness harness = _SliderHarness()
        ..pointerDown(const Offset(120, 60))
        ..pointerMove(const Offset(-9000, 900));

      expect(harness.value, 0.0);
      harness.dispose();
    });

    test('the drag ends at the release, and later moves are ignored', () {
      final _SliderHarness harness = _SliderHarness()
        ..pointerDown(const Offset(20, 60))
        ..pointerUp(const Offset(20, 60));
      final double afterRelease = harness.value;

      harness.pointerMove(const Offset(150, 60));

      expect(harness.value, afterRelease);
      harness.dispose();
    });

    test('the value is read from the slider, not from the window', () {
      // The slider is inset by the layout, so a window-space position would be
      // off by the inset - a bug that looks like "the thumb lags the mouse".
      final _SliderHarness harness = _SliderHarness();
      final RenderSlider slider = harness.slider;
      expect(slider.globalOffset.dx, greaterThan(0));

      // Press exactly on the slider's own left edge: that is value 0, whatever
      // the window coordinate happens to be.
      harness.pointerDown(
        Offset(slider.globalOffset.dx, slider.globalOffset.dy + 4),
      );

      expect(harness.value, 0.0);
      harness.dispose();
    });

    test('a vertical slider increases from bottom to top', () {
      final _SliderHarness harness = _SliderHarness(
        orientation: SliderOrientation.vertical,
      );
      final RenderSlider slider = harness.slider;
      final Offset origin = slider.globalOffset;

      harness.pointerDown(Offset(
        origin.dx + slider.size.width / 2,
        origin.dy + slider.size.height - 2,
      ));
      final double nearBottom = harness.value;
      harness.pointerMove(Offset(
        origin.dx + slider.size.width / 2,
        origin.dy + 2,
      ));

      expect(nearBottom, lessThan(0.1));
      expect(harness.value, greaterThan(0.9));
      harness.dispose();
    });
  });

  group('a press that wanders off does not activate', () {
    test('releasing outside a button does not press it', () {
      final _ButtonHarness harness = _ButtonHarness();

      harness
        ..pointerDown(const Offset(10, 10))
        ..pointerMove(const Offset(500, 500))
        ..pointerUp(const Offset(500, 500));

      expect(harness.presses, 0);
      harness.dispose();
    });

    test('wandering off and back again still activates', () {
      final _ButtonHarness harness = _ButtonHarness();

      harness
        ..pointerDown(const Offset(10, 10))
        ..pointerMove(const Offset(500, 500))
        ..pointerMove(const Offset(10, 10))
        ..pointerUp(const Offset(10, 10));

      expect(harness.presses, 1);
      harness.dispose();
    });

    test('a button stops looking pressed while the pointer is away', () {
      final _ButtonHarness harness = _ButtonHarness()
        ..pointerDown(const Offset(10, 10));
      expect(harness.button.isPressed, isTrue);

      harness.pointerMove(const Offset(500, 500));
      expect(harness.button.isPressed, isFalse,
          reason: 'the press is still owned, but it no longer reads as armed');

      harness.pointerMove(const Offset(10, 10));
      expect(harness.button.isPressed, isTrue);
      harness.dispose();
    });
  });

  group('the router itself', () {
    test('a captured pointer bypasses hit testing entirely', () {
      final _TwoButtonHarness harness = _TwoButtonHarness();

      harness.pointerDown(harness.firstCenter);
      // Straight over the second button, which must not react at all.
      harness.pointerMove(harness.secondCenter);

      expect(harness.second.isHovered, isFalse);
      expect(harness.second.isPressed, isFalse);
      harness.dispose();
    });

    test('capture is reported and released on the up', () {
      final PointerRouter router = PointerRouter();
      final _RecordingTarget target = _RecordingTarget();
      final _Host host = _Host(target)..mountAndLayout();

      router.route(_down(const Offset(5, 5)), root: host);
      expect(router.hasCapture(0), isTrue);
      expect(router.captureHolders(0), <PointerEventTarget>[target]);

      router.route(_up(const Offset(5, 5)), root: host);
      expect(router.hasCapture(0), isFalse);
    });

    test('a target can give up a capture it is holding', () {
      final PointerRouter router = PointerRouter();
      final _RecordingTarget target = _RecordingTarget();
      final _Host host = _Host(target)..mountAndLayout();
      router.route(_down(const Offset(5, 5)), root: host);

      // Capture-lost: an unmounting control must do this, or every later event
      // for that pointer disappears into a node no longer in the tree.
      router.releaseCaptureFor(target);

      expect(router.hasCapture(0), isFalse);
      final int before = target.events.length;
      router.route(_move(const Offset(500, 500)), root: host);
      expect(target.events.length, before,
          reason: 'a released target is back to ordinary hit testing');
    });

    test('a second press cancels a capture that was never released', () {
      final PointerRouter router = PointerRouter();
      final _RecordingTarget target = _RecordingTarget();
      final _Host host = _Host(target)..mountAndLayout();

      router.route(_down(const Offset(5, 5)), root: host);
      router.route(_down(const Offset(5, 5)), root: host);

      expect(
        target.events.whereType<PointerCancelEvent>(),
        hasLength(1),
        reason: 'the abandoned press is cancelled rather than left armed',
      );
    });

    test('releaseAllCaptures drops everything, for a lost window', () {
      final PointerRouter router = PointerRouter();
      final _Host host = _Host(_RecordingTarget())..mountAndLayout();
      router.route(_down(const Offset(5, 5)), root: host);

      router.releaseAllCaptures();

      expect(router.hasCapture(0), isFalse);
    });
  });

  group('coordinate conversion', () {
    test('globalToLocal is the inverse of localToGlobal', () {
      final _SliderHarness harness = _SliderHarness();
      final RenderSlider slider = harness.slider;

      const Offset local = Offset(7, 3);
      expect(slider.globalToLocal(slider.localToGlobal(local)), local);
      harness.dispose();
    });

    test('a point outside converts to a value outside, not a clamped one', () {
      final _SliderHarness harness = _SliderHarness();
      final RenderSlider slider = harness.slider;

      final Offset local = slider.globalToLocal(Offset.zero);

      // Unclamped on purpose: a slider needs to know *how far* off the pointer
      // went, and clamping here would throw that away before it is used.
      expect(local.dx, lessThan(0));
      expect(local.dy, lessThan(0));
      harness.dispose();
    });
  });
}

// ---------------------------------------------------------------------------
// Harnesses
// ---------------------------------------------------------------------------

/// A slider inset by padding, so window space and slider space differ.
final class _SliderHarness {
  _SliderHarness({
    this.orientation = SliderOrientation.horizontal,
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(
          orientation == SliderOrientation.vertical
              ? const Size(300, 260)
              : const Size(300, 200),
        ),
      ),
    );
    _mount();
    owner.pipelineOwner.drawFrame(DisplayList());
  }

  late final BuildOwner owner;
  final SliderOrientation orientation;
  double value = 0.5;

  void _mount() => owner.updateRoot(Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: <Widget>[
          const SizedBox(height: 40, child: Text('HEADER')),
          Slider(
            value: value,
            orientation: orientation,
            onChanged: (double next) {
              value = next;
              _mount();
            },
          ),
        ]),
      ));

  RenderSlider get slider {
    RenderSlider? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is RenderSlider) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found!;
  }

  void pointerDown(Offset at) {
    owner.dispatchPointerEvent(_down(at));
    owner.pipelineOwner.drawFrame(DisplayList());
  }

  void pointerMove(Offset at) {
    owner.dispatchPointerEvent(_move(at));
    owner.pipelineOwner.drawFrame(DisplayList());
  }

  void pointerUp(Offset at) {
    owner.dispatchPointerEvent(_up(at));
    owner.pipelineOwner.drawFrame(DisplayList());
  }

  void dispose() => owner.dispose();
}

final class _ButtonHarness {
  _ButtonHarness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(300, 200)),
      ),
    );
    owner.updateRoot(Button(label: 'OK', onPressed: () => presses++));
    owner.pipelineOwner.drawFrame(DisplayList());
  }

  late final BuildOwner owner;
  int presses = 0;

  RenderButton get button => owner.renderRoot! as RenderButton;

  void pointerDown(Offset at) => owner.dispatchPointerEvent(_down(at));

  void pointerMove(Offset at) => owner.dispatchPointerEvent(_move(at));

  void pointerUp(Offset at) => owner.dispatchPointerEvent(_up(at));

  void dispose() => owner.dispose();
}

final class _TwoButtonHarness {
  _TwoButtonHarness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 200)),
      ),
    );
    owner.updateRoot(Column(children: <Widget>[
      Button(label: 'FIRST', onPressed: () {}),
      Button(label: 'SECOND', onPressed: () {}),
    ]));
    owner.pipelineOwner.drawFrame(DisplayList());
  }

  late final BuildOwner owner;

  List<RenderButton> get _buttons {
    final List<RenderButton> found = <RenderButton>[];
    void walk(RenderBox node) {
      if (node is RenderButton) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  RenderButton get first => _buttons[0];

  RenderButton get second => _buttons[1];

  Offset get firstCenter => _centerOf(first);

  Offset get secondCenter => _centerOf(second);

  Offset _centerOf(RenderButton button) {
    final Offset origin = button.globalOffset;
    return Offset(
      origin.dx + button.size.width / 2,
      origin.dy + button.size.height / 2,
    );
  }

  void pointerDown(Offset at) => owner.dispatchPointerEvent(_down(at));

  void pointerMove(Offset at) => owner.dispatchPointerEvent(_move(at));

  void dispose() => owner.dispose();
}

/// A leaf that records what it is sent, for router-level tests.
final class _RecordingTarget extends RenderBox implements PointerEventTarget {
  final List<PointerEvent> events = <PointerEvent>[];

  @override
  void performLayout() => size = constraints.constrain(const Size(20, 20));

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) => events.add(event);
}

/// A root that lays out one child, so a router test needs no widget tree.
final class _Host extends RenderSingleChildBox {
  _Host(RenderBox child) : super(child: child);

  void mountAndLayout() {
    final PipelineOwner owner = PipelineOwner(
      rootConstraints: BoxConstraints.tight(const Size(100, 100)),
    )..root = this;
    owner.drawFrame(DisplayList());
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.constrain(const Size(100, 100));
  }
}

PointerDownEvent _down(Offset at, {int pointerId = 0}) => PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: pointerId,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerMoveEvent _move(Offset at, {int pointerId = 0}) => PointerMoveEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: pointerId,
      kind: PointerKind.mouse,
      logicalPosition: at,
    );

PointerUpEvent _up(Offset at, {int pointerId = 0}) => PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: pointerId,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );
