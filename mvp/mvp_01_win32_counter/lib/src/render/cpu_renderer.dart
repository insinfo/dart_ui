/// Renderer CPU do MVP-05 para DisplayList v0.
library;

import '../core/geometry.dart';
import 'canvas.dart';
import 'display_list.dart';

final class CpuRenderer {
  /// Executa [displayList] no [target], respeitando transformações e clip.
  void render(DisplayList displayList, Canvas target) {
    var state = _RenderState(
      offsetX: 0,
      offsetY: 0,
      clip: Rect.fromLTWH(0, 0, target.width, target.height),
    );
    final stack = <_RenderState>[];

    for (final command in displayList.commands) {
      switch (command) {
        case SaveCommand():
          stack.add(state);
        case RestoreCommand():
          if (stack.isNotEmpty) state = stack.removeLast();
        case TranslateCommand(:final x, :final y):
          state = state.translate(x, y);
        case ClipRectCommand(:final rect):
          state = state.clipRect(rect);
        case DrawRectCommand(:final rect, :final color):
          final transformed = state.transform(rect);
          final visible = transformed.intersect(state.clip);
          if (!visible.isEmpty) target.fillRect(visible, color);
        case DrawTextCommand(:final text, :final area, :final color):
          final transformed = state.transform(area);
          final visible = transformed.intersect(state.clip);
          if (!visible.isEmpty) target.drawText(text, visible, color);
      }
    }
  }
}

final class _RenderState {
  const _RenderState(
      {required this.offsetX, required this.offsetY, required this.clip});

  final int offsetX;
  final int offsetY;
  final Rect clip;

  _RenderState translate(int x, int y) => _RenderState(
        offsetX: offsetX + x,
        offsetY: offsetY + y,
        clip: clip,
      );

  _RenderState clipRect(Rect rect) => _RenderState(
        offsetX: offsetX,
        offsetY: offsetY,
        clip: clip.intersect(transform(rect)),
      );

  Rect transform(Rect rect) => rect.translate(offsetX, offsetY);
}
