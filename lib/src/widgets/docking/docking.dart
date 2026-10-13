/// Desktop docking: panels in splits and tabs that the user rearranges by
/// dragging, resizes by their dividers and can float out as windows.
library;

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../graphics/display_list.dart';
import '../../layout/box_constraints.dart';
import '../../layout/edge_insets.dart';
import '../../layout/render_flex.dart';
import '../../layout/render_proxy_box.dart';
import '../../layout/render_stack.dart' show StackFit;
import '../basic.dart';
import '../element.dart';
import '../gesture_detector.dart';
import '../icon.dart';
import '../layout_builder.dart';
import '../phosphor_icons.dart';
import '../proxy.dart';
import '../split_view.dart';
import '../theme.dart';
import '../tooltip.dart';
import '../widget.dart';
import 'docking_layout.dart';
import 'docking_theme.dart';

typedef OnItemSelection = void Function(DockingItem item);
typedef OnItemClose = void Function(DockingItem item);
typedef ItemCloseInterceptor = bool Function(DockingItem item);

/// Asked to show [item] - already taken out of the layout - in a window of
/// its own, near [globalPosition] (in this window's coordinates).
typedef OnItemFloat = void Function(DockingItem item, Offset globalPosition);

/// Displays a mutable [DockingLayout] as tabs and resizable split panes.
///
/// * **Drag** a panel's title bar or tab: drop zones light up over every
///   area (its left, right, top, bottom or middle - the middle makes tabs)
///   and along the edges of the whole layout.
/// * **Dividers** resize; an area keeps its size in pixels from then on, and
///   the area that has none (an editor's document) takes what is left.
/// * **Float**: with [onItemFloat], a panel dropped outside the layout - or
///   sent by its float button - leaves it, and the callback puts it in a
///   window. [DockingLayout.placementOf] and [DockingLayout.restoreItem]
///   bring it back to where it was.
final class Docking extends StatefulWidget {
  const Docking({
    super.key,
    this.layout,
    this.onItemSelection,
    this.onItemClose,
    this.itemCloseInterceptor,
    this.onItemFloat,
    this.maximizableItem = true,
    this.maximizableTab = true,
    this.maximizableTabsArea = true,
    this.draggable = true,
  });

  final DockingLayout? layout;
  final OnItemSelection? onItemSelection;
  final OnItemClose? onItemClose;
  final ItemCloseInterceptor? itemCloseInterceptor;
  final OnItemFloat? onItemFloat;
  final bool maximizableItem;
  final bool maximizableTab;
  final bool maximizableTabsArea;

  /// Whether panels can be dragged to another place at all.
  final bool draggable;

  @override
  State<Docking> createState() => _DockingState();
}

/// Where a drag would land.
final class _DropTarget {
  const _DropTarget.area(this.area, this.position, this.preview)
      : root = false,
        float = false;
  const _DropTarget.root(this.position, this.preview)
      : area = null,
        root = true,
        float = false;
  const _DropTarget.float()
      : area = null,
        position = DropPosition.center,
        preview = null,
        root = false,
        float = true;

  final DockingArea? area;
  final DropPosition position;
  final Rect? preview;
  final bool root;
  final bool float;
}

final class _DragSession {
  _DragSession(this.item, this.start);

  final DockingItem item;
  final Offset start;
  Offset pointer = Offset.zero;
  _DropTarget? target;
}

const Object _rootKey = Object();

final class _DockingState extends State<Docking> {
  /// Every area's box in window coordinates, as last painted.
  final Map<Object, Rect> _rects = <Object, Rect>{};

