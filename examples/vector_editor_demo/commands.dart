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
/// what it can do is worse than one that is honest about a gap; the reason
/// is what a disabled toolbar button's tooltip says.
library;

import 'package:dart_ui/dart_ui.dart';

import 'editor_model.dart';
import 'workspace.dart';

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
    this.alsoShortcuts = const <KeyGesture>[],
    this.icon,
    this.enabled = true,
    this.disabledReason,
    this.checked,
    this.children,
  });

  final String id;
  final String label;
  final void Function() onInvoke;
  final KeyGesture? shortcut;

  /// Keys that also run this command without being shown in the menu.
  final List<KeyGesture> alsoShortcuts;
  final IconData? icon;
  final bool enabled;

  /// Why this is unavailable now. Required whenever [enabled] is false.
  final String? disabledReason;

  /// Non-null for a toggle, which the menu marks with a leading tick.
  final bool? checked;

  /// A submenu's commands; `null` entries are separators.
  final List<EditorCommand?>? children;

  /// This command as an entry of the menu bar - in the window or in the
  /// system's bar: an icon or a check mark, the label, and the shortcut. A
  /// submenu when it has [children].
  PlatformMenuEntry toPlatformEntry() {
    final List<EditorCommand?>? sub = children;
    if (sub != null) {
      return PlatformMenu(
        label: label,
        icon: icon,
        children: EditorMenu.entries(sub),
      );
    }
    return PlatformMenuItem(
      label: label,
      icon: icon,
      checked: checked,
      shortcut: shortcut,
      onSelected: enabled ? onInvoke : null,
    );
  }
}

/// A top-level menu and its rows. `null` in [items] is a separator.
class EditorMenu {
  const EditorMenu({required this.label, required this.items});

  final String label;
  final List<EditorCommand?> items;

  PlatformMenu toPlatformMenu({MenuController? controller}) => PlatformMenu(
        label: label,
        controller: controller,
        children: entries(items),
      );

  /// [items] as menu entries; `null` is a divider.
  static List<PlatformMenuEntry> entries(List<EditorCommand?> items) =>
      <PlatformMenuEntry>[
        for (final EditorCommand? item in items)
          if (item == null)
            const PlatformMenuDivider()
          else
            item.toPlatformEntry(),
      ];
}

/// Builds the catalog against the current state, so enablement is always live.
class CommandCatalog {
  CommandCatalog({required this.model, required this.services});

  final EditorModel model;
  final EditorServices services;

  static bool get _mac => platformEditingConvention == EditingConvention.mac;

  static const String _notImplemented =
      'this command is not implemented in the Dart demo yet';

