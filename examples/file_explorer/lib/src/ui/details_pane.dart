/// The details pane: what is selected, big, with its properties.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/explorer_model.dart';
import '../engine/file_system.dart';
import '../engine/file_types.dart';
import 'file_icon.dart';

/// The pane on the right.
class DetailsPane extends StatelessWidget {
  const DetailsPane({super.key, required this.model});

  final ExplorerModel model;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<FileEntry> picked = model.selectedEntries;
    final bool pt = model.strings.locale.startsWith('pt');
    final FileEntry? one = picked.length == 1 ? picked.single : null;
    final String title = one?.name ??
        (picked.isEmpty
            ? model.titleOf(model.tab.location)
            : model.strings.selectedCount(picked.length));
    final FileKind kind = one == null ? FileKind.folder : kindOf(one);
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label,
                  style: theme.textTheme.bodySmall,
                  color: theme.foregroundSecondary),
              Text(value,
                  style: theme.textTheme.bodyMedium,
                  color: theme.foreground,
                  softWrap: true),
            ],
          ),
        );
    final int bytes = picked.fold<int>(
        0, (int s, FileEntry e) => s + (e.isDirectory ? 0 : e.size ?? 0));
    return ScrollViewer(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(child: FileIcon(kind, size: 96)),
            const SizedBox(height: 12),
            Text(title,
                style: theme.textTheme.titleSmall,
                color: theme.foreground,
                softWrap: true,
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (one != null) ...<Widget>[
              row(model.strings.type, typeNameOf(one, model.strings)),
              if (!one.isDirectory)
                row(model.strings.size,
                    humanSize(one.size ?? 0, model.strings)),
              row(model.strings.dateModified,
                  dateColumn(one.modified, model.strings)),
              if (one.created != null)
                row(pt ? 'Data de criação' : 'Date created',
                    dateColumn(one.created, model.strings)),
              row(model.strings.location, model.fs.parentOf(one.path) ?? ''),
            ] else if (picked.isNotEmpty) ...<Widget>[
              if (bytes > 0)
                row(model.strings.size, humanSize(bytes, model.strings)),
            ] else
              row(model.strings.items,
                  model.strings.itemCount(model.tab.visible.length)),
          ],
        ),
      ),
    );
  }
}
