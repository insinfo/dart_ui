/// The editor's workspace: the document in the middle and the panels around
/// it in a [DockingLayout] the user rearranges - dragged to another side,
/// stacked as tabs, resized, or floated out as windows of their own.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/editor_model.dart';
import 'metrics.dart';
import 'objects_panel.dart';
import 'panels.dart';

/// Every panel the workspace can show, by id.
abstract final class WorkspacePanels {
  static const String document = 'document';
  static const String transform = PanelIds.transform;
  static const String align = PanelIds.align;
  static const String fillStroke = PanelIds.fillStroke;
  static const String objects = 'ObjectsPlugin';

  /// The panels a user can open, close and move - not the document.
  static const List<String> all = <String>[
    transform,
    align,
    fillStroke,
    objects,
  ];

  static String nameOf(String id) => switch (id) {
        objects => 'Objects',
        transform => 'Transform',
        align => 'Align',
        fillStroke => 'Fill & Outline',
        _ => PanelIds.names[id] ?? id,
      };

  static IconData iconOf(String id) => switch (id) {
        transform => PhosphorIcons.arrowsOutCardinal,
        align => PhosphorIcons.alignLeft,
        fillStroke => PhosphorIcons.paintBucket,
        objects => PhosphorIcons.stack,
        _ => PhosphorIcons.squaresFour,
      };
}

/// The docking layout, the panels in it and the ones floating in windows.
final class EditorWorkspace {
  EditorWorkspace() {
    reset();
  }

  final DockingLayout layout = DockingLayout();

  /// Panels shown in windows of their own, with where they came from.
  final Map<String, ({ChildWindow? window, DockingPlacement placement})>
      floating =
      <String, ({ChildWindow? window, DockingPlacement placement})>{};

  /// The items, kept across rebuilds so a panel keeps its place and size;
  /// only their widgets are refreshed.
  final Map<String, DockingItem> _items = <String, DockingItem>{};

  DockingItem item(String id) => _items.putIfAbsent(
        id,
        () => id == WorkspacePanels.document
            ? DockingItem(
                id: id,
                name: 'Document',
                widget: const SizedBox(),
                closable: false,
                draggable: false,
                floatable: false,
                maximizable: false,
                showHeader: false,
              )
            : DockingItem(
                id: id,
                name: WorkspacePanels.nameOf(id),
                widget: const SizedBox(),
                leading: Icon(WorkspacePanels.iconOf(id)),
              ),
      );

  /// The default arrangement: the document, and on the right the property
  /// panels as tabs above the Objects panel - VectorCraft's and CorelDRAW's
  /// layout.
  void reset() {
    for (final entry in floating.values.toList()) {
      entry.window?.close();
    }
    floating.clear();
    for (final DockingItem item in _items.values) {
      item.size = null;
    }
    final DockingItem objects = item(WorkspacePanels.objects)..size = 260;
    layout.root = DockingRow(<DockingArea>[
      item(WorkspacePanels.document),
      DockingColumn(
        <DockingArea>[
          DockingTabs(<DockingItem>[
            item(WorkspacePanels.transform),
            item(WorkspacePanels.align),
            item(WorkspacePanels.fillStroke),
          ]),
          objects,
        ],
        size: 300,
      ),
    ]);
  }

  bool isDocked(String id) => layout.findDockingItem(id) != null;

  bool isFloating(String id) => floating.containsKey(id);

  /// Gives every item a widget built from the model as it is now. Called on
  /// every rebuild of the window: an item holds a widget, and a held widget
  /// never rebuilds on its own.
  void refresh(EditorModel model, Widget document) {
    item(WorkspacePanels.document).widget = document;
    for (final String id in WorkspacePanels.all) {
      item(id).widget = panelFor(id, model);
    }
    layout.rebuild();
  }

  static Widget panelFor(String id, EditorModel model) => switch (id) {
        WorkspacePanels.transform => TransformPanel(model: model),
        WorkspacePanels.align => AlignPanel(model: model),
        WorkspacePanels.fillStroke => FillStrokePanel(model: model),
        WorkspacePanels.objects => ObjectsPanel(model: model),
        _ => const SizedBox(),
      };

