/// Canvas BGRA do MVP-01.
///
/// Desenha em um `Uint8List` BGRA (4 bytes/pixel, top-down, stride = 4*width)
/// com clipping por retângulo. O mesmo canvas é usado pelo backend headless e
/// pelo host Win32, garantindo saída idêntica entre os dois.
library;

import 'dart:typed_data';

import '../core/bitmap_font.dart' as font;
import '../core/color.dart';
import '../core/geometry.dart';

final class Canvas {
  Canvas(this.width, this.height, this._pixels);

  final int width;
  final int height;
  final Uint8List _pixels;

  /// Limpa a área [rect] com [color].
  void fillRect(Rect rect, Color color) {
    final clip = rect.intersect(Rect(0, 0, width, height));
    if (clip.isEmpty) return;
    final packed = color.packedBgra;
    final words = Uint32List.view(_pixels.buffer, _pixels.offsetInBytes);
    for (var y = clip.top; y < clip.bottom; y++) {
      final start = y * width + clip.left;
      words.fillRange(start, start + clip.width, packed);
    }
  }

  /// Preenche um retângulo com cantos arredondados de raio [radius].
  void fillRoundRect(Rect rect, int radius, Color color) {
    final clip = rect.intersect(Rect(0, 0, width, height));
    if (clip.isEmpty) return;
    final packed = color.packedBgra;
    final words = Uint32List.view(_pixels.buffer, _pixels.offsetInBytes);
    final r2 = radius * radius;
    for (var y = clip.top; y < clip.bottom; y++) {
      var x = clip.left;
      // Centro retangular (sem cantos) em uma varredura por linha.
      while (x < clip.right) {
        final inCorner = _inCorner(rect, x, y, radius, r2);
        if (!inCorner) {
          // Pinta a maior extensão possível de pixels do meio em lote.
          var runEnd = x;
          while (
              runEnd < clip.right && !_inCorner(rect, runEnd, y, radius, r2)) {
            runEnd++;
          }
          final start = y * width + x;
          words.fillRange(start, start + (runEnd - x), packed);
          x = runEnd;
        } else {
          words[y * width + x] = packed;
          x++;
        }
      }
    }
  }

  bool _inCorner(Rect rect, int x, int y, int radius, int r2) {
    if (x < rect.left + radius || x >= rect.right - radius) {
      // Escolhe o centro do canto mais próximo.
      final cx =
          x < rect.left + radius ? rect.left + radius : rect.right - radius - 1;
      final cy =
          y < rect.top + radius ? rect.top + radius : rect.bottom - radius - 1;
      final dx = x - cx;
      final dy = y - cy;
      if (dx.abs() >= radius || dy.abs() >= radius) return false;
      return dx * dx + dy * dy >= r2;
    }
    return false;
  }

  /// Desenha uma borda de [thickness] pixels ao redor de [rect].
  void strokeRect(Rect rect, int thickness, Color color) {
    if (rect.isEmpty) return;
    fillRect(
        Rect(rect.left, rect.top, rect.right, rect.top + thickness), color);
    fillRect(Rect(rect.left, rect.bottom - thickness, rect.right, rect.bottom),
        color);
    fillRect(
        Rect(rect.left, rect.top + thickness, rect.left + thickness,
            rect.bottom - thickness),
        color);
    fillRect(
        Rect(rect.right - thickness, rect.top + thickness, rect.right,
            rect.bottom - thickness),
        color);
  }

  /// Desenha [text] centralizado em [area] na cor [color].
  void drawText(String text, Rect area, Color color) {
    final packed = color.packedBgra;
    final words = Uint32List.view(_pixels.buffer, _pixels.offsetInBytes);
    font.drawText((x, y) {
      if (x < 0 || y < 0 || x >= width || y >= height) return;
      words[y * width + x] = packed;
    }, text, area);
  }
}
