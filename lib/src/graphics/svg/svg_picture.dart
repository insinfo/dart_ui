/// A compact, renderer-independent SVG picture model.
library;

import 'dart:math' as math;

import '../../foundation/lru_cache.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../geometry/transform2d.dart';
import '../display_list_opcodes.dart';
import '../xml/xml.dart';
import 'svg_path.dart';

final class SvgLimits {
  const SvgLimits({
    this.maxSourceCharacters = 4 * 1024 * 1024,
    this.maxElements = 10000,
    this.maxPathCharacters = 1024 * 1024,
  });

  final int maxSourceCharacters;
  final int maxElements;
  final int maxPathCharacters;
}

/// One vector path and its resolved presentation attributes.
final class SvgDrawPath {
  const SvgDrawPath({
    required this.path,
    this.transform = Transform2D.identity,
    this.fillColor,
    this.strokeColor,
    this.strokeWidth = 1,
    this.fillRule = pathFillRuleNonZero,
  });

  final Path path;

  /// Cumulative SVG transform, retained until display-list recording so
  /// strokes are expanded in local units and then transformed with the path.
  final Transform2D transform;
  final int? fillColor;
  final int? strokeColor;
  final double strokeWidth;
  final int fillRule;
}

/// Parsed SVG geometry, independent from CPU/GPU rasterization.
final class SvgPicture {
  const SvgPicture._(this.size, this.viewBox, this.paths);

  factory SvgPicture.parse(
    String source, {
    SvgLimits limits = const SvgLimits(),
    int currentColor = 0xFF000000,
  }) {
    if (source.length > limits.maxSourceCharacters) {
      throw SvgParseException(
        'SVG source exceeds ${limits.maxSourceCharacters} characters',
      );
    }
    final XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } on XmlParserException catch (error) {
      throw SvgParseException('invalid XML: ${error.message}', source: source);
    }
    final XmlElement root = document.rootElement;
    if (root.name.local.toLowerCase() != 'svg') {
      throw const SvgParseException('root element must be <svg>');
    }

    final Rect? declaredViewBox = _parseViewBox(root.getAttribute('viewBox'));
    final double width = _parseLength(root.getAttribute('width')) ??
        declaredViewBox?.width ??
        300;
    final double height = _parseLength(root.getAttribute('height')) ??
        declaredViewBox?.height ??
        150;
    if (!(width > 0) || !(height > 0)) {
      throw const SvgParseException('SVG width and height must be positive');
    }
    final Rect viewBox = declaredViewBox ?? Rect.fromLTWH(0, 0, width, height);
    if (!(viewBox.width > 0) || !(viewBox.height > 0)) {
      throw const SvgParseException(
          'viewBox width and height must be positive');
    }

    final _SvgCollector collector = _SvgCollector(limits);
    collector.walk(
      root,
      _SvgStyle.initial(currentColor),
      Transform2D.identity,
      includeSelf: true,
    );
    return SvgPicture._(
      Size(width, height),
      viewBox,
      List<SvgDrawPath>.unmodifiable(collector.paths),
    );
  }

  final Size size;
  final Rect viewBox;
  final List<SvgDrawPath> paths;
}

/// Application-wide decoded SVG cache. Replace or resize it when desired.
final LruCache<Object, SvgPicture> svgPictureCache =
    LruCache<Object, SvgPicture>(maximumSize: 100);

SvgPicture parseSvgCached(
  Object key,
  String source, {
  SvgLimits limits = const SvgLimits(),
  int currentColor = 0xFF000000,
}) =>
    svgPictureCache.putIfAbsent(
      key,
      () => SvgPicture.parse(
        source,
        limits: limits,
        currentColor: currentColor,
      ),
    );

final class _SvgCollector {
  _SvgCollector(this.limits);

  final SvgLimits limits;
  final List<SvgDrawPath> paths = <SvgDrawPath>[];
  int _elementCount = 0;

  void walk(
    XmlElement element,
    _SvgStyle inherited,
    Transform2D parentTransform, {
    bool includeSelf = false,
  }) {
    _elementCount++;
    if (_elementCount > limits.maxElements) {
      throw SvgParseException(
        'SVG exceeds the ${limits.maxElements}-element limit',
      );
    }
    final _SvgStyle style = _styleFor(inherited, element);
    if (!style.visible) return;
    final Transform2D transform = parentTransform.multiply(
      _parseTransform(element.getAttribute('transform')),
    );
    final String name = element.name.local.toLowerCase();

    if (!includeSelf) _emitShape(name, element, style, transform);
    if (name == 'defs' || name == 'symbol' || name == 'clipPath') return;
    for (final XmlElement child in element.childElements) {
      walk(child, style, transform);
    }
  }

