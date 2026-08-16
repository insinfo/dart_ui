import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/graphics/svg/svg_path.dart';
import 'package:test/test.dart';

void main() {
  test('parses absolute, relative, implicit, and close commands', () {
    final Path path = parseSvgPathData('M 10 10 20 10 l 0 10 H 5 v -5 z');
    expect(path.verbCount, 6);
    expect(path.bounds.left, 5);
    expect(path.bounds.top, 10);
    expect(path.bounds.right, 20);
    expect(path.bounds.bottom, 20);
  });

  test('smooth cubic and quadratic commands reflect their controls', () {
    final Path path = parseSvgPathData(
      'M0 0 C10 0 10 10 20 10 S30 20 40 10 Q50 0 60 10 T80 10',
    );
    expect(path.verbCount, 5);
    expect(path.verbAt(1), verbCubicTo);
    expect(path.verbAt(2), verbCubicTo);
    expect(path.verbAt(3), verbQuadraticTo);
    expect(path.verbAt(4), verbQuadraticTo);
    // Reflected control of S: (30,10), then its explicit control (30,20).
    expect(path.pointX(4), 30);
    expect(path.pointY(4), 10);
    // Reflected control of T: (70,20).
    expect(path.pointX(9), 70);
    expect(path.pointY(9), 20);
  });

  test('elliptical arcs become bounded cubic segments with exact endpoint', () {
    final Path path = parseSvgPathData('M 0 0 A 10 10 0 0 1 20 0');
    expect(path.verbCount, 3, reason: 'a half-circle is two cubics');
    expect(path.verbAt(1), verbCubicTo);
    expect(path.verbAt(2), verbCubicTo);
    expect(path.pointX(path.pointCount - 1), closeTo(20, 0.0001));
    expect(path.pointY(path.pointCount - 1), closeTo(0, 0.0001));
    expect(path.bounds.width, closeTo(20, 0.001));
    expect(path.bounds.height, closeTo(10, 0.001));
  });

  test('rejects malformed numbers and arc flags with an offset', () {
    expect(
      () => parseSvgPathData('M 0 0 L nope'),
      throwsA(isA<SvgParseException>()),
    );
    expect(
      () => parseSvgPathData('M0 0 A10 10 0 2 0 20 20'),
      throwsA(isA<SvgParseException>()),
    );
  });
}
