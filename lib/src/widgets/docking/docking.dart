/// Desktop docking control adapted from docking_flutter's public model.
library;

import '../../layout/box_constraints.dart';
import '../../layout/edge_insets.dart';
import '../../layout/render_flex.dart';
import '../basic.dart';
import '../icon.dart';
import '../icon_button.dart';
import '../proxy.dart';
import '../split_view.dart';
import '../tabs.dart';
import '../theme.dart';
import '../widget.dart';
import 'docking_layout.dart';
import 'docking_theme.dart';

typedef OnItemSelection = void Function(DockingItem item);
typedef OnItemClose = void Function(DockingItem item);
typedef ItemCloseInterceptor = bool Function(DockingItem item);

/// Displays a mutable [DockingLayout] as tabs and resizable split panes.
final class Docking extends StatefulWidget {
  const Docking({
    super.key,
    this.layout,
    this.onItemSelection,
    this.onItemClose,
    this.itemCloseInterceptor,
    this.maximizableItem = true,
    this.maximizableTab = true,
    this.maximizableTabsArea = true,
    this.draggable = true,
  });

  final DockingLayout? layout;
  final OnItemSelection? onItemSelection;
  final OnItemClose? onItemClose;
  final ItemCloseInterceptor? itemCloseInterceptor;
  final bool maximizableItem;
  final bool maximizableTab;
  final bool maximizableTabsArea;

  /// Reserved for pointer drag-and-drop docking. Programmatic move/add is
  /// available today through [DockingLayout].
  final bool draggable;

  @override
  State<Docking> createState() => _DockingState();
}

final class _DockingState extends State<Docking> {
  @override
  void initState() {
    super.initState();
    widget.layout?.addListener(_onLayoutChanged);
  }

