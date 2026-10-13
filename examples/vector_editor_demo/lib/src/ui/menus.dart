/// Every menu of the editor, as command ids: the menu bar, the right-click
/// menus and the standard toolbar.
///
/// A row names a command and, when it takes any, its parameters; its label,
/// shortcut, enabled and checked state come from the command, its icon from
/// [commandIcon]. A
/// row whose command is not registered yet still shows, disabled - the gap
/// is visible, and `tool/parity.dart` counts it.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/editor_model.dart';
import 'command_icons.dart';
import 'editor_ui.dart';
import 'workspace.dart';

final class EditorMenus {
  EditorMenus(this.registry, this.ui)
      : builder = MenuBuilder(registry, iconOf: commandIcon);

  final CommandRegistry registry;
  final EditorUi ui;
  final MenuBuilder builder;

  EditorModel get model => ui.model;

  static const MenuSeparator _ = MenuSeparator();

  /// The menu bar, in CorelDRAW's order of menus.
  List<SubmenuSpec> get bar => <SubmenuSpec>[
        const SubmenuSpec('File', <MenuSpecEntry>[
          CommandItem('file.new'),
          CommandItem('file.open'),
          _,
          CommandItem('file.save'),
          CommandItem('file.saveAs'),
          _,
          CommandItem('file.close'),
          _,
          CommandItem('file.import', label: 'Import...'),
          CommandItem('file.export',
              params: <String, Object?>{'format': 'svg'},
              label: 'Export as SVG...'),
          CommandItem('file.export',
              params: <String, Object?>{'format': 'pdf'},
              label: 'Export as PDF...'),
          CommandItem('file.export',
              params: <String, Object?>{'format': 'cdr'},
              label: 'Export as CDR...'),
          _,
          CommandItem('file.print'),
          _,
          CommandItem('app.quit'),
        ]),
        const SubmenuSpec('Edit', <MenuSpecEntry>[
          CommandItem('edit.undo'),
          CommandItem('edit.redo'),
          _,
          CommandItem('edit.cut'),
          CommandItem('edit.copy'),
          CommandItem('edit.paste'),
          CommandItem('edit.delete'),
          CommandItem('edit.duplicate'),
          _,
          CommandItem('edit.selectAll'),
          CommandItem('edit.deselect'),
          _,
          CommandItem('panel.fillStroke', label: 'Fill...', checkable: false),
          CommandItem('panel.fillStroke',
              label: 'Outline...', checkable: false),
        ]),
        SubmenuSpec('View', <MenuSpecEntry>[
          const CommandItem('view.zoom100'),
          const CommandItem('view.zoomIn'),
          const CommandItem('view.zoomOut'),
          _,
          const CommandItem('view.zoomPage'),
          const CommandItem('view.zoomSelection'),
          _,
          const CommandItem('view.grid'),
          const CommandItem('view.guides'),
          _,
          const CommandItem('view.snapGrid'),
          _,
          for (final EditorThemeMode mode in EditorThemeMode.values)
            CommandItem('theme.${mode.name}'),
          if (ui.nativeMenuAvailable) ...const <MenuSpecEntry>[
            _,
            CommandItem('view.systemMenuBar'),
          ],
        ]),
        const SubmenuSpec('Layout', <MenuSpecEntry>[
          CommandItem('page.insert', label: 'Insert page...'),
          CommandItem('page.delete', label: 'Delete page...'),
          CommandItem('page.goTo', label: 'Go to page...'),
          _,
          CommandItem('page.frame', label: 'Page frame'),
          CommandItem('guides.aroundPage', label: 'Guides around page'),
          CommandItem('guides.removeAll', label: 'Remove all guides'),
        ]),
        const SubmenuSpec('Arrange', <MenuSpecEntry>[
          CommandItem('panel.transform',
              label: 'Position...', checkable: false),
          _,
          CommandItem('object.rotate',
              params: <String, Object?>{'degrees': -90},
              label: 'Rotate left 90 degrees'),
          CommandItem('object.rotate',
              params: <String, Object?>{'degrees': 90},
              label: 'Rotate right 90 degrees'),
          CommandItem('object.flip',
              params: <String, Object?>{'direction': 'horizontal'},
              label: 'Flip horizontal'),
          CommandItem('object.flip',
              params: <String, Object?>{'direction': 'vertical'},
              label: 'Flip vertical'),
          _,
          SubmenuSpec('Align and Distribute', _alignAndDistribute),
          SubmenuSpec('Order', _order),
          _,
          CommandItem('object.group'),
          CommandItem('object.ungroup'),
          _,
          CommandItem('object.combine'),
          CommandItem('object.breakApart'),
          _,
          CommandItem('object.toCurves'),
        ]),
        const SubmenuSpec('Paths', <MenuSpecEntry>[
          CommandItem('tool.shape', checkable: false),
          CommandItem('path.selectAllNodes'),
          _,
          CommandItem('path.addNode'),
          CommandItem('path.deleteNodes'),
          _,
          CommandItem('path.toLine'),
          CommandItem('path.toCurve'),
          _,
          CommandItem('path.cusp'),
          CommandItem('path.smooth'),
          CommandItem('path.symmetrical'),
          _,
          CommandItem('path.breakNode'),
          CommandItem('path.joinNodes'),
          CommandItem('path.close'),
          CommandItem('path.reverse'),
        ]),
        const SubmenuSpec('Bitmaps', <MenuSpecEntry>[
          CommandItem('bitmap.toCmyk', label: 'Convert to CMYK'),
          CommandItem('bitmap.toRgb', label: 'Convert to RGB'),
          CommandItem('bitmap.toGray', label: 'Convert to Grayscale'),
          _,
          CommandItem('bitmap.invert', label: 'Invert bitmap'),
        ]),
        const SubmenuSpec('Text', <MenuSpecEntry>[
          CommandItem('text.edit', label: 'Edit text'),
          _,
          CommandItem('text.onPath', label: 'Text on path...'),
          _,
          CommandItem('text.upperCase', label: 'Uppercase'),
          CommandItem('text.lowerCase', label: 'Lowercase'),
        ]),
        SubmenuSpec('Window', <MenuSpecEntry>[
          for (final String id in WorkspacePanels.all)
            CommandItem(WorkspacePanels.commandOf(id)),
          _,
          const CommandItem('window.resetWorkspace'),
        ]),
        const SubmenuSpec('Help', <MenuSpecEntry>[
          CommandItem('help.about'),
        ]),
      ];

