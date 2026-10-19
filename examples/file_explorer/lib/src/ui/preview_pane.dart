/// Read-only previews, bounded and protected against stale asynchronous reads.
library;

import 'dart:async';
import 'package:dart_ui/dart_ui.dart';
import '../engine/explorer_model.dart';
import '../engine/file_system.dart';
import '../engine/file_types.dart';
import 'thumbnails.dart';

class PreviewPane extends StatefulWidget {
  const PreviewPane({super.key, required this.model, this.loader});
  final ExplorerModel model;
  final ThumbnailLoader? loader;
  @override
  State<PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends State<PreviewPane> {
  String? path;
  DateTime? modified;
  int generation = 0;
  String? text;
  DecodedImage? image;
  bool loading = false;
  String? error;

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  void load(FileEntry? entry) {
    if (path == entry?.path && modified == entry?.modified) return;
    path = entry?.path;
    modified = entry?.modified;
    final token = ++generation;
    text = null;
    image = null;
    error = null;
    loading = entry != null && !entry.isDirectory;
    if (!loading) return;
    unawaited(() async {
      try {
        if (kindOf(entry!) == FileKind.image && widget.loader != null) {
          final result = await widget.loader!(entry.path);
          if (!mounted || token != generation) return;
          image = result;
        } else if (widget.model.fs case final TextPreviewFileSystem reader) {
          final result = await reader.readTextPreview(entry.path);
          if (!mounted || token != generation) return;
          text = result;
        }
      } on Object catch (e) {
        if (!mounted || token != generation) return;
        error = '$e';
      }
      if (mounted && token == generation) setState(() => loading = false);
    }());
  }

  @override
  Widget build(BuildContext context) {
    final picked = widget.model.selectedEntries;
    final entry = picked.length == 1 ? picked.single : null;
    load(entry);
    final pt = widget.model.strings.locale.startsWith('pt');
    return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(pt ? 'Visualização' : 'Preview'),
            const Divider(height: 16),
            if (entry != null) Text(entry.name, maxLines: 2, ellipsis: '…'),
            const SizedBox(height: 12),
            Expanded(
                child: image != null
                    ? Image(image!, fit: BoxFit.contain)
                    : ScrollViewer(
                        child: Text(
                            loading
                                ? (pt ? 'Carregando…' : 'Loading…')
                                : error ??
                                    text ??
                                    (pt
                                        ? 'Selecione um arquivo de texto ou imagem para visualizar.'
                                        : 'Select a text file or image to preview.'),
                            softWrap: true,
                            breakWords: true))),
            if (text != null)
              Text(pt
                  ? 'Prévia limitada a 64 KiB.'
                  : 'Preview limited to 64 KiB.'),
          ],
        ));
  }
}
