/// Dashing: which stretches of a path a pattern keeps.
library;

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/stroke.dart';
import 'package:dart_ui/src/rendering/path/dasher.dart';
import 'package:test/test.dart';

/// Each contour's points: a moveTo starts one, every verb's end point
/// follows.
List<List<Offset>> contours(Path path) {
  final List<List<Offset>> out = <List<Offset>>[];
  var p = 0;
  for (var v = 0; v < path.verbCount; v++) {
    switch (path.verbAt(v)) {
      case verbMoveTo:
        out.add(<Offset>[path.pointAt(p)]);
        p += 1;
      case verbLineTo:
        out.last.add(path.pointAt(p));
        p += 1;
      case verbQuadraticTo:
        out.last.add(path.pointAt(p + 1));
        p += 2;
      case verbCubicTo:
        out.last.add(path.pointAt(p + 2));
        p += 3;
    }
  }
  return out;
}

Path line(Offset a, Offset b) => (PathBuilder()
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy))
    .build();

void main() {
  test('a line is cut into its dashes', () {
    final List<List<Offset>> dashes = contours(dashPath(
        line(Offset.zero, const Offset(100, 0)), const <double>[10, 10]));
    expect(dashes, hasLength(5));
    expect(dashes.first, <Offset>[Offset.zero, const Offset(10, 0)]);
    expect(dashes.last, <Offset>[const Offset(80, 0), const Offset(90, 0)]);
  });

  test('the offset starts the pattern partway in', () {
    final List<List<Offset>> dashes = contours(dashPath(
        line(Offset.zero, const Offset(30, 0)), const <double>[10, 10],
        offset: 5));
    // 5 left of the first dash, a gap, then a whole dash.
    expect(dashes.first, <Offset>[Offset.zero, const Offset(5, 0)]);
    expect(dashes[1], <Offset>[const Offset(15, 0), const Offset(25, 0)]);
  });

  test('a dash that reaches a corner turns it in one piece', () {
    final Path corner = (PathBuilder()
          ..moveTo(0, 0)
          ..lineTo(10, 0)
          ..lineTo(10, 10))
        .build();
    final List<List<Offset>> dashes =
        contours(dashPath(corner, const <double>[15, 100]));
    expect(dashes.single,
        <Offset>[Offset.zero, const Offset(10, 0), const Offset(10, 5)],
        reason: 'one contour through the corner, so the stroker joins it');
  });

  test('a closed contour dashes its closing edge too', () {
    final Path square = (PathBuilder()
          ..moveTo(0, 0)
          ..lineTo(10, 0)
          ..lineTo(10, 10)
          ..lineTo(0, 10)
          ..close())
        .build();
    final List<List<Offset>> dashes =
        contours(dashPath(square, const <double>[35, 100]));
    expect(dashes.single.last, const Offset(0, 5),
        reason: 'past three edges and halfway up the closing one');
  });

  test('a curve stays a curve, and its dashes land on it', () {
    final Path circle =
        (PathBuilder()..addOval(const Rect.fromLTWH(0, 0, 100, 100))).build();
    final Path dashed = dashPath(circle, const <double>[20, 10]);
    var cubics = 0;
    for (var v = 0; v < dashed.verbCount; v++) {
      if (dashed.verbAt(v) == verbCubicTo) cubics++;
      expect(dashed.verbAt(v), isNot(verbLineTo), reason: 'no facets');
    }
    expect(cubics, greaterThan(8));
    for (final List<Offset> dash in contours(dashed)) {
      for (final Offset p in dash) {
        expect((p - const Offset(50, 50)).distance, closeTo(50, 0.05));
      }
    }
    // About 314 around: ten dashes of 20 with gaps of 10, and a piece.
    expect(contours(dashed).length, inInclusiveRange(10, 11));
  });

  test('a zero-length dash is a point, which a round cap draws as a dot', () {
    final List<List<Offset>> dots = contours(dashPath(
        line(Offset.zero, const Offset(40, 0)), const <double>[0, 10]));
    expect(dots, hasLength(5));
    expect(dots.first, <Offset>[Offset.zero, Offset.zero]);
    expect(dots[1].first, const Offset(10, 0));
  });

  test('an unusable or absurdly fine pattern leaves the path solid', () {
    final Path path = line(Offset.zero, const Offset(1e6, 0));
    expect(dashPath(path, const <double>[1, -1]), same(path));
    expect(dashPath(path, const <double>[0, 0]), same(path));
    expect(dashPath(path, const <double>[0.001, 0.001]), same(path),
        reason: 'more pieces than kMaxDashPieces');
  });

  test('StrokeExtras follows SVG: odd lists repeat, bad ones are solid', () {
    expect(StrokeExtras.of(4, null, 0), isNull);
    expect(StrokeExtras.of(4, const <double>[5], 0)!.dashArray, <double>[5, 5]);
    expect(StrokeExtras.of(4, const <double>[1, 2, 3], 0)!.dashArray,
        <double>[1, 2, 3, 1, 2, 3]);
    expect(StrokeExtras.of(4, const <double>[1, -2], 0), isNull);
    expect(StrokeExtras.of(4, const <double>[0, 0], 0), isNull);
    expect(StrokeExtras.of(0.5, null, 0)!.miterLimit, 1);
    expect(StrokeExtras.of(10, null, 3)!.dashOffset, 0,
        reason: 'no dashes, no offset');
    expect(StrokeExtras.of(4, const <double>[2, 2], 1),
        StrokeExtras.of(4, const <double>[2, 2], 1));
  });
}