  void _emitShape(
    String name,
    XmlElement element,
    _SvgStyle style,
    Transform2D transform,
  ) {
    Path? path;
    switch (name) {
      case 'path':
        final String? data = element.getAttribute('d');
        if (data == null || data.trim().isEmpty) return;
        if (data.length > limits.maxPathCharacters) {
          throw SvgParseException(
            'path data exceeds ${limits.maxPathCharacters} characters',
          );
        }
        path = parseSvgPathData(data);
        break;
      case 'rect':
        final double x = _number(element, 'x', 0);
        final double y = _number(element, 'y', 0);
        final double width = _number(element, 'width', 0);
        final double height = _number(element, 'height', 0);
        if (!(width > 0) || !(height > 0)) return;
        var rx = _numberOrNull(element, 'rx');
        var ry = _numberOrNull(element, 'ry');
        rx ??= ry ?? 0;
        ry ??= rx;
        final PathBuilder builder = PathBuilder()
          ..addRoundedRect(Rect.fromLTWH(x, y, width, height), rx, ry);
        path = builder.build();
        break;
      case 'circle':
        final double radius = _number(element, 'r', 0);
        if (!(radius > 0)) return;
        final double cx = _number(element, 'cx', 0);
        final double cy = _number(element, 'cy', 0);
        path = Path.oval(
          Rect.fromLTWH(cx - radius, cy - radius, radius * 2, radius * 2),
        );
        break;
      case 'ellipse':
        final double rx = _number(element, 'rx', 0);
        final double ry = _number(element, 'ry', 0);
        if (!(rx > 0) || !(ry > 0)) return;
        final double cx = _number(element, 'cx', 0);
        final double cy = _number(element, 'cy', 0);
        path = Path.oval(Rect.fromLTWH(cx - rx, cy - ry, rx * 2, ry * 2));
        break;
      case 'line':
        path = (PathBuilder()
              ..moveTo(_number(element, 'x1', 0), _number(element, 'y1', 0))
              ..lineTo(_number(element, 'x2', 0), _number(element, 'y2', 0)))
            .build();
        break;
      case 'polyline' || 'polygon':
        final List<double> points = _parseNumbers(
          element.getAttribute('points') ?? '',
        );
        if (points.length < 4 || points.length.isOdd) return;
        final PathBuilder builder = PathBuilder()..moveTo(points[0], points[1]);
        for (var i = 2; i < points.length; i += 2) {
          builder.lineTo(points[i], points[i + 1]);
        }
        if (name == 'polygon') builder.close();
        path = builder.build();
        break;
      default:
        return;
    }

    if (path.isEmpty || (style.fill == null && style.stroke == null)) return;
    paths.add(
      SvgDrawPath(
        path: path,
        transform: transform,
        fillColor: _applyOpacity(style.fill, style.opacity * style.fillOpacity),
        strokeColor:
            _applyOpacity(style.stroke, style.opacity * style.strokeOpacity),
        strokeWidth: style.strokeWidth,
        fillRule: style.fillRule,
      ),
    );
  }
}

final class _SvgStyle {
  const _SvgStyle({
    required this.fill,
    required this.stroke,
    required this.strokeWidth,
    required this.opacity,
    required this.fillOpacity,
    required this.strokeOpacity,
    required this.currentColor,
    required this.visible,
    required this.fillRule,
  });

  factory _SvgStyle.initial(int currentColor) => _SvgStyle(
        fill: 0xFF000000,
        stroke: null,
        strokeWidth: 1,
        opacity: 1,
        fillOpacity: 1,
        strokeOpacity: 1,
        currentColor: currentColor,
        visible: true,
        fillRule: pathFillRuleNonZero,
      );

  final int? fill;
  final int? stroke;
  final double strokeWidth;
  final double opacity;
  final double fillOpacity;
  final double strokeOpacity;
  final int currentColor;
  final bool visible;
  final int fillRule;
}

