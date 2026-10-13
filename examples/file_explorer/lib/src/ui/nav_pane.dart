/// The navigation pane: Home, the pinned folders, This PC and its drives -
/// each folder expandable, its subfolders read when it is opened.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';

import '../engine/explorer_model.dart';
import '../engine/file_system.dart';
import '../engine/location.dart';
import '../engine/sorting.dart';

/// The icon and colour Windows 11 gives each known folder.
(IconData, Color) placeIcon(Place? place) => switch (place) {
      Place.desktop => (FluentIcons.desktopFilled, const Color(0xFF2B88D8)),
      Place.downloads => (FluentIcons.arrowDownload, const Color(0xFF1E8E4E)),
      Place.documents => (FluentIcons.documentFilled, const Color(0xFF5A7FA8)),
      Place.pictures => (FluentIcons.imageFilled, const Color(0xFF2B88D8)),
      Place.music => (FluentIcons.musicNote2Filled, const Color(0xFFD9541E)),
      Place.videos => (FluentIcons.videoClipFilled, const Color(0xFF8E44AD)),
      Place.home => (FluentIcons.homeFilled, const Color(0xFF0F6CBD)),
      null => (FluentIcons.folderFilled, const Color(0xFFE0A100)),
    };

/// The pane.
class NavigationPane extends StatefulWidget {
  const NavigationPane(
      {super.key, required this.model, required this.registry});

  final ExplorerModel model;
  final CommandRegistry registry;

  @override
  State<NavigationPane> createState() => _NavigationPaneState();
}

class _NavigationPaneState extends State<NavigationPane> {
  static const String _home = '::home';
  static const String _thisPc = '::thispc';

  final Set<Object> _expanded = <Object>{_thisPc};

  /// Subfolders read so far, by folder.
  final Map<String, List<FileEntry>> _children = <String, List<FileEntry>>{};

  ExplorerModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    if (model.volumes.isEmpty) {
      unawaited(model.fs.volumes().then((List<Volume> found) {
        if (!mounted) return;
        setState(() => model.volumes = found);
      }));
    }
  }

  Future<void> _load(String path) async {
    try {
      final List<FileEntry> listed = await model.fs.list(path);
      final List<FileEntry> folders = sortEntries(
        <FileEntry>[
          for (final FileEntry e in listed)
            if (e.isDirectory && (model.showHidden || !e.isHidden)) e,
        ],
        SortField.name,
        true,
        model.strings,
      );
      if (mounted) setState(() => _children[path] = folders);
    } on Object {
      if (mounted) setState(() => _children[path] = const <FileEntry>[]);
    }
  }

  TreeNode _folder(String path, {String? label, Place? place}) {
    final (IconData icon, Color color) = placeIcon(place);
    final List<FileEntry>? loaded = _children[path];
    return TreeNode(
      id: path,
      label: label ?? model.fs.nameOf(path),
      icon: icon,
      iconColor: color,
      hasChildren: loaded == null || loaded.isNotEmpty,
      children: <TreeNode>[
        for (final FileEntry child in loaded ?? const <FileEntry>[])
          _folder(child.path),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<TreeNode> nodes = <TreeNode>[
      TreeNode(
        id: _home,
        label: model.strings.home,
        icon: FluentIcons.homeFilled,
        iconColor: const Color(0xFF0F6CBD),
      ),
      for (final String path in model.pinned)
        _folder(path,
            label: model.placeAt(path) == null
                ? null
                : model.placeName(model.placeAt(path)!),
            place: model.placeAt(path)),
      TreeNode(
        id: _thisPc,
        label: model.strings.thisPc,
        icon: FluentIcons.desktopFilled,
        iconColor: const Color(0xFF2B88D8),
        hasChildren: true,
        children: <TreeNode>[
          for (final Volume volume in model.volumes)
            TreeNode(
              id: volume.path,
              label: volume.label,
              icon: FluentIcons.hardDrive,
              iconColor: const Color(0xFF6E6E6E),
              hasChildren: _children[volume.path]?.isNotEmpty ?? true,
              children: <TreeNode>[
                for (final FileEntry child
                    in _children[volume.path] ?? const <FileEntry>[])
                  _folder(child.path),
              ],
            ),
        ],
      ),
    ];
    final Location at = model.tab.location;
    final Object selected = switch (at) {
      HomeLocation() => _home,
      ThisPcLocation() => _thisPc,
      FolderLocation(:final String path) => path,
      SearchLocation(:final String root) => root,
    };
    return Padding(
      padding: const EdgeInsets.all(4),
      child: TreeView(
        decorated: false,
        nodes: nodes,
        rowExtent: 32,
        expandedIds: _expanded,
        selectedId: selected,
        onToggle: (TreeNode node, bool expand) {
          setState(() {
            if (expand) {
              _expanded.add(node.identity);
            } else {
              _expanded.remove(node.identity);
            }
          });
          final Object id = node.identity;
          if (expand &&
              id is String &&
              !id.startsWith('::') &&
              !_children.containsKey(id)) {
            unawaited(_load(id));
          }
        },
        onSelected: (TreeNode node) {
          final Object id = node.identity;
          if (id == _home) {
            widget.registry.execute('nav.home');
          } else if (id == _thisPc) {
            widget.registry.execute('nav.thisPc');
          } else if (id is String) {
            widget.registry.execute('nav.go', <String, Object?>{'path': id});
          }
        },
      ),
    );
  }
}
