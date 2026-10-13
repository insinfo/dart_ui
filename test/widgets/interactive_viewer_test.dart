/// Flutter's `InteractiveViewer`: the wheel and a pinch zoom about the
/// pointer, a drag pans, and the child never leaves its boundary.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'input_test_harness.dart';

/// A 200x200 viewer at the window's origin.
InputHarness _viewer(
  TransformationController controller, {
  double minScale = 0.8,
  double maxScale = 2.5,
  EdgeInsets boundaryMargin = EdgeInsets.zero,
  bool panEnabled = true,
  bool scaleEnabled = true,
  List<String>? log,
}) =>
    InputHarness(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          height: 200,
          child: InteractiveViewer(
            transformationController: controller,
            minScale: minScale,
            maxScale: maxScale,
            boundaryMargin: boundaryMargin,
            panEnabled: panEnabled,
            scaleEnabled: scaleEnabled,
            onInteractionStart: (_) => log?.add('start'),
            onInteractionUpdate: (_) => log?.add('update'),
            onInteractionEnd: (_) => log?.add('end'),
            child: const ColoredBox(color: Color(0xFF3949AB)),
          ),
        ),
      ),
      overlay: false,
    );

void main() {
  test('the wheel zooms about the pointer', () {
    final TransformationController c = TransformationController();
    final List<String> log = <String>[];
    final InputHarness h = _viewer(c, log: log);
    const Offset at = Offset(50, 80);
    final Offset sceneBefore = c.toScene(at);
    h.wheel(at, const Offset(0, -100));
    expect(c.value.a, closeTo(1.6487, 1e-3), reason: 'exp(100 / 200)');
    expect(c.toScene(at).dx, closeTo(sceneBefore.dx, 1e-9));
    expect(c.toScene(at).dy, closeTo(sceneBefore.dy, 1e-9));
    expect(log, <String>['start', 'update', 'end']);
    h.dispose();
  });

  test('the scale stays within minScale and maxScale', () {
    final TransformationController c = TransformationController();
    final InputHarness h = _viewer(c, maxScale: 3);
    for (int i = 0; i < 10; i++) {
      h.wheel(const Offset(100, 100), const Offset(0, -200));
    }
    expect(c.value.a, 3);
    for (int i = 0; i < 20; i++) {
      h.wheel(const Offset(100, 100), const Offset(0, 200));
    }
    expect(c.value.a, 1,
        reason: 'with no margin the child may not get smaller than the view');
    h.dispose();
  });

  test('a margin lets it shrink to minScale', () {
    final TransformationController c = TransformationController();
    final InputHarness h = _viewer(c,
        minScale: 0.5, boundaryMargin: const EdgeInsets.all(double.infinity));
    for (int i = 0; i < 20; i++) {
      h.wheel(const Offset(100, 100), const Offset(0, 200));
    }
    expect(c.value.a, 0.5);
    h.dispose();
  });

  test('a drag pans, inside the boundary', () {
    final TransformationController c =
        TransformationController(const Transform2D.scaling(2, 2));
    final InputHarness h = _viewer(c);
    h.drag(const Offset(150, 150), const Offset(100, 120), steps: 5);
    // The first step, which crossed the slop, is where the pan starts - as
    // in Flutter, whose scale recognizer also starts at the slop.
    expect(c.value.tx, closeTo(-40, 1e-9));
    expect(c.value.ty, closeTo(-24, 1e-9));
    // Far past the edge: clamped so the child still covers the view.
    h.drag(const Offset(150, 150), const Offset(-400, -400), steps: 10);
    expect(c.value.tx, -200);
    expect(c.value.ty, -200);
    h.drag(const Offset(10, 10), const Offset(400, 400), steps: 10);
    expect(c.value.tx, 0);
    expect(c.value.ty, 0);
    h.dispose();
  });

  test('panEnabled false keeps it still', () {
    final TransformationController c =
        TransformationController(const Transform2D.scaling(2, 2));
    final InputHarness h = _viewer(c, panEnabled: false);
    h.drag(const Offset(150, 150), const Offset(100, 100));
    expect(c.value.tx, 0);
    h.dispose();
  });

  test('a two-finger pinch zooms about the fingers', () {
    final TransformationController c = TransformationController();
    final InputHarness h = _viewer(c);
    h.down(const Offset(80, 100), pointer: 1, kind: PointerKind.touch);
    h.down(const Offset(120, 100), pointer: 2, kind: PointerKind.touch);
    for (int i = 1; i <= 10; i++) {
      h.move(Offset(80 - i * 2.0, 100), pointer: 1, kind: PointerKind.touch);
      h.move(Offset(120 + i * 2.0, 100), pointer: 2, kind: PointerKind.touch);
    }
    expect(c.value.a, closeTo(2.0, 1e-9),
        reason: 'the fingers are twice as far apart');
    // The point between the fingers stays put.
    expect(c.toScene(const Offset(100, 100)).dx, closeTo(100, 1));
    h.up(const Offset(60, 100), pointer: 1, kind: PointerKind.touch);
    h.up(const Offset(140, 100), pointer: 2, kind: PointerKind.touch);
    h.dispose();
  });

  test('a trackpad pinch zooms; its two-finger scroll pans', () {
    final TransformationController c = TransformationController();
    final InputHarness h = _viewer(c);
    h.panZoom(const Offset(100, 100), PanZoomPhase.start);
    h.panZoom(const Offset(100, 100), PanZoomPhase.update, scale: 2);
    h.panZoom(const Offset(100, 100), PanZoomPhase.end, scale: 2);
    expect(c.value.a, closeTo(2, 1e-9));
    expect(c.toScene(const Offset(100, 100)).dx, closeTo(100, 1e-6));

    final double before = c.value.tx;
    h.wheel(const Offset(100, 100), const Offset(30, 0),
        kind: PointerKind.trackpad);
    expect(c.value.a, closeTo(2, 1e-9), reason: 'a trackpad scroll pans');
    expect(c.value.tx, closeTo(before - 30, 1e-9));
    h.dispose();
  });

  test('Ctrl+wheel zooms, also from a trackpad', () {
    final TransformationController c = TransformationController();
    final InputHarness h = _viewer(c);
    h.key(0x11, modifiers: <KeyModifier>{KeyModifier.control});
    h.wheel(const Offset(100, 100), const Offset(0, -100),
        kind: PointerKind.trackpad);
    expect(c.value.a, greaterThan(1.5));
    h.key(0x11, up: true);
    h.dispose();
  });

  test('scaleEnabled false makes the wheel pan', () {
    final TransformationController c =
        TransformationController(const Transform2D.scaling(2, 2));
    final InputHarness h = _viewer(c, scaleEnabled: false);
    h.wheel(const Offset(100, 100), const Offset(0, 40));
    expect(c.value.a, 2);
    expect(c.value.ty, -40);
    h.dispose();
  });

  test('the child is drawn through the transform', () {
    final TransformationController c = TransformationController();
    final InputHarness h = _viewer(c);
    c.value = const Transform2D(2, 0, 0, 2, -50, -60);
    h.frame();
    final RenderTransform transform = h.find<RenderTransform>().single;
    expect(transform.transform, c.value);
    h.dispose();
  });
}
