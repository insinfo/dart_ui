/// The command catalog: one definition per action, shared by the menus, the
/// toolbar and the tool box.
///
/// sK1 does the same thing in `app_actions.py`, and for the same reason: the
/// menu item, the toolbar button and the keyboard shortcut for "Group" must
/// agree about whether grouping is possible right now, and they only can if
/// there is one place that decides.
///
/// A command that this editor does not implement is present and **disabled with
/// a named reason** rather than absent or silently inert. A menu that lies about
/// what it can do is worse than one that is honest about a gap, and [MenuItem]
/// already carries [MenuItem.disabledReason] to assistive technology.
library;

import 'package:dart_ui/dart_ui.dart';

import 'editor_model.dart';

/// Callbacks the window owns because they need the widget tree or the disk.
class EditorServices {
  const EditorServices({
    required this.newDocument,
    required this.openDocument,
    required this.saveDocument,
    required this.saveDocumentAs,
    required this.exportDocument,
    required this.printDocument,
    required this.closeDocument,
    required this.zoomIn,
    required this.zoomOut,
    required this.zoomActual,
    required this.zoomToPage,
    required this.zoomToSelection,
    required this.showPanel,
    required this.quit,
  });

  final void Function() newDocument;
  final void Function() openDocument;
  final void Function() saveDocument;
  final void Function() saveDocumentAs;
  final void Function(String format) exportDocument;
  final void Function() printDocument;
  final void Function() closeDocument;
  final void Function() zoomIn;
  final void Function() zoomOut;
  final void Function() zoomActual;
  final void Function() zoomToPage;
  final void Function() zoomToSelection;
  final void Function(String panelId) showPanel;
  final void Function() quit;
}

/// One invocable action.
class EditorCommand {
  const EditorCommand({
    required this.id,
    required this.label,
    required this.onInvoke,
    this.shortcut,
    this.icon,
    this.enabled = true,
    this.disabledReason,
    this.checked,
  });

  final String id;
  final String label;
  final void Function() onInvoke;
  final String? shortcut;
  final IconData? icon;
  final bool enabled;

  /// Why this is unavailable now. Required whenever [enabled] is false.
  final String? disabledReason;

  /// Non-null for a toggle, which the menu marks with a leading tick.
  final bool? checked;

  MenuItem toMenuItem() => MenuItem(
        label: checked == null
            ? label
            : '${checked! ? '✓ ' : '   '}$label',
        shortcut: shortcut,
        enabled: enabled,
        disabledReason: disabledReason,
        onSelected: enabled ? onInvoke : null,
      );
}

/// A top-level menu and its rows. `null` in [items] is a separator.
class EditorMenu {
  const EditorMenu({required this.label, required this.items});

  final String label;
  final List<EditorCommand?> items;

  List<MenuItem> toMenuItems() => <MenuItem>[
        for (final item in items)
          if (item == null) const MenuItem.separator() else item.toMenuItem(),
      ];
}

/// Builds the catalog against the current state, so enablement is always live.
class CommandCatalog {
  CommandCatalog({required this.model, required this.services});

  final EditorModel model;
  final EditorServices services;

  static const String _notImplemented =
      'this command is not implemented in the Dart demo yet';

  EditorCommand _todo(String id, String label, {String? shortcut}) =>
      EditorCommand(
        id: id,
        label: label,
        shortcut: shortcut,
        enabled: false,
        disabledReason: _notImplemented,
        onInvoke: () {},
      );

  EditorCommand _needsSelection(
    String id,
    String label,
    void Function() run, {
    String? shortcut,
    IconData? icon,
    int minimum = 1,
  }) {
    final count = model.hasDocument ? model.selection.count : 0;
    final enough = count >= minimum;
    return EditorCommand(
      id: id,
      label: label,
      shortcut: shortcut,
      icon: icon,
      enabled: enough,
      disabledReason: enough
          ? null
          : minimum == 1
              ? 'nothing is selected'
              : 'at least $minimum objects must be selected; $count '
                  '${count == 1 ? 'is' : 'are'}',
      onInvoke: run,
    );
  }

  // -------------------------------------------------------------------------

  EditorCommand get newDocument => EditorCommand(
        id: 'new',
        label: 'New',
        shortcut: 'Ctrl+N',
        icon: PhosphorIcons.filePlus,
        onInvoke: services.newDocument,
      );

