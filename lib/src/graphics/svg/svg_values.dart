/// Value syntax shared by everything that reads SVG: transforms, lengths,
/// colours, number lists.
library;

import 'dart:math' as math;

import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import 'svg_path.dart';

Transform2D parseSvgTransform(String? raw) {
  if (raw == null || raw.trim().isEmpty) return Transform2D.identity;
  final RegExp function = RegExp(r'([A-Za-z]+)\s*\(([^)]*)\)');
  var result = Transform2D.identity;
  var matched = 0;
  for (final RegExpMatch match in function.allMatches(raw)) {
    matched += match.group(0)!.length;
    final String name = match.group(1)!.toLowerCase();
    final List<double> n = parseSvgNumbers(match.group(2)!);
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

Rect? parseSvgViewBox(String? raw) {
  if (raw == null) return null;
  final List<double> n = parseSvgNumbers(raw);
  if (n.length != 4) {
    throw const SvgParseException('viewBox needs four numbers');
  }
  return Rect.fromLTWH(n[0], n[1], n[2], n[3]);
}

List<double> parseSvgNumbers(String raw) {
  final RegExp number = RegExp(
    r'[+-]?(?:(?:\d+(?:\.\d*)?)|(?:\.\d+))(?:[eE][+-]?\d+)?',
  );
  return number
      .allMatches(raw)
      .map((RegExpMatch match) => double.parse(match.group(0)!))
      .toList(growable: false);
}

double? parseSvgLength(String? raw) {
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

double parseSvgUnit(String? raw, double fallback) {
  if (raw == null) return fallback;
  final double? parsed = double.tryParse(raw);
  return parsed == null ? fallback : parsed.clamp(0, 1).toDouble();
}

int? parseSvgColor(String raw, int currentColor) {
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
  return svgNamedColors[value] ??
      (throw SvgParseException('unsupported color "$raw"'));
}

const Map<String, int> svgNamedColors = <String, int>{
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
