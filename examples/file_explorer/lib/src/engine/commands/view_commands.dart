/// View: the layouts, sorting, hidden items, extensions and the panes.
library;

import 'package:dart_ui/commands.dart';

import '../columns.dart';
import '../explorer_model.dart';
import '../location.dart';
import 'command_context.dart';

/// Windows 11's layouts and their keys, Ctrl+Shift+1 to 8.
const List<(String, String, ViewMode, int)> kViewModeCommands =
    <(String, String, ViewMode, int)>[
  ('view.extraLargeIcons', 'Extra large icons', ViewMode.extraLargeIcons, 1),
  ('view.largeIcons', 'Large icons', ViewMode.largeIcons, 2),
  ('view.mediumIcons', 'Medium icons', ViewMode.mediumIcons, 3),
  ('view.smallIcons', 'Small icons', ViewMode.smallIcons, 4),
  ('view.list', 'List', ViewMode.list, 5),
  ('view.details', 'Details', ViewMode.details, 6),
  ('view.tiles', 'Tiles', ViewMode.tiles, 7),
  ('view.content', 'Content', ViewMode.content, 8),
];

const List<(String, String, SortField)> kSortCommands =
    <(String, String, SortField)>[
  ('sort.name', 'Name', SortField.name),
  ('sort.dateModified', 'Date modified', SortField.dateModified),
  ('sort.type', 'Type', SortField.type),
  ('sort.size', 'Size', SortField.size),
  ('sort.dateCreated', 'Date created', SortField.dateCreated),
  ('sort.extension', 'Extension', SortField.extension),
];

List<CommandSpec> viewCommands(ExplorerContext context) {
  final ExplorerModel model = context.model;

  CommandSpec toggle(
          String id, String label, bool Function() get, void Function(bool) set,
          {KeyGesture? shortcut}) =>
      CommandSpec(
        id: id,
        label: label,
        shortcut: shortcut,
        checked: (_) => get(),
        run: (_) {
          set(!get());
          model.notify();
          return get();
        },
      );

  return <CommandSpec>[
    CommandSpec(
        id: 'view.commands',
        label: 'Command palette',
        shortcut: const KeyGesture(logicalKeyP, command: true, shift: true),
        run: (_) => context.host.showCommands()),
    CommandSpec(
        id: 'file.terminal',
        label: 'Open in Terminal',
        when: context.needsFolder,
        run: (_) => context.host.openTerminal(model.currentFolder!)),
    CommandSpec(
        id: 'view.options',
        label: 'Folder Options',
        shortcut: const KeyGesture(logicalKeyComma, command: true),
        run: (_) => context.host.showFolderOptions()),
    for (final (key, label) in <(String, String)>[
      ('compact', 'Compact view'),
      ('itemCheckboxes', 'Item checkboxes'),
      ('showThumbnails', 'Thumbnails'),
      ('showStatusBar', 'Status bar'),
    ])
      toggle('view.$key', label, () => model.preferences[key],
          (v) => model.preferences[key] = v),
    CommandSpec(
        id: 'view.previewPane',
        label: 'Preview pane',
        shortcut: const KeyGesture(logicalKeyP, alt: true),
        checked: (_) => model.preferences['previewPane'],
        run: (_) {
          model.preferences['previewPane'] = !model.preferences['previewPane'];
          if (model.preferences['previewPane']) model.detailsPane = false;
          model.notify();
          return null;
        }),
    for (final (String id, String label, ViewMode mode, int digit)
        in kViewModeCommands)
      CommandSpec(
        id: id,
        label: label,
        // Command+Shift+3/4/5 belong to macOS screenshots. Keep the Windows
        // layout shortcuts on Control on every platform.
        shortcut: KeyGesture(logicalKeyDigit1 + digit - 1,
            control: true, shift: true),
        checked: (_) => model.viewMode == mode,
        run: (_) {
          model.viewMode = mode;
          model.notify();
          return null;
        },
      ),
    for (final (String id, String label, SortField field) in kSortCommands)
      CommandSpec(
        id: id,
        label: label,
        checked: (_) => model.sortField == field,
        run: (_) => model.sortBy(field, ascending: model.ascending),
      ),
    CommandSpec(
      id: 'sort.ascending',
      label: 'Ascending',
      checked: (_) => model.ascending,
      run: (_) => model.sortBy(model.sortField, ascending: true),
    ),
    CommandSpec(
      id: 'sort.descending',
      label: 'Descending',
      checked: (_) => !model.ascending,
      run: (_) => model.sortBy(model.sortField, ascending: false),
    ),
    CommandSpec(
      id: 'view.hiddenItems',
      label: 'Hidden items',
      shortcut: const KeyGesture(logicalKeyH, command: true),
      checked: (_) => model.showHidden,
      run: (_) {
        model.setShowHidden(!model.showHidden);
        return model.showHidden;
      },
    ),
    toggle('view.extensions', 'File name extensions',
        () => model.showExtensions, (bool v) => model.showExtensions = v),
    CommandSpec(
      id: 'view.protectedFiles',
      label: 'Protected operating system files',
      description: 'Shows the files the system keeps for itself - '
          'desktop.ini, .DS_Store.',
      checked: (_) => model.showProtected,
      run: (_) {
        model.setShowProtected(!model.showProtected);
        return model.showProtected;
      },
    ),
    CommandSpec(
        id: 'column.fitAll',
        label: 'Size all columns to fit',
        when: context.needsFolder,
        run: (_) => context.host.fitAllColumns()),
    CommandSpec(
        id: 'column.choose',
        label: 'Choose columns…',
        run: (_) => context.host.showColumnOptions()),
    for (final column in DetailsColumn.values)
      CommandSpec(
        id: 'column.${column.name}',
        label: column.englishLabel,
        description: 'Shows or hides the column in Details.',
        checked: (_) => model.visibleColumns.contains(column),
        when: (_) =>
            column == DetailsColumn.name ? 'the name is always shown' : null,
        run: (_) {
          model.toggleColumn(column);
          return model.visibleColumns.contains(column);
        },
      ),
    toggle('view.navigationPane', 'Navigation pane', () => model.navigationPane,
        (bool v) => model.navigationPane = v,
        shortcut: const KeyGesture(logicalKeyB, command: true)),
    toggle('view.detailsPane', 'Details pane', () => model.detailsPane,
        (bool v) {
      model.detailsPane = v;
      if (v) model.preferences['previewPane'] = false;
    }, shortcut: const KeyGesture(logicalKeyP, alt: true, shift: true)),
  ];
}
