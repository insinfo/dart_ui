/// The document tab strip - sK1's `doctabs.py`.
///
/// A tab shows the document name with sK1's `*` marker for unsaved changes, and
/// carries its own close button.
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

  /// Per-character width used to size the tab, matched to the 11 px label.
  static const double _characterWidth = 6.2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: GestureHitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: title.length * _characterWidth + 44,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? theme.surface : theme.surfaceAlternate,
            border: BoxBorder(color: theme.border, width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 8, right: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    color: selected
                        ? theme.foreground
                        : theme.foregroundSecondary,
                    fontSize: 11,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  iconSize: 11,
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: 16, minHeight: 16),
                  tooltip: 'Close $title',
                  onPressed: onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
