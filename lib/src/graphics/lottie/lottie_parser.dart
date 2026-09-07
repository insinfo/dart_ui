/// Reading Lottie JSON, and the dotLottie ZIP container it sometimes arrives
/// in, into the immutable model in `lottie_model.dart`.
///
/// ## What it refuses, and why refusing is the point
///
/// The subset implemented here is shape animation: shape layers, precomps, null
/// layers, groups, bezier paths, ellipses, rounded rectangles, fills, strokes
/// and transforms. A file using anything else — text, images, masks, track
/// mattes, trim paths, gradients, repeaters, merge paths, 3D — still parses and
/// still plays; the unsupported element is left out and its name is recorded in
/// [LottieAnimation.unsupported].
///
/// Recording rather than throwing, and recording rather than ignoring, are two
/// separate decisions and both matter. Throwing would mean a file with one
/// decorative gradient does not play at all, which is worse for the viewer than
/// a file that plays with one shape flat. Ignoring in silence would mean the
/// difference between "this animation looks wrong" and "this animation uses
/// something we do not draw" is invisible — and that is the failure this
/// repository keeps running into from the other direction, where an absent
/// exception was read as a correct result.
///
/// ## The three things this format gets wrong on a first reading
///
/// They are called out here because each produces output that looks like a bug
/// somewhere else:
///
///   1. **Bezier tangents are relative to their own vertex.** `i[n]` and `o[n]`
///      are offsets from `v[n]`, not absolute control points. Read as absolute,
///      every shape collapses towards the origin.
///   2. **`i` and `o` on a keyframe both describe the segment that starts
///      there.** `o` is the first control point of the timing curve and `i` is
///      the second. `i` reads like it belongs to the arriving segment and does
///      not.
///   3. **`e` is optional.** Newer exporters omit the end value and mean "the
///      next keyframe's `s`". A parser that trusts `e` produces an animation
///      that holds every value until the next keyframe and then jumps.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../container/zip_archive.dart';
import 'lottie_model.dart';

/// Raised when the bytes or the text are not a Lottie animation at all.
///
/// Distinct from an unsupported *feature*, which is recorded and played around.
/// This is "there is nothing here to play".
final class LottieParseException implements Exception {
  const LottieParseException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() =>
      'LottieParseException: $message${detail == null ? '' : ' ($detail)'}';
}

/// Parses Lottie JSON text.
LottieAnimation parseLottieJson(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (error) {
    throw LottieParseException('the source is not JSON', detail: '$error');
  }
  if (decoded is! Map<String, Object?>) {
    throw LottieParseException(
      'a Lottie animation is a JSON object',
      detail: 'found ${decoded.runtimeType}',
    );
  }
  return _Parser(decoded).parse();
}

/// Parses either plain Lottie JSON or a dotLottie container, deciding from the
/// bytes rather than from a file name.
///
/// A `.lottie` is a ZIP whose first two bytes are `PK`; a `.json` starts with
/// whitespace and then `{`. Sniffing is not a shortcut here — the same bytes
/// arrive from a file, from a network response and from an asset, and only one
/// of those three reliably carries an extension.
LottieAnimation parseLottieBytes(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    return parseDotLottie(bytes);
  }
  return parseLottieJson(utf8.decode(bytes, allowMalformed: true));
}

