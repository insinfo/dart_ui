/// Rótulo de texto estático desenhado com a fonte bitmap embutida.
library;

import '../core/color.dart';
import '../core/geometry.dart';
import '../render/canvas.dart';
import 'widget.dart';

final class Label extends Widget {
  Label({required this.text, this.color = const Color.opaque(230, 233, 240)});

  String text;
  Color color;

  void setText(String value) {
    if (text == value) return;
    text = value;
    repaint();
  }

  @override
  void layout(int width, int height) {
    // O host (CounterApp) posiciona os rótulos; o layout do label só valida.
    bounds = Rect(
      bounds.left,
      bounds.top,
      bounds.right,
      bounds.bottom,
    );
  }

  @override
  void paint(Canvas canvas) {
    if (bounds.isEmpty) return;
    canvas.drawText(text, bounds, color);
  }
}
