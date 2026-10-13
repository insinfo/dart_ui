/// Two-colour pattern fills - CorelDRAW's pattern fill: stripes, hatching,
/// dots, a grid, a chequerboard - as geometry cut to the shape.
///
/// The marks are made as outlines and intersected with the shape's own by
/// [PathBoolean], so a pattern is as crisp at any zoom as the shape is and
/// draws the same on every backend; a clip to a path is the one thing the
/// display list cannot replay. The pattern lives in document units,
/// anchored at the centre of the object's box: its size is what it says
/// whatever the object's scale, and a stretched ellipse has round dots.
///
/// Cutting is the expensive part, so the result is kept per object until
/// its geometry, its placement or its fill changes, and a mark wholly
/// inside the shape - every corner inside, the commonest case - is kept as
/// it is.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../graphics/vector/constants.dart';
import '../graphics/vector/primitives.dart';
import '../graphics/vector/selectable_objects.dart' show applyTrafoToPoint;
import '../graphics/vector/style.dart';
import 'path_boolean.dart';

abstract final class VectorPatterns {
  /// The pattern names [FillDescriptor.patternId] takes.
  static const List<String> kinds = <String>[
    'hatch',
    'crosshatch',
    'diagonal',
    'dots',
    'grid',
    'checker',
  ];

  /// The texture names [FillDescriptor.patternId] takes - CorelDRAW's
  /// texture fill: procedural noise between the fill colour and the
  /// background, drawn as an image rather than as marks.
  static const List<String> textures = <String>['clouds', 'paper', 'noise'];

  /// Whether [id] names a texture rather than a pattern of marks.
  static bool isTexture(String? id) => textures.contains(id);

  /// The texture's value at [x], [y] (in units of the texture's size): 0
  /// is the background colour, 1 the fill colour. Deterministic - the same
  /// point always gives the same value - so a redraw never shimmers.
  static double textureAt(String kind, double x, double y) {
    switch (kind) {
      case 'paper':
        // Fine fibre: several octaves of small noise, most of it light.
        return 0.15 + 0.5 * _fbm(x * 4, y * 4, 4);
      case 'noise':
        // Grain: noise at about a pixel of the texture's size.
        return _value(x * 3, y * 3);
      default: // clouds
        return _fbm(x * 0.5, y * 0.5, 5);
    }
  }

  static double _fbm(double x, double y, int octaves) {
    double sum = 0, amplitude = 0.5, frequency = 1, total = 0;
    for (int i = 0; i < octaves; i++) {
      sum += amplitude * _value(x * frequency, y * frequency);
      total += amplitude;
      amplitude *= 0.5;
      frequency *= 2;
    }
    return sum / total;
  }

  /// Smooth value noise in 0..1.
  static double _value(double x, double y) {
    final int xi = x.floor();
    final int yi = y.floor();
    final double fx = x - xi;
    final double fy = y - yi;
    final double u = fx * fx * (3 - 2 * fx);
    final double v = fy * fy * (3 - 2 * fy);
    final double a = _hash(xi, yi);
    final double b = _hash(xi + 1, yi);
    final double c = _hash(xi, yi + 1);
    final double d = _hash(xi + 1, yi + 1);
    return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v;
  }

  static double _hash(int x, int y) {
    int h = (x * 374761393 + y * 668265263) & 0xFFFFFFFF;
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF;
    return ((h ^ (h >> 16)) & 0xFFFF) / 0xFFFF;
  }

  static final Expando<_Cut> _cuts = Expando<_Cut>();

  /// [object]'s pattern marks, cut to its outline, in document units - or
  /// empty when its fill is no pattern.
  static List<VectorPath> marksOf(PrimitiveObject object) {
    final FillDescriptor fill = object.style.fill;
    final List<VectorPath>? shape = object.cachePaths;
    if (!fill.isPattern ||
        isTexture(fill.patternId) ||
        shape == null ||
        shape.isEmpty) {
      return const <VectorPath>[];
    }
    final List<double> trafo = object.trafo;
    final _Cut? cached = _cuts[object];
    if (cached != null &&
        identical(cached.shape, shape) &&
        _same(cached.trafo, trafo) &&
        cached.kind == fill.patternId &&
        cached.size == fill.patternSize &&
        cached.angle == fill.patternAngle) {
      return cached.marks;
    }
    final List<VectorPath> marks = cut(
      placed(shape, trafo),
      fill.patternId!,
      size: fill.patternSize,
      angle: fill.patternAngle,
    );
    _cuts[object] = _Cut(shape, List<double>.of(trafo), fill.patternId!,
        fill.patternSize, fill.patternAngle, marks);
    return marks;
  }

  /// Where [object]'s pattern is anchored, in document units: the centre of
  /// its placed outline's box. SVG export tiles from the same point.
  static Offset? anchorOf(PrimitiveObject object) {
    final List<VectorPath>? shape = object.cachePaths;
    if (shape == null) return null;
    return _bounds(placed(shape, object.trafo))?.center;
  }

  /// [paths] moved by [trafo] into document units.
  static List<VectorPath> placed(List<VectorPath> paths, List<double> trafo) =>
      <VectorPath>[
        for (final VectorPath path in paths)
          VectorPath(
            start: applyTrafoToPoint(path.start, trafo),
            points: <Object>[
              for (final Object point in path.points)
                if (point is CurvePoint)
                  CurvePoint(
                    applyTrafoToPoint(point.control1, trafo),
                    applyTrafoToPoint(point.control2, trafo),
                    applyTrafoToPoint(point.endpoint, trafo),
                    point.nodeType,
                  )
                else if (point is Offset)
                  applyTrafoToPoint(point, trafo),
            ],
            closure: path.closure,
          ),
      ];

