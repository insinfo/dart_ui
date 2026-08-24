/// The application menu bar and its drop-downs.
///
/// The bar itself is a row of headers; the open drop-down is *not* a child of
/// its header. It is returned separately so the window can put it in a [Stack]
/// above everything else - a menu painted inside the bar would be clipped by
/// the bar's own 24 px and painted under every widget that follows it, which is
/// the same ordering trap the canvas used to fall into.
library;

import 'package:dart_ui/dart_ui.dart';

import 'commands.dart';
import 'metrics.dart';

/// The row of menu headers.
class EditorMenuBar extends StatelessWidget {
  const EditorMenuBar({
    super.key,
    required this.menus,
    required this.openIndex,
    required this.onOpen,
  });

  final List<EditorMenu> menus;

  /// The open drop-down's index, or -1.
  final int openIndex;

  /// Reports the header the user pressed. -1 means "close whatever is open".
  final void Function(int index) onOpen;

  /// The width a header with [label] occupies.
  ///
  /// Shared with [dropdownLeftFor] so the drop-down lines up with the header it
  /// belongs to without either of them measuring text.
  static double headerWidth(String label) =>
      label.length * ChromeMetrics.menuHeaderCharacterWidth +
      ChromeMetrics.menuHeaderPadding * 2;

  /// The x a drop-down for menu [index] opens at.
  static double dropdownLeftFor(List<EditorMenu> menus, int index) {
    var left = 0.0;
    for (var i = 0; i < index && i < menus.length; i++) {
      left += headerWidth(menus[i].label);
    }
    return left;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: ChromeMetrics.menuBarHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.surfaceAlternate,
          border: BoxBorder(color: theme.border, width: 1),
        ),
        child: Row(
          children: <Widget>[
            for (var index = 0; index < menus.length; index++)
              _MenuHeader(
                label: menus[index].label,
                open: index == openIndex,
                onTap: () => onOpen(index == openIndex ? -1 : index),
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuHeader extends StatelessWidget {
  const _MenuHeader({
    required this.label,
    required this.open,
    required this.onTap,
  });

  final String label;
  final bool open;
  final void Function() onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: GestureHitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        // Explicit, because a header is a click target: an intrinsically sized
        // label leaves the gaps between words unclickable.
        width: EditorMenuBar.headerWidth(label),
        height: ChromeMetrics.menuBarHeight,
        child: ColoredBox(
          color: open ? theme.accent : theme.surfaceAlternate,
          child: Center(
            child: Text(
              label,
              color: open ? theme.surfaceAlternate : theme.foreground,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}

/// The open drop-down, positioned under its header.
///
/// Returned by the window rather than built by the bar so it can be stacked
/// over the whole window. Tapping anywhere outside closes it.
class EditorMenuOverlay extends StatelessWidget {
  const EditorMenuOverlay({
    super.key,
    required this.menus,
    required this.openIndex,
    required this.onDismiss,
  });

  final List<EditorMenu> menus;
  final int openIndex;
  final void Function() onDismiss;

  @override
  Widget build(BuildContext context) {
    if (openIndex < 0 || openIndex >= menus.length) return const SizedBox();
    final menu = menus[openIndex];
    return Stack(
      children: <Widget>[
        // The dismiss barrier: a click anywhere else closes the menu without
        // reaching the widget under it, which is what makes an open menu modal.
        Positioned.fill(
          child: GestureDetector(
            behavior: GestureHitTestBehavior.opaque,
            onTap: onDismiss,
            child: const SizedBox(),
          ),
        ),
        Positioned(
          left: EditorMenuBar.dropdownLeftFor(menus, openIndex),
          top: ChromeMetrics.menuBarHeight,
          child: Menu(
            items: <MenuItem>[
              for (final item in menu.toMenuItems())
                item.isSeparator
                    ? item
                    : MenuItem(
                        label: item.label,
                        shortcut: item.shortcut,
                        enabled: item.enabled,
                        disabledReason: item.disabledReason,
                        onSelected: () {
                          item.onSelected?.call();
                          onDismiss();
                        },
                      ),
            ],
          ),
        ),
      ],
    );
  }
}
