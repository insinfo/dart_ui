/// Properties (Alt+Enter): the General tab of Windows' dialog - the name,
/// what the item is, where, how big, what a folder holds, when it was made
/// and changed - with OK, Cancel and Apply.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';

import '../engine/explorer_model.dart';
import '../engine/file_system.dart';
import '../engine/file_types.dart';
import '../engine/properties.dart';
import 'file_icon.dart';

/// Opens an owned, non-modal properties window. The owner stays usable.
Future<void> showPropertiesDialog(
  BuildContext context,
  ExplorerModel model,
  List<FileEntry> entries,
) async {
  if (entries.isEmpty) return;
  final owner = WindowScope.of(context);
  if (owner == null) {
    throw StateError('Properties requires an application window');
  }
  final closed = Completer<void>();
  await owner.openChildWindow(
    title: propertiesTitle(entries, model.strings),
    size: const Size(480, 520),
    child: Theme(
      data: Theme.of(context),
      child: PropertiesDialog(
          model: model, entries: List.of(entries), windowed: true),
    ),
    onClosed: () {
      if (!closed.isCompleted) closed.complete();
    },
  );
  await closed.future;
}

/// The dialog itself; see [showPropertiesDialog].
class PropertiesDialog extends StatefulWidget {
  const PropertiesDialog({
    super.key,
    required this.model,
    required this.entries,
    this.windowed = false,
  });

  final ExplorerModel model;
  final List<FileEntry> entries;
  final bool windowed;

  @override
  State<PropertiesDialog> createState() => _PropertiesDialogState();
}

class _PropertiesDialogState extends State<PropertiesDialog> {
  late final TextEditingController _name =
      TextEditingController(widget.entries.first.name);
  late List<FileEntry> _entries = widget.entries;
  Tally? _tally;
  bool _counting = false;
  bool _closed = false;
  String? _error;

  ExplorerModel get model => widget.model;
  bool get _single => _entries.length == 1;
  bool get _walks => _entries.any((FileEntry e) => e.isDirectory);

  @override
  void initState() {
    super.initState();
    if (_walks) {
      _counting = true;
      unawaited(tally(
        model.fs,
        _entries,
        cancelled: () => _closed,
        progress: (Tally running) {
          if (mounted) setState(() => _tally = running);
        },
      ).then((Tally done) {
        if (mounted) {
          setState(() {
            _tally = done;
            _counting = false;
          });
        }
      }));
    } else {
      _tally = tally0(_entries);
    }
  }

  /// The sum of plain files, which needs no walk.
  static Tally tally0(List<FileEntry> files) => Tally(
        files: files.length,
        bytes: files.fold(0, (int sum, FileEntry e) => sum + (e.size ?? 0)),
      );

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  Future<void> _accept() async {
    if (await _apply() && mounted) _close();
  }

  void _close() {
    if (widget.windowed) {
      WindowScope.of(context)?.close();
    } else {
      closeDialog<void>(context);
    }
  }

  /// Renames when the name changed; answers whether the dialog may close.
  Future<bool> _apply() async {
    if (!_single) return true;
    final FileEntry entry = _entries.single;
    final String name = _name.value.trim();
    if (name.isEmpty || name == entry.name) return true;
    final String? renamed = await model.rename(entry.path, name);
    if (!mounted) return false;
    if (renamed == null) {
      setState(() => _error = model.message ?? 'Could not rename');
      return false;
    }
    final FileEntry? fresh = await model.fs.stat(renamed);
    if (!mounted) return false;
    setState(() {
      _error = null;
      if (fresh != null) _entries = <FileEntry>[fresh];
    });
    if (widget.windowed) {
      WindowScope.of(context)
          ?.setTitle(propertiesTitle(_entries, model.strings));
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final strings = model.strings;
    final bool pt = strings.locale.startsWith('pt');
    final FileEntry first = _entries.first;
    final Tally? sums = _tally;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            children: <Widget>[
              SizedBox(
                width: 120,
                child: Text(label, color: theme.foregroundSecondary),
              ),
              Expanded(
                child: Text(value,
                    color: theme.foreground, softWrap: true, breakWords: true),
              ),
            ],
          ),
        );
    const Widget rule = Divider(height: 17);

    final actions = <Widget>[
      Button(
        label: 'OK',
        isDefault: true,
        onPressed: _accept,
      ),
      Button(
        label: pt ? 'Cancelar' : 'Cancel',
        accent: false,
        isCancel: true,
        onPressed: _close,
      ),
      Button(
        label: pt ? 'Aplicar' : 'Apply',
        accent: false,
        onPressed: () => unawaited(_apply()),
      ),
    ];
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 120,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FileIcon(
                  _single ? kindOf(first) : FileKind.generic,
                  size: 32,
                ),
              ),
            ),
            Expanded(
              child: _single
                  ? TextField(
                      controller: _name,
                      onSubmitted: (_) => unawaited(_accept()))
                  : Text(strings.itemCount(_entries.length),
                      color: theme.foreground),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_error!, color: const Color(0xFFC42B1C)),
          ),
        rule,
        row(pt ? 'Tipo:' : 'Type:', typeText(_entries, strings)),
        row(pt ? 'Local:' : 'Location:',
            locationText(_entries, model.fs, strings)),
        row(
          pt ? 'Tamanho:' : 'Size:',
          sums == null
              ? ''
              : '${exactSize(sums.bytes, strings)}'
                  '${_counting ? (pt ? ' - calculando…' : ' - calculating…') : ''}',
        ),
        if (_walks && sums != null)
          row(pt ? 'Contém:' : 'Contains:', containsText(sums, strings)),
        if (_single) ...<Widget>[
          rule,
          if (first.created != null)
            row(pt ? 'Criado em:' : 'Created:',
                longDate(first.created!, strings)),
          if (first.modified != null)
            row(pt ? 'Modificado em:' : 'Modified:',
                longDate(first.modified!, strings)),
        ],
        rule,
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 120,
              child: Text(pt ? 'Atributos:' : 'Attributes:',
                  color: theme.foregroundSecondary),
            ),
            CheckBox(
              value: _entries.every((FileEntry e) => e.isHidden)
                  ? true
                  : _entries.any((FileEntry e) => e.isHidden)
                      ? null
                      : false,
              tristate: true,
              label: pt ? 'Oculto' : 'Hidden',
            ),
          ],
        ),
      ],
    );
    if (widget.windowed) {
      return CallbackShortcuts(
        bindings: {
          const KeyGesture(logicalKeyEscape): _close,
          const KeyGesture(logicalKeyEnter): () => unawaited(_accept())
        },
        child: ColoredBox(
          color: theme.surface,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: ScrollViewer(child: content)),
                  const SizedBox(height: 16),
                  Row(children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(child: actions[i]),
                    ]
                  ]),
                ]),
          ),
        ),
      );
    }
    return SizedBox(
        width: 440,
        child: Dialog(
          title: propertiesTitle(widget.entries, strings),
          onDismiss: _close,
          actions: actions,
          child: content,
        ));
  }
}
