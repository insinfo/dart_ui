/// An isolated column draft: visibility, order and widths apply together.
library;

import 'package:dart_ui/dart_ui.dart';
import '../engine/columns.dart';
import '../engine/explorer_model.dart';
import '../engine/file_system.dart';
import '../engine/location.dart';

Future<void> showColumnOptions(BuildContext context, ExplorerModel model) =>
    showDialog<void>(
        context: context, builder: (_) => ColumnOptions(model: model));

/// Shared measurement for the configuration window and grid header auto-fit.
double measureColumnWidth(ExplorerModel model, ThemeData theme,
    DetailsColumn column, List<FileEntry> items) {
  final font = FontRegistry.instance.uiFont(theme.fontSize);
  double measure(String value) => font == null
      ? FontRegistry.estimatedSize(value, theme.fontSize).width
      : uiTextPainter.measure(value, font).width;
  var width = measure(column.label(model.strings)) + 24;
  for (final entry in items) {
    final next = measure(columnText(column, entry, model.strings,
            showExtensions: model.showExtensions)) +
        (column == DetailsColumn.name
            ? 26 + (model.preferences['itemCheckboxes'] ? 24 : 0)
            : 0);
    if (next > width) width = next;
  }
  return (width + theme.effectiveControlPadding * 2 + 8).clamp(60.0, 2000.0);
}

class ColumnOptions extends StatefulWidget {
  const ColumnOptions({super.key, required this.model});
  final ExplorerModel model;
  @override
  State<ColumnOptions> createState() => _ColumnOptionsState();
}

class _ColumnOptionsState extends State<ColumnOptions> {
  late final visible = widget.model.visibleColumns.toSet();
  late final order = [
    ...widget.model.visibleColumns,
    for (final c in DetailsColumn.values)
      if (!visible.contains(c)) c,
  ];
  late final widths = Map<String, double>.of(widget.model.columnWidths);
  DetailsColumn selected = DetailsColumn.name;
  String query = '';
  bool dirty = false;
  bool get pt => widget.model.strings.locale.startsWith('pt');
  String tr(String en, String br) => pt ? br : en;

  void toggle(DetailsColumn column, bool shown) => setState(() {
        selected = column;
        if (column != DetailsColumn.name) {
          shown ? visible.add(column) : visible.remove(column);
          dirty = true;
        }
      });

  void move(int delta) => setState(() {
        final at = order.indexOf(selected);
        final next = at + delta;
        if (at < 1 || next < 1 || next >= order.length) return;
        order
          ..removeAt(at)
          ..insert(next, selected);
        dirty = true;
      });

  void apply() {
    widget.model.configureColumns(order.where(visible.contains), widths);
    setState(() => dirty = false);
  }

  void defaults() => setState(() {
        order
          ..clear()
          ..addAll(DetailsColumn.values);
        visible
          ..clear()
          ..addAll(const [
            DetailsColumn.name,
            DetailsColumn.dateModified,
            DetailsColumn.type,
            DetailsColumn.size
          ]);
        widths.clear();
        selected = DetailsColumn.name;
        dirty = true;
      });