  static bool _same(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The marks of pattern [kind] cut to [shape].
  static List<VectorPath> cut(
    List<VectorPath> shape,
    String kind, {
    double size = 8,
    double angle = 0,
  }) {
    final Rect? box = _bounds(shape);
    if (box == null || size <= 0) return const <VectorPath>[];
    // Not more than this many marks: a pattern finer than the shape can
    // show is a grey, and cutting a hundred thousand dots is a hang.
    final double period = math.max(size, math.max(box.width, box.height) / 200);
    final List<VectorPath> out = <VectorPath>[];
    for (final List<Offset> mark in _marks(kind, box, period, angle)) {
      out.addAll(_clip(_polygon(mark), shape));
    }
    return out;
  }

  /// [kind]'s marks covering [box], each a closed polygon.
  static Iterable<List<Offset>> _marks(
      String kind, Rect box, double period, double degrees) sync* {
    final Offset centre = box.center;
    final double reach =
        math.sqrt(box.width * box.width + box.height * box.height) / 2 + period;
    final int count = (reach / period).ceil();
    final double turn = -degrees * math.pi / 180;
    Offset place(double x, double y, [double extra = 0]) {
      final double a = turn + extra;
      return Offset(centre.dx + x * math.cos(a) - y * math.sin(a),
          centre.dy + x * math.sin(a) + y * math.cos(a));
    }

    List<Offset> stripe(double y, double thickness, [double extra = 0]) =>
        <Offset>[
          place(-reach, y - thickness / 2, extra),
          place(reach, y - thickness / 2, extra),
          place(reach, y + thickness / 2, extra),
          place(-reach, y + thickness / 2, extra),
        ];

    switch (kind) {
      case 'hatch' || 'diagonal':
        final double extra = kind == 'diagonal' ? -math.pi / 4 : 0;
        for (int i = -count; i <= count; i++) {
          yield stripe(i * period, period * 0.25, extra);
        }
      case 'crosshatch' || 'grid':
        final double thickness = period * (kind == 'grid' ? 0.08 : 0.2);
        for (int i = -count; i <= count; i++) {
          yield stripe(i * period, thickness);
          yield stripe(i * period, thickness, math.pi / 2);
        }
      case 'dots':
        final double r = period * 0.22;
        for (int i = -count; i <= count; i++) {
          for (int j = -count; j <= count; j++) {
            final Offset c = place(i * period, j * period);
            if (!_near(c, box, r)) continue;
            yield <Offset>[
              for (int k = 0; k < 12; k++)
                c +
                    Offset(math.cos(k * math.pi / 6) * r,
                        math.sin(k * math.pi / 6) * r),
            ];
          }
        }
      case 'checker':
        for (int i = -count; i <= count; i++) {
          for (int j = -count; j <= count; j++) {
            if ((i + j).isOdd) continue;
            final double x = i * period;
            final double y = j * period;
            if (!_near(place(x + period / 2, y + period / 2), box, period)) {
              continue;
            }
            yield <Offset>[
              place(x, y),
              place(x + period, y),
              place(x + period, y + period),
              place(x, y + period),
            ];
          }
        }
    }
  }

  static bool _near(Offset p, Rect box, double margin) =>
      p.dx > box.left - margin &&
      p.dx < box.right + margin &&
      p.dy > box.top - margin &&
      p.dy < box.bottom + margin;

  static List<VectorPath> _polygon(List<Offset> points) => <VectorPath>[
        VectorPath(
          start: points.first,
          points: <Object>[...points.skip(1)],
          closure: PathClosure.closed,
        ),
      ];

  /// [mark] ∩ [shape]; the mark itself when all its corners are inside.
  static List<VectorPath> _clip(List<VectorPath> mark, List<VectorPath> shape) {
    final List<Offset> corners = <Offset>[
      mark.first.start,
      for (final Object p in mark.first.points) p as Offset,
    ];
    final bool allInside =
        corners.every((Offset c) => PathBoolean.winding(shape, c) != 0);
    if (allInside) return mark;
    return PathBoolean.apply(mark, shape, PathBooleanOperation.intersect);
  }

  static Rect? _bounds(List<VectorPath> paths) {
    double left = double.infinity, top = double.infinity;
    double right = double.negativeInfinity, bottom = double.negativeInfinity;
    void add(Offset p) {
      left = math.min(left, p.dx);
      top = math.min(top, p.dy);
      right = math.max(right, p.dx);
      bottom = math.max(bottom, p.dy);
    }

    for (final VectorPath path in paths) {
      add(path.start);
      for (final Object point in path.points) {
        if (point is CurvePoint) {
          add(point.control1);
          add(point.control2);
          add(point.endpoint);
        } else if (point is Offset) {
          add(point);
        }
      }
    }
    if (!left.isFinite || right <= left || bottom <= top) return null;
    return Rect.fromLTRB(left, top, right, bottom);
  }
}

final class _Cut {
  _Cut(this.shape, this.trafo, this.kind, this.size, this.angle, this.marks);

  final List<VectorPath> shape;
  final List<double> trafo;
  final String kind;
  final double size;
  final double angle;
  final List<VectorPath> marks;
}