/// Parses a dotLottie (`.lottie`) container.
///
/// The container holds `manifest.json` and one or more animations under
/// `animations/`. [animationId] picks one; without it the manifest's first
/// animation wins, and without a usable manifest the first `animations/*.json`
/// in the archive does — a container with exactly one animation, which is what
/// every export tool produces, therefore needs no manifest at all.
LottieAnimation parseDotLottie(Uint8List bytes, {String? animationId}) {
  final ZipArchive archive = ZipArchive.parse(bytes);
  if (archive.entries.isEmpty) {
    throw const LottieParseException(
      'the dotLottie container has no readable entries',
      detail: 'not a ZIP, or truncated',
    );
  }

  String? wanted = animationId;
  if (wanted == null) {
    final ZipEntry? manifest = archive['manifest.json'];
    if (manifest != null) {
      try {
        final Object? decoded = jsonDecode(manifest.readAsString());
        if (decoded is Map<String, Object?>) {
          final Object? animations = decoded['animations'];
          if (animations is List && animations.isNotEmpty) {
            final Object? first = animations.first;
            if (first is Map<String, Object?>) {
              wanted = first['id'] as String?;
            }
          }
        }
      } on FormatException {
        // A container whose manifest is corrupt but whose animation is fine is
        // still playable, and refusing it would help nobody. The fallback
        // below finds the animation by path.
        wanted = null;
      }
    }
  }

  if (wanted != null) {
    final ZipEntry? entry = archive['animations/$wanted.json'];
    if (entry != null) return parseLottieJson(entry.readAsString());
  }
  for (final String name in archive.names) {
    if (name.startsWith('animations/') && name.endsWith('.json')) {
      return parseLottieJson(archive[name]!.readAsString());
    }
  }
  throw LottieParseException(
    'the dotLottie container holds no animation',
    detail: 'entries: ${archive.names.join(', ')}',
  );
}

/// Names the animation could carry for a feature that is not drawn.
///
/// Kept as a table rather than inline strings so the set in
/// [LottieAnimation.unsupported] uses one spelling per feature and a player can
/// show it to a person.
const Map<String, String> _unsupportedShapeTypes = <String, String>{
  'gf': 'gradient fill',
  'gs': 'gradient stroke',
  'tm': 'trim path',
  'rp': 'repeater',
  'mm': 'merge path',
  'rd': 'rounded corners',
  'pb': 'pucker and bloat',
  'tw': 'twist',
  'op': 'offset path',
  'zz': 'zig zag',
  'sr': 'polystar',
};

final class _Parser {
  _Parser(this.root);

  final Map<String, Object?> root;
  final Set<String> unsupported = <String>{};

  LottieAnimation parse() {
    final double frameRate = _double(root['fr'], 30);
    if (frameRate <= 0) {
      throw LottieParseException(
        'the composition has no usable frame rate',
        detail: 'fr = ${root['fr']}',
      );
    }
    if (_double(root['ddd'], 0) != 0) {
      // The file declares 3D layers. They are parsed as 2D, which is right for
      // the many files that set the flag and never use a Z value, and visibly
      // flat for the few that do. Named either way.
      unsupported.add('3D layers');
    }

    final Map<String, LottiePrecomp> precomps = <String, LottiePrecomp>{};
    final Object? assets = root['assets'];
    if (assets is List) {
      for (final Object? asset in assets) {
        if (asset is! Map<String, Object?>) continue;
        final Object? layers = asset['layers'];
        final String? id = asset['id'] as String?;
        if (id == null) continue;
        if (layers is List) {
          precomps[id] = LottiePrecomp(
            id: id,
            layers: _layers(layers),
            frameRate: asset.containsKey('fr') ? _double(asset['fr'], 0) : null,
          );
        } else if (asset.containsKey('p') || asset.containsKey('u')) {
          unsupported.add('image assets');
        }
      }
    }

    final Object? layers = root['layers'];
    if (layers is! List) {
      throw const LottieParseException('the composition has no layers');
    }

    return LottieAnimation(
      version: root['v'] as String? ?? '',
      name: root['nm'] as String? ?? '',
      frameRate: frameRate,
      inPoint: _double(root['ip'], 0),
      outPoint: _double(root['op'], 0),
      width: _double(root['w'], 0),
      height: _double(root['h'], 0),
      layers: _layers(layers),
      precomps: precomps,
      unsupported: Set<String>.unmodifiable(unsupported),
    );
  }

  List<LottieLayer> _layers(List<Object?> raw) {
    final List<LottieLayer> layers = <LottieLayer>[];
    for (final Object? entry in raw) {
      if (entry is! Map<String, Object?>) continue;
      final LottieLayer? layer = _layer(entry);
      if (layer != null) layers.add(layer);
    }
    // Lottie lists layers front-to-back — index 0 is on top — and a painter
    // draws back-to-front. Reversing once here means the painter never has to
    // remember, and a reversed list read back from the model still names the
    // layers the file named.
    return List<LottieLayer>.unmodifiable(layers.reversed);
  }