  _DragSession? _drag;

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
    final Rect? root = _rects[_rootKey];
    final _DropTarget? target = _drag?.target;
    final Rect? preview = target?.preview;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _Measured(
          onRect: (Rect rect) => _rects[_rootKey] = rect,
          child: ColoredBox(
            color: theme.backgroundColor,
            child: _buildArea(visible, theme),
          ),
        ),
        if (preview != null && root != null)
          Positioned(
            left: preview.left - root.left,
            top: preview.top - root.top,
            width: preview.width,
            height: preview.height,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.accentColor.withAlpha(0x40),
                  border: BoxBorder(color: theme.accentColor, width: 2),
                  radius: theme.cornerRadius,
                ),
              ),
            ),
          ),
        if (_drag != null && root != null && _drag!.pointer != Offset.zero)
          Positioned(
            left: _drag!.pointer.dx - root.left + 12,
            top: _drag!.pointer.dy - root.top + 12,
            child: IgnorePointer(
              child: _DragLabel(
                text: target?.float ?? false
                    ? '${_drag!.item.name ?? 'Panel'} - new window'
                    : _drag!.item.name ?? 'Panel',
                theme: theme,
              ),
            ),
          ),
      ],
    );
  }

  // --- areas ---------------------------------------------------------------

  Widget _measured(DockingArea area, Widget child) => _Measured(
        onRect: (Rect rect) => _rects[area] = rect,
        child: child,
      );

  Widget _buildArea(DockingArea area, DockingThemeData theme) {
    if (area is DockingItem) {
      return _measured(
          area, _buildItem(area, theme, showHeader: area.showHeader));
    }
    if (area is DockingTabs) return _measured(area, _buildTabs(area, theme));
    if (area is DockingRow) {
      return _buildSplit(area.children, 0, Axis.horizontal, theme);
    }
    if (area is DockingColumn) {
      return _buildSplit(area.children, 0, Axis.vertical, theme);
    }
    throw StateError('Unsupported docking area ${area.runtimeType}');
  }

  /// A chain of [SplitView]s: [children] at [index] against the rest.
  ///
  /// An area with a [DockingArea.size] keeps it in pixels; one without (the
  /// document of an editor) takes what is left, so growing the window grows
  /// the document and not the panels around it.
  Widget _buildSplit(
    List<DockingArea> children,
    int index,
    Axis axis,
    DockingThemeData theme,
  ) {
    final DockingArea first = children[index];
    if (index == children.length - 1) return _buildArea(first, theme);
    final List<DockingArea> rest = children.sublist(index + 1);
    final DockingArea? lone = rest.length == 1 ? rest.single : null;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double total = axis == Axis.horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        final double divider = theme.dividerThickness;
        double? extent = first.size;
        if (extent == null && lone?.size != null && total.isFinite) {
          extent = total - divider - lone!.size!;
        }
        var restWeight = 0.0;
        for (final DockingArea area in rest) {
          restWeight += area.weight ?? 1;
        }
        final double firstWeight = first.weight ?? 1;
        return SplitView(
          axis: axis,
          firstExtent: extent == null || !total.isFinite
              ? null
              : extent.clamp(0.0, total),
          initialFraction:
              (firstWeight / (firstWeight + restWeight)).clamp(0.05, 0.95),
          minFirst: first.minimalSize ?? 60,
          minSecond: lone?.minimalSize ?? 60,
          dividerThickness: divider,
          onResized: (double resized) {
            if (first.size == null && lone != null && lone.size != null) {
              lone.size = total - divider - resized;
            } else {
              first.size = resized;
            }
            setState(() {});
          },
          first: _buildArea(first, theme),
          second: _buildSplit(children, index + 1, axis, theme),
        );
      },
    );
  }

  Widget _buildTabs(DockingTabs area, DockingThemeData theme) {
    final DockingItem selected =
        area.childAt(area.selectedIndex.clamp(0, area.childrenCount - 1));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.backgroundColor,
        border: BoxBorder(color: theme.borderColor, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: theme.headerHeight,
            child: ColoredBox(
              color: theme.headerColor,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var index = 0; index < area.childrenCount; index++)
                    _draggable(
                      area.childAt(index),
                      _TabChip(
                        item: area.childAt(index),
                        selected: identical(area.childAt(index), selected),
                        theme: theme,
                        onTap: () {
                          final item = area.childAt(index);
                          widget.layout!.selectItem(item);
                          widget.onItemSelection?.call(item);
                        },
                      ),
                    ),
                  const Spacer(),
                  ..._buttons(selected, area, theme),
                ],
              ),
            ),
          ),
          Expanded(child: selected.widget),
        ],
      ),
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
          border:
              showHeader ? BoxBorder(color: theme.borderColor, width: 1) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (showHeader) _buildItemHeader(item, theme),
            Expanded(child: item.widget),
          ],
        ),
      );

  Widget _buildItemHeader(DockingItem item, DockingThemeData theme) => SizedBox(
        height: theme.headerHeight,
        child: ColoredBox(
          color: theme.headerColor,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: _draggable(
                  item,
                  _TabChip(
                    item: item,
                    selected: true,
                    theme: theme,
                    onTap: () => widget.onItemSelection?.call(item),
                  ),
                  expand: true,
                ),
              ),
              ..._buttons(item, null, theme),
            ],
          ),
        ),
      );

  List<Widget> _buttons(
    DockingItem item,
    DockingTabs? tabs,
    DockingThemeData theme,
  ) {
    final DockingLayout layout = widget.layout!;
    final bool maximized = identical(layout.maximizedArea, item) ||
        (tabs != null && identical(layout.maximizedArea, tabs));
    final bool canMaximize = tabs == null
        ? widget.maximizableItem && (item.maximizable ?? true)
        : (widget.maximizableTab && (item.maximizable ?? true)) ||
            (widget.maximizableTabsArea && (tabs.maximizable ?? true));
    final bool canFloat = widget.onItemFloat != null && item.floatable;
    return <Widget>[
      if (canFloat)
        _HeaderButton(
          icon: PhosphorIcons.arrowSquareOut,
          tooltip: 'Open in a window',
          theme: theme,
          onTap: () => _float(item, Offset.zero),
        ),
      if (canMaximize)
        _HeaderButton(
          icon: maximized ? PhosphorIcons.cornersIn : PhosphorIcons.cornersOut,
          tooltip: maximized ? 'Restore' : 'Maximize',
          theme: theme,
          onTap: maximized
              ? layout.restore
              : () => tabs == null
                  ? layout.maximizeDockingItem(item)
                  : layout.maximizeDockingTabs(tabs),
        ),
      if (item.closable)
        _HeaderButton(
          icon: PhosphorIcons.x,
          tooltip: 'Close',
          theme: theme,
          onTap: () => _close(item),
        ),
      const SizedBox(width: 2),
    ];
  }

  void _close(DockingItem item) {
    if (!(widget.itemCloseInterceptor?.call(item) ?? true)) return;
    widget.layout!.removeItem(item: item);
    widget.onItemClose?.call(item);
  }

  void _float(DockingItem item, Offset at) {
    final OnItemFloat? onFloat = widget.onItemFloat;
    if (onFloat == null) return;
    // The caller remembers where it was before it is gone.
    onFloat(item, at);
  }

  // --- dragging --------------------------------------------------------------

  Widget _draggable(DockingItem item, Widget child, {bool expand = false}) {
    if (!widget.draggable || !item.draggable) return child;
    return GestureDetector(
      behavior: GestureHitTestBehavior.opaque,
      onPanStart: (d) => setState(() {
        _drag = _DragSession(item, d.globalPosition)
          ..pointer = d.globalPosition;
      }),
      onPanUpdate: (d) {
        final _DragSession? drag = _drag;
        if (drag == null) return;
        setState(() {
          drag
            ..pointer = d.globalPosition
            ..target = _targetAt(drag.item, d.globalPosition);
        });
      },
      onPanEnd: (d) => _drop(d.globalPosition),
      onPanCancel: () => setState(() => _drag = null),
      child: child,
    );
  }

  /// The drop zone under [p] for [item].
  _DropTarget? _targetAt(DockingItem item, Offset p) {
    final Rect? root = _rects[_rootKey];
    if (root == null) return null;
    if (!root.inflate(4).contains(p)) {
      return widget.onItemFloat != null && item.floatable
          ? const _DropTarget.float()
          : null;
    }
    // Along the edges of the whole layout: beside everything.
    const double edge = 24;
    const double third = 0.3;
    if (p.dx - root.left < edge) {
      return _DropTarget.root(DropPosition.left,
          Rect.fromLTWH(root.left, root.top, root.width * third, root.height));
    }
    if (root.right - p.dx < edge) {
      return _DropTarget.root(
          DropPosition.right,
          Rect.fromLTWH(root.right - root.width * third, root.top,
              root.width * third, root.height));
    }
    if (p.dy - root.top < edge) {
      return _DropTarget.root(DropPosition.top,
          Rect.fromLTWH(root.left, root.top, root.width, root.height * third));
    }
    if (root.bottom - p.dy < edge) {
      return _DropTarget.root(
          DropPosition.bottom,
          Rect.fromLTWH(root.left, root.bottom - root.height * third,
              root.width, root.height * third));
    }

    // The innermost area that takes drops: a tab group, or an item alone.
    DockingArea? best;
    Rect? bestRect;
    _rects.forEach((Object key, Rect rect) {
      if (key is! DockingArea || !rect.contains(p)) return;
      final bool dropArea = key is DockingTabs ||
          (key is DockingItem && key.parent is! DockingTabs);
      if (!dropArea) return;
      if (bestRect == null ||
          rect.width * rect.height < bestRect!.width * bestRect!.height) {
        best = key;
        bestRect = rect;
      }
    });
    final DockingArea? area = best;
    final Rect? r = bestRect;
    if (area == null || r == null || identical(area, item)) return null;
    final bool ownTabs = area is DockingTabs && area.contains(item);
    if (ownTabs && area.childrenCount == 1) return null;

    final double rx = (p.dx - r.left) / r.width;
    final double ry = (p.dy - r.top) / r.height;
    final double toEdgeX = rx < 0.5 ? rx : 1 - rx;
    final double toEdgeY = ry < 0.5 ? ry : 1 - ry;
    final bool document = area is DockingItem && !area.showHeader;
    if (toEdgeX > 0.28 && toEdgeY > 0.28) {
      // The middle makes tabs - but not with a document area, and not with
      // the group the item is already in.
      if (document || ownTabs) return null;
      return _DropTarget.area(area, DropPosition.center, r);
    }
    if (toEdgeX < toEdgeY) {
      return rx < 0.5
          ? _DropTarget.area(area, DropPosition.left,
              Rect.fromLTWH(r.left, r.top, r.width / 2, r.height))
          : _DropTarget.area(
              area,
              DropPosition.right,
              Rect.fromLTWH(
                  r.left + r.width / 2, r.top, r.width / 2, r.height));
    }
    return ry < 0.5
        ? _DropTarget.area(area, DropPosition.top,
            Rect.fromLTWH(r.left, r.top, r.width, r.height / 2))
        : _DropTarget.area(area, DropPosition.bottom,
            Rect.fromLTWH(r.left, r.top + r.height / 2, r.width, r.height / 2));
  }

  void _drop(Offset p) {
    final _DragSession? drag = _drag;
    setState(() => _drag = null);
    if (drag == null) return;
    // A press that barely moved is a click on the tab, not a drag.
    if ((p - drag.start).distance < 6) return;
    final _DropTarget? target = _targetAt(drag.item, p);
    if (target == null) return;
    final DockingLayout layout = widget.layout!;
    if (target.float) {
      _float(drag.item, p);
      return;
    }
    // A move keeps the item's identity, but its old size belonged to the
    // split it left.
    drag.item.size = null;
    if (target.root) {
      layout.moveItemToRoot(item: drag.item, position: target.position);
    } else {
      layout.moveItem(
        draggedItem: drag.item,
        targetArea: target.area! as DropArea,
        dropPosition: target.position,
      );
    }
  }
}

