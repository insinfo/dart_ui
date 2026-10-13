/// The icon of each command - Fluent System Icons, the ones Windows 11's
/// File Explorer uses. Presentation, so it lives with the window.
library;

import 'package:dart_ui/dart_ui.dart';

const Map<String, IconData> _icons = <String, IconData>{
  'nav.back': FluentIcons.arrowLeft,
  'nav.forward': FluentIcons.arrowRight,
  'nav.up': FluentIcons.arrowUp,
  'nav.refresh': FluentIcons.arrowClockwise,
  'nav.home': FluentIcons.home,
  'file.open': FluentIcons.open,
  'file.openInNewTab': FluentIcons.tabAdd,
  'file.newFolder': FluentIcons.folderAdd,
  'file.newTextDocument': FluentIcons.documentAdd,
  'file.cut': FluentIcons.cut,
  'file.copy': FluentIcons.copy,
  'file.paste': FluentIcons.clipboardPaste,
  'file.rename': FluentIcons.rename,
  'file.delete': FluentIcons.delete,
  'file.copyPath': FluentIcons.link,
  'file.pin': FluentIcons.pin,
  'file.reveal': FluentIcons.folderOpen,
  'file.properties': FluentIcons.wrench,
  'select.all': FluentIcons.selectAllOn,
  'select.none': FluentIcons.selectAllOff,
  'select.invert': FluentIcons.arrowSwap,
  'view.details': FluentIcons.textBulletListLtr,
  'view.list': FluentIcons.list,
  'view.tiles': FluentIcons.grid,
  'view.smallIcons': FluentIcons.appsList,
  'view.mediumIcons': FluentIcons.gridDots,
  'view.largeIcons': FluentIcons.squareMultiple,
  'view.extraLargeIcons': FluentIcons.square,
  'view.detailsPane': FluentIcons.panelRight,
  'view.navigationPane': FluentIcons.panelLeft,
  'view.hiddenItems': FluentIcons.eyeOff,
  'view.extensions': FluentIcons.documentText,
  'sort.ascending': FluentIcons.arrowSortUp,
  'sort.descending': FluentIcons.arrowSortDown,
  'tab.new': FluentIcons.tabAdd,
};

/// [id]'s icon, or null.
IconData? commandIcon(String id) => _icons[id];