  EditorCommand _todo(String id, String label, {KeyGesture? shortcut}) =>
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
    KeyGesture? shortcut,
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
        shortcut: const KeyGesture(logicalKeyN, command: true),
        icon: PhosphorIcons.filePlus,
        onInvoke: services.newDocument,
      );

  EditorCommand get open => EditorCommand(
        id: 'open',
        label: 'Open...',
        shortcut: const KeyGesture(logicalKeyO, command: true),
        icon: PhosphorIcons.folderOpen,
        onInvoke: services.openDocument,
      );

  EditorCommand get save => EditorCommand(
        id: 'save',
        label: 'Save',
        shortcut: const KeyGesture(logicalKeyS, command: true),
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
        shortcut: const KeyGesture(logicalKeyW, command: true),
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
        shortcut: const KeyGesture(logicalKeyP, command: true),
        icon: PhosphorIcons.printer,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: services.printDocument,
      );

  EditorCommand get quit => EditorCommand(
        id: 'quit',
        label: 'Exit',
        // Each platform's own: Alt+F4 on a PC, Cmd+Q on a Mac.
        shortcut: _mac
            ? const KeyGesture(logicalKeyQ, command: true)
            : const KeyGesture(logicalKeyF4, alt: true),
        onInvoke: services.quit,
      );

  EditorCommand get undo {
    final can = model.hasDocument && model.active.api.canUndo;
    return EditorCommand(
      id: 'undo',
      label: 'Undo',
      shortcut: const KeyGesture(logicalKeyZ, command: true),
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
      shortcut: const KeyGesture(logicalKeyZ, command: true, shift: true),
      icon: PhosphorIcons.arrowClockwise,
      enabled: can,
      disabledReason: can ? null : 'there is nothing to redo',
      onInvoke: model.redo,
    );
  }

  EditorCommand get cut => _needsSelection(
        'cut',
        'Cut',
        model.cutSelection,
        shortcut: const KeyGesture(logicalKeyX, command: true),
        icon: PhosphorIcons.scissors,
      );

  EditorCommand get copy => _needsSelection(
        'copy',
        'Copy',
        model.copySelection,
        shortcut: const KeyGesture(logicalKeyC, command: true),
        icon: PhosphorIcons.copy,
      );

  EditorCommand get paste => EditorCommand(
        id: 'paste',
        label: 'Paste',
        shortcut: const KeyGesture(logicalKeyV, command: true),
        icon: PhosphorIcons.clipboardText,
        enabled: model.canPaste,
        disabledReason: model.canPaste ? null : 'nothing has been copied',
        onInvoke: model.paste,
      );

  EditorCommand get delete {
    final command = _needsSelection(
      'delete',
      'Delete',
      model.deleteSelection,
      // The Mac's "delete" key is Backspace; its forward delete also works.
      shortcut: _mac
          ? const KeyGesture(logicalKeyBackspace)
          : const KeyGesture(logicalKeyDelete),
      icon: PhosphorIcons.trash,
    );
    return EditorCommand(
      id: command.id,
      label: command.label,
      onInvoke: command.onInvoke,
      shortcut: command.shortcut,
      alsoShortcuts: _mac
          ? const <KeyGesture>[KeyGesture(logicalKeyDelete)]
          : const <KeyGesture>[],
      icon: command.icon,
      enabled: command.enabled,
      disabledReason: command.disabledReason,
    );
  }

  EditorCommand get duplicate => _needsSelection(
        'duplicate',
        'Duplicate',
        model.duplicateSelection,
        shortcut: const KeyGesture(logicalKeyD, command: true),
      );

  EditorCommand get selectAll => EditorCommand(
        id: 'selectAll',
        label: 'Select All',
        shortcut: const KeyGesture(logicalKeyA, command: true),
        icon: PhosphorIcons.selectionAll,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: model.selectAll,
      );

  EditorCommand get deselect => _needsSelection(
        'deselect',
        'Deselect',
        model.deselect,
        shortcut: const KeyGesture(logicalKeyA, command: true, shift: true),
      );

  EditorCommand get group => _needsSelection(
        'group',
        'Group',
        model.group,
        shortcut: const KeyGesture(logicalKeyG, command: true),
        minimum: 2,
      );

  EditorCommand get ungroup {
    final isGroup = model.singleSelection is VectorGroup;
    return EditorCommand(
      id: 'ungroup',
      label: 'Ungroup',
      shortcut: const KeyGesture(logicalKeyU, command: true),
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
        shortcut: const KeyGesture(logicalKeyF4, command: true),
        icon: PhosphorIcons.magnifyingGlass,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: services.zoomActual,
      );

  EditorCommand get zoomPage => EditorCommand(
        id: 'zoomPage',
        label: 'Fit zoom to page',
        shortcut: const KeyGesture(logicalKeyF4, shift: true),
        icon: PhosphorIcons.frameCorners,
        enabled: model.hasDocument,
        disabledReason: model.hasDocument ? null : 'no document is open',
        onInvoke: services.zoomToPage,
      );

  EditorCommand get zoomSelection => _needsSelection(
        'zoomSelection',
        'Zoom selected',
        services.zoomToSelection,
        shortcut: const KeyGesture(logicalKeyF4),
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

  /// View > Theme: dark, light, or whatever the system uses.
  List<EditorCommand> get themeCommands => <EditorCommand>[
        for (final EditorThemeMode mode in EditorThemeMode.values)
          EditorCommand(
            id: 'theme.${mode.name}',
            label: 'Theme: ${mode.label}',
            checked: model.themeMode == mode,
            onInvoke: () => model.setThemeMode(mode),
          ),
      ];

  /// Window: every panel - shown docked, floating, or brought back - and
  /// the default arrangement.
  List<EditorCommand?> get windowCommands => <EditorCommand?>[
        for (final String id in WorkspacePanels.all)
          EditorCommand(
            id: 'panel.$id',
            label: model.workspace.isFloating(id)
                ? '${WorkspacePanels.nameOf(id)} (dock again)'
                : WorkspacePanels.nameOf(id),
            icon: WorkspacePanels.iconOf(id),
            checked:
                model.workspace.isDocked(id) || model.workspace.isFloating(id),
            shortcut: id == WorkspacePanels.objects
                ? const KeyGesture(logicalKeyF7, command: true)
                : null,
            onInvoke: () {
              if (model.workspace.isFloating(id)) {
                model.workspace.dock(id);
              } else {
                model.workspace.show(id);
              }
              model.refresh('${WorkspacePanels.nameOf(id)} shown');
            },
          ),
        null,
        EditorCommand(
          id: 'resetWorkspace',
          label: 'Reset workspace',
          onInvoke: () {
            model.workspace.reset();
            model.refresh('Workspace reset');
          },
        ),
      ];

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
        shortcut: const KeyGesture(logicalKeyG, alt: true),
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
        shortcut:
            const KeyGesture(logicalKeyPageUp, command: true, shift: true),
      );

  EditorCommand get moveUp => _needsSelection(
        'moveUp',
        'Move Up',
        () => model.reorder(up: true, toEnd: false),
        shortcut: const KeyGesture(logicalKeyPageUp, command: true),
      );

  EditorCommand get moveDown => _needsSelection(
        'moveDown',
        'Move Down',
        () => model.reorder(up: false, toEnd: false),
        shortcut: const KeyGesture(logicalKeyPageDown, command: true),
      );

  EditorCommand get moveToBottom => _needsSelection(
        'moveBottom',
        'Move to Bottom',
        () => model.reorder(up: false, toEnd: true),
        shortcut:
            const KeyGesture(logicalKeyPageDown, command: true, shift: true),
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
        shortcut: const KeyGesture(logicalKeyD, command: true, shift: true),
        onInvoke: () => services.showPanel(PanelIds.align),
      );

  EditorCommand get transformPanel => EditorCommand(
        id: 'transformPanel',
        label: 'Position...',
        shortcut: const KeyGesture(logicalKeyF5, alt: true),
        onInvoke: () => services.showPanel(PanelIds.transform),
      );

  EditorCommand get fillPanel => EditorCommand(
        id: 'fillPanel',
        label: 'Fill...',
        shortcut: const KeyGesture(logicalKeyF11),
        onInvoke: () => services.showPanel(PanelIds.fillStroke),
      );

  EditorCommand get strokePanel => EditorCommand(
        id: 'strokePanel',
        label: 'Stroke...',
        shortcut: const KeyGesture(logicalKeyF12),
        onInvoke: () => services.showPanel(PanelIds.fillStroke),
      );

  // -------------------------------------------------------------------------
  // Menus, in sK1's order.
  // -------------------------------------------------------------------------

  /// Every shortcut the menus advertise, bound to what the menu item does -
  /// so a chord works exactly when its menu item is enabled.
  Map<KeyGesture, void Function()?> keyBindings(List<EditorMenu> menus) {
    final Map<KeyGesture, void Function()?> bindings =
        <KeyGesture, void Function()?>{};
    for (final EditorMenu menu in menus) {
      for (final EditorCommand? command in menu.items) {
        if (command == null) continue;
        for (final KeyGesture gesture in <KeyGesture>[
          if (command.shortcut != null) command.shortcut!,
          ...command.alsoShortcuts,
        ]) {
          // Two items may share a chord (F8 is a tool and a todo); the one
          // that can run wins.
          if (bindings[gesture] != null) continue;
          bindings[gesture] = command.enabled ? command.onInvoke : null;
        }
      }
    }
    return bindings;
  }

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
          _todo('import', 'Import...',
              shortcut: const KeyGesture(logicalKeyI, command: true)),
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
          null,
          ...themeCommands,
          if (model.nativeMenuAvailable) ...<EditorCommand?>[
            null,
            EditorCommand(
              id: 'systemMenuBar',
              label: 'Use the macOS menu bar',
              checked: model.nativeMenuBar,
              onInvoke: () => model.setNativeMenuBar(!model.nativeMenuBar),
            ),
          ],
        ]),
        EditorMenu(label: 'Layout', items: <EditorCommand?>[
          _todo('insertPage', 'Insert page...'),
          _todo('deletePage', 'Delete page...'),
          _todo('gotoPage', 'Go to page...'),
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
          // sK1's Ctrl+Q; on a Mac that chord is Quit.
          _todo('toCurves', 'Convert to curves',
              shortcut:
                  _mac ? null : const KeyGesture(logicalKeyQ, command: true)),
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
          _todo('editText', 'Edit text',
              shortcut: const KeyGesture(logicalKeyF8)),
          null,
          _todo('textOnPath', 'Text on path...'),
          null,
          _todo('upperCase', 'Uppercase'),
          _todo('lowerCase', 'Lowercase'),
        ]),
        EditorMenu(label: 'Window', items: windowCommands),
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