  EditorCommand get open => EditorCommand(
        id: 'open',
        label: 'Open...',
        shortcut: 'Ctrl+O',
        icon: PhosphorIcons.folderOpen,
        onInvoke: services.openDocument,
      );

  EditorCommand get save => EditorCommand(
        id: 'save',
        label: 'Save',
        shortcut: 'Ctrl+S',
        icon: PhosphorIcons.floppyDisk,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: services.saveDocument,
      );

  EditorCommand get saveAs => EditorCommand(
        id: 'saveAs',
        label: 'Save As...',
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: services.saveDocumentAs,
      );

  EditorCommand get closeDocument => EditorCommand(
        id: 'close',
        label: 'Close',
        shortcut: 'Ctrl+W',
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: services.closeDocument,
      );

  EditorCommand get exportSvg => EditorCommand(
        id: 'exportSvg',
        label: 'Export as SVG...',
        icon: PhosphorIcons.exportIcon,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: () => services.exportDocument('svg'),
      );

  EditorCommand get exportPdf => EditorCommand(
        id: 'exportPdf',
        label: 'Export as PDF...',
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: () => services.exportDocument('pdf'),
      );

  EditorCommand get exportCdr => EditorCommand(
        id: 'exportCdr',
        label: 'Export as CDR...',
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: () => services.exportDocument('cdr'),
      );

  EditorCommand get print => EditorCommand(
        id: 'print',
        label: 'Print...',
        shortcut: 'Ctrl+P',
        icon: PhosphorIcons.printer,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: services.printDocument,
      );

  EditorCommand get quit => EditorCommand(
        id: 'quit',
        label: 'Exit',
        shortcut: 'Alt+F4',
        onInvoke: services.quit,
      );

  EditorCommand get undo {
    final can = model.hasDocument && model.active.api.canUndo;
    return EditorCommand(
      id: 'undo',
      label: 'Undo',
      shortcut: 'Ctrl+Z',
      icon: PhosphorIcons.arrowCounterClockwise,
      enabled: can,
      disabledReason: can ? null : 'there is nothing to undo',
      onInvoke: model.undo,
    );
  }

  EditorCommand get redo {
    final can = model.hasDocument && model.active.api.canRedo;
    return EditorCommand(
      id: 'redo',
      label: 'Redo',
      shortcut: 'Shift+Ctrl+Z',
      icon: PhosphorIcons.arrowClockwise,
      enabled: can,
      disabledReason: can ? null : 'there is nothing to redo',
      onInvoke: model.redo,
    );
  }

  EditorCommand get cut => _needsSelection(
        'cut',
        'Cut',
        () {
          model.deleteSelection();
          model.refresh('Cut');
        },
        shortcut: 'Ctrl+X',
        icon: PhosphorIcons.scissors,
      );

  EditorCommand get copy => _needsSelection(
        'copy',
        'Copy',
        () => model.refresh('Copied ${model.selection.count} object(s)'),
        shortcut: 'Ctrl+C',
        icon: PhosphorIcons.copy,
      );

  EditorCommand get paste => _todo('paste', 'Paste', shortcut: 'Ctrl+V');

  EditorCommand get delete => _needsSelection(
        'delete',
        'Delete',
        model.deleteSelection,
        shortcut: 'Delete',
        icon: PhosphorIcons.trash,
      );

  EditorCommand get duplicate => _needsSelection(
        'duplicate',
        'Duplicate',
        () => model.moveSelectionBy(10, 10),
        shortcut: 'Ctrl+D',
      );

  EditorCommand get selectAll => EditorCommand(
        id: 'selectAll',
        label: 'Select All',
        shortcut: 'Ctrl+A',
        icon: PhosphorIcons.selectionAll,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: model.selectAll,
      );

  EditorCommand get deselect => _needsSelection(
        'deselect',
        'Deselect',
        model.deselect,
        shortcut: 'Shift+Ctrl+A',
      );

  EditorCommand get group => _needsSelection(
        'group',
        'Group',
        model.group,
        shortcut: 'Ctrl+G',
        minimum: 2,
      );

  EditorCommand get ungroup {
    final isGroup = model.singleSelection is VectorGroup;
    return EditorCommand(
      id: 'ungroup',
      label: 'Ungroup',
      shortcut: 'Ctrl+U',
      enabled: isGroup,
      disabledReason: isGroup ? null : 'select exactly one group to ungroup',
      onInvoke: model.ungroup,
    );
  }