  @override
  void didUpdateWidget(Docking oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.layout, widget.layout)) {
      oldWidget.layout?.removeListener(_onLayoutChanged);
      widget.layout?.addListener(_onLayoutChanged);
    }
  }

  @override
  void dispose() {
    widget.layout?.removeListener(_onLayoutChanged);
    super.dispose();
  }

  void _onLayoutChanged(int _) {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout;
    if (layout == null || layout.root == null) return const SizedBox();
    final theme = DockingTheme.of(context);
    final visible = layout.maximizedArea ?? layout.root!;
    return ColoredBox(
      color: theme.backgroundColor,
      child: _buildArea(visible, theme),
    );
  }

  Widget _buildArea(DockingArea area, DockingThemeData theme) {
    if (area is DockingItem) return _buildItem(area, theme, showHeader: true);
    if (area is DockingTabs) return _buildTabs(area, theme);
    if (area is DockingRow) {
      return _buildSplit(area.children, 0, Axis.horizontal, theme);
    }
    if (area is DockingColumn) {
      return _buildSplit(area.children, 0, Axis.vertical, theme);
    }
    throw StateError('Unsupported docking area ${area.runtimeType}');
  }

  Widget _buildSplit(
    List<DockingArea> children,
    int index,
    Axis axis,
    DockingThemeData theme,
  ) {
    final firstArea = children[index];
    if (index == children.length - 1) return _buildArea(firstArea, theme);
    final firstWeight = firstArea.weight ?? 1;
    var remainingWeight = 0.0;
    for (var i = index + 1; i < children.length; i++) {
      remainingWeight += children[i].weight ?? 1;
    }
    final fraction =
        (firstWeight / (firstWeight + remainingWeight)).clamp(0.05, 0.95);
    return SplitView(
      axis: axis,
      initialFraction: fraction,
      minFirst: firstArea.minimalSize ?? 40,
      minSecond: 40,
      dividerThickness: theme.dividerThickness,
      first: _buildArea(firstArea, theme),
      second: _buildSplit(children, index + 1, axis, theme),
    );
  }

  Widget _buildTabs(DockingTabs area, DockingThemeData theme) {
    if (area.childrenCount == 1) {
      return _buildItem(area.childAt(0), theme, showHeader: true);
    }
    return Tabs(
      tabs: <TabItem>[
        for (var index = 0; index < area.childrenCount; index++)
          TabItem(
            id: area.childAt(index).id ?? area.childAt(index),
            label: area.childAt(index).name ?? 'Documento ${index + 1}',
            content: _buildTabbedItem(area, area.childAt(index), theme),
          ),
      ],
      selectedIndex: area.selectedIndex,
      onSelected: (int index) {
        final item = area.childAt(index);
        widget.layout!.selectItem(item);
        widget.onItemSelection?.call(item);
      },
    );
  }

  Widget _buildTabbedItem(
    DockingTabs area,
    DockingItem item,
    DockingThemeData theme,
  ) {
    final DockingLayout layout = widget.layout!;
    final bool canMaximizeItem =
        widget.maximizableTab && (item.maximizable ?? true);
    final bool canMaximizeArea =
        widget.maximizableTabsArea && (area.maximizable ?? true);
    if (!canMaximizeItem && !canMaximizeArea && !item.closable) {
      return _buildItem(item, theme, showHeader: false);
    }
    final bool itemMaximized = identical(layout.maximizedArea, item);
    final bool areaMaximized = identical(layout.maximizedArea, area);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: 32,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.headerColor,
              border: BoxBorder(color: theme.borderColor, width: 1),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: <Widget>[
                  const Spacer(),
                  if (canMaximizeItem)
                    IconButton(
                      icon: Icon(
                        itemMaximized ? Icons.fullscreenExit : Icons.fullscreen,
                      ),
                      iconSize: 16,
                      constraints: BoxConstraints(minWidth: 30, minHeight: 28),
                      padding: const EdgeInsets.all(6),
                      tooltip: itemMaximized
                          ? 'Restaurar aba'
                          : 'Maximizar esta aba',
                      onPressed: itemMaximized
                          ? layout.restore
                          : () => layout.maximizeDockingItem(item),
                    ),
                  if (canMaximizeArea)
                    IconButton(
                      icon: Icon(
                        areaMaximized ? Icons.fullscreenExit : Icons.fitScreen,
                      ),
                      iconSize: 16,
                      constraints: BoxConstraints(minWidth: 30, minHeight: 28),
                      padding: const EdgeInsets.all(6),
                      tooltip: areaMaximized
                          ? 'Restaurar grupo de abas'
                          : 'Maximizar grupo de abas',
                      onPressed: areaMaximized
                          ? layout.restore
                          : () => layout.maximizeDockingTabs(area),
                    ),
                  if (item.closable)
                    IconButton(
                      icon: const Icon(Icons.close),
                      iconSize: 16,
                      constraints: BoxConstraints(minWidth: 30, minHeight: 28),
                      padding: const EdgeInsets.all(6),
                      tooltip: 'Fechar aba',
                      onPressed: () => _close(item),
                    ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: _buildItem(item, theme, showHeader: false)),
      ],
    );
  }

  Widget _buildItem(
    DockingItem item,
    DockingThemeData theme, {
    required bool showHeader,
  }) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: theme.backgroundColor,
          border: BoxBorder(color: theme.borderColor, width: 1),
          radius: theme.cornerRadius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (showHeader) _buildItemHeader(item, theme),
            Expanded(child: item.widget),
          ],
        ),
      );

  Widget _buildItemHeader(DockingItem item, DockingThemeData theme) {
    final layout = widget.layout!;
    final maximized = identical(layout.maximizedArea, item);
    final canMaximize = widget.maximizableItem && (item.maximizable ?? true);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.headerColor,
        border: BoxBorder(color: theme.borderColor, width: 1),
        radius: theme.cornerRadius,
      ),
      child: SizedBox(
        height: theme.headerHeight,
        child: Padding(
          padding: const EdgeInsets.only(left: 10, right: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (item.leading != null) ...<Widget>[
                item.leading!,
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  item.name ?? 'Painel',
                  style: TextStyle(
                    color: theme.foregroundColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (canMaximize)
                IconButton(
                  icon: Icon(
                    maximized ? Icons.fullscreenExit : Icons.fullscreen,
                  ),
                  iconSize: 17,
                  tooltip: maximized ? 'Restaurar painel' : 'Maximizar painel',
                  padding: const EdgeInsets.all(6),
                  onPressed: maximized
                      ? layout.restore
                      : () => layout.maximizeDockingItem(item),
                ),
              if (item.closable)
                IconButton(
                  icon: const Icon(Icons.close),
                  iconSize: 17,
                  tooltip: 'Fechar painel',
                  padding: const EdgeInsets.all(6),
                  onPressed: () => _close(item),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _close(DockingItem item) {
    if (!(widget.itemCloseInterceptor?.call(item) ?? true)) return;
    widget.layout!.removeItem(item: item);
    widget.onItemClose?.call(item);
  }
}
