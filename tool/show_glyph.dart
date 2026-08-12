/// Prints a glyph as ASCII art, for looking at what the rasterizer produced.
///
/// A developer tool, not a test: a golden asserts that pixels do not change,
/// and this answers the different question of whether they were ever right.
/// Reading a stem's antialiasing ramp by eye catches things no assertion was
/// written for.
///
/// ```
/// dart run tool/show_glyph.dart test/fonts/Roboto-Regular.ttf "Aág" 24
/// ```
library;

import 'dart:io';

import 'package:dart_ui/src/rendering/text/glyph_raster.dart';
import 'package:dart_ui/src/text/typeface.dart';

const String _shades = ' .:-=+*#%@';

void main(List<String> arguments) {
  if (arguments.length < 2) {
    stderr.writeln('usage: show_glyph.dart <font.ttf> <text> [pixelSize]');
    exitCode = 2;
    return;
  }
  final Typeface face = Typeface.parse(File(arguments[0]).readAsBytesSync());
  final String text = arguments[1];
  final double size =
      arguments.length > 2 ? double.tryParse(arguments[2]) ?? 24 : 24;

  final ScaledTypeface font = face.atSize(size);
  final GlyphRasterizer rasterizer = GlyphRasterizer();
  stdout.writeln('$face at ${size}px, line height '
      '${font.lineHeight.toStringAsFixed(1)}px');

  for (final int rune in text.runes) {
    final int glyphId = face.glyphForCodePoint(rune);
    final GlyphMask mask = rasterizer.render(font, glyphId);
    stdout.writeln('--- "${String.fromCharCode(rune)}" glyph $glyphId '
        'advance ${font.advanceOf(glyphId).toStringAsFixed(2)}px $mask');
    for (int y = 0; y < mask.height; y++) {
      final StringBuffer row = StringBuffer();
      for (int x = 0; x < mask.width; x++) {
        row.write(_shades[mask.coverageAt(x, y) * (_shades.length - 1) ~/ 255]);
      }
      stdout.writeln(row);
    }
  }
}