_SvgStyle _styleFor(_SvgStyle parent, XmlElement element) {
  final Map<String, String> values = <String, String>{};
  const List<String> names = <String>[
    'fill',
    'stroke',
    'stroke-width',
    'opacity',
    'fill-opacity',
    'stroke-opacity',
    'color',
    'display',
    'visibility',
    'fill-rule',
  ];
  for (final String name in names) {
    final String? value = element.getAttribute(name);
    if (value != null) values[name] = value.trim();
  }
  final String? inline = element.getAttribute('style');
  if (inline != null) {
    for (final String declaration in inline.split(';')) {
      final int colon = declaration.indexOf(':');
      if (colon <= 0) continue;
      values[declaration.substring(0, colon).trim().toLowerCase()] =
          declaration.substring(colon + 1).trim();
    }
  }
  final int currentColor = values.containsKey('color')
      ? _parseColor(values['color']!, parent.currentColor) ??
          parent.currentColor
      : parent.currentColor;
  return _SvgStyle(
    fill: values.containsKey('fill')
        ? _parseColor(values['fill']!, currentColor)
        : parent.fill,
    stroke: values.containsKey('stroke')
        ? _parseColor(values['stroke']!, currentColor)
        : parent.stroke,
    strokeWidth: values.containsKey('stroke-width')
        ? (_parseLength(values['stroke-width']) ?? parent.strokeWidth)
        : parent.strokeWidth,
    opacity: parent.opacity * _unit(values['opacity'], 1),
    fillOpacity: values.containsKey('fill-opacity')
        ? _unit(values['fill-opacity'], 1)
        : parent.fillOpacity,
    strokeOpacity: values.containsKey('stroke-opacity')
        ? _unit(values['stroke-opacity'], 1)
        : parent.strokeOpacity,
    currentColor: currentColor,
    visible: parent.visible &&
        values['display']?.toLowerCase() != 'none' &&
        values['visibility']?.toLowerCase() != 'hidden',
    fillRule: values.containsKey('fill-rule')
        ? switch (values['fill-rule']!.toLowerCase()) {
            'nonzero' => pathFillRuleNonZero,
            'evenodd' => pathFillRuleEvenOdd,
            final String value =>
              throw SvgParseException('unsupported fill-rule "$value"'),
          }
        : parent.fillRule,
  );
}

Transform2D _parseTransform(String? raw) {
  if (raw == null || raw.trim().isEmpty) return Transform2D.identity;
  final RegExp function = RegExp(r'([A-Za-z]+)\s*\(([^)]*)\)');
  var result = Transform2D.identity;
  var matched = 0;
  for (final RegExpMatch match in function.allMatches(raw)) {
    matched += match.group(0)!.length;
    final String name = match.group(1)!.toLowerCase();
    final List<double> n = _parseNumbers(match.group(2)!);
    final Transform2D next = switch (name) {
      'matrix' when n.length == 6 =>
        Transform2D(n[0], n[1], n[2], n[3], n[4], n[5]),
      'translate' when n.length == 1 => Transform2D.translation(n[0], 0),
      'translate' when n.length == 2 => Transform2D.translation(n[0], n[1]),
      'scale' when n.length == 1 => Transform2D.scaling(n[0], n[0]),
      'scale' when n.length == 2 => Transform2D.scaling(n[0], n[1]),
      'rotate' when n.length == 1 => Transform2D.rotation(n[0] * math.pi / 180),
      'rotate' when n.length == 3 => Transform2D.translation(n[1], n[2])
          .multiply(Transform2D.rotation(n[0] * math.pi / 180))
          .multiply(Transform2D.translation(-n[1], -n[2])),
      'skewx' when n.length == 1 =>
        Transform2D(1, 0, math.tan(n[0] * math.pi / 180), 1, 0, 0),
      'skewy' when n.length == 1 =>
        Transform2D(1, math.tan(n[0] * math.pi / 180), 0, 1, 0, 0),
      _ => throw SvgParseException('invalid $name transform'),
    };
    // A list is equivalent to nested groups in source order: the first item
    // is the outer transform, so column-vector matrices concatenate on the
    // right (`translate(...) scale(...)` becomes T * S).
    result = result.multiply(next);
  }
  if (matched == 0) throw const SvgParseException('invalid transform');
  return result;
}

Rect? _parseViewBox(String? raw) {
  if (raw == null) return null;
  final List<double> n = _parseNumbers(raw);
  if (n.length != 4) {
    throw const SvgParseException('viewBox needs four numbers');
  }
  return Rect.fromLTWH(n[0], n[1], n[2], n[3]);
}