  static const List<MenuSpecEntry> _alignAndDistribute = <MenuSpecEntry>[
    CommandItem('object.alignLeft'),
    CommandItem('object.alignRight'),
    CommandItem('object.alignTop'),
    CommandItem('object.alignBottom'),
    CommandItem('object.alignCentersVertically'),
    CommandItem('object.alignCentersHorizontally'),
    MenuSeparator(),
    CommandItem('object.centerToPage'),
    MenuSeparator(),
    CommandItem('object.distribute',
        params: <String, Object?>{'direction': 'horizontal'},
        label: 'Distribute horizontally'),
    CommandItem('object.distribute',
        params: <String, Object?>{'direction': 'vertical'},
        label: 'Distribute vertically'),
    MenuSeparator(),
    CommandItem('panel.align',
        label: 'Align and Distribute...', checkable: false),
  ];

  static const List<MenuSpecEntry> _order = <MenuSpecEntry>[
    CommandItem('object.toFront'),
    CommandItem('object.forward'),
    CommandItem('object.backward'),
    CommandItem('object.toBack'),
  ];

  /// The canvas: the selection's menu, or the page's when nothing is
  /// selected.
  List<MenuSpecEntry> get canvas => model.hasSelection ? selection : page;

  /// What can be done to the selected objects, CorelDRAW's order.
  List<MenuSpecEntry> get selection => <MenuSpecEntry>[
        const CommandItem('edit.undo'),
        _,
        const CommandItem('edit.cut'),
        const CommandItem('edit.copy'),
        const CommandItem('edit.paste'),
        const CommandItem('edit.delete'),
        const CommandItem('edit.duplicate'),
        _,
        const CommandItem('object.toCurves'),
        const SubmenuSpec('Order', _order, id: 'menu.order'),
        const SubmenuSpec(
          'Transform',
          <MenuSpecEntry>[
            CommandItem('object.rotate',
                params: <String, Object?>{'degrees': -90},
                label: 'Rotate left 90 degrees'),
            CommandItem('object.rotate',
                params: <String, Object?>{'degrees': 90},
                label: 'Rotate right 90 degrees'),
            MenuSeparator(),
            CommandItem('object.flip',
                params: <String, Object?>{'direction': 'horizontal'},
                label: 'Flip horizontal'),
            CommandItem('object.flip',
                params: <String, Object?>{'direction': 'vertical'},
                label: 'Flip vertical'),
          ],
          id: 'menu.transform',
        ),
        if (registry.isEnabled('object.group'))
          const CommandItem('object.group'),
        if (registry.isEnabled('object.ungroup'))
          const CommandItem('object.ungroup'),
        if (registry.isEnabled('object.combine'))
          const CommandItem('object.combine'),
        if (registry.isEnabled('object.breakApart'))
          const CommandItem('object.breakApart'),
        _,
        const CommandItem('panel.align',
            label: 'Align and Distribute...', checkable: false),
        const CommandItem('panel.fillStroke',
            label: 'Fill and Outline...', checkable: false),
        const CommandItem('panel.transform',
            label: 'Position...', checkable: false),
      ];

