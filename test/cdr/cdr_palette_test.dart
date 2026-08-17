import 'package:dart_ui/cdr.dart';
import 'package:test/test.dart';

void main() {
  group('Paletas de Cores CorelDRAW e Pantone', () {
    test('CdrColorPalette resolve cores padrão da Corel por ID', () {
      const palette = CdrColorPalette.corelStandard;

      final white = palette.getColor(0);
      expect(white.colorArgb, 0xFFFFFFFF);

      final black = palette.getColor(1);
      expect(black.colorArgb, 0xFF000000);

      final red = palette.getColor(2);
      expect(red.colorArgb, 0xFFFF0000);

      final blue = palette.getColor(4);
      expect(blue.colorArgb, 0xFF0000FF);
    });

    test('CdrColorPalette resolve cores Pantone por nome', () {
      final yellow = CdrColorPalette.getPantoneColor('PANTONE Yellow C');
      expect(yellow.colorArgb, 0xFFFEDD00);

      final red = CdrColorPalette.getPantoneColor('PANTONE Red 032 C');
      expect(red.colorArgb, 0xFFEF3340);
    });
  });
}
