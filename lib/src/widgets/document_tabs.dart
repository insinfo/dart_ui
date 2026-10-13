/// Document tabs: the strip of open things - drawings in an editor, folders
/// in a file manager, pages in a browser - each with its own close button,
/// and a button that opens another.
///
/// Not [Tabs]. That one switches between fixed panels of one view and has
/// neither close nor add; this one is a list the user grows and shrinks.
/// The strip is controlled: it shows [DocumentTabStrip.tabs] and reports
/// selection, closing and adding.
library;

import '../graphics/color.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_flex.dart' as layout;
import '../platform/input_events.dart';
import 'basic.dart';
import 'context_menu_area.dart';
import 'gesture_detector.dart';
import 'hover.dart';
import 'icon.dart';
import 'icon_button.dart';
import 'phosphor_icons.dart';
import 'pointer_listener.dart';
import 'proxy.dart';
import 'sizing.dart';
import 'theme.dart';
import 'tooltip.dart';
import 'widget.dart';

/// One tab of a [DocumentTabStrip].
final class DocumentTab {
  const DocumentTab({
    required this.label,
    this.icon,
    this.id,
    this.tooltip,
    this.closable = true,
  });

  final String label;
  final IconData? icon;

  /// What the tab is across rebuilds; defaults to the label.
  final Object? id;

  /// Shown over the tab; the label when null - a path is the usual one.
  final String? tooltip;

  final bool closable;

  Object get identity => id ?? label;
}

/// How the selected tab stands out.
enum DocumentTabStyle {
  /// An accent underline on a tinted tab - a strip inside a window, as an
  /// editor's open documents.
  underline,

  /// The selected tab is a raised card with rounded top corners in
  /// [DocumentTabStrip.selectedColor], open at the bottom so it runs into
  /// the toolbar below it - the tabs of a browser or of Windows 11's File
  /// Explorer.
  raised,
}

/// A strip of closable document tabs and an add button.
final class DocumentTabStrip extends StatelessWidget {
  const DocumentTabStrip({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    this.onSelected,
    this.onClosed,
    this.onAdd,
    this.contextMenu,
    this.style = DocumentTabStyle.underline,
    this.height,
    this.maxTabWidth = 240,
    this.selectedColor,
    this.addTooltip = 'New tab',
  });

  final List<DocumentTab> tabs;
  final int selectedIndex;
  final void Function(int index)? onSelected;

  /// The close button, or a middle click on the tab.
  final void Function(int index)? onClosed;

  /// The add button after the last tab; null shows none.
  final void Function()? onAdd;

  /// A tab's right-click menu, built after it was made the selected one.
  final List<Widget> Function(int index)? contextMenu;

  final DocumentTabStyle style;

  /// The strip's height; null for the theme's control height plus a little.
  final double? height;

  /// How wide a tab grows when there is room; with many open they share the
  /// strip and their labels shorten.
  final double maxTabWidth;

  /// The raised tab's colour; null for the theme's alternate surface.
  final Color? selectedColor;

