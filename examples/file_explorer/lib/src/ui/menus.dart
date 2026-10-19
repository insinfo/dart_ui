/// The explorer's menus, as data: the right-click menus of an item and of
/// the background, and the drop-downs of the command bar.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/explorer_commands.dart';
import '../engine/strings.dart';

const MenuSeparator _ = MenuSeparator();

/// New ▾ - Folder, Text Document.
const List<MenuSpecEntry> kNewMenu = <MenuSpecEntry>[
  CommandItem('file.newFolder'),
  _,
  CommandItem('file.newTextDocument'),
];

/// Sort ▾ - the columns, then the direction.
final List<MenuSpecEntry> kSortMenu = <MenuSpecEntry>[
  for (final (String id, String _, Object _) in kSortCommands) CommandItem(id),
  _,
  const CommandItem('sort.ascending'),
  const CommandItem('sort.descending'),
];

/// View ▾ - the layouts, then Show.
List<MenuSpecEntry> viewMenu(ExplorerStrings strings) => <MenuSpecEntry>[
      for (final (String id, String _, Object _, int _) in kViewModeCommands)
        CommandItem(id),
      _,
      const CommandItem('view.compact'),
      SubmenuSpec(strings.menu('Show'), const <MenuSpecEntry>[
        CommandItem('view.navigationPane'),
        CommandItem('view.detailsPane'),
        CommandItem('view.previewPane'),
        CommandItem('view.itemCheckboxes'),
        CommandItem('view.showThumbnails'),
        CommandItem('view.showStatusBar'),
        CommandItem('view.extensions'),
        CommandItem('view.hiddenItems'),
        CommandItem('view.protectedFiles'),
      ]),
    ];

/// Settings, at the foot of the sidebar: what Windows keeps in Folder
/// Options - what is shown, and how.
List<MenuSpecEntry> settingsMenu(ExplorerStrings strings) => <MenuSpecEntry>[
      const CommandItem('view.options'),
      _,
      const CommandItem('view.hiddenItems'),
      const CommandItem('view.extensions'),
      const CommandItem('view.protectedFiles'),
      _,
      const CommandItem('view.navigationPane'),
      const CommandItem('view.detailsPane'),
    ];

/// The Details header's menu: the columns to show.
const List<MenuSpecEntry> kColumnsMenu = <MenuSpecEntry>[
  CommandItem('column.name'),
  CommandItem('column.dateModified'),
  CommandItem('column.type'),
  CommandItem('column.size'),
  CommandItem('column.dateCreated'),
];

/// ··· - what does not fit on the bar.
const List<MenuSpecEntry> kMoreMenu = <MenuSpecEntry>[
  CommandItem('file.undo'),
  CommandItem('file.redo'),
  _,
  CommandItem('select.all'),
  CommandItem('select.none'),
  CommandItem('select.invert'),
  _,
  CommandItem('file.copyPath'),
  CommandItem('file.copyFolderPath'),
  CommandItem('file.pin'),
  _,
  CommandItem('file.properties'),
  _,
  CommandItem('view.options'),
  CommandItem('view.commands'),
  CommandItem('file.terminal'),
];

/// The menu of the selected items.
const List<MenuSpecEntry> kItemMenu = <MenuSpecEntry>[
  CommandItem('file.open'),
  CommandItem('file.openInNewTab'),
  _,
  CommandItem('file.cut'),
  CommandItem('file.copy'),
  CommandItem('file.rename'),
  CommandItem('file.delete'),
  _,
  CommandItem('file.copyPath'),
  CommandItem('file.pin'),
  CommandItem('file.favorite'),
  CommandItem('file.compress'),
  CommandItem('file.extract'),
  CommandItem('file.reveal'),
  _,
  CommandItem('file.properties'),
];

/// The menu of the empty space of a folder.
List<MenuSpecEntry> backgroundMenu(ExplorerStrings strings) => <MenuSpecEntry>[
      SubmenuSpec(strings.menu('View'), viewMenu(strings)),
      SubmenuSpec(strings.menu('Sort by'), kSortMenu),
      const CommandItem('nav.refresh'),
      _,
      const CommandItem('file.undo'),
      const CommandItem('file.redo'),
      const CommandItem('file.paste'),
      SubmenuSpec(strings.menu('New'), kNewMenu),
      _,
      const CommandItem('select.all'),
      _,
      const CommandItem('file.terminal'),
      const CommandItem('view.options'),
    ];
