import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

LinearGradient _ramp({GradientSpread spread = GradientSpread.pad}) =>
    LinearGradient(
      startX: 0,
      startY: 0,
      endX: 1,
      endY: 0,
      spread: spread,
      stops: const <GradientStop>[
        GradientStop(0, 0xFF000000),
        GradientStop(1, 0xFFFFFFFF),
      ],
    );

void main() {
  group('GradientLut', () {
    test('builds deterministic straight-alpha sRGB texels', () {
      final gradient = LinearGradient(
        startX: 0,
        startY: 0,
        endX: 1,
        endY: 0,
        stops: const <GradientStop>[
          GradientStop(0, 0x00FF0000),
          GradientStop(1, 0xFF0000FF),
        ],
      );

      final first = GradientLut(gradient, size: 257);
      final second = GradientLut(gradient, size: 257);

      expect(first.colorsArgb, orderedEquals(second.colorsArgb));
      expect(first.sampleArgb(0), 0x00FF0000);
      expect(first.sampleArgb(0.5), 0x80800080);
      expect(first.sampleArgb(1), 0xFF0000FF);
      expect(() => first.colorsArgb[0] = 0, throwsUnsupportedError);
    });

    test('pad, repeat and reflect normalize parameters consistently', () {
      int red(int color) => (color >> 16) & 0xFF;

      expect(red(GradientLut(_ramp()).sampleArgb(-2)), 0);
      expect(red(GradientLut(_ramp()).sampleArgb(2)), 255);
      expect(
        red(GradientLut(_ramp(spread: GradientSpread.repeat), size: 257)
            .sampleArgb(1.25)),
        64,
      );
      expect(
        red(GradientLut(_ramp(spread: GradientSpread.repeat), size: 257)
            .sampleArgb(-0.25)),
        191,
      );
      expect(
        red(GradientLut(_ramp(spread: GradientSpread.reflect), size: 257)
            .sampleArgb(1.25)),
        191,
      );
    });

    test('the last stop wins at a duplicated hard-stop offset', () {
      final gradient = LinearGradient(
        startX: 0,
        startY: 0,
        endX: 1,
        endY: 0,
        stops: const <GradientStop>[
          GradientStop(0, 0xFFFF0000),
          GradientStop(0.5, 0xFFFF0000),
          GradientStop(0.5, 0xFF0000FF),
          GradientStop(1, 0xFF0000FF),
        ],
      );

      expect(GradientLut(gradient, size: 257).sampleArgb(0.5), 0xFF0000FF);
    });
  });
}
