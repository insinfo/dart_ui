/// Reading Lottie, checked against numbers computed by hand and against the two
/// sample files.
///
/// The hand-computed half matters more than it looks. A parser tested only
/// against its own output agrees with itself about every misreading, and this
/// format has three misreadings that produce plausible-looking animation:
/// tangents read as absolute, `i`/`o` attached to the wrong segment, and a
/// missing `e` read as "no change". Each of those has a case below with the
/// expected value worked out from the specification rather than from a run.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/graphics/lottie/lottie_model.dart';
import 'package:dart_ui/src/graphics/lottie/lottie_parser.dart';
import 'package:test/test.dart';

/// Wraps [layers] in the smallest composition the parser will accept.
String _composition(String layers, {String assets = '[]'}) => jsonEncode(
      jsonDecode('''
{
  "v": "5.12.1", "nm": "t", "fr": 30, "ip": 0, "op": 60,
  "w": 100, "h": 100, "ddd": 0,
  "assets": $assets,
  "layers": $layers
}
'''),
    );

/// A shape layer carrying one property, for the property cases.
String _layerWith(String transform) => '''
[{"ty": 4, "ind": 1, "nm": "L", "ip": 0, "op": 60, "st": 0, "sr": 1,
  "ks": $transform, "shapes": []}]
''';

