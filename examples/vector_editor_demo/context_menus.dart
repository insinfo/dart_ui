/// The right-click menus: on the canvas, in the Objects panel and on a
/// document tab - CorelDRAW's order, built from the same commands as the
/// menu bar, so an item is enabled, checked and labelled the same in both.
library;

import 'package:dart_ui/dart_ui.dart';

import 'commands.dart';
import 'editor_model.dart';

class EditorContextMenus {
  EditorContextMenus(this.catalog);

  final CommandCatalog catalog;

  EditorModel get model => catalog.model;

  /// The canvas: the selection's menu, or the page's when nothing is
  /// selected.
  List<PlatformMenuEntry> canvas() => model.hasSelection ? selection() : page();

  /// What can be done to the selected objects.
  List<PlatformMenuEntry> selection() => EditorMenu.entries(<EditorCommand?>[
        catalog.undo,
        null,
        catalog.cut,
        catalog.copy,
        catalog.paste,
        catalog.delete,
        catalog.duplicate,
        null,
        catalog.toCurves,
        EditorCommand(
          id: 'order',
          label: 'Order',
          icon: PhosphorIcons.stack,
          onInvoke: () {},
          children: <EditorCommand?>[
            catalog.moveToTop,
            catalog.moveUp,
            catalog.moveDown,
            catalog.moveToBottom,
          ],
        ),
        EditorCommand(
          id: 'transform',
          label: 'Transform',
          icon: PhosphorIcons.arrowsOutCardinal,
          onInvoke: () {},
          children: <EditorCommand?>[
            catalog.rotateLeft,
            catalog.rotateRight,
            null,
            catalog.flipHorizontal,
            catalog.flipVertical,
          ],
        ),
        if (catalog.group.enabled) catalog.group,
        if (catalog.ungroup.enabled) catalog.ungroup,
        null,
        catalog.alignPanel,
        catalog.fillPanel,
        catalog.strokePanel,
        catalog.transformPanel,
      ]);

  /// Empty canvas: the page and the view.
  List<PlatformMenuEntry> page() => EditorMenu.entries(<EditorCommand?>[
        catalog.undo,
        catalog.redo,
        null,
        catalog.paste,
        catalog.selectAll,
        null,
        EditorCommand(
          id: 'zoom',
          label: 'Zoom',
          icon: PhosphorIcons.magnifyingGlass,
          onInvoke: () {},
          children: <EditorCommand?>[
            catalog.zoomIn,
            catalog.zoomOut,
            catalog.zoomActual,
            null,
            catalog.zoomPage,
          ],
        ),
        null,
        catalog.toggleGrid,
        catalog.toggleGuides,
        catalog.toggleSnap,
      ]);

  /// A layer row of the Objects panel.
  List<PlatformMenuEntry> layer(VectorLayer layer) {
    final layers = model.active.layers;
    final index = layers.indexOf(layer);
    return EditorMenu.entries(<EditorCommand?>[
      EditorCommand(
        id: 'layer.activate',
        label: 'Make active layer',
        checked: identical(model.active.layer, layer),
        onInvoke: () => model.activateLayer(layer),
      ),
      EditorCommand(
        id: 'layer.new',
        label: 'New layer',
        icon: PhosphorIcons.plus,
        onInvoke: model.addLayer,
      ),
      null,
      EditorCommand(
        id: 'layer.visible',
        label: 'Visible',
        checked: layer.isVisible,
        onInvoke: () => model.setLayerVisible(layer, !layer.isVisible),
      ),
      EditorCommand(
        id: 'layer.locked',
        label: 'Locked',
        checked: !layer.isEditable,
        onInvoke: () => model.setLayerLocked(layer, layer.isEditable),
      ),
      null,
      EditorCommand(
        id: 'layer.up',
        label: 'Raise layer',
        icon: PhosphorIcons.arrowUp,
        enabled: index < layers.length - 1,
        disabledReason: 'already the top layer',
        onInvoke: () => model.moveLayer(layer, up: true),
      ),
      EditorCommand(
        id: 'layer.down',
        label: 'Lower layer',
        icon: PhosphorIcons.arrowDown,
        enabled: index > 0,
        disabledReason: 'already the bottom layer',
        onInvoke: () => model.moveLayer(layer, up: false),
      ),
      null,
      EditorCommand(
        id: 'layer.delete',
        label: 'Delete layer',
        icon: PhosphorIcons.trash,
        enabled: layers.length > 1,
        disabledReason: 'the last layer cannot be deleted',
        onInvoke: () => model.deleteLayer(layer),
      ),
    ]);
  }

  /// A document tab, once it has been made the active one.
  List<PlatformMenuEntry> documentTab() => EditorMenu.entries(<EditorCommand?>[
        catalog.save,
        catalog.saveAs,
        null,
        catalog.closeDocument,
      ]);
}
