/// Folder Options with an isolated draft: Cancel never applies preferences.
library;

import 'package:dart_ui/dart_ui.dart';
import '../engine/explorer_model.dart';
import '../engine/preferences.dart';

Future<void> showFolderOptions(BuildContext context, ExplorerModel model) =>
    showDialog<void>(
        context: context, builder: (_) => FolderOptions(model: model));

class FolderOptions extends StatefulWidget {
  const FolderOptions({super.key, required this.model});
  final ExplorerModel model;
  @override
  State<FolderOptions> createState() => _FolderOptionsState();
}

class _FolderOptionsState extends State<FolderOptions> {
  late ExplorerPreferences draft = widget.model.preferences.copy();
  bool dirty = false;
  int viewAction = 0;
  int selectedTab = 0;
  bool clearHistory = false;
  bool get pt => widget.model.strings.locale.startsWith('pt');
  String tr(String en, String br) => pt ? br : en;

  void apply() {
    widget.model.applyPreferences(draft);
    if (viewAction == 1) widget.model.applyViewToAllFolders();
    if (viewAction == 2) widget.model.resetFolderViews();
    if (clearHistory) widget.model.clearHistory();
    setState(() {
      dirty = false;
      viewAction = 0;
      clearHistory = false;
    });
  }

  Widget check(String key, String en, String br) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: CheckBox(
            value: draft[key],
            label: tr(en, br),
            onChanged: (v) => setState(() {
                  draft[key] = v;
                  dirty = true;
                })),
      );
  Widget page(List<Widget> children) => ScrollViewer(
          child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ));

  @override
  Widget build(BuildContext context) => SizedBox(
      width: 540,
      child: Dialog(
        title: tr('Folder Options', 'Opções de Pasta'),
        onDismiss: () => closeDialog<void>(context),
        actions: [
          Button(
              label: 'OK',
              isDefault: true,
              onPressed: () {
                apply();
                closeDialog<void>(context);
              }),
          Button(
              label: tr('Cancel', 'Cancelar'),
              isCancel: true,
              accent: false,
              onPressed: () => closeDialog<void>(context)),
          Button(
              label: tr('Apply', 'Aplicar'),
              accent: false,
              onPressed: dirty ? apply : null),
        ],
        child: SizedBox(
            height: 350,
            child: Tabs(
                selectedIndex: selectedTab,
                onSelected: (v) => setState(() => selectedTab = v),
                tabs: [
                  TabItem(
                      label: tr('General', 'Geral'),
                      content: page([
                        check(
                            'startThisPc',
                            'Open new tabs on This PC (otherwise Home)',
                            'Abrir novas abas em Este Computador (senão, Início)'),
                        check('restoreTabs', 'Restore tabs when starting',
                            'Restaurar abas ao iniciar'),
                        check('singleClick', 'Single click to open items',
                            'Abrir itens com um clique'),
                        check(
                            'openFoldersInNewTab',
                            'Open folders in a new tab',
                            'Abrir pastas em uma nova aba'),
                        const Divider(height: 16),
                        check(
                            'showRecent',
                            'Remember and show recently opened files',
                            'Lembrar e mostrar arquivos abertos recentemente'),
                        Button(
                            label: clearHistory
                                ? tr('History will be cleared on Apply',
                                    'Histórico será limpo ao aplicar')
                                : tr('Clear history', 'Limpar histórico'),
                            accent: false,
                            onPressed: () => setState(() {
                                  clearHistory = true;
                                  dirty = true;
                                })),
                        const SizedBox(height: 10),
                        Button(
                            label: tr('Restore defaults', 'Restaurar padrões'),
                            accent: false,
                            onPressed: () => setState(() {
                                  draft = ExplorerPreferences();
                                  dirty = true;
                                })),
                      ])),
                  TabItem(
                      label: tr('View', 'Modo de Exibição'),
                      content: page([
                        Row(children: [
                          Expanded(
                              child: Button(
                                  label: tr('Apply view to all folders',
                                      'Aplicar exibição a todas as pastas'),
                                  accent: false,
                                  onPressed: () => setState(() {
                                        viewAction = 1;
                                        dirty = true;
                                      }))),
                          const SizedBox(width: 8),
                          Button(
                              label: tr('Reset folders', 'Redefinir pastas'),
                              accent: false,
                              onPressed: () => setState(() {
                                    viewAction = 2;
                                    dirty = true;
                                  })),
                        ]),
                        if (viewAction != 0)
                          Text(tr(
                              'Folder view changes will take effect on Apply.',
                              'As alterações de exibição serão feitas ao aplicar.')),
                        check(
                            'rememberFolderViews',
                            'Remember view settings per folder',
                            'Lembrar exibição de cada pasta'),
                        check('showHidden', 'Show hidden files and folders',
                            'Mostrar arquivos e pastas ocultos'),
                        check('showExtensions', 'Show file name extensions',
                            'Mostrar extensões de nomes de arquivos'),
                        check(
                            'showProtected',
                            'Show protected operating system files',
                            'Mostrar arquivos protegidos do sistema'),
                        check('compact', 'Use compact spacing',
                            'Usar espaçamento compacto'),
                        check(
                            'itemCheckboxes',
                            'Use checkboxes to select items',
                            'Usar caixas de seleção para selecionar itens'),
                        check(
                            'showThumbnails',
                            'Show thumbnails instead of only icons',
                            'Mostrar miniaturas em vez de apenas ícones'),
                        check(
                            'showFolderTips',
                            'Show item information in tooltips',
                            'Mostrar informações dos itens nas dicas'),
                        check('showStatusBar', 'Show status bar',
                            'Mostrar barra de status'),
                        check(
                            'showFullPath',
                            'Show full path in the window title',
                            'Mostrar caminho completo no título da janela'),
                        check('navigationPane', 'Show navigation pane',
                            'Mostrar painel de navegação'),
                      ])),
                  TabItem(
                      label: tr('Search', 'Pesquisar'),
                      content: page([
                        check(
                            'searchSubfolders',
                            'Include subfolders in searches',
                            'Incluir subpastas nas pesquisas'),
                        const SizedBox(height: 12),
                        Text(
                            tr('Search names and properties without an index. Hidden and protected items follow View options.',
                                'Pesquise nomes e propriedades sem um índice. Itens ocultos e protegidos seguem as opções de exibição.'),
                            softWrap: true),
                        const SizedBox(height: 12),
                        const Text(
                            '*.pdf   ext:dart   kind:image   size:>10MB\nmodified:>=2026-01-01   created:<2026-06-01\n"annual report" AND NOT ext:tmp\next:png OR ext:jpg',
                            softWrap: true),
                        const SizedBox(height: 12),
                        Text(
                            tr('Up to 5,000 matches. Stop keeps results already found. Document contents are not indexed.',
                                'Até 5.000 resultados. Parar mantém os resultados encontrados. O conteúdo dos documentos não é indexado.'),
                            softWrap: true),
                      ])),
                ])),
      ));
}
