/// The document tab strip - sK1's `doctabs.py`.
///
/// A tab shows the document name with sK1's `*` marker for unsaved changes, and
/// carries its own close button.
///
/// ## Why it stopped being a box
///
/// Every tab used to draw a full 1 px border around itself on a bar that
/// already had one, so an open document read as a rectangle *inside* a
/// rectangle - two nested boxes and a double rule where they touched, which is
/// the Windows 95 drawing the design system exists to replace. A tab is a
/// selected surface, and the framework's own [Tabs] says so in one line: the
/// selected tab is the panel colour carrying an accent underline, an
/// unselected one is nothing at all until the pointer arrives and then it is
/// `hoverSurface`. This strip follows that, because a window whose document
/// tabs are drawn differently from its panel tabs is a window assembled by two
/// people.
library;

import 'package:dart_ui/dart_ui.dart';

import 'editor_model.dart';
import 'metrics.dart';

/// The strip of open documents.
class DocumentTabs extends StatelessWidget {
  const DocumentTabs({
    super.key,
    required this.documents,
    required this.activeIndex,
    required this.onSelected,
    required this.onClosed,
  });

  final List<DocumentSession> documents;
  final int activeIndex;
  final void Function(int index) onSelected;
  final void Function(int index) onClosed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: ChromeMetrics.documentTabsHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.surfaceAlternate,
          border: BoxBorder(color: theme.border, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var index = 0; index < documents.length; index++)
              _DocumentTab(
                title: documents[index].tabTitle,
                selected: index == activeIndex,
                onTap: () => onSelected(index),
                onClose: () => onClosed(index),
              ),
          ],
        ),
      ),
    );
  }
}

class _DocumentTab extends StatelessWidget {
  const _DocumentTab({
    required this.title,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final String title;
  final bool selected;
  final void Function() onTap;
  final void Function() onClose;

  /// Per-character width used to size the tab.
  ///
  /// Fixed rather than measured for the same reason the menu headers are: the
  /// strip is rebuilt on every document change and shaping every title twice a
  /// frame to learn a width is a cost with nothing behind it. Matched to the
  /// theme's base size, which the label is now drawn at.
  static const double _characterWidth = 7.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: GestureHitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: title.length * _characterWidth +
            theme.effectiveControlPadding * 2 +
            theme.iconSize +
            theme.effectiveGap,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // The accent wash marks a *selected* neutral control; the
                  // rest of the strip is unbroken surface.
                  color: selected ? theme.accentSubtle : null,
                ),
              ),
            ),
            // The indicator, which is what says "this one" now that the box is
            // gone. Two pixels, along the bottom edge, in the accent - the
            // same mark the framework's own tab strip draws.
            if (selected)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: theme.focusRingWidth,
                child: ColoredBox(color: theme.accent),
              ),
            Padding(
              padding: EdgeInsets.only(
                left: theme.effectiveControlPadding,
                right: Spacing.xs,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      title,
                      // A tab label is a control label: the theme's base size
                      // at medium weight. It was 11 px, which made the open
                      // document's own name the smallest type in the window.
                      style: theme.textTheme.labelLarge,
                      color: selected
                          ? theme.accent
                          : theme.foregroundSecondary,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close,
                        color: theme.foregroundSecondary),
                    iconSize: theme.iconSize,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(
                      minWidth: theme.iconSize + Spacing.xs,
                      minHeight: theme.iconSize + Spacing.xs,
                    ),
                    tooltip: 'Close $title',
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
