/// The right-hand dock: Properties on top, Objects below.
///
/// CorelDRAW's dockers and Graphite's Properties/Layers pair, stacked rather
/// than behind tabs on a strip: the two things an editor looks at most - what
/// the selection is and where it sits in the document - are both on screen
/// at once. Properties has its own tabs for the three property panels.
library;

import 'package:dart_ui/dart_ui.dart';

import 'editor_model.dart';
import 'metrics.dart';
import 'objects_panel.dart';
import 'panels.dart';

class PluginArea extends StatelessWidget {
  const PluginArea({super.key, required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!model.showDock) return const SizedBox();
    final String tab = model.activePanel ?? PanelIds.transform;
    return SizedBox(
      width: ChromeMetrics.pluginPanelWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(color: theme.surface),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(width: 1, child: ColoredBox(color: theme.borderSubtle)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _DockHeader(
                    title: 'Properties',
                    trailing: <Widget>[
                      for (final id in PanelIds.names.keys)
                        _Tab(
                          icon: switch (id) {
                            PanelIds.transform =>
                              PhosphorIcons.arrowsOutCardinal,
                            PanelIds.align => PhosphorIcons.alignLeft,
                            PanelIds.fillStroke => PhosphorIcons.paintBucket,
                            _ => PhosphorIcons.circle,
                          },
                          tooltip: PanelIds.names[id]!,
                          selected: tab == id,
                          onTap: () => model.showPanelTab(id),
                        ),
                    ],
                  ),
                  Expanded(
                    flex: 3,
                    child: switch (tab) {
                      PanelIds.align => AlignPanel(model: model),
                      PanelIds.fillStroke => FillStrokePanel(model: model),
                      _ => TransformPanel(model: model),
                    },
                  ),
                  SizedBox(height: 1, child: ColoredBox(color: theme.border)),
                  const _DockHeader(title: 'Objects'),
                  Expanded(flex: 2, child: ObjectsPanel(model: model)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DockHeader extends StatelessWidget {
  const _DockHeader({required this.title, this.trailing = const <Widget>[]});

  final String title;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: ChromeMetrics.dockHeaderHeight,
      child: ColoredBox(
        color: theme.surfaceSunken,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.labelLarge,
                color: theme.foreground,
              ),
            ),
            ...trailing,
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final void Function() onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 26,
          height: 22,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected ? theme.surfaceRaised : null,
              radius: theme.cornerRadiusSmall,
            ),
            child: Center(
              child: Icon(
                icon,
                size: 14,
                color: selected ? theme.accent : theme.foregroundSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
