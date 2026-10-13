/// Immediate mode: the whole interface is the function below, run each frame.
///
/// ```
/// dart run example/immediate_demo.dart
/// ```
///
/// The state is plain variables; each control returns what the user did to
/// it. The theme switch at the top restyles everything live - including the
/// switch, slider and check box shapes of each [ControlStyle].
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/immediate.dart';

final Map<String, ThemeData> demoThemes = <String, ThemeData>{
  'Neutro': ThemeData.neutralLight,
  'Material': ThemeData.materialLight,
  'Material escuro': ThemeData.materialDark,
  'iOS': ThemeData.cupertinoLight,
  'iOS escuro': ThemeData.cupertinoDark,
};

var demoTheme = 'Material';
var _brightness = 0.2;
var _contrast = 0.5;
var _mask = true;
var _histogram = false;
var _sharpen = true;
var _mode = 'normal';
var _name = '';
var _applied = 0;
var _layersOpen = true;
final List<bool> _layerVisible = <bool>[true, true, false, true];
final List<String> _layerNames = <String>[
  'Fundo',
  'Céu',
  'Texto',
  'Ajuste de curvas'
];
final List<String> _log = <String>[];

void build(Ui ui) => ui.themed(demoThemes[demoTheme]!, (Ui ui) {
      if (_layersOpen) {
        _layersOpen =
            ui.window('Camadas', position: const Offset(560, 160), (Ui w) {
          for (var i = 0; i < _layerNames.length; i++) {
            _layerVisible[i] = w.checkbox(_layerNames[i], _layerVisible[i]);
          }
          w.separator();
          _layerNames[0] = w.textField(_layerNames[0], key: 'nome-fundo');
        });
      }
      ui.horizontal((Ui row) {
        for (final String name in demoThemes.keys) {
          demoTheme = row.radio(name, name, demoTheme);
        }
      });
      ui.separator();
      ui.horizontal((Ui columns) {
        columns.panel((Ui panel) {
          panel.heading('Ajustes');
          _brightness = panel.slider('Brilho   ', _brightness, min: -1, max: 1);
          _contrast = panel.slider('Contraste', _contrast);
          panel.progress((_brightness + 1) / 2);
          _mask = panel.checkbox('Máscara de camada', _mask);
          _histogram = panel.checkbox('Mostrar histograma', _histogram);
          _sharpen = panel.toggle('Nitidez automática', _sharpen);
          panel.label('Mesclagem', secondary: true);
          panel.horizontal((Ui modes) {
            for (final String mode in <String>[
              'normal',
              'multiplicar',
              'tela'
            ]) {
              _mode = modes.radio(mode, mode, _mode);
            }
          });
          _name =
              panel.textField(_name, key: 'nome', hint: 'Nome da predefinição');
          panel.horizontal((Ui buttons) {
            if (buttons.button('Aplicar')) {
              _applied++;
              _log.insert(0,
                  '#$_applied ${_name.isEmpty ? 'sem nome' : _name}: brilho ${_brightness.toStringAsFixed(2)}, $_mode');
            }
            if (buttons.button('Limpar', enabled: _log.isNotEmpty)) {
              _log.clear();
            }
          });
        });
        columns.panel((Ui panel) {
          panel.heading('Histórico');
          panel.label('${_log.length} aplicações', secondary: true);
          panel.scrollArea(height: 180, width: 360, key: 'log', (Ui list) {
            if (_log.isEmpty) {
              list.label('Nada aplicado ainda.', secondary: true);
            }
            for (final String line in _log) {
              list.label(line);
            }
          });
          _layersOpen = panel.checkbox('Janela de camadas', _layersOpen);
          panel.collapsing('Detalhes', (Ui details) {
            details.label('Modo imediato: a interface é esta função.');
            details.label('Estado: variáveis comuns do programa.');
          });
        });
      });
    });

Future<void> main() async {
  await runImmediateApp(
    build,
    options: const ApplicationOptions(
      title: 'dart_ui — modo imediato',
      size: Size(920, 640),
    ),
  );
}