  /// Empty canvas: the page and the view.
  List<MenuSpecEntry> get page => const <MenuSpecEntry>[
        CommandItem('edit.undo'),
        CommandItem('edit.redo'),
        _,
        CommandItem('edit.paste'),
        CommandItem('edit.selectAll'),
        _,
        SubmenuSpec(
          'Zoom',
          <MenuSpecEntry>[
            CommandItem('view.zoomIn'),
            CommandItem('view.zoomOut'),
            CommandItem('view.zoom100'),
            MenuSeparator(),
            CommandItem('view.zoomPage'),
          ],
          id: 'menu.zoom',
        ),
        _,
        CommandItem('view.grid'),
        CommandItem('view.guides'),
        CommandItem('view.snapGrid'),
      ];

  /// Layer [index] of the Objects panel.
  List<MenuSpecEntry> layer(int index) {
    final Map<String, Object?> at = <String, Object?>{'index': index};
    return <MenuSpecEntry>[
      CommandItem('layer.activate', params: at),
      const CommandItem('layer.new'),
      _,
      CommandItem('layer.visible', params: at),
      CommandItem('layer.lock', params: at),
      _,
      CommandItem('layer.raise', params: at),
      CommandItem('layer.lower', params: at),
      _,
      CommandItem('layer.delete', params: at),
    ];
  }

  /// A document tab, once it has been made the active one.
  List<MenuSpecEntry> get documentTab => const <MenuSpecEntry>[
        CommandItem('file.save'),
        CommandItem('file.saveAs'),
        _,
        CommandItem('file.close'),
      ];

  /// The standard toolbar, in sK1's grouping.
  static const List<MenuSpecEntry> standardToolbar = <MenuSpecEntry>[
    CommandItem('file.new'),
    CommandItem('file.open'),
    CommandItem('file.save'),
    _,
    CommandItem('file.print'),
    CommandItem('file.export',
        params: <String, Object?>{'format': 'svg'}, label: 'Export as SVG'),
    _,
    CommandItem('edit.undo'),
    CommandItem('edit.redo'),
    _,
    CommandItem('edit.cut'),
    CommandItem('edit.copy'),
    CommandItem('edit.delete'),
    _,
    CommandItem('view.zoomIn'),
    CommandItem('view.zoomOut'),
    CommandItem('view.zoom100'),
    CommandItem('view.zoomPage'),
    CommandItem('view.zoomSelection'),
  ];

  /// [entries] as framework menu widgets, for a right-click menu.
  List<Widget> widgets(List<MenuSpecEntry> entries) =>
      PlatformMenuBar.menuWidgets(builder.entries(entries));

  /// The bar as [PlatformMenu]s, with the controllers a tool opens them by.
  List<PlatformMenu> barMenus() =>
      builder.bar(bar, controllers: ui.menuControllers);
}
