/// A folder's items in the chosen layout: Details (columns), List, Tiles,
/// or icons from small to extra large.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/explorer_model.dart';
import '../engine/explorer_tab.dart';
import '../engine/file_system.dart';
import '../engine/file_types.dart';
import '../engine/location.dart';
import 'drag_support.dart';
import 'file_icon.dart';
import 'thumbnails.dart';

/// The items of the active tab.
class FolderView extends StatelessWidget {
  const FolderView({
    super.key,
    required this.model,
    required this.registry,
    required this.renameField,
    this.headerMenu,
    this.thumbnails,
  });

  final ExplorerModel model;
  final CommandRegistry registry;

  /// The in-place rename field, built by the window so it keeps its
  /// controller and focus across rebuilds.
  final Widget Function(FileEntry entry) renameField;

  /// The Details header's right-click menu: which columns to show.
  final List<Widget> Function()? headerMenu;

  /// Pictures' thumbnails for the icon views and Tiles.
  final ThumbnailCache? thumbnails;

  /// [entry]'s picture in a [size] box - its thumbnail cropped to fill the
  /// box, as Files shows photographs - or its icon.
  Widget _picture(FileEntry entry, double size) {
    final DecodedImage? thumb = size >= 40 ? thumbnails?.of(entry) : null;
    if (thumb == null) return FileIcon(kindOf(entry), size: size);
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: ClipRRect(
          radius: 2,
          child:
              Image(thumb, width: size, height: size * .66, fit: BoxFit.cover),
        ),
      ),
    );
  }

  ExplorerTab get tab => model.tab;

  void _select(List<String> paths) =>
      registry.execute('select.paths', <String, Object?>{'paths': paths});

  /// A click on [entry] with the modifiers the window last saw: Ctrl
  /// toggles, Shift extends from the focused item, nothing replaces.
  void _click(BuildContext context, FileEntry entry) {
    final BuildOwner? owner = context is Element ? context.owner : null;
    final Set<KeyModifier> mods = owner?.keyModifiers ?? const <KeyModifier>{};
    final bool toggle = owner?.commandHeld ?? false;
    final List<FileEntry> items = tab.visible;
    if (mods.contains(KeyModifier.shift) && tab.focused != null) {
      final int a = items.indexWhere((FileEntry e) => e.path == tab.focused);
      final int b = items.indexOf(entry);
      if (a >= 0 && b >= 0) {
        final int lo = a < b ? a : b;
        final int hi = a < b ? b : a;
        model.select(<String>[for (var i = lo; i <= hi; i++) items[i].path],
            focused: tab.focused);
        return;
      }
    }
    if (toggle) {
      final Set<String> next = <String>{...tab.selection};
      if (!next.remove(entry.path)) next.add(entry.path);
      model.select(next, focused: entry.path);
      return;
    }
    _select(<String>[entry.path]);
  }

  /// The folder a drop on the empty space goes into: the one on screen, and
  /// none for Home, This PC or search results.
  String? get _dropHere => model.canCreateHere ? model.currentFolder : null;

  /// What a drag starting on [entry] carries: the selection when [entry] is
  /// in it, [entry] alone otherwise.
  List<String> _dragPaths(FileEntry entry) => tab.selection.contains(entry.path)
      ? <String>[
          for (final FileEntry e in tab.visible)
            if (tab.selection.contains(e.path)) e.path,
        ]
      : <String>[entry.path];

  /// [child] as a place files can be dropped into the folder on screen.
  Widget _background(Widget child) {
    final String? here = _dropHere;
    return here == null
        ? child
        : folderDropTarget(model: model, folder: here, child: child);
  }

  void _open(FileEntry entry) {
    _select(<String>[entry.path]);
    registry.execute('file.open');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (tab.error != null) {
      return _Message(icon: PhosphorIcons.warningCircle, text: tab.error!);
    }
    if (tab.visible.isEmpty && !tab.loading) {
      return _background(_Message(
        icon: tab.location is SearchLocation
            ? PhosphorIcons.magnifyingGlass
            : PhosphorIcons.folderOpen,
        text: tab.location is SearchLocation
            ? model.strings.noResults
            : model.strings.emptyFolder,
      ));
    }
    return switch (model.viewMode) {
      ViewMode.details => _details(theme),
      ViewMode.list => _grid(context, theme, iconSize: 16, list: true),
      ViewMode.tiles => _grid(context, theme, iconSize: 48, tiles: true),
      ViewMode.smallIcons => _grid(context, theme, iconSize: 16, list: true),
      ViewMode.mediumIcons => _grid(context, theme, iconSize: 48),
      ViewMode.largeIcons => _grid(context, theme, iconSize: 96),
      ViewMode.extraLargeIcons => _grid(context, theme, iconSize: 192),
    };
  }

  // --- Details ----------------------------------------------------------------

  Widget _details(ThemeData theme) {
    final List<FileEntry> items = tab.visible;
    final bool search = tab.location is SearchLocation;
    final List<DataGridColumn> columns = <DataGridColumn>[
      for (final DetailsColumn c in model.columns) ...<DataGridColumn>[
        _column(c),
        if (search && c == DetailsColumn.name)
          DataGridColumn(
              title: model.strings.location, id: 'location', width: 260),
      ],
    ];
    final List<SortField?> fieldOf = <SortField?>[
      for (final DataGridColumn c in columns)
        switch (c.identity) {
          'name' => SortField.name,
          'date' => SortField.dateModified,
          'type' => SortField.type,
          'size' => SortField.size,
          _ => null,
        },
    ];
    final int sortColumn = fieldOf.indexOf(model.sortField);
    return DataGrid(
      decorated: false,
      headerMenu: headerMenu,
      columnFitWidth: (int column) =>
          _fitWidth(theme, columns[column].identity as String, items),
      columns: columns,
      rowCount: items.length,
      rowExtent: 30,
      selectionMode: DataGridSelectionMode.multiple,
      selectedRows: <int>{
        for (var i = 0; i < items.length; i++)
          if (tab.selection.contains(items[i].path)) i,
      },
      onSelectionChanged: (Set<int> rows) => _select(
          <String>[for (final int i in rows.toList()..sort()) items[i].path]),
      onRowActivated: (int row) => _open(items[row]),
      // Rows drag out as files - to a folder here, or to another
      // application - and folders take drops; anywhere else in the list is
      // the folder on screen.
      rowDragData: (Set<int> rows) => dragOut(model,
          <String>[for (final int i in rows.toList()..sort()) items[i].path]),
      onRowDragEnd: (DragAction action) => dragEnded(model, action),
      rowAcceptsDrops: (int row) => items[row].isDirectory,
      rowDropResponse: (int? row, DropDetails details) {
        final String? folder = row != null ? items[row].path : _dropHere;
        return folder == null
            ? const DropResponse.reject()
            : folderDropResponse(model, folder, details);
      },
      onRowDrop: (int? row, DropDetails details) async {
        final String? folder = row != null ? items[row].path : _dropHere;
        return folder == null
            ? DragAction.none
            : dropIntoFolder(model, folder, details);
      },
      sort: sortColumn < 0
          ? null
          : DataGridSort(
              sortColumn,
              model.ascending
                  ? DataGridSortDirection.ascending
                  : DataGridSortDirection.descending),
      onSortChanged: (DataGridSort sort) {
        final SortField? field = fieldOf[sort.columnIndex];
        if (field == null) return;
        model.sortBy(field,
            ascending: sort.direction == DataGridSortDirection.ascending);
      },
      cellBuilder: (BuildContext context, int row, int column) {
        final FileEntry entry = items[row];
        final String id = columns[column].identity as String;
        final Color secondary = theme.foregroundSecondary;
        return switch (id) {
          'name' => Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                FileIcon(kindOf(entry), size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: tab.renaming == entry.path
                      ? renameField(entry)
                      : Text(
                          model.shownName(entry),
                          style: theme.textTheme.bodyMedium,
                          color: theme.foreground,
                          maxLines: 1,
                          ellipsis: '…',
                        ),
                ),
              ],
            ),
          'location' =>
            _cell(theme, model.fs.parentOf(entry.path) ?? '', secondary),
          'date' =>
            _cell(theme, dateColumn(entry.modified, model.strings), secondary),
          'created' =>
            _cell(theme, dateColumn(entry.created, model.strings), secondary),
          'type' => _cell(theme, typeNameOf(entry, model.strings), secondary),
          _ => Align(
              alignment: Alignment.centerRight,
              child: _cell(
                  theme, sizeColumn(entry.size, model.strings), secondary),
            ),
        };
      },
    );
  }

  DataGridColumn _column(DetailsColumn c) => switch (c) {
        DetailsColumn.name =>
          DataGridColumn(title: model.strings.name, id: 'name', width: 320),
        DetailsColumn.dateModified => DataGridColumn(
            title: model.strings.dateModified, id: 'date', width: 170),
        DetailsColumn.type =>
          DataGridColumn(title: model.strings.type, id: 'type', width: 170),
        DetailsColumn.size =>
          DataGridColumn(title: model.strings.size, id: 'size', width: 100),
        DetailsColumn.dateCreated => DataGridColumn(
            title: model.strings.locale.startsWith('pt')
                ? 'Data de criação'
                : 'Date created',
            id: 'created',
            width: 170,
            sortable: false),
      };

  /// What column [id] needs to show every value whole - a double click on
  /// its edge, as in File Explorer.
  double? _fitWidth(ThemeData theme, String id, List<FileEntry> items) {
    final ScaledTypeface? font = FontRegistry.instance.uiFont(theme.fontSize);
    double measure(String text) => font == null
        ? FontRegistry.estimatedSize(text, theme.fontSize).width
        : uiTextPainter.measure(text, font).width;
    var widest = 0.0;
    for (final FileEntry e in items) {
      final String text = switch (id) {
        'name' => model.shownName(e),
        'location' => model.fs.parentOf(e.path) ?? '',
        'date' => dateColumn(e.modified, model.strings),
        'created' => dateColumn(e.created, model.strings),
        'type' => typeNameOf(e, model.strings),
        _ => sizeColumn(e.size, model.strings),
      };
      final double w = measure(text);
      if (w > widest) widest = w;
    }
    final double padding = theme.effectiveControlPadding * 2 + 8;
    return (widest + padding + (id == 'name' ? 26 : 0)).clamp(60.0, 900.0);
  }

  Widget _cell(ThemeData theme, String text, Color color) => Text(
        text,
        style: theme.textTheme.bodyMedium,
        color: color,
        maxLines: 1,
        ellipsis: '…',
      );

  // --- icons, list, tiles -----------------------------------------------------

  Widget _grid(BuildContext context, ThemeData theme,
      {required double iconSize, bool list = false, bool tiles = false}) {
    final List<FileEntry> items = tab.visible;
    final double cellWidth = list
        ? 260
        : tiles
            ? 300
            : iconSize < 64
                ? 96
                : iconSize + 32;
    // Files' Large icons: a 128 x 132 px cell, the name on one line under
    // it, the rows touching - the tiles' own 2 px margins keep them apart.
    final double cellHeight = list
        ? 28
        : tiles
            ? 72
            : iconSize + 36;
    return _background(GestureDetector(
      behavior: GestureHitTestBehavior.opaque,
      // A click between the items drops the selection, as in Explorer.
      onTap: () => _select(const <String>[]),
      // 4 px short on the right, as Files leaves it, so six 128 px cells
      // fit beside a 232 px sidebar in a 1024 px window.
      child: Padding(
        padding: const EdgeInsets.only(left: 8, top: 7, right: 4, bottom: 6),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final int perRow =
                (constraints.maxWidth / cellWidth).floor().clamp(1, 1000);
            final int rows = (items.length + perRow - 1) ~/ perRow;
            return ListView.builder(
              itemCount: rows,
              itemExtent: list || tiles ? cellHeight + 4 : cellHeight,
              itemBuilder: (BuildContext context, int row) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (var k = 0; k < perRow; k++)
                    if (row * perRow + k < items.length)
                      SizedBox(
                        width: cellWidth,
                        height: cellHeight,
                        child: _item(context, theme, items[row * perRow + k],
                            iconSize: iconSize, list: list, tiles: tiles),
                      ),
                ],
              ),
            );
          },
        ),
      ),
    ));
  }

  Widget _item(BuildContext context, ThemeData theme, FileEntry entry,
      {required double iconSize, required bool list, required bool tiles}) {
    final bool selected = tab.selection.contains(entry.path);
    final bool renaming = tab.renaming == entry.path;
    final Widget tile = HoverBuilder(
      builder: (BuildContext context, bool hovered) => GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: () => _click(context, entry),
        onDoubleTap: (_) => _open(entry),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // Files marks a selected icon with an accent outline on a
              // white tile; a row of List or Tiles with a tint.
              color: selected
                  ? (list || tiles ? theme.selection : theme.surfaceAlternate)
                  : hovered
                      ? theme.hoverSurface
                      : null,
              border: selected
                  ? BoxBorder(
                      color: list || tiles
                          ? theme.accent.withAlpha(0x80)
                          : theme.accent,
                      width: list || tiles ? 1 : 2)
                  : null,
              radius: 4,
            ),
            child: list || tiles
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        _picture(entry, iconSize),
                        SizedBox(width: tiles ? 12 : 8),
                        Expanded(
                          child: renaming
                              ? renameField(entry)
                              : tiles
                                  ? _tileText(theme, entry)
                                  : Text(model.shownName(entry),
                                      style: theme.textTheme.bodyMedium,
                                      color: theme.foreground,
                                      maxLines: 1,
                                      ellipsis: '…'),
                        ),
                      ],
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(
                        left: 6, top: 2, right: 6, bottom: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        _picture(entry, iconSize),
                        if (renaming)
                          SizedBox(height: 28, child: renameField(entry))
                        else
                          Text(
                            model.shownName(entry),
                            style: theme.textTheme.bodyMedium,
                            color: theme.foreground,
                            maxLines: 1,
                            ellipsis: '…',
                            textAlign: TextAlign.center,
                          ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
    // Every item drags; a folder also takes drops, lit while they hover.
    return DragSource(
      data: () => dragOut(model, _dragPaths(entry)),
      allowedActions: const <DragAction>{DragAction.copy, DragAction.move},
      preferredAction: DragAction.move,
      opaque: true,
      onDragEnd: (DragAction action) => dragEnded(model, action),
      child: entry.isDirectory
          ? folderDropTarget(
              model: model,
              folder: entry.path,
              highlight: theme.accent.withAlpha(0x2E),
              child: tile,
            )
          : tile,
    );
  }

  Widget _tileText(ThemeData theme, FileEntry entry) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(model.shownName(entry),
              style: theme.textTheme.bodyMedium,
              color: theme.foreground,
              maxLines: 1,
              ellipsis: '…'),
          Text(typeNameOf(entry, model.strings),
              style: theme.textTheme.bodySmall,
              color: theme.foregroundSecondary,
              maxLines: 1,
              ellipsis: '…'),
          if (!entry.isDirectory)
            Text(humanSize(entry.size ?? 0, model.strings),
                style: theme.textTheme.bodySmall,
                color: theme.foregroundSecondary,
                maxLines: 1),
        ],
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Align(
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 32, color: theme.foregroundSecondary),
            const SizedBox(height: 12),
            Text(text,
                style: theme.textTheme.bodyMedium,
                color: theme.foregroundSecondary),
          ],
        ),
      ),
    );
  }
}
