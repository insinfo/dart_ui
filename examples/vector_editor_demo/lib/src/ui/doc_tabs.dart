///
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

import '../engine/editor_model.dart';
import 'metrics.dart';

/// The strip of open documents.
class DocumentTabs extends StatelessWidget {
  const DocumentTabs({
    super.key,
    required this.documents,
    required this.activeIndex,
    required this.onSelected,
    required this.onClosed,
    this.contextMenu,
  });

  final List<DocumentSession> documents;
  final int activeIndex;
  final void Function(int index) onSelected;
  final void Function(int index) onClosed;

  /// A tab's right-click menu, built after the tab was made the active one.
  final List<Widget> Function()? contextMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final List<Widget> Function()? menu = contextMenu;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surfaceAlternate,
        border: BoxBorder(color: theme.border, width: 1),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: DocumentTabStrip(
          height: ChromeMetrics.of(theme).documentTabsHeight,
          tabs: <DocumentTab>[
            for (final DocumentSession document in documents)
              DocumentTab(label: document.tabTitle, id: document),
          ],
          selectedIndex: activeIndex,
          onSelected: onSelected,
          onClosed: onClosed,
          contextMenu: menu == null ? null : (int _) => menu(),
        ),
      ),
    );
  }
}