List<double> _parseNumbers(String raw) {
  final RegExp number = RegExp(
    r'[+-]?(?:(?:\d+(?:\.\d*)?)|(?:\.\d+))(?:[eE][+-]?\d+)?',
  );
  return number
      .allMatches(raw)
      .map((RegExpMatch match) => double.parse(match.group(0)!))
      .toList(growable: false);
}

double? _parseLength(String? raw) {
  if (raw == null) return null;
  final RegExpMatch? match = RegExp(
    r'^\s*([+-]?(?:(?:\d+(?:\.\d*)?)|(?:\.\d+))(?:[eE][+-]?\d+)?)\s*(px|pt|pc|mm|cm|in)?\s*$',
    caseSensitive: false,
  ).firstMatch(raw);
  if (match == null) return null;
  final double value = double.parse(match.group(1)!);
  return switch (match.group(2)?.toLowerCase()) {
    'pt' => value * 96 / 72,
    'pc' => value * 16,
    'mm' => value * 96 / 25.4,
    'cm' => value * 96 / 2.54,
    'in' => value * 96,
    _ => value,
  };
}

double _number(XmlElement element, String name, double fallback) =>
    _numberOrNull(element, name) ?? fallback;

double? _numberOrNull(XmlElement element, String name) =>
    _parseLength(element.getAttribute(name));

double _unit(String? raw, double fallback) {
  if (raw == null) return fallback;
  final double? parsed = double.tryParse(raw);
  return parsed == null ? fallback : parsed.clamp(0, 1).toDouble();
}

int? _parseColor(String raw, int currentColor) {
  final String value = raw.trim().toLowerCase();
  if (value == 'none') return null;
  if (value == 'currentcolor') return currentColor;
  if (value == 'transparent') return 0;
  if (value.startsWith('#')) {
    final String hex = value.substring(1);
    if (hex.length == 3 || hex.length == 4) {
      final int r = int.parse('${hex[0]}${hex[0]}', radix: 16);
      final int g = int.parse('${hex[1]}${hex[1]}', radix: 16);
      final int b = int.parse('${hex[2]}${hex[2]}', radix: 16);
      final int a =
          hex.length == 4 ? int.parse('${hex[3]}${hex[3]}', radix: 16) : 255;
      return a << 24 | r << 16 | g << 8 | b;
    }
    if (hex.length == 6 || hex.length == 8) {
      final int rgb = int.parse(hex.substring(0, 6), radix: 16);
      final int alpha =
          hex.length == 8 ? int.parse(hex.substring(6), radix: 16) : 255;
      return alpha << 24 | rgb;
    }
  }
  final RegExpMatch? rgb = RegExp(r'^rgba?\s*\(([^)]*)\)$').firstMatch(value);
  if (rgb != null) {
    final List<String> channels = rgb.group(1)!.split(',');
    if (channels.length == 3 || channels.length == 4) {
      int channel(String text) => text.trim().endsWith('%')
          ? (double.parse(text.trim().substring(0, text.trim().length - 1)) *
                  2.55)
              .round()
              .clamp(0, 255)
          : double.parse(text.trim()).round().clamp(0, 255);
      final int alpha = channels.length == 4
          ? (double.parse(channels[3].trim()).clamp(0, 1) * 255).round()
          : 255;
      return alpha << 24 |
          channel(channels[0]) << 16 |
          channel(channels[1]) << 8 |
          channel(channels[2]);
    }
  }
  return _namedColors[value] ??
      (throw SvgParseException('unsupported color "$raw"'));
}

int? _applyOpacity(int? color, double opacity) {
  if (color == null) return null;
  final int alpha = (color >> 24) & 0xFF;
  final int composed = (alpha * opacity.clamp(0, 1)).round();
  return (color & 0x00FFFFFF) | composed << 24;
}

const Map<String, int> _namedColors = <String, int>{
  'black': 0xFF000000,
  'silver': 0xFFC0C0C0,
  'gray': 0xFF808080,
  'white': 0xFFFFFFFF,
  'maroon': 0xFF800000,
  'red': 0xFFFF0000,
  'purple': 0xFF800080,
  'fuchsia': 0xFFFF00FF,
  'green': 0xFF008000,
  'lime': 0xFF00FF00,
  'olive': 0xFF808000,
  'yellow': 0xFFFFFF00,
  'navy': 0xFF000080,
  'blue': 0xFF0000FF,
  'teal': 0xFF008080,
  'aqua': 0xFF00FFFF,
  'orange': 0xFFFFA500,
};
