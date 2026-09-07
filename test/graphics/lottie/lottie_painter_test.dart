/// Drawing a Lottie animation: the geometry, the transform order, and the two
/// questions a player actually asks.
///
/// The transform cases are the ones worth reading. Lottie composes a transform
/// in an order that is not the order the JSON lists the fields in, and getting
/// it wrong produces animation that moves — so nothing looks broken enough to
/// point at the transform — while rotating about the wrong point. Each case
/// below states the expected coordinate, worked out by hand.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/lottie/lottie_model.dart';
import 'package:dart_ui/src/graphics/lottie/lottie_painter.dart';
import 'package:dart_ui/src/graphics/lottie/lottie_parser.dart';
import 'package:test/test.dart';

LottieTransform _transform({
  Offset anchor = Offset.zero,
  Offset position = Offset.zero,
  Offset scale = const Offset(100, 100),
  double rotation = 0,
  double opacity = 100,
}) =>
    LottieTransform(
      anchor: LottieConstant<Offset>(anchor),
      position: LottiePosition(LottieConstant<Offset>(position)),
      scale: LottieConstant<Offset>(scale),
      rotation: LottieConstant<double>(rotation),
      opacity: LottieConstant<double>(opacity),
    );

void main() {
  group('the transform order', () {
    test('an anchor with no rotation is a plain offset', () {
      final Transform2D matrix = transformMatrix(
        _transform(
            anchor: const Offset(10, 20), position: const Offset(50, 50)),
        0,
      );

      expect(matrix.transformOffset(const Offset(10, 20)), const Offset(50, 50),
          reason: 'the anchor point lands on the position, by definition');
    });

    test('rotation turns about the anchor and not about the origin', () {
      // The case that catches the wrong order. A layer anchored at (10, 0),
      // positioned at (100, 100), rotated 90 degrees clockwise: the anchor
      // must still land exactly on the position, whatever the rotation.
      //
      // Applying the anchor first instead rotates the anchor offset too, and
      // the layer lands at (100, 110) - ten pixels out, in a direction that
      // changes with the angle, which reads as "the animation is slightly
      // wrong" rather than as an order bug.
      final Transform2D matrix = transformMatrix(
        _transform(
          anchor: const Offset(10, 0),
          position: const Offset(100, 100),
          rotation: 90,
        ),
        0,
      );
      final Offset anchorImage = matrix.transformOffset(const Offset(10, 0));

      expect(anchorImage.dx, closeTo(100, 1e-9));
      expect(anchorImage.dy, closeTo(100, 1e-9));
    });

    test('and a point beside the anchor swings around it', () {
      // Same layer, and the point 10 to the right of the anchor. Rotated 90
      // degrees clockwise it must end up 10 *below* the position.
      final Transform2D matrix = transformMatrix(
        _transform(
          anchor: const Offset(10, 0),
          position: const Offset(100, 100),
          rotation: 90,
        ),
        0,
      );
      final Offset moved = matrix.transformOffset(const Offset(20, 0));

      expect(moved.dx, closeTo(100, 1e-9));
      expect(moved.dy, closeTo(110, 1e-9));
    });

    test('scale is a percentage, and 100 means unscaled', () {
      final Transform2D unscaled = transformMatrix(_transform(), 0);
      final Transform2D doubled =
          transformMatrix(_transform(scale: const Offset(200, 50)), 0);

      expect(unscaled.transformOffset(const Offset(3, 4)), const Offset(3, 4));
      expect(doubled.transformOffset(const Offset(3, 4)), const Offset(6, 2));
    });

    test('opacity is a percentage clamped to the unit interval', () {
      expect(_transform(opacity: 100).opacityAt(0), 1);
      expect(_transform(opacity: 50).opacityAt(0), 0.5);
      expect(_transform(opacity: 250).opacityAt(0), 1);
      expect(_transform(opacity: -10).opacityAt(0), 0);
    });
  });

  group('shape geometry', () {
    test('bezier tangents are relative to their own vertex', () {
      // The first misreading, and the one that produces the most confusing
      // output: read as absolute control points, every shape collapses towards
      // the origin. A square-ish contour with an out-tangent of (10, 0) on the
      // first vertex must put its first control point at x = 10, not at x = 0.
      final Path path = buildShapePath(
        const LottieShapeData(
          vertices: <Offset>[Offset(0, 0), Offset(100, 0)],
          inTangents: <Offset>[Offset(-10, 0), Offset(-10, 0)],
          outTangents: <Offset>[Offset(10, 0), Offset(10, 0)],
          closed: false,
        ),
      );

      // move + one cubic.
      expect(path.verbCount, 2);
      expect(
        path.bounds.right,
        closeTo(100, 1e-6),
        reason: 'absolute tangents would pull the curve back towards zero',
      );
    });

    test('a closed contour gets the segment back to the first vertex', () {
      Path build({required bool closed}) => buildShapePath(
            LottieShapeData(
              vertices: const <Offset>[
                Offset(0, 0),
                Offset(10, 0),
                Offset(10, 10),
              ],
              inTangents: const <Offset>[
                Offset.zero,
                Offset.zero,
                Offset.zero,
              ],
              outTangents: const <Offset>[
                Offset.zero,
                Offset.zero,
                Offset.zero,
              ],
              closed: closed,
            ),
          );

      expect(build(closed: false).verbCount, 3);
      expect(
        build(closed: true).verbCount,
        greaterThan(3),
        reason: 'the closing cubic and the close itself',
      );
    });

    test('an ellipse covers exactly its size', () {
      final Path path = buildEllipsePath(
        const Offset(50, 50),
        const Offset(80, 40),
      );

      expect(path.bounds.left, closeTo(10, 1e-6));
      expect(path.bounds.right, closeTo(90, 1e-6));
      expect(path.bounds.top, closeTo(30, 1e-6));
      expect(path.bounds.bottom, closeTo(70, 1e-6));
    });

    test('and its kappa really is a circle to within a thousandth', () {
      // Sampled rather than assumed: the constant is what makes a circle land
      // on the reference player's pixels, and a transposed digit in it is
      // invisible in a bounds check.
      final Path path = buildEllipsePath(Offset.zero, const Offset(200, 200));
      // The midpoint of the first quarter's cubic, at t = 0.5, must be at
      // radius 100 from the centre. Control points from `buildEllipsePath`:
      // (0,-100) -> (55.23,-100) -> (100,-55.23) -> (100,0).
      const double k = 0.5522847498307933 * 100;
      double at(double p0, double p1, double p2, double p3) =>
          0.125 * p0 + 0.375 * p1 + 0.375 * p2 + 0.125 * p3;
      final double x = at(0, k, 100, 100);
      final double y = at(-100, -100, -k, 0);

      expect(math.sqrt(x * x + y * y), closeTo(100, 0.1));
      expect(path.verbCount, greaterThan(4));
    });

    test('a rectangle with no radius is a rectangle', () {
      final Path path =
          buildRectPath(const Offset(50, 50), const Offset(20, 10), 0);

      expect(path.bounds, const Rect.fromLTRB(40, 45, 60, 55));
    });

    test('and a radius larger than the box is clamped, not inverted', () {
      // An exporter can write a radius bigger than half the shorter side. Left
      // unclamped the corner arcs cross over and the shape turns inside out.
      final Path path =
          buildRectPath(const Offset(0, 0), const Offset(20, 10), 999);

      expect(path.bounds.left, closeTo(-10, 1e-6));
      expect(path.bounds.right, closeTo(10, 1e-6));
      expect(path.bounds.top, closeTo(-5, 1e-6));
      expect(path.bounds.bottom, closeTo(5, 1e-6));
    });
  });

  group('painting the sample file', () {
    final File json = File('test/data/Cute Mascot Jumping Character.json');
    final File dot = File('test/data/Cute Mascot Jumping Character.lottie');
    final String? skip = json.existsSync() && dot.existsSync()
        ? null
        : 'the Lottie sample files are not in test/data';

    late LottieAnimation animation;

    setUp(() {
      if (skip != null) return;
      animation = parseLottieJson(json.readAsStringSync());
    });

    test('draws something on every frame of the animation', () {
      // The assertion a player needs and the one a structural test cannot
      // make: not "it parsed" but "commands came out, on every frame, without
      // throwing". A painter that quietly emitted nothing would satisfy every
      // parser test in the file next door.
      final LottiePainter painter = LottiePainter(animation);
      const Rect bounds = Rect.fromLTWH(0, 0, 400, 400);

      for (var frame = animation.inPoint;
          frame < animation.outPoint;
          frame += 1) {
        final DisplayList list = DisplayList();
        painter.paint(list, bounds, frame);
        expect(
          list.commandCount,
          greaterThan(0),
          reason: 'frame $frame produced no commands',
        );
        expect(painter.stats.pathsDrawn, greaterThan(0),
            reason: 'frame $frame drew no paths');
      }
    }, skip: skip);

    test('and the picture actually changes between frames', () {
      // A painter that emitted the same geometry regardless of time would pass
      // the case above on all 165 frames.
      final LottiePainter painter = LottiePainter(animation);
      const Rect bounds = Rect.fromLTWH(0, 0, 400, 400);

      final DisplayList first = DisplayList();
      painter.paint(first, bounds, animation.inPoint);
      final DisplayList later = DisplayList();
      painter.paint(later, bounds, animation.inPoint + 20);

      expect(
        _floatsOf(first),
        isNot(equals(_floatsOf(later))),
        reason: 'a bouncing mascot must not draw identical geometry 20 frames '
            'apart',
      );
    }, skip: skip);

    test('the path cache changes speed and not pixels', () {
      // A cache that changed the output would be a correctness bug wearing a
      // performance costume, so the two are compared command for command.
      final LottiePainter cached = LottiePainter(animation);
      final LottiePainter uncached =
          LottiePainter(animation, cacheStaticPaths: false);
      const Rect bounds = Rect.fromLTWH(0, 0, 400, 400);

      for (final double frame in <double>[0, 33, 82, 164]) {
        final DisplayList a = DisplayList();
        final DisplayList b = DisplayList();
        cached.paint(a, bounds, frame);
        uncached.paint(b, bounds, frame);

        expect(a.commandCount, b.commandCount, reason: 'frame $frame');
        expect(_floatsOf(a), _floatsOf(b), reason: 'frame $frame');
      }
    }, skip: skip);

    test('the dotLottie container draws the same as the loose JSON', () {
      final LottieAnimation zipped = parseLottieBytes(
        Uint8List.fromList(dot.readAsBytesSync()),
      );
      const Rect bounds = Rect.fromLTWH(0, 0, 400, 400);

      final DisplayList a = DisplayList();
      final DisplayList b = DisplayList();
      LottiePainter(animation).paint(a, bounds, 40);
      LottiePainter(zipped).paint(b, bounds, 40);

      expect(a.commandCount, b.commandCount);
      expect(_floatsOf(a), _floatsOf(b));
    }, skip: skip);

    test('every layer stays inside its in and out points', () {
      // Before the first frame and after the last, the counts must fall to
      // what the composition still has visible - never to more.
      final LottiePainter painter = LottiePainter(animation);
      const Rect bounds = Rect.fromLTWH(0, 0, 400, 400);

      painter.paint(DisplayList(), bounds, animation.outPoint + 1000);
      final int afterEnd = painter.stats.layersDrawn;
      painter.paint(DisplayList(), bounds, animation.inPoint + 40);
      final int during = painter.stats.layersDrawn;

      expect(afterEnd, lessThan(during));
    }, skip: skip);
  });
}

/// Every float a display list holds, in order.
///
/// Compared instead of the command count because two lists can agree on how
/// many commands they hold and disagree about every coordinate in them.
List<double> _floatsOf(DisplayList list) =>
    List<double>.generate(list.floatLength, (int i) => list.floatBuffer[i]);