  final String addTooltip;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double extent = height ?? theme.effectiveControlHeight + 8;
    return SizedBox(
      height: extent,
      child: Row(
        crossAxisAlignment: layout.CrossAxisAlignment.stretch,
        mainAxisSize: layout.MainAxisSize.min,
        children: <Widget>[
          for (var index = 0; index < tabs.length; index++)
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxTabWidth),
                child: _wrapMenu(
                  index,
                  _DocumentTabView(
                    tab: tabs[index],
                    selected: index == selectedIndex,
                    style: style,
                    selectedColor: selectedColor ?? theme.surfaceAlternate,
                    onTap: () => onSelected?.call(index),
                    onClose: onClosed == null || !tabs[index].closable
                        ? null
                        : () => onClosed!(index),
                  ),
                ),
              ),
            ),
          if (onAdd != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: IconButton(
                  icon: const Icon(PhosphorIcons.plus),
                  iconSize: theme.iconSize,
                  padding: const EdgeInsets.all(6),
                  tooltip: addTooltip,
                  onPressed: onAdd,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _wrapMenu(int index, Widget tab) {
    final List<Widget> Function(int index)? menu = contextMenu;
    if (menu == null) return tab;
    return ContextMenuArea(
      onOpen: (_) => onSelected?.call(index),
      menuChildren: () => menu(index),
      child: tab,
    );
  }
}

final class _DocumentTabView extends StatelessWidget {
  const _DocumentTabView({
    required this.tab,
    required this.selected,
    required this.style,
    required this.selectedColor,
    required this.onTap,
    required this.onClose,
  });

  final DocumentTab tab;
  final bool selected;
  final DocumentTabStyle style;
  final Color selectedColor;
  final void Function() onTap;
  final void Function()? onClose;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool raised = style == DocumentTabStyle.raised;
    return Tooltip(
      message: tab.tooltip ?? tab.label,
      child: HoverBuilder(
        builder: (BuildContext context, bool hovered) => PointerListener(
          // A middle click closes, as in every tabbed application.
          onPointerDown: (PointerDownEvent event) {
            if (event.button == PointerButton.middle) onClose?.call();
          },
          child: GestureDetector(
            behavior: GestureHitTestBehavior.opaque,
            onTap: onTap,
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: _background(theme, raised, hovered)),
                if (selected && !raised)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: theme.focusRingWidth,
                    child: ColoredBox(color: theme.accent),
                  ),
                // Filling the tab, so the row is centred in it - in the
                // raised card below its 4 px of headroom. Left loose in the
                // stack, the row would shrink to its tallest child and sit
                // at the top, the label a few pixels above the middle.
                Positioned.fill(
                    child: Padding(
                  padding: EdgeInsets.only(
                    left: theme.effectiveControlPadding,
                    right: 4,
                    top: raised ? 4 : 0,
                  ),
                  child: Row(
                    crossAxisAlignment: layout.CrossAxisAlignment.center,
                    children: <Widget>[
                      if (tab.icon != null) ...<Widget>[
                        Icon(tab.icon!,
                            color: selected && !raised
                                ? theme.accent
                                : theme.foregroundSecondary),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          tab.label,
                          style: theme.textTheme.labelLarge,
                          color: selected
                              ? (raised ? theme.foreground : theme.accent)
                              : theme.foregroundSecondary,
                          maxLines: 1,
                          ellipsis: '\u2026',
                        ),
                      ),
                      if (onClose != null)
                        // Shown on the selected tab and under the pointer,
                        // like a browser's; the room is kept either way so
                        // the label does not jump.
                        Opacity(
                          opacity: selected || hovered ? 1 : 0,
                          child: IconButton(
                            icon: Icon(PhosphorIcons.x,
                                color: theme.foregroundSecondary),
                            iconSize: theme.iconSize - 2,
                            padding: const EdgeInsets.all(4),
                            constraints: BoxConstraints(
                              minWidth: theme.iconSize + 6,
                              minHeight: theme.iconSize + 6,
                            ),
                            tooltip: 'Close tab',
                            onPressed: onClose,
                          ),
                        ),
                    ],
                  ),
                )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _background(ThemeData theme, bool raised, bool hovered) {
    if (!raised) {
      final Color? color = selected
          ? theme.accentSubtle
          : hovered
              ? theme.hoverSurface
              : null;
      return color == null ? const SizedBox() : ColoredBox(color: color);
    }
    if (!selected && !hovered) return const SizedBox();
    // Rounded at the top only: a rounded box that runs a radius past the
    // bottom edge, clipped there, so the tab opens into what is below it.
    final double radius = theme.cornerRadius * 2;
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 2, right: 2),
      child: ClipRect(
        child: Stack(
          children: <Widget>[
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: selected ? -radius : 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected ? selectedColor : theme.hoverSurface,
                  radius: radius,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