  LottieLayer? _layer(Map<String, Object?> raw) {
    final int code = _double(raw['ty'], -1).toInt();
    final LottieLayerType? type = LottieLayerType.fromCode(code);
    if (type == null) {
      unsupported.add('layer type $code');
      return null;
    }
    switch (type) {
      case LottieLayerType.text:
        unsupported.add('text layers');
        return null;
      case LottieLayerType.image:
        unsupported.add('image layers');
        return null;
      case LottieLayerType.precomp:
      case LottieLayerType.solid:
      case LottieLayerType.nullLayer:
      case LottieLayerType.shape:
        break;
    }
    if (raw.containsKey('tt')) unsupported.add('track mattes');
    if (_double(raw['td'], 0) != 0) {
      // A matte *source*: the layer whose alpha shapes the one below it. It is
      // never drawn in its own right, matte implemented or not, so leaving it
      // out is correct rather than a compromise - drawing it would put an
      // extra silhouette on screen that no correct player shows. The matted
      // layer itself is kept and drawn unmatted, which is the visible half of
      // the limitation and is why `track mattes` is recorded above.
      unsupported.add('track mattes');
      return null;
    }
    final Object? masks = raw['masksProperties'];
    if (masks is List && masks.isNotEmpty) unsupported.add('masks');
    if (raw['ef'] is List) unsupported.add('layer effects');

    final Object? shapes = raw['shapes'];
    return LottieLayer(
      index: _double(raw['ind'], 0).toInt(),
      name: raw['nm'] as String? ?? '',
      type: type,
      transform: _transform(raw['ks']),
      inPoint: _double(raw['ip'], 0),
      outPoint: _double(raw['op'], 0),
      startTime: _double(raw['st'], 0),
      timeStretch: _double(raw['sr'], 1),
      parent:
          raw.containsKey('parent') ? _double(raw['parent'], 0).toInt() : null,
      shapes: shapes is List ? _shapes(shapes) : const <LottieShapeElement>[],
      refId: raw['refId'] as String?,
      solidColor: _solidColor(raw['sc']),
      solidWidth: _double(raw['sw'], 0),
      solidHeight: _double(raw['sh'], 0),
      hidden: raw['hd'] == true,
    );
  }

  List<LottieShapeElement> _shapes(List<Object?> raw) {
    final List<LottieShapeElement> shapes = <LottieShapeElement>[];
    for (final Object? entry in raw) {
      if (entry is! Map<String, Object?>) continue;
      if (entry['hd'] == true) continue;
      final LottieShapeElement? shape = _shape(entry);
      if (shape != null) shapes.add(shape);
    }
    return List<LottieShapeElement>.unmodifiable(shapes);
  }

  LottieShapeElement? _shape(Map<String, Object?> raw) {
    final String type = raw['ty'] as String? ?? '';
    final String name = raw['nm'] as String? ?? '';
    switch (type) {
      case 'gr':
        final Object? items = raw['it'];
        return LottieShapeGroup(
          name,
          items is List ? _shapes(items) : const <LottieShapeElement>[],
        );
      case 'sh':
        return LottieShapePath(
          name,
          _shapeProperty(raw['ks']),
          direction: _double(raw['d'], 1).toInt(),
        );
      case 'el':
        return LottieShapeEllipse(
          name,
          _pointProperty(raw['p']),
          _pointProperty(raw['s']),
        );
      case 'rc':
        return LottieShapeRect(
          name,
          _pointProperty(raw['p']),
          _pointProperty(raw['s']),
          _doubleProperty(raw['r'], 0),
        );
      case 'fl':
        return LottieShapeFill(
          name,
          _colorProperty(raw['c']),
          _doubleProperty(raw['o'], 100),
          evenOdd: _double(raw['r'], 1).toInt() == 2,
        );
      case 'st':
        return LottieShapeStroke(
          name,
          _colorProperty(raw['c']),
          _doubleProperty(raw['o'], 100),
          _doubleProperty(raw['w'], 1),
          lineCap: _double(raw['lc'], 2).toInt(),
          lineJoin: _double(raw['lj'], 2).toInt(),
        );
      case 'tr':
        return LottieShapeTransform(name, _transform(raw));
      default:
        unsupported.add(_unsupportedShapeTypes[type] ?? 'shape type "$type"');
        return null;
    }
  }

