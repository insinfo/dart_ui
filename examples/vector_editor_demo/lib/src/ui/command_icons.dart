/// The icon each command shows in a menu or a toolbar.
///
/// Presentation, so it lives with the user interface and not with the
/// commands: the engine names what a command does; this window decides how
/// it looks. Another interface over the same engine draws its own.
library;

import 'package:dart_ui/dart_ui.dart';

import 'workspace.dart';

const Map<String, IconData> _icons = <String, IconData>{
  'file.new': PhosphorIcons.filePlus,
  'file.open': PhosphorIcons.folderOpen,
  'file.save': PhosphorIcons.floppyDisk,
  'file.export': PhosphorIcons.exportIcon,
  'file.print': PhosphorIcons.printer,
  'edit.undo': PhosphorIcons.arrowCounterClockwise,
  'edit.redo': PhosphorIcons.arrowClockwise,
  'edit.cut': PhosphorIcons.scissors,
  'edit.copy': PhosphorIcons.copy,
  'edit.paste': PhosphorIcons.clipboardText,
  'edit.delete': PhosphorIcons.trash,
  'edit.selectAll': PhosphorIcons.selectionAll,
  'object.toCurves': PhosphorIcons.bezierCurve,
  'object.group': PhosphorIcons.stack,
  'object.ungroup': PhosphorIcons.circlesThree,
  'object.combine': PhosphorIcons.circlesFour,
  'object.breakApart': PhosphorIcons.circleDashed,
  'object.weld': PhosphorIcons.unite,
  'object.trim': PhosphorIcons.subtract,
  'object.intersect': PhosphorIcons.intersect,
  'tool.shape': PhosphorIcons.bezierCurve,
  'path.selectAllNodes': PhosphorIcons.selectionAll,
  'path.addNode': PhosphorIcons.plusCircle,
  'path.deleteNodes': PhosphorIcons.minusCircle,
  'path.joinNodes': PhosphorIcons.linkSimple,
  'path.breakNode': PhosphorIcons.linkSimpleBreak,
  'path.toLine': PhosphorIcons.lineSegment,
  'path.toCurve': PhosphorIcons.waveSine,
  'path.cusp': PhosphorIcons.polygon,
  'path.smooth': PhosphorIcons.bezierCurve,
  'path.symmetrical': PhosphorIcons.vectorTwo,
  'path.reverse': PhosphorIcons.arrowsLeftRight,
  'path.close': PhosphorIcons.circleDashed,
  'view.zoomIn': PhosphorIcons.magnifyingGlassPlus,
  'view.zoomOut': PhosphorIcons.magnifyingGlassMinus,
  'view.zoom100': PhosphorIcons.magnifyingGlass,
  'view.zoomPage': PhosphorIcons.frameCorners,
  'view.zoomSelection': PhosphorIcons.crosshair,
  'layer.new': PhosphorIcons.plus,
  'layer.raise': PhosphorIcons.arrowUp,
  'layer.lower': PhosphorIcons.arrowDown,
  'layer.delete': PhosphorIcons.trash,
  // Submenus, by their SubmenuSpec id.
  'menu.order': PhosphorIcons.stack,
  'menu.transform': PhosphorIcons.arrowsOutCardinal,
  'menu.zoom': PhosphorIcons.magnifyingGlass,
};

/// The icon for command or submenu [id], or null for none.
IconData? commandIcon(String id) {
  final IconData? icon = _icons[id];
  if (icon != null) return icon;
  for (final String panel in WorkspacePanels.all) {
    if (WorkspacePanels.commandOf(panel) == id) {
      return WorkspacePanels.iconOf(panel);
    }
  }
  return null;
}
