import 'package:dart_ui/dart_ui.dart';

void main() {
  FrameworkFonts.install();
  runApp(const DockingDemo());
}

final class DockingDemo extends StatefulWidget {
  const DockingDemo({super.key});

  @override
  State<DockingDemo> createState() => _DockingDemoState();
}

final class _DockingDemoState extends State<DockingDemo> {
  late final DockingLayout _layout = DockingLayout(
    root: DockingRow(<DockingArea>[
      DockingItem(
        id: 'files',
        name: 'Arquivos',
        weight: 0.22,
        minimalSize: 180,
        widget: const _PanelBody(
          title: 'Projeto',
          lines: <String>['lib', 'examples', 'test', 'pubspec.yaml'],
        ),
      ),
      DockingTabs(<DockingItem>[
        DockingItem(
          id: 'editor',
          name: 'documento.pdf',
          closable: false,
          widget: const _DocumentPreview(),
        ),
        DockingItem(
          id: 'source',
          name: 'notas.txt',
          widget: const _PanelBody(
            title: 'Notas',
            lines: <String>[
              'As abas mantêm uma seleção controlada.',
              'Os divisores aceitam mouse e teclado.',
            ],
          ),
        ),
      ]),
      DockingItem(
        id: 'inspector',
        name: 'Propriedades',
        weight: 0.26,
        minimalSize: 210,
        widget: const _PanelBody(
          title: 'Documento',
          lines: <String>['Página: A4', 'Zoom: 100%', 'Rotação: 0°'],
        ),
      ),
    ]),
  );

  bool _darkMode = false;

  @override
  Widget build(BuildContext context) {
    final theme = _darkMode ? ThemeData.neutralDark : ThemeData.neutralLight;
    return Theme(
      data: theme,
      child: DockingTheme(
        data: DockingThemeData.fromTheme(theme),
        child: Column(
          children: <Widget>[
            Toolbar(
              height: 52,
              child: Row(
                children: <Widget>[
                  const Text(
                    'Docking workspace',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Button(
                    label: _darkMode ? 'Modo claro' : 'Modo escuro',
                    onPressed: () => setState(() => _darkMode = !_darkMode),
                  ),
                  const SizedBox(width: 8),
                  Button(label: 'Restaurar', onPressed: _layout.restore),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Docking(layout: _layout),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _PanelBody extends StatelessWidget {
  const _PanelBody({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            for (final line in lines) ...<Widget>[
              Text(line),
              const SizedBox(height: 8),
            ],
          ],
        ),
      );
}

final class _DocumentPreview extends StatelessWidget {
  const _DocumentPreview();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.surfaceAlternate,
      child: Center(
        child: SizedBox(
          width: 420,
          height: 520,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              border: BoxBorder(color: theme.border, width: 1),
              radius: 4,
            ),
            child: const Padding(
              padding: EdgeInsets.all(36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'DOCUMENTO DE EXEMPLO',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 24),
                  Text(
                    'O controle de docking organiza painéis redimensionáveis, '
                    'abas selecionáveis e áreas que podem ser maximizadas.',
                    style: TextStyle(color: Colors.black),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