  @override
  Widget build(BuildContext context) {
    final filtered = order
        .where((c) => c
            .label(widget.model.strings)
            .toLowerCase()
            .contains(query.trim().toLowerCase()))
        .toList();
    final selectedIndex = filtered.indexOf(selected);
    final at = order.indexOf(selected);
    final column = selected; // A width draft always belongs to this column.
    return SizedBox(
        width: 580,
        child: Dialog(
          title: tr('Choose columns', 'Escolher colunas'),
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
              height: 410,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(tr(
                        'Choose the columns for Details view in this folder.',
                        'Escolha as colunas da exibição Detalhes nesta pasta.')),
                    const SizedBox(height: 8),
                    TextField(
                        label: tr('Find a column', 'Buscar coluna'),
                        onChanged: (value) => setState(() => query = value)),
                    const SizedBox(height: 8),
                    Expanded(
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                          Expanded(
                              child: filtered.isEmpty
                                  ? Center(
                                      child: Text(tr('No columns found',
                                          'Nenhuma coluna encontrada')))
                                  : ListBox(
                                      itemCount: filtered.length,
                                      itemExtent: 30,
                                      selectedIndex: selectedIndex < 0
                                          ? null
                                          : selectedIndex,
                                      onSelected: (index) => setState(
                                          () => selected = filtered[index]),
                                      itemBuilder: (context, index) {
                                        final c = filtered[index];
                                        return Row(children: [
                                          Semantics(
                                              container: true,
                                              label:
                                                  c.label(widget.model.strings),
                                              role: SemanticsRole.checkbox,
                                              checked: visible.contains(c),
                                              enabled: c != DetailsColumn.name,
                                              onTap: c == DetailsColumn.name
                                                  ? null
                                                  : () => toggle(
                                                      c, !visible.contains(c)),
                                              child: CheckBox(
                                                  value: visible.contains(c),
                                                  onChanged: c ==
                                                          DetailsColumn.name
                                                      ? null
                                                      : (shown) =>
                                                          toggle(c, shown))),
                                          const SizedBox(width: 6),
                                          Expanded(
                                              child: Text(
                                                  c.label(widget.model.strings),
                                                  maxLines: 1,
                                                  ellipsis: '…')),
                                        ]);
                                      })),
                          const SizedBox(width: 10),
                          SizedBox(
                              width: 130,
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Button(
                                        label: tr('Move Up', 'Mover para cima'),
                                        accent: false,
                                        onPressed:
                                            query.trim().isEmpty && at > 1
                                                ? () => move(-1)
                                                : null),
                                    const SizedBox(height: 6),
                                    Button(
                                        label:
                                            tr('Move Down', 'Mover para baixo'),
                                        accent: false,
                                        onPressed: query.trim().isEmpty &&
                                                at > 0 &&
                                                at < order.length - 1
                                            ? () => move(1)
                                            : null),
                                    const SizedBox(height: 12),
                                    Button(
                                        label: tr('Show', 'Mostrar'),
                                        accent: false,
                                        onPressed: !visible.contains(selected)
                                            ? () => toggle(selected, true)
                                            : null),
                                    const SizedBox(height: 6),
                                    Button(
                                        label: tr('Hide', 'Ocultar'),
                                        accent: false,
                                        onPressed:
                                            selected != DetailsColumn.name &&
                                                    visible.contains(selected)
                                                ? () => toggle(selected, false)
                                                : null),
                                    const SizedBox(height: 12),
                                    Button(
                                        label: tr('Restore defaults',
                                            'Restaurar padrão'),
                                        accent: false,
                                        onPressed: defaults),
                                  ])),
                        ])),
                    const SizedBox(height: 10),
                    Text(
                        '${tr('Selected column', 'Coluna selecionada')}: ${selected.label(widget.model.strings)}'),
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(
                          child:
                              Text(tr('Width (pixels):', 'Largura (pixels):'))),
                      SizedBox(
                          width: 110,
                          child: NumberBox(
                              key: ValueKey(column),
                              value: widths[column.id] ?? column.defaultWidth,
                              min: 60,
                              max: 2000,
                              onChanged: (value) => setState(() {
                                    widths[column.id] = value;
                                    dirty = true;
                                  }))),
                      const SizedBox(width: 8),
                      Button(
                          label: tr('Auto size', 'Ajustar ao conteúdo'),
                          accent: false,
                          onPressed: () => setState(() {
                                widths[column.id] = measureColumnWidth(
                                    widget.model,
                                    Theme.of(context),
                                    column,
                                    widget.model.tab.visible);
                                dirty = true;
                              })),
                    ]),
                  ])),
        ));
  }
}
