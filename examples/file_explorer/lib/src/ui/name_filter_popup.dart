/// Multi-choice filtering stays open while its owner listing updates.
library;

import 'package:dart_ui/dart_ui.dart';
import '../engine/explorer_model.dart';
import '../engine/name_filter.dart';

void showNameFilter(BuildContext context, ExplorerModel model, Rect anchor) {
  final host = PopupHost.maybeOf(context);
  if (host == null) return;
  final theme = Theme.of(context);
  final tab = model.tab;
  final location = tab.location;
  final choices = model.availableNameRanges;
  final selected = Set<NameRange>.of(tab.nameRanges);
  final pt = model.strings.locale.startsWith('pt');
  late final PopupHandle handle;
  handle = host.open(PopupSpec(
    anchorRect: anchor,
    kind: PopupKind.menu,
    builder: (_) => Theme(
      data: theme,
      child: _NameFilter(
        choices: choices,
        selected: selected,
        portuguese: pt,
        onClose: () => handle.close(),
        onChanged: (ranges) {
          if (!identical(model.tab, tab) || tab.location != location) {
            handle.close();
            return;
          }
          model.setNameRanges(ranges);
        },
      ),
    ),
  ));
}

class _NameFilter extends StatefulWidget {
  const _NameFilter(
      {required this.choices,
      required this.selected,
      required this.portuguese,
      required this.onChanged,
      required this.onClose});
  final Set<NameRange> choices;
  final Set<NameRange> selected;
  final bool portuguese;
  final void Function(Set<NameRange>) onChanged;
  final void Function() onClose;
  @override
  State<_NameFilter> createState() => _NameFilterState();
}

class _NameFilterState extends State<_NameFilter> {
  late final selected = Set<NameRange>.of(widget.selected);
  final scope = FocusScopeNode(debugLabel: 'name filter');
  BuildOwner? owner;

  @override
  void initState() {
    super.initState();
    scope.requestFocusOnAttach();
    owner = (context as Element).owner;
    owner?.addWindowKeyHandler(escape, modalDepth: 1 << 30, first: true);
  }

  bool escape(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != logicalKeyEscape) {
      return false;
    }
    widget.onClose();
    return true;
  }

  @override
  void dispose() {
    owner?.removeWindowKeyHandler(escape);
    scope.dispose();
    super.dispose();
  }

  void change(NameRange range, bool enabled) {
    setState(() => enabled ? selected.add(range) : selected.remove(range));
    widget.onChanged(Set<NameRange>.of(selected));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusScope(
        node: scope,
        child: DecoratedBox(
          decoration: BoxDecoration(
              color: theme.surfaceRaised,
              border: BoxBorder(color: theme.border, width: 1),
              radius: theme.cornerRadiusLarge),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: 192,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(widget.portuguese
                        ? 'Filtrar por nome'
                        : 'Filter by name'),
                    const SizedBox(height: 6),
                    for (final range in NameRange.values)
                      if (widget.choices.contains(range))
                        CheckBox(
                            value: selected.contains(range),
                            label: range == NameRange.other
                                ? (widget.portuguese ? 'Outros' : 'Other')
                                : range.label,
                            onChanged: (value) => change(range, value)),
                    const SizedBox(height: 6),
                    Button(
                        label: widget.portuguese
                            ? 'Limpar filtro'
                            : 'Clear filter',
                        onPressed: selected.isEmpty
                            ? null
                            : () {
                                setState(selected.clear);
                                widget.onChanged(<NameRange>{});
                              }),
                  ]),
            ),
          ),
        ));
  }
}