  LottieTransform _transform(Object? raw) {
    if (raw is! Map<String, Object?>) return LottieTransform.identity;
    // `s` is a two-component scale in percent; some exporters write three
    // components for a 3D layer and the third is dropped by `_pointProperty`.
    return LottieTransform(
      anchor: _pointProperty(raw['a']),
      position: LottiePosition(_pointProperty(raw['p'], spatial: true)),
      scale: _pointProperty(raw['s'], fallback: const Offset(100, 100)),
      rotation: _doubleProperty(raw['r'] ?? raw['rz'], 0),
      opacity: _doubleProperty(raw['o'], 100),
      skew: raw.containsKey('sk') ? _doubleProperty(raw['sk'], 0) : null,
      skewAxis: raw.containsKey('sa') ? _doubleProperty(raw['sa'], 0) : null,
    );
  }

  // -------------------------------------------------------------------------
  // Properties
  // -------------------------------------------------------------------------

  /// The shared shape of every property: `{"a": 0|1, "k": ...}`.
  ///
  /// [read] turns one raw `s`/`e`/`k` value into `T`. Doing the dispatch once
  /// here rather than four times is what keeps the optional-`e` rule and the
  /// easing extraction in a single place; each of the four had its own copy in
  /// the first draft and the copies drifted.
  LottieProperty<T> _property<T>(
    Object? raw,
    T Function(Object? value) read,
    T Function(T a, T b, double t) lerp,
    T fallback, {
    bool spatial = false,
  }) {
    if (raw is! Map<String, Object?>) return LottieConstant<T>(fallback);
    final Object? k = raw['k'];
    final bool animated = _double(raw['a'], 0) != 0;
    if (!animated || k is! List || k.isEmpty || k.first is! Map) {
      return LottieConstant<T>(read(k));
    }

    final List<LottieKeyframe<T>> keyframes = <LottieKeyframe<T>>[];
    for (var i = 0; i < k.length; i++) {
      final Object? entry = k[i];
      if (entry is! Map<String, Object?>) continue;
      if (!entry.containsKey('s')) {
        // The last entry of a modern export is a bare `{"t": n}` marking the
        // end of the final segment. It carries no value and is not a keyframe;
        // the segment before it already knows where it ends.
        continue;
      }
      final T start = read(entry['s']);
      T end;
      if (entry.containsKey('e')) {
        end = read(entry['e']);
      } else if (i + 1 < k.length) {
        final Object? next = k[i + 1];
        end = next is Map<String, Object?> && next.containsKey('s')
            ? read(next['s'])
            : start;
      } else {
        end = start;
      }
      keyframes.add(
        LottieKeyframe<T>(
          frame: _double(entry['t'], 0),
          value: start,
          endValue: end,
          easeOut: _controlPoint(entry['o']),
          easeIn: _controlPoint(entry['i']),
          hold: _double(entry['h'], 0) != 0,
          spatialOut: spatial ? _offset(entry['to']) : null,
          spatialIn: spatial ? _offset(entry['ti']) : null,
        ),
      );
    }
    if (keyframes.isEmpty) return LottieConstant<T>(fallback);
    if (keyframes.length == 1) return LottieConstant<T>(keyframes.first.value);
    return LottieAnimatedProperty<T>(keyframes: keyframes, lerp: lerp);
  }

  LottieProperty<double> _doubleProperty(Object? raw, double fallback) =>
      _property<double>(
        raw,
        (Object? value) => _scalar(value, fallback),
        lerpDouble,
        fallback,
      );

  LottieProperty<Offset> _pointProperty(
    Object? raw, {
    Offset fallback = Offset.zero,
    bool spatial = false,
  }) =>
      _property<Offset>(
        raw,
        (Object? value) => _offset(value) ?? fallback,
        lerpOffset,
        fallback,
        spatial: spatial,
      );

