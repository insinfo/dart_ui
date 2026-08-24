/// The right-hand plugin area - sK1's `plgarea.py` + `plgtabs.py`.
///
/// The body is a [Docking] layout so the open panels can be split, tabbed and
/// maximized like any other docked pane. The vertical strip on the far right is
/// [CollapsedTabStrip]: clicking a tab opens that panel, clicking the open one
/// collapses the body entirely and leaves only the strip - which is how sK1
/// keeps two panels reachable in 24 px.
library;

import 'package:dart_ui/dart_ui.dart';

import 'editor_model.dart';
import 'metrics.dart';
import 'panels.dart';

/// The panel body and its collapsed tab strip.
class PluginArea extends StatefulWidget {
  const PluginArea({super.key, required this.model});

  final EditorModel model;

  @override
  State<PluginArea> createState() => _PluginAreaState();
}

class _PluginAreaState extends State<PluginArea> {
  DockingLayout? _layout;
  String? _layoutFor;

  /// The docking layout for the open panel, rebuilt only when it changes.
  ///
  /// Rebuilding a [DockingLayout] every frame would reset the user's splitter
  /// positions and drop the maximized state on each repaint.
  DockingLayout? _layoutForActive(String? id) {
    if (id == null) return null;
    final existing = _layout;
    if (_layoutFor == id && existing != null) {
      // The layout persists; its *content* does not. A docking item holds the
      // widget it was built with, so without this the panel would keep showing
      // the state it had when the tab was first opened.
      final root = existing.root;
      if (root is DockingItem) root.widget = _panelFor(id);
      return existing;
    }
    _layoutFor = id;
    _layout = DockingLayout(
      root: DockingItem(
        id: id,
        name: PanelIds.names[id] ?? id,
        closable: true,
        maximizable: false,
        widget: _panelFor(id),
      ),
    );
    return _layout;
  }

  Widget _panelFor(String id) => switch (id) {
        PanelIds.transform => TransformPanel(model: widget.model),
        PanelIds.align => AlignPanel(model: widget.model),
        PanelIds.fillStroke => FillStrokePanel(model: widget.model),
        _ => const SizedBox(),
      };

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final active = model.activePanel;
    final layout = _layoutForActive(active);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (layout != null)
          SizedBox(
            width: ChromeMetrics.pluginPanelWidth,
            child: Docking(
              layout: layout,
              maximizableItem: false,
              onItemClose: (DockingItem item) {
                // The docking header's close button and the strip's close
                // button have to mean the same thing, so both go through the
                // model rather than only removing the docked pane.
                final id = item.id;
                if (id is String) model.closePanel(id);
              },
            ),
          ),
        CollapsedTabStrip(
          width: ChromeMetrics.collapsedTabStripWidth,
          selectedId: active,
          tabs: <CollapsedTab>[
            for (final id in model.openPanels)
              CollapsedTab(
                id: id,
                label: PanelIds.names[id] ?? id,
                icon: switch (id) {
                  PanelIds.transform => PhosphorIcons.arrowsOutCardinal,
                  PanelIds.align => PhosphorIcons.alignLeft,
                  PanelIds.fillStroke => PhosphorIcons.paintBucket,
                  _ => PhosphorIcons.circle,
                },
              ),
          ],
          onSelected: (Object id) => model.togglePanel(id as String),
          onClosed: (Object id) => model.closePanel(id as String),
        ),
      ],
    );
  }
}
