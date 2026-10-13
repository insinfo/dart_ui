/// Flutter's mutable `Path` API on the framework's path type.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('Path() is editable with Flutter\'s calls', () {
    final Path p = Path()
      ..moveTo(0, 0)
      ..lineTo(10, 0)
      ..quadraticBezierTo(15, 5, 10, 10)
      ..cubicTo(8, 12, 2, 12, 0, 10)
      ..close();
    expect(p.verbCount, 5);
    expect(p.getBounds().left, 0);
    expect(p.getBounds().right, closeTo(12.5, 1e-6),
        reason: 'tight bounds: the quadratic peaks at 12.5, not at 15');
    expect(p.contains(const Offset(5, 5)), isTrue);
    expect(p.contains(const Offset(20, 5)), isFalse);
  });

  test('relative calls start at the current point', () {
    final Path p = Path()
      ..moveTo(10, 10)
      ..relativeLineTo(5, 0)
      ..relativeMoveTo(0, 5)
      ..relativeLineTo(-5, 0);
    expect(p.pointAt(1), const Offset(15, 10));
    expect(p.pointAt(2), const Offset(15, 15));
    expect(p.pointAt(3), const Offset(10, 15));
  });

  test('a segment after close starts where the closed contour began', () {
    final Path p = Path()
      ..moveTo(3, 4)
      ..lineTo(10, 4)
      ..close()
      ..lineTo(3, 20);
    expect(p.pointAt(p.pointCount - 2), const Offset(3, 4));
  });

  test('arcTo, addArc and arcToPoint land on the circle', () {
    const Rect oval = Rect.fromLTRB(0, 0, 20, 20);
    final Path p = Path()..addArc(oval, 0, math.pi / 2);
    expect(p.pointAt(0), const Offset(20, 10));
    final Offset end = p.pointAt(p.pointCount - 1);
    expect(end.dx, closeTo(10, 1e-4));
    expect(end.dy, closeTo(20, 1e-4));

    final Path q = Path()
      ..moveTo(0, 10)
      ..arcToPoint(const Offset(20, 10), radius: const Radius.circular(10));
    final Offset last = q.pointAt(q.pointCount - 1);
    expect(last, const Offset(20, 10));
    // Clockwise from the left to the right of the circle passes over the top.
    expect(q.getBounds().top, closeTo(0, 0.05));
    expect(q.getBounds().bottom, closeTo(10, 0.05));

    final Path joined = Path()
      ..moveTo(-5, 10)
      ..arcTo(oval, math.pi, math.pi / 2, false);
    expect(joined.pointAt(1), const Offset(0, 10),
        reason: 'without forceMoveTo a line joins the arc');
  });

  test('addRect, addOval, addRRect and addPolygon add closed contours', () {
    final Path p = Path()
      ..addRect(const Rect.fromLTRB(0, 0, 10, 10))
      ..addOval(const Rect.fromLTRB(20, 0, 30, 10))
      ..addRRect(RRect.fromLTRBR(40, 0, 60, 10, const Radius.circular(3)))
      ..addPolygon(
          const <Offset>[Offset(70, 0), Offset(80, 10), Offset(70, 10)], true);
    expect(p.contains(const Offset(5, 5)), isTrue);
    expect(p.contains(const Offset(25, 5)), isTrue);
    expect(p.contains(const Offset(40.3, 0.3)), isFalse, reason: 'corner');
    expect(p.contains(const Offset(50, 5)), isTrue);
    expect(p.contains(const Offset(72, 8)), isTrue);
    expect(p.contains(const Offset(79, 2)), isFalse);
  });

  test('fill type decides overlap', () {
    final Path p = Path()
      ..addRect(const Rect.fromLTRB(0, 0, 20, 20))
      ..addRect(const Rect.fromLTRB(5, 5, 15, 15));
    expect(p.contains(const Offset(10, 10)), isTrue);
    p.fillType = PathFillType.evenOdd;
    expect(p.contains(const Offset(10, 10)), isFalse);
    expect(p.contains(const Offset(2, 2)), isTrue);
  });

  test('addPath and extendWithPath', () {
    final Path square = Path()..addRect(const Rect.fromLTRB(0, 0, 10, 10));
    final Path p = Path()..addPath(square, const Offset(100, 0));
    expect(p.getBounds(), const Rect.fromLTRB(100, 0, 110, 10));

    final Path open = Path()
      ..moveTo(0, 0)
      ..lineTo(5, 0);
    final Path tail = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 5);
    open.extendWithPath(tail, const Offset(5, 0));
    expect(open.verbAt(2), verbLineTo,
        reason: 'the move of the extension became a line');
    expect(open.pointAt(3), const Offset(5, 5));
  });

  test('transform takes Matrix4 storage, shift a translation', () {
    final Path p = Path()..addRect(const Rect.fromLTRB(0, 0, 10, 10));
    final Float64List scale2 = Float64List(16)
      ..[0] = 2
      ..[5] = 2
      ..[10] = 1
      ..[15] = 1
      ..[12] = 3;
    expect(p.transform(scale2).getBounds(), const Rect.fromLTRB(3, 0, 23, 20));
    expect(p.shift(const Offset(1, 1)).getBounds(),
        const Rect.fromLTRB(1, 1, 11, 11));
    expect(() => p.transform(<double>[1, 2]), throwsArgumentError);
  });

  test('Path.from copies; editing the copy leaves the source alone', () {
    final Path a = Path()..addRect(const Rect.fromLTRB(0, 0, 10, 10));
    final Path b = Path.from(a)..lineTo(50, 50);
    expect(a.verbCount, 5);
    expect(b.verbCount, 7, reason: 'an implicit move after the close');
    final Path moved = a.shift(const Offset(5, 5));
    a.reset();
    expect(a.isEmpty, isTrue);
    expect(moved.isEmpty, isFalse, reason: 'transformed copies own their data');
  });

  test('equality and hash follow edits', () {
    final Path a = Path()..addRect(const Rect.fromLTRB(0, 0, 10, 10));
    final Path b = Path()..addRect(const Rect.fromLTRB(0, 0, 10, 10));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    b.lineTo(1, 1);
    expect(a == b, isFalse);
    a.fillType = PathFillType.evenOdd;
    expect(a == Path.rect(const Rect.fromLTRB(0, 0, 10, 10)), isFalse);
  });

  test('reset returns to a new path, fill type included', () {
    final Path p = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(const Rect.fromLTRB(0, 0, 1, 1))
      ..reset();
    expect(p.isEmpty, isTrue);
    expect(p.fillType, PathFillType.nonZero);
  });

  test('Path.empty is shared and refuses edits', () {
    expect(() => Path.empty.lineTo(1, 1), throwsStateError);
    expect(Path.empty.isEmpty, isTrue);
  });

  test('conicTo of weight 1 is a quadratic', () {
    final Path p = Path()
      ..moveTo(0, 0)
      ..conicTo(5, 10, 10, 0, 1);
    expect(p.verbAt(1), verbQuadraticTo);
    final Path q = Path()
      ..moveTo(0, 0)
      ..conicTo(10, 0, 10, 10, math.sqrt1_2);
    expect(q.verbAt(1), verbCubicTo);
    // A quarter circle of radius 10 around (0, 10): its midpoint is on the arc.
    final FlattenedPath flat = q.flatten(0.01);
    final Offset mid = flat.pointAt(flat.pointCount ~/ 2);
    expect((mid - const Offset(0, 10)).distance, closeTo(10, 0.05));
  });
}
