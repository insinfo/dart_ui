import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('Color', () {
    test('exposes Flutter-compatible ARGB channels', () {
      const color = Color(0x804080C0);

      expect(color.alpha, 0x80);
      expect(color.red, 0x40);
      expect(color.green, 0x80);
      expect(color.blue, 0xC0);
      expect(color.opacity, closeTo(0x80 / 255, 0.00001));
    });

    test('constructors and channel replacements keep packed ARGB', () {
      expect(const Color.fromARGB(0x80, 0x10, 0x20, 0x30).value, 0x80102030);
      expect(Color.fromRGBO(0x10, 0x20, 0x30, 0.5).value, 0x80102030);
      expect(const Color(0xFF102030).withAlpha(0x40).value, 0x40102030);
      expect(const Color(0xFF102030).withOpacity(0.5).value, 0x80102030);
    });

    test('alphaBlend follows source-over composition', () {
      final blended = Color.alphaBlend(
        const Color(0x80FF0000),
        const Color(0xFF0000FF),
      );

      expect(blended.alpha, 0xFF);
      expect(blended.red, closeTo(128, 1));
      expect(blended.blue, closeTo(127, 1));
    });
  });
}