  LottieProperty<LottieColor> _colorProperty(Object? raw) =>
      _property<LottieColor>(
        raw,
        _color,
        LottieColor.lerp,
        LottieColor.black,
      );

  LottieProperty<LottieShapeData> _shapeProperty(Object? raw) =>
      _property<LottieShapeData>(
        raw,
        _shapeData,
        LottieShapeData.lerp,
        LottieShapeData.empty,
      );

  // -------------------------------------------------------------------------
  // Leaf readers
  // -------------------------------------------------------------------------

  /// A scalar that may arrive wrapped in a one-element list.
  ///
  /// Lottie writes an animated scalar's `s` as `[value]` and a static one as
  /// `value`, and both spellings turn up for the same property in the same
  /// file depending on which tool touched it last.
  static double _scalar(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    if (value is List && value.isNotEmpty && value.first is num) {
      return (value.first as num).toDouble();
    }
    return fallback;
  }

  static Offset? _offset(Object? value) {
    if (value is List && value.length >= 2) {
      final Object? x = value[0];
      final Object? y = value[1];
      if (x is num && y is num) return Offset(x.toDouble(), y.toDouble());
    }
    return null;
  }

  /// A timing control point, which Lottie writes as `{"x": .., "y": ..}` where
  /// each may be a number or a one-element list.
  ///
  /// Returns null when the entry is absent, and null means linear. It does
  /// **not** return `(0,0)`: a bezier with both control points at the origin is
  /// a real and very different curve, and conflating "no easing was written"
  /// with "ease from a standstill" makes every un-eased segment start slowly.
  static Offset? _controlPoint(Object? value) {
    if (value is! Map) return null;
    final double x = _scalar(value['x'], double.nan);
    final double y = _scalar(value['y'], double.nan);
    if (x.isNaN || y.isNaN) return null;
    return Offset(x, y);
  }

  static LottieColor _color(Object? value) {
    if (value is! List || value.length < 3) return LottieColor.black;
    double channel(int index) {
      if (index >= value.length) return 1;
      final Object? raw = value[index];
      if (raw is! num) return 1;
      final double v = raw.toDouble();
      // Some exporters write 0..255 rather than 0..1. A channel above 1 can
      // only be the byte spelling, since the normalised one is clamped to 1.
      return v > 1 ? v / 255 : v;
    }

    return LottieColor(channel(0), channel(1), channel(2), channel(3));
  }

  static LottieShapeData _shapeData(Object? value) {
    // An animated shape wraps the object in a one-element list, the same
    // wrapping `_scalar` deals with for numbers.
    Object? raw = value;
    if (raw is List && raw.isNotEmpty) raw = raw.first;
    if (raw is! Map) return LottieShapeData.empty;

    List<Offset> points(Object? source) {
      if (source is! List) return const <Offset>[];
      return <Offset>[
        for (final Object? entry in source) _offset(entry) ?? Offset.zero,
      ];
    }

    final List<Offset> vertices = points(raw['v']);
    List<Offset> inTangents = points(raw['i']);
    List<Offset> outTangents = points(raw['o']);
    // A shape whose tangent lists are short is a polygon, and treating the
    // missing ones as zero draws exactly that. Refusing the shape instead
    // would lose a contour over a detail that has a correct answer.
    if (inTangents.length != vertices.length) {
      inTangents = List<Offset>.generate(vertices.length,
          (int i) => i < inTangents.length ? inTangents[i] : Offset.zero);
    }
    if (outTangents.length != vertices.length) {
      outTangents = List<Offset>.generate(vertices.length,
          (int i) => i < outTangents.length ? outTangents[i] : Offset.zero);
    }
    return LottieShapeData(
      vertices: vertices,
      inTangents: inTangents,
      outTangents: outTangents,
      closed: raw['c'] == true,
    );
  }

  static LottieColor? _solidColor(Object? value) {
    if (value is! String || !value.startsWith('#') || value.length < 7) {
      return null;
    }
    int component(int at) =>
        int.tryParse(value.substring(at, at + 2), radix: 16) ?? 0;
    return LottieColor(
      component(1) / 255,
      component(3) / 255,
      component(5) / 255,
      1,
    );
  }

  static double _double(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;
}