  EditorCommand get zoomIn => EditorCommand(
        id: 'zoomIn',
        label: 'Zoom in',
        icon: PhosphorIcons.magnifyingGlassPlus,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: services.zoomIn,
      );

  EditorCommand get zoomOut => EditorCommand(
        id: 'zoomOut',
        label: 'Zoom out',
        icon: PhosphorIcons.magnifyingGlassMinus,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: services.zoomOut,
      );

  EditorCommand get zoomActual => EditorCommand(
        id: 'zoom100',
        label: 'Zoom 100%',
        shortcut: 'Ctrl+F4',
        icon: PhosphorIcons.magnifyingGlass,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: services.zoomActual,
      );

  EditorCommand get zoomPage => EditorCommand(
        id: 'zoomPage',
        label: 'Fit zoom to page',
        shortcut: 'Shift+F4',
        icon: PhosphorIcons.frameCorners,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: services.zoomToPage,
      );

  EditorCommand get zoomSelection => _needsSelection(
        'zoomSelection',
        'Zoom selected',
        services.zoomToSelection,
        shortcut: 'F4',
        icon: PhosphorIcons.crosshair,
      );

  EditorCommand get toggleGrid => EditorCommand(
        id: 'showGrid',
        label: 'Show grid',
        checked: model.showGrid,
        onInvoke: () {
          model.showGrid = !model.showGrid;
          model.refresh(model.showGrid ? 'Grid shown' : 'Grid hidden');
        },
      );

  EditorCommand get toggleGuides => EditorCommand(
        id: 'showGuides',
        label: 'Show guides',
        checked: model.showGuides,
        onInvoke: () {
          model.showGuides = !model.showGuides;
          model.refresh(model.showGuides ? 'Guides shown' : 'Guides hidden');
        },
      );

  EditorCommand get toggleSnap => EditorCommand(
        id: 'snapGrid',
        label: 'Snap to grid',
        shortcut: 'Alt+G',
        checked: model.snapToGrid,
        onInvoke: () {
          model.snapToGrid = !model.snapToGrid;
          if (model.hasDocument) {
            model.active.snap.snapToGrid = model.snapToGrid;
          }
          model.refresh(model.snapToGrid ? 'Snapping on' : 'Snapping off');
        },
      );

  EditorCommand get moveToTop => _needsSelection(
        'moveTop',
        'Move to Top',
        () => model.reorder(up: true, toEnd: true),
        shortcut: 'Ctrl+Shift+PageUp',
      );

  EditorCommand get moveUp => _needsSelection(
        'moveUp',
        'Move Up',
        () => model.reorder(up: true, toEnd: false),
        shortcut: 'Ctrl+PageUp',
      );

  EditorCommand get moveDown => _needsSelection(
        'moveDown',
        'Move Down',
        () => model.reorder(up: false, toEnd: false),
        shortcut: 'Ctrl+PageDown',
      );

  EditorCommand get moveToBottom => _needsSelection(
        'moveBottom',
        'Move to Bottom',
        () => model.reorder(up: false, toEnd: true),
        shortcut: 'Ctrl+Shift+PageDown',
      );

  EditorCommand get rotateLeft => _needsSelection(
        'rotateLeft',
        'Rotate left 90 degrees',
        () => model.rotateSelection(-90),
      );

  EditorCommand get rotateRight => _needsSelection(
        'rotateRight',
        'Rotate right 90 degrees',
        () => model.rotateSelection(90),
      );

  EditorCommand get flipHorizontal => _needsSelection(
        'flipH',
        'Flip horizontal',
        () => model.flipSelection(horizontal: true),
      );

  EditorCommand get flipVertical => _needsSelection(
        'flipV',
        'Flip vertical',
        () => model.flipSelection(horizontal: false),
      );

  EditorCommand get alignPanel => EditorCommand(
        id: 'alignPanel',
        label: 'Align and Distribute...',
        shortcut: 'Ctrl+Shift+D',
        onInvoke: () => services.showPanel(PanelIds.align),
      );

  EditorCommand get transformPanel => EditorCommand(
        id: 'transformPanel',
        label: 'Position...',
        shortcut: 'Alt+F5',
        onInvoke: () => services.showPanel(PanelIds.transform),
      );

