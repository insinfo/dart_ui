import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:test/test.dart';

const _stops = <GradientStop>[
  GradientStop(0, 0xFFFF0000),
  GradientStop(0.5, 0x8000FF00),
  GradientStop(1, 0xFF0000FF),
];

void main() {
  group('Gradient', () {
    test('stores geometry and stops at float32 precision by value', () {
      final a = LinearGradient(
        startX: 0,
        startY: 1,
        endX: 100,
        endY: 101,
        stops: _stops,
        spread: GradientSpread.reflect,
      );
      final b = LinearGradient(
        startX: 0,
        startY: 1,
        endX: 100,
        endY: 101,
        stops: List<GradientStop>.of(_stops),
        spread: GradientSpread.reflect,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.shaderKind, shaderKindLinear);
      expect(a.stopOffsets, <double>[0, 0.5, 1]);
      expect(a.stopColors, <int>[0xFFFF0000, 0x8000FF00, 0xFF0000FF]);
    });

    test('copies caller stops and exposes only read-only typed views', () {
      final source = <GradientStop>[
        const GradientStop(0, 0xFF000000),
        const GradientStop(1, 0xFFFFFFFF),
      ];
      final gradient = LinearGradient(
        startX: 0,
        startY: 0,
        endX: 1,
        endY: 0,
        stops: source,
      );
      source[0] = const GradientStop(0, 0xFFFF00FF);

      expect(gradient.stopColors.first, 0xFF000000);
      expect(() => gradient.stopColors[0] = 0, throwsUnsupportedError);
      expect(() => gradient.stopOffsets[0] = 1, throwsUnsupportedError);
      expect(() => gradient.geometry[0] = 9, throwsUnsupportedError);
    });

    test('rejects malformed stops and non-finite geometry', () {
      LinearGradient linear(List<GradientStop> stops) => LinearGradient(
            startX: 0,
            startY: 0,
            endX: 1,
            endY: 0,
            stops: stops,
          );

      expect(() => linear(const <GradientStop>[]), throwsArgumentError);
      expect(
        () => linear(const <GradientStop>[
          GradientStop(0.8, 0),
          GradientStop(0.2, 0),
        ]),
        throwsArgumentError,
      );
      expect(
        () => LinearGradient(
          startX: double.infinity,
          startY: 0,
          endX: 1,
          endY: 0,
          stops: _stops,
        ),
        throwsArgumentError,
      );
      expect(
        () => RadialGradient(
          centerX: 0,
          centerY: 0,
          radius: double.infinity,
          stops: _stops,
        ),
        throwsArgumentError,
      );
      expect(
        () => RadialGradient(
          centerX: 0,
          centerY: 0,
          radius: 1,
          focusX: double.nan,
          stops: _stops,
        ),
        throwsArgumentError,
      );
    });

    test('radial focus defaults to its centre', () {
      final gradient = RadialGradient(
        centerX: 10,
        centerY: 20,
        radius: 8,
        stops: _stops,
      );

      expect(gradient.shaderKind, shaderKindRadial);
      expect(gradient.focusX, gradient.centerX);
      expect(gradient.focusY, gradient.centerY);
      expect(gradient.hasFocus, isFalse);
    });
  });
}
