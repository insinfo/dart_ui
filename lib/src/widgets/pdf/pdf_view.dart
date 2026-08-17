import '../../layout/edge_insets.dart';
import '../../layout/render_flex.dart';
import '../../layout/render_viewport.dart';
import '../../pdf/document/pdf_document.dart';
import '../basic.dart';
import '../proxy.dart';
import '../scroll_view.dart';
import '../widget.dart';
import 'pdf_page_view.dart';

/// Widget visual para navegação e renderização de arquivos PDF.
/// Suporta virtualização de páginas, pan e zoom interativo.
class PdfView extends StatelessWidget {
  final PdfDocument document;
  final Axis scrollDirection;
  final double pageSpacing;
  final bool enableTextSelection;
  final bool enablePinchZoom;
  final void Function(int pageIndex)? onPageChanged;

  const PdfView({
    super.key,
    required this.document,
    this.scrollDirection = Axis.vertical,
    this.pageSpacing = 16.0,
    this.enableTextSelection = false,
    this.enablePinchZoom = false,
    this.onPageChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (document.pageCount == 0) {
      return const Center(
        child: Text('O PDF não contém páginas.'),
      );
    }

    final bool vertical = scrollDirection == Axis.vertical;
    final firstPage = document.getPage(1);
    return ListView.builder(
      itemCount: document.pageCount,
      axis: vertical ? ScrollAxis.vertical : ScrollAxis.horizontal,
      estimatedItemExtent:
          (vertical ? firstPage.height : firstPage.width) + pageSpacing,
      itemBuilder: (BuildContext context, int index) {
        final page = document.getPage(index + 1);
        final bool hasTrailingSpacing = index + 1 < document.pageCount;
        return Padding(
          padding: vertical
              ? EdgeInsets.only(
                  bottom: hasTrailingSpacing ? pageSpacing : 0.0,
                )
              : EdgeInsets.only(
                  right: hasTrailingSpacing ? pageSpacing : 0.0,
                ),
          child: Center(
            child: ColoredBox(
              color: 0xFFFFFFFF,
              child: PdfPageView(page: page),
            ),
          ),
        );
      },
    );
  }
}
