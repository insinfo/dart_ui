/// DisplayList v0 do MVP-05.
///
/// A lista é independente do backend: widgets gravam comandos simples e um
/// renderer decide como executá-los. Os comandos são objetos imutáveis nesta
/// primeira versão; o formato compacto em typed buffers fica para a promoção
/// ao framework principal.
library;

import '../core/color.dart';
import '../core/geometry.dart';

sealed class DrawCommand {
  const DrawCommand();
}

final class SaveCommand extends DrawCommand {
  const SaveCommand();
}

final class RestoreCommand extends DrawCommand {
  const RestoreCommand();
}

final class TranslateCommand extends DrawCommand {
  const TranslateCommand(this.x, this.y);

  final int x;
  final int y;
}

final class ClipRectCommand extends DrawCommand {
  const ClipRectCommand(this.rect);

  final Rect rect;
}

final class DrawRectCommand extends DrawCommand {
  const DrawRectCommand(this.rect, this.color);

  final Rect rect;
  final Color color;
}

final class DrawTextCommand extends DrawCommand {
  const DrawTextCommand(this.text, this.area, this.color);

  final String text;
  final Rect area;
  final Color color;
}

/// Lista imutável de comandos de desenho.
final class DisplayList {
  DisplayList(List<DrawCommand> commands)
      : commands = List<DrawCommand>.unmodifiable(commands);

  final List<DrawCommand> commands;
}

/// Gravador de DisplayList.
final class DisplayListBuilder {
  final List<DrawCommand> _commands = <DrawCommand>[];

  void save() => _commands.add(const SaveCommand());
  void restore() => _commands.add(const RestoreCommand());
  void translate(int x, int y) => _commands.add(TranslateCommand(x, y));
  void clipRect(Rect rect) => _commands.add(ClipRectCommand(rect));
  void drawRect(Rect rect, Color color) =>
      _commands.add(DrawRectCommand(rect, color));
  void drawText(String text, Rect area, Color color) =>
      _commands.add(DrawTextCommand(text, area, color));

  DisplayList build() => DisplayList(_commands);
}