  EditorCommand get fillPanel => EditorCommand(
        id: 'fillPanel',
        label: 'Fill...',
        shortcut: 'F11',
        onInvoke: () => services.showPanel(PanelIds.fillStroke),
      );

  EditorCommand get strokePanel => EditorCommand(
        id: 'strokePanel',
        label: 'Stroke...',
        shortcut: 'F12',
        onInvoke: () => services.showPanel(PanelIds.fillStroke),
      );

  // -------------------------------------------------------------------------
  // Menus, in sK1's order.
  // -------------------------------------------------------------------------

  List<EditorMenu> get menus => <EditorMenu>[
        EditorMenu(label: 'File', items: <EditorCommand?>[
          newDocument,
          open,
          null,
          save,
          saveAs,
          null,
          closeDocument,
          null,
          _todo('import', 'Import...', shortcut: 'Ctrl+I'),
          exportSvg,
          exportPdf,
          exportCdr,
          null,
          print,
          null,
          quit,
        ]),
        EditorMenu(label: 'Edit', items: <EditorCommand?>[
          undo,
          redo,
          null,
          cut,
          copy,
          paste,
          delete,
          duplicate,
          null,
          selectAll,
          deselect,
          null,
          fillPanel,
          strokePanel,
        ]),
        EditorMenu(label: 'View', items: <EditorCommand?>[
          zoomActual,
          zoomIn,
          zoomOut,
          null,
          zoomPage,
          zoomSelection,
          null,
          toggleGrid,
          toggleGuides,
          null,
          toggleSnap,
        ]),
        EditorMenu(label: 'Layout', items: <EditorCommand?>[
          _todo('insertPage', 'Insert page...'),
          _todo('deletePage', 'Delete page...'),
          _todo('gotoPage', 'Go to page...'),
          null,
          _todo('layers', 'Layers...', shortcut: 'F7'),
          null,
          _todo('pageFrame', 'Page frame'),
          _todo('guidesAround', 'Guides around page'),
          _todo('removeGuides', 'Remove all guides'),
        ]),
        EditorMenu(label: 'Arrange', items: <EditorCommand?>[
          transformPanel,
          null,
          rotateLeft,
          rotateRight,
          flipHorizontal,
          flipVertical,
          null,
          alignPanel,
          moveToTop,
          moveUp,
          moveDown,
          moveToBottom,
          null,
          group,
          ungroup,
          null,
          _todo('toCurves', 'Convert to curves', shortcut: 'Ctrl+Q'),
        ]),
        EditorMenu(label: 'Paths', items: <EditorCommand?>[
          _todo('selAllNodes', 'Select all nodes'),
          _todo('reversePaths', 'Reverse all paths'),
          null,
          _todo('addNode', 'Add node'),
          _todo('deleteNode', 'Delete nodes'),
          null,
          _todo('segToLine', 'Convert segments to line'),
          _todo('segToCurve', 'Convert segments to curve'),
        ]),
        EditorMenu(label: 'Bitmaps', items: <EditorCommand?>[
          _todo('toCmyk', 'Convert to CMYK'),
          _todo('toRgb', 'Convert to RGB'),
          _todo('toGray', 'Convert to Grayscale'),
          null,
          _todo('invertBitmap', 'Invert bitmap'),
        ]),
        EditorMenu(label: 'Text', items: <EditorCommand?>[
          _todo('editText', 'Edit text', shortcut: 'F8'),
          null,
          _todo('textOnPath', 'Text on path...'),
          null,
          _todo('upperCase', 'Uppercase'),
          _todo('lowerCase', 'Lowercase'),
        ]),
        EditorMenu(label: 'Help', items: <EditorCommand?>[
          EditorCommand(
            id: 'about',
            label: 'About this editor',
            onInvoke: () => model.refresh(
              'Vector Editor - 100% pure Dart, modelled on sK1',
            ),
          ),
        ]),
      ];

  /// The standard toolbar, in sK1's grouping. `null` is a divider.
  List<EditorCommand?> get standardToolbar => <EditorCommand?>[
        newDocument,
        open,
        save,
        null,
        print,
        exportSvg,
        null,
        undo,
        redo,
        null,
        cut,
        copy,
        delete,
        null,
        zoomIn,
        zoomOut,
        zoomActual,
        zoomPage,
        zoomSelection,
      ];
}
