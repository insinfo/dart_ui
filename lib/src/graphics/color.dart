/// Immutable ARGB colours with a Flutter-compatible public shape.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

/// A colour in the sRGB colour space.
@immutable
final class Color {
  const Color(this.value);

  const Color.fromARGB(int alpha, int red, int green, int blue)
      : value = ((alpha & 0xFF) << 24) |
            ((red & 0xFF) << 16) |
            ((green & 0xFF) << 8) |
            (blue & 0xFF);

  factory Color.fromRGBO(int red, int green, int blue, double opacity) =>
      Color.fromARGB((opacity.clamp(0.0, 1.0) * 255).round(), red, green, blue);

  /// Packed `0xAARRGGBB`, used only at renderer and platform boundaries.
  final int value;

  int get alpha => (value >> 24) & 0xFF;
  int get red => (value >> 16) & 0xFF;
  int get green => (value >> 8) & 0xFF;
  int get blue => value & 0xFF;
  double get opacity => alpha / 255;

  double get a => alpha / 255;
  double get r => red / 255;
  double get g => green / 255;
  double get b => blue / 255;

  Color withAlpha(int alpha) => Color.fromARGB(alpha, red, green, blue);

  Color withOpacity(double opacity) =>
      Color.fromRGBO(red, green, blue, opacity);

  Color withValues({double? alpha, double? red, double? green, double? blue}) =>
      Color.fromARGB(
        ((alpha ?? a).clamp(0.0, 1.0) * 255).round(),
        ((red ?? r).clamp(0.0, 1.0) * 255).round(),
        ((green ?? g).clamp(0.0, 1.0) * 255).round(),
        ((blue ?? b).clamp(0.0, 1.0) * 255).round(),
      );

  double computeLuminance() {
    double linear(int component) {
      final double channel = component / 255;
      return channel <= 0.03928
          ? channel / 12.92
          : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * linear(red) +
        0.7152 * linear(green) +
        0.0722 * linear(blue);
  }

  static Color alphaBlend(Color foreground, Color background) {
    final double foregroundAlpha = foreground.a;
    final double inverse = 1 - foregroundAlpha;
    final double outputAlpha = foregroundAlpha + background.a * inverse;
    if (outputAlpha <= 0) return Colors.transparent;
    int blend(int foregroundChannel, int backgroundChannel) =>
        ((foregroundChannel * foregroundAlpha +
                    backgroundChannel * background.a * inverse) /
                outputAlpha)
            .round();
    return Color.fromARGB(
      (outputAlpha * 255).round(),
      blend(foreground.red, background.red),
      blend(foreground.green, background.green),
      blend(foreground.blue, background.blue),
    );
  }

  static Color? lerp(Color? a, Color? b, double t) {
    if (identical(a, b)) return a;
    final Color from = a ?? Colors.transparent;
    final Color to = b ?? Colors.transparent;
    int channel(int start, int end) => (start + (end - start) * t).round();
    return Color.fromARGB(
      channel(from.alpha, to.alpha),
      channel(from.red, to.red),
      channel(from.green, to.green),
      channel(from.blue, to.blue),
    );
  }

  @override
  bool operator ==(Object other) => other is Color && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() =>
      'Color(0x${value.toRadixString(16).padLeft(8, '0').toUpperCase()})';
}

/// Common opaque colours, matching Flutter's familiar names.
abstract final class Colors {
  static const Color transparent = Color(0x00000000);
  static const Color black = Color(0xFF000000);
  static const Color white = Color(0xFFFFFFFF);
  static const Color red = Color(0xFFF44336);
  static const Color orange = Color(0xFFFF9800);
  static const Color yellow = Color(0xFFFFEB3B);
  static const Color green = Color(0xFF4CAF50);
  static const Color teal = Color(0xFF009688);
  static const Color blue = Color(0xFF2196F3);
  static const Color indigo = Color(0xFF3F51B5);
  static const Color purple = Color(0xFF9C27B0);
  static const Color pink = Color(0xFFE91E63);
  static const Color grey = Color(0xFF9E9E9E);
}
