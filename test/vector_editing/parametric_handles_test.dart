/// The Shape tool's handles on rectangles and ellipses.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  VectorRectangle rectangle() => VectorRectangle(
        // Placed at (100, 50), twice as wide: the handles are in document
        // coordinates, through the transform.
        trafo: <double>[2, 0, 0, 1, 100, 50],
        rectWidth: 40,
        rectHeight: 20,
      )..update();

  test('a square rectangle has a handle on each corner', () {
    final List<Offset> handles = ParametricHandles.of(rectangle());
    expect(handles, <Offset>[
      const Offset(100, 50),
      const Offset(100, 70),
      const Offset(180, 70),
      const Offset(180, 50),
    ]);
  });

  test('dragging a corner along its edge rounds every corner', () {
    final VectorRectangle r = rectangle();
    // Corner 0 is (0, 0) locally; its handle slides up the left edge. Half
    // the shorter side is 10, so 5 along it is half rounded.
    ParametricHandles.drag(r, 0, const Offset(100, 55));
    expect(r.corners, <double>[.5, .5, .5, .5]);
    expect(ParametricHandles.of(r).first, const Offset(100, 55));
    // Past half the shorter side it stops at fully round.
    ParametricHandles.drag(r, 0, const Offset(100, 90));
    expect(r.corners, <double>[1, 1, 1, 1]);
  });

  test('with single, only that corner rounds', () {
    final VectorRectangle r = rectangle();
    ParametricHandles.drag(r, 2, const Offset(180, 65), single: true);
    expect(r.corners, <double>[0, 0, .5, 0]);
  });

  test('the handle under the pointer is found within the tolerance', () {
    final VectorRectangle r = rectangle();
    expect(ParametricHandles.at(r, const Offset(181, 69), 3), 2);
    expect(ParametricHandles.at(r, const Offset(140, 60), 3), isNull);
  });

  VectorCircle ellipse() =>
      VectorCircle.fromRect(<double>[0, 0, 100, 100])..update();

  test('an ellipse opens into a pie inside its outline', () {
    final VectorCircle c = ellipse();
    expect(ParametricHandles.of(c), <Offset>[const Offset(100, 50)],
        reason: 'one node while whole');
    // Dragged to the bottom, inside: a pie from there to where it was.
    ParametricHandles.drag(c, 0, const Offset(50, 80));
    expect(c.arcType, ArcType.pieslice);
    expect(c.angle1, closeTo(math.pi / 2, 1e-9));
    expect(c.angle2, 0);
    expect(ParametricHandles.of(c), hasLength(2));
  });

  test('and into an arc outside it', () {
    final VectorCircle c = ellipse();
    ParametricHandles.drag(c, 0, const Offset(0, 50) - const Offset(30, 0));
    expect(c.arcType, ArcType.arc);
    expect(c.angle1, closeTo(math.pi, 1e-9));
    // The second handle moves the other end.
    ParametricHandles.drag(c, 1, const Offset(50, -20));
    expect(c.angle2, closeTo(3 * math.pi / 2, 1e-9));
  });

  test('only rectangles and ellipses have them', () {
    expect(ParametricHandles.supports(rectangle()), isTrue);
    expect(ParametricHandles.supports(ellipse()), isTrue);
    expect(ParametricHandles.supports(VectorPolygon()), isFalse);
  });
}