  /// Brings panel [id] into view: selects its tab, raises its window, or
  /// docks it again where it was last.
  void show(String id) {
    final DockingItem? docked = layout.findDockingItem(id);
    if (docked != null) {
      layout.selectItem(docked);
      return;
    }
    if (floating.containsKey(id)) return;
    final DockingItem panel = item(id);
    final DockingItem? anchor =
        layout.findDockingItem(WorkspacePanels.objects) ??
            layout.findDockingItem(WorkspacePanels.transform);
    layout.restoreItem(
      panel,
      anchor == null
          ? const DockingPlacement(null, DropPosition.right)
          : DockingPlacement(anchor.id, DropPosition.center),
    );
  }

  /// Takes [item] out of the layout into a window near [at] (this window's
  /// coordinates; zero for "wherever the platform puts it"). Closing the
  /// window docks it back where it was.
  Future<void> float(
    DockingItem item, {
    required Offset at,
    required WindowController? window,
    required ThemeData theme,
    required EditorModel model,
  }) async {
    final Object? id = item.id;
    if (id is! String || window == null) return;
    final DockingPlacement placement = layout.placementOf(item);
    layout.removeItem(item: item);
    floating[id] = (window: null, placement: placement);
    final ChildWindow child = await window.openChildWindow(
      title: item.name,
      size: const Size(300, 460),
      position:
          at == Offset.zero ? null : window.toScreen(at - const Offset(40, 14)),
      child:
          _FloatingPanel(model: model, id: id, theme: theme, workspace: this),
      onClosed: () => dock(id),
    );
    final entry = floating[id];
    if (entry == null) {
      // Docked again before the window finished opening.
      child.close();
      return;
    }
    floating[id] = (window: child, placement: entry.placement);
  }

  /// Puts a floating panel back where it came from and closes its window.
  void dock(String id) {
    final entry = floating.remove(id);
    if (entry == null) return;
    entry.window?.close();
    if (!isDocked(id)) layout.restoreItem(item(id), entry.placement);
  }
}

/// A panel in a window of its own, rebuilt whenever the editor changes.
final class _FloatingPanel extends StatefulWidget {
  const _FloatingPanel({
    required this.model,
    required this.id,
    required this.theme,
    required this.workspace,
  });

  final EditorModel model;
  final String id;
  final ThemeData theme;
  final EditorWorkspace workspace;

  @override
  State<_FloatingPanel> createState() => _FloatingPanelState();
}

final class _FloatingPanelState extends State<_FloatingPanel> {
  @override
  void initState() {
    super.initState();
    widget.model.revision.addListener(_changed);
  }

  @override
  void dispose() {
    widget.model.revision.removeListener(_changed);
    super.dispose();
  }

  void _changed(int _) {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = widget.model.theme;
    return Directionality(
      textDirection: TextDirection.leftToRight,
      child: Theme(
        data: theme,
        // Inside the theme, so the drop-down wears the editor's colours.
        child: ComboBoxScope(
            child: ColoredBox(
          color: theme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                height: ChromeMetrics.of(theme).dockHeaderHeight,
                child: ColoredBox(
                  color: theme.surfaceAlternate,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      const SizedBox(width: 8),
                      Icon(WorkspacePanels.iconOf(widget.id)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          WorkspacePanels.nameOf(widget.id),
                          style: theme.textTheme.labelLarge,
                          color: theme.foreground,
                        ),
                      ),
                      Tooltip(
                        message: 'Dock in the main window',
                        child: GestureDetector(
                          behavior: GestureHitTestBehavior.opaque,
                          onTap: () {
                            widget.workspace.dock(widget.id);
                            widget.model.refresh(
                                '${WorkspacePanels.nameOf(widget.id)} docked');
                          },
                          child: SizedBox(
                            width: ChromeMetrics.of(theme).dockHeaderHeight,
                            child: const Center(
                              child: Icon(PhosphorIcons.arrowSquareIn),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: EditorWorkspace.panelFor(widget.id, widget.model),
              ),
            ],
          ),
        )),
      ),
    );
  }
}