/// A tab, or the title of a panel standing alone.
final class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.item,
    required this.selected,
    required this.theme,
    required this.onTap,
  });

  final DockingItem item;
  final bool selected;
  final DockingThemeData theme;
  final void Function() onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData appTheme = Theme.of(context);
    return GestureDetector(
      behavior: GestureHitTestBehavior.opaque,
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? theme.activeHeaderColor : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (item.leading != null) ...<Widget>[
                item.leading!,
                const SizedBox(width: 6),
              ],
              Text(
                item.name ?? 'Panel',
                style: appTheme.textTheme.labelLarge,
                color: selected
                    ? theme.foregroundColor
                    : theme.inactiveForegroundColor,
                maxLines: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.theme,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final DockingThemeData theme;
  final void Function() onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: GestureHitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: 24,
            child: Center(
              child: Icon(icon, size: 13, color: theme.inactiveForegroundColor),
            ),
          ),
        ),
      );
}

final class _DragLabel extends StatelessWidget {
  const _DragLabel({required this.text, required this.theme});

  final String text;
  final DockingThemeData theme;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: theme.headerColor,
          border: BoxBorder(color: theme.accentColor, width: 1),
          radius: 4,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            text,
            style: Theme.of(context).textTheme.labelSmall,
            color: theme.foregroundColor,
          ),
        ),
      );
}

/// Reports its box in window coordinates every time it paints.
final class _Measured extends SingleChildRenderObjectWidget {
  const _Measured({required this.onRect, required super.child});

  final void Function(Rect rect) onRect;

  @override
  _RenderMeasured createRenderObject(BuildContext context) =>
      _RenderMeasured(onRect);

  @override
  void updateRenderObject(
      BuildContext context, covariant _RenderMeasured renderObject) {
    renderObject.onRect = onRect;
  }
}

final class _RenderMeasured extends RenderProxyBox {
  _RenderMeasured(this.onRect);

  void Function(Rect rect) onRect;

  @override
  void paint(DisplayList list, Offset offset) {
    final Offset origin = localToGlobal(Offset.zero);
    onRect(Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height));
    super.paint(list, offset);
  }
}