void main() {
  group('the composition header', () {
    test('carries what a player needs to run a clock', () {
      final LottieAnimation animation =
          parseLottieJson(_composition(_layerWith('{}')));

      expect(animation.version, '5.12.1');
      expect(animation.frameRate, 30);
      expect(animation.inPoint, 0);
      expect(animation.outPoint, 60);
      expect(animation.width, 100);
      expect(animation.height, 100);
      expect(animation.durationInFrames, 60);
      expect(animation.duration, const Duration(seconds: 2));
    });

    test('a file with no frame rate is refused rather than divided by zero',
        () {
      expect(
        () => parseLottieJson('{"fr": 0, "layers": []}'),
        throwsA(isA<LottieParseException>()),
      );
    });

    test('text that is not JSON is refused by name', () {
      expect(
        () => parseLottieJson('not json at all'),
        throwsA(isA<LottieParseException>()),
      );
    });

    test('layers arrive back to front', () {
      // Lottie lists front to back. Reversing in the parser is what lets the
      // painter walk the list in order; if it ever stops, a two-layer file
      // draws the background over the foreground and looks empty.
      final LottieAnimation animation = parseLottieJson(_composition('''
[{"ty": 4, "ind": 1, "nm": "front", "ip": 0, "op": 60, "st": 0, "sr": 1,
  "ks": {}, "shapes": []},
 {"ty": 4, "ind": 2, "nm": "back", "ip": 0, "op": 60, "st": 0, "sr": 1,
  "ks": {}, "shapes": []}]
'''));

      expect(
        animation.layers.map((LottieLayer l) => l.name),
        <String>['back', 'front'],
      );
    });
  });

  group('properties', () {
    test('a static value is a constant and costs no search', () {
      final LottieAnimation animation = parseLottieJson(
        _composition(_layerWith('{"o": {"a": 0, "k": 42}}')),
      );
      final LottieProperty<double> opacity =
          animation.layers.single.transform.opacity;

      expect(opacity.isAnimated, isFalse);
      expect(opacity.valueAt(0), 42);
      expect(opacity.valueAt(999), 42);
    });

    test('a missing "e" means the next keyframe s, not "no change"', () {
      // The third misreading. An exporter that omits `e` and a parser that
      // trusts it produce an animation that holds every value and then jumps,
      // which reads as "the easing is broken" rather than as a parse bug.
      final LottieAnimation animation = parseLottieJson(
        _composition(_layerWith('''
{"o": {"a": 1, "k": [
  {"t": 0, "s": [0]},
  {"t": 10, "s": [100]},
  {"t": 10}
]}}
''')),
      );
      final LottieProperty<double> opacity =
          animation.layers.single.transform.opacity;

      expect(opacity.isAnimated, isTrue);
      expect(opacity.valueAt(0), 0);
      expect(opacity.valueAt(5), closeTo(50, 1e-9));
      expect(opacity.valueAt(10), 100);
    });

    test('a hold keyframe steps instead of sliding', () {
      final LottieAnimation animation = parseLottieJson(
        _composition(_layerWith('''
{"o": {"a": 1, "k": [
  {"t": 0, "s": [0], "e": [100], "h": 1},
  {"t": 10, "s": [100]}
]}}
''')),
      );
      final LottieProperty<double> opacity =
          animation.layers.single.transform.opacity;

      expect(opacity.valueAt(0), 0);
      expect(opacity.valueAt(9.9), 0, reason: 'held right up to the next key');
      expect(opacity.valueAt(10), 100);
    });

    test('easing control points belong to the segment that starts at them', () {
      // The second misreading. `o` is the first control point and `i` the
      // second, and both sit on the *earlier* keyframe. Attaching `i` to the
      // arriving segment instead mirrors every curve in the file, which looks
      // like an animation with the wrong feel rather than like a bug.
      //
      // The curve below is the standard ease-in-out, control points (0.42, 0)
      // and (0.58, 1). At the midpoint of the segment it must return exactly
      // 0.5 by symmetry, and at a quarter it must be *below* a quarter,
      // because an ease-in starts slowly.
      final LottieAnimation animation = parseLottieJson(
        _composition(_layerWith('''
{"o": {"a": 1, "k": [
  {"t": 0, "s": [0], "e": [100],
   "o": {"x": [0.42], "y": [0]}, "i": {"x": [0.58], "y": [1]}},
  {"t": 100, "s": [100]}
]}}
''')),
      );
      final LottieProperty<double> opacity =
          animation.layers.single.transform.opacity;

      expect(opacity.valueAt(50), closeTo(50, 0.01));
      expect(opacity.valueAt(25), lessThan(25));
      expect(opacity.valueAt(75), greaterThan(75));
    });

    test('and an absent easing is linear, not an ease from a standstill', () {
      // `_controlPoint` returns null and not (0,0) for a missing entry. A
      // bezier with both control points at the origin is a real curve and a
      // very slow start; using it wherever no easing was written would make
      // every plain segment crawl.
      final LottieAnimation animation = parseLottieJson(
        _composition(_layerWith('''
{"o": {"a": 1, "k": [
  {"t": 0, "s": [0], "e": [100]},
  {"t": 100, "s": [100]}
]}}
''')),
      );

      expect(
        animation.layers.single.transform.opacity.valueAt(25),
        closeTo(25, 1e-9),
      );
    });

    test('a scalar written bare and a scalar in a list read the same', () {
      // Both spellings occur for the same property in the same file, depending
      // on which tool touched it last.
      final LottieAnimation bare = parseLottieJson(
        _composition(_layerWith('{"r": {"a": 0, "k": 45}}')),
      );
      final LottieAnimation listed = parseLottieJson(
        _composition(_layerWith('{"r": {"a": 0, "k": [45]}}')),
      );

      expect(bare.layers.single.transform.rotation.valueAt(0), 45);
      expect(listed.layers.single.transform.rotation.valueAt(0), 45);
    });

    test('a position with spatial tangents arcs instead of sliding', () {
      // A straight line from (0,0) to (100,0) with both tangents pulling
      // 50 units down: at the midpoint the y must be off the line. The exact
      // value is the cubic at t = 0.5 with control points (50, -50) and
      // (50, -50): y = 3/8 * -50 + 3/8 * -50 = -37.5.
      final LottieAnimation animation = parseLottieJson(
        _composition(_layerWith('''
{"p": {"a": 1, "k": [
  {"t": 0, "s": [0, 0], "e": [100, 0],
   "to": [50, -50], "ti": [-50, -50]},
  {"t": 100, "s": [100, 0]}
]}}
''')),
      );
      final Offset middle =
          animation.layers.single.transform.position.valueAt(50);

      expect(middle.dx, closeTo(50, 1e-9));
      expect(middle.dy, closeTo(-37.5, 1e-9));
    });

    test('and without them it is a straight line', () {
      final LottieAnimation animation = parseLottieJson(
        _composition(_layerWith('''
{"p": {"a": 1, "k": [
  {"t": 0, "s": [0, 0], "e": [100, 40]},
  {"t": 100, "s": [100, 40]}
]}}
''')),
      );
      final Offset middle =
          animation.layers.single.transform.position.valueAt(50);

      expect(middle.dx, closeTo(50, 1e-9));
      expect(middle.dy, closeTo(20, 1e-9));
    });

    test('colours normalise whichever scale they were written in', () {
      LottieColor colorOf(String k) {
        final LottieAnimation animation = parseLottieJson(_composition('''
[{"ty": 4, "ind": 1, "nm": "L", "ip": 0, "op": 60, "st": 0, "sr": 1, "ks": {},
  "shapes": [{"ty": "fl", "nm": "f", "c": {"a": 0, "k": $k},
              "o": {"a": 0, "k": 100}}]}]
'''));
        final LottieShapeFill fill =
            animation.layers.single.shapes.single as LottieShapeFill;
        return fill.color.valueAt(0);
      }

      final LottieColor normalised = colorOf('[1, 0.5, 0, 1]');
      final LottieColor bytes = colorOf('[255, 128, 0, 1]');

      expect(normalised.r, 1);
      expect(bytes.r, 1);
      expect(bytes.g, closeTo(128 / 255, 1e-9));
      expect(bytes.b, 0);
    });
  });

  group('the timing bezier', () {
    test('is the identity when its control points are on the diagonal', () {
      for (final double x in <double>[0.1, 0.25, 0.5, 0.9]) {
        expect(
          solveTimingBezier(const Offset(0.3, 0.3), const Offset(0.7, 0.7), x),
          closeTo(x, 1e-6),
        );
      }
    });

    test('pins both ends exactly', () {
      const Offset out = Offset(0.42, 0);
      const Offset into = Offset(0.58, 1);
      expect(solveTimingBezier(out, into, 0), 0);
      expect(solveTimingBezier(out, into, 1), 1);
    });

    test('inverts x rather than evaluating at the parameter', () {
      // The mistake this catches: treating `x` as the bezier parameter `t`.
      // For control points (0.9, 0) and (1, 0.1) - a hard ease-in - evaluating
      // at t = 0.5 gives y = 3*0.25*0.5*0 + 3*0.5*0.25*0.1 + 0.125 = 0.1625,
      // while the correct answer solves x(t) = 0.5 first, which happens much
      // later, and returns a *smaller* y.
      const Offset out = Offset(0.9, 0);
      const Offset into = Offset(1, 0.1);
      final double solved = solveTimingBezier(out, into, 0.5);

      expect(solved, lessThan(0.1625));
      expect(solved, greaterThan(0));
    });

    test('is monotonic across the unit interval for a sane curve', () {
      const Offset out = Offset(0.42, 0);
      const Offset into = Offset(0.58, 1);
      var previous = -1.0;
      for (var i = 0; i <= 100; i++) {
        final double y = solveTimingBezier(out, into, i / 100);
        expect(y, greaterThanOrEqualTo(previous - 1e-9));
        previous = y;
      }
    });
  });

  group('unsupported features are named, not dropped in silence', () {
    test('a gradient fill is reported and the file still parses', () {
      final LottieAnimation animation = parseLottieJson(_composition('''
[{"ty": 4, "ind": 1, "nm": "L", "ip": 0, "op": 60, "st": 0, "sr": 1, "ks": {},
  "shapes": [{"ty": "gf", "nm": "g"},
             {"ty": "fl", "nm": "f", "c": {"a": 0, "k": [0, 0, 0, 1]},
              "o": {"a": 0, "k": 100}}]}]
'''));

      expect(animation.unsupported, contains('gradient fill'));
      expect(
        animation.layers.single.shapes,
        hasLength(1),
        reason: 'the fill it could draw is still there',
      );
    });

    test('a text layer is named and left out', () {
      final LottieAnimation animation = parseLottieJson(_composition('''
[{"ty": 5, "ind": 1, "nm": "T", "ip": 0, "op": 60, "st": 0, "sr": 1, "ks": {}}]
'''));

      expect(animation.unsupported, contains('text layers'));
      expect(animation.layers, isEmpty);
    });

    test('a track matte is named on a layer that still draws', () {
      final LottieAnimation animation = parseLottieJson(_composition('''
[{"ty": 4, "ind": 1, "nm": "L", "tt": 1, "ip": 0, "op": 60, "st": 0,
  "sr": 1, "ks": {}, "shapes": []}]
'''));

      expect(animation.unsupported, contains('track mattes'));
      expect(animation.layers, hasLength(1));
    });
  });

  group('the sample files', () {
    final File json = File('test/data/Cute Mascot Jumping Character.json');
    final File dot = File('test/data/Cute Mascot Jumping Character.lottie');
    final String? skip = json.existsSync() && dot.existsSync()
        ? null
        : 'the Lottie sample files are not in test/data';

    test('the JSON one parses whole, with nothing unsupported', () {
      final LottieAnimation animation =
          parseLottieJson(json.readAsStringSync());

      expect(animation.version, '5.12.1');
      expect(animation.frameRate, 30);
      expect(animation.outPoint, 165);
      expect(animation.width, 1080);
      expect(animation.height, 1080);
      expect(
        animation.layers,
        hasLength(3),
        reason: 'one precomp layer and two shape layers; the matte sources '
            'are not among them',
      );
      expect(animation.precomps, hasLength(1));
      // Not empty, and the one entry is worth spelling out rather than
      // loosening the matcher over. Two leg layers carry an inverted alpha
      // track matte (`tt: 2`) fed by two `td: 1` source layers. The sources
      // are left out - correct either way, since no player draws a matte
      // source in its own right - and the two legs draw unmatted, which is
      // the visible half of the limitation.
      expect(animation.unsupported, <String>{'track mattes'});
    }, skip: skip);

    test('the dotLottie one is the same animation', () {
      // Same content, one of them through the ZIP reader. Comparing the two is
      // what proves the container path rather than merely exercising it.
      final LottieAnimation plain = parseLottieJson(json.readAsStringSync());
      final LottieAnimation zipped = parseLottieBytes(
        Uint8List.fromList(dot.readAsBytesSync()),
      );

      expect(zipped.version, plain.version);
      expect(zipped.frameRate, plain.frameRate);
      expect(zipped.outPoint, plain.outPoint);
      expect(zipped.width, plain.width);
      expect(zipped.height, plain.height);
      expect(zipped.layers.length, plain.layers.length);
      expect(zipped.precomps.keys, plain.precomps.keys);
      expect(zipped.unsupported, plain.unsupported);
    }, skip: skip);

    test('and its layers animate rather than sitting still', () {
      // A parser that silently produced constants everywhere would pass every
      // structural assertion above. This asks whether anything moves.
      final LottieAnimation animation =
          parseLottieJson(json.readAsStringSync());

      var animated = 0;
      void countShapes(List<LottieShapeElement> shapes) {
        for (final LottieShapeElement shape in shapes) {
          switch (shape) {
            case LottieShapeGroup(:final List<LottieShapeElement> children):
              countShapes(children);
            case LottieShapePath(:final LottieProperty<LottieShapeData> data):
              if (data.isAnimated) animated++;
            case LottieShapeTransform(:final LottieTransform transform):
              if (transform.position.isAnimated ||
                  transform.rotation.isAnimated ||
                  transform.scale.isAnimated) {
                animated++;
              }
            default:
              break;
          }
        }
      }

      for (final LottiePrecomp precomp in animation.precomps.values) {
        for (final LottieLayer layer in precomp.layers) {
          countShapes(layer.shapes);
          if (layer.transform.position.isAnimated) animated++;
        }
      }
      for (final LottieLayer layer in animation.layers) {
        countShapes(layer.shapes);
      }

      expect(
        animated,
        greaterThan(0),
        reason: 'a bouncing mascot that reads as entirely static is a parser '
            'that turned every keyframe list into a constant',
      );
    }, skip: skip);
  });
}
