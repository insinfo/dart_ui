/// CounterApp: composição do vertical slice MVP-01.
///
/// Layout fixo e centralizado: título, contador, botão "INCREMENTAR" e botão
/// "ZERAR". Todo o layout, input e estado vivem em Dart puro — o mesmo código
/// roda no host Win32 e no backend headless.
library;

import '../core/bitmap_font.dart' as font;
import '../core/color.dart';
import '../core/geometry.dart';
import '../render/display_list.dart';
import 'button.dart';
import 'label.dart';
import 'widget.dart';

final class CounterApp extends UiRoot {
  CounterApp(super._canvas) {
    _title =
        Label(text: 'DART UI MVP-01', color: const Color.opaque(150, 160, 180));
    _countLabel = Label(text: 'CONTAGEM: 0');
    _incrementButton = Button(label: 'INCREMENTAR', onActivate: increment);
    _resetButton = Button(label: 'ZERAR', onActivate: reset);
    addChild(_title);
    addChild(_countLabel);
    addChild(_incrementButton);
    addChild(_resetButton);
  }

  late final Label _title;
  late final Label _countLabel;
  late final Button _incrementButton;
  late final Button _resetButton;

  Button get incrementButton => _incrementButton;
  Button get resetButton => _resetButton;
  Label get countLabel => _countLabel;
  Label get title => _title;

  int _count = 0;
  int get count => _count;

  /// Grava a cena atual em DisplayList v0 para renderers alternativos.
  ///
  /// O caminho widget-paint continua disponível para dirty rect; esta lista
  /// representa o frame completo e é usada por headless, golden e futuros
  /// backends acelerados.
  DisplayList recordDisplayList() {
    final builder = DisplayListBuilder()
      ..drawRect(
          Rect.fromLTWH(0, 0, width, height), const Color.opaque(30, 34, 42))
      ..drawText(_title.text, _title.bounds, _title.color)
      ..drawText(_countLabel.text, _countLabel.bounds, _countLabel.color)
      ..drawRect(
          _incrementButton.bounds, _buttonFillColor(_incrementButton.state))
      ..drawText('INCREMENTAR', _incrementButton.bounds, Color.white)
      ..drawRect(_resetButton.bounds, _buttonFillColor(_resetButton.state))
      ..drawText('ZERAR', _resetButton.bounds, Color.white);
    return builder.build();
  }

  Color _buttonFillColor(ButtonState state) {
    return switch (state) {
      ButtonState.pressed => const Color.opaque(48, 54, 68),
      ButtonState.hover => const Color.opaque(82, 92, 116),
      _ => const Color.opaque(68, 74, 92),
    };
  }

  static const int buttonWidth = 190;
  static const int buttonHeight = 44;
  static const int columnSpacing = 16;

  void increment() {
    _setCount(_count + 1);
  }

  void reset() {
    _setCount(0);
  }

  void _setCount(int value) {
    _count = value;
    _countLabel.setText('CONTAGEM: $_count');
  }

  @override
  void layout() {
    super.layout();
    final cx = width ~/ 2;
    final centerY = height ~/ 2;

    // Título no topo, centralizado.
    _title.bounds = Rect.fromLTWH(0, 24, width, font.fontCellHeight);
    _title.layout(width, height);

    // Coluna central: contador + botões com espaçamento fixo.
    const columnHeight = font.fontCellHeight +
        columnSpacing +
        buttonHeight +
        columnSpacing +
        buttonHeight;
    var y = centerY - columnHeight ~/ 2;

    _countLabel.bounds = Rect.fromLTWH(0, y, width, font.fontCellHeight);
    _countLabel.layout(width, height);
    y += font.fontCellHeight + columnSpacing;

    _incrementButton.bounds = Rect(
      cx - buttonWidth ~/ 2,
      y,
      cx + buttonWidth ~/ 2,
      y + buttonHeight,
    );
    _incrementButton.layout(width, height);
    y += buttonHeight + columnSpacing;

    _resetButton.bounds = Rect(
      cx - buttonWidth ~/ 2,
      y,
      cx + buttonWidth ~/ 2,
      y + buttonHeight,
    );
    _resetButton.layout(width, height);
  }
}
