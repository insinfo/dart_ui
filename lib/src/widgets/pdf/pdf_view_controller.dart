library;

import '../../foundation/value_notifier.dart';
import '../../pdf/document/pdf_document.dart';
import '../../pdf/render/pdf_text_layout.dart';

/// A text range selected across one or more PDF pages.
final class PdfTextSelection {
  const PdfTextSelection({
    required int pageNumber,
    required this.baseOffset,
    required this.extentOffset,
    required this.text,
  })  : basePageNumber = pageNumber,
        extentPageNumber = pageNumber;

  const PdfTextSelection.range({
    required this.basePageNumber,
    required this.extentPageNumber,
    required this.baseOffset,
    required this.extentOffset,
    required this.text,
  });

  final int basePageNumber;
  final int extentPageNumber;
  final int baseOffset;
  final int extentOffset;
  final String text;

  /// Compatibility spelling for single-page callers and the active end of a
  /// multi-page selection.
  int get pageNumber => extentPageNumber;

  bool get isForward =>
      basePageNumber < extentPageNumber ||
      basePageNumber == extentPageNumber && baseOffset <= extentOffset;

  int get startPageNumber => isForward ? basePageNumber : extentPageNumber;
  int get endPageNumber => isForward ? extentPageNumber : basePageNumber;
  int get start => isForward ? baseOffset : extentOffset;
  int get end => isForward ? extentOffset : baseOffset;
  bool get isCollapsed =>
      basePageNumber == extentPageNumber && baseOffset == extentOffset;

  /// The ordered text offsets painted on [pageNumber], or null when that page
  /// is outside this selection.
  ({int start, int end})? rangeForPage(int pageNumber, int textLength) {
    if (pageNumber < startPageNumber || pageNumber > endPageNumber) {
      return null;
    }
    if (startPageNumber == endPageNumber) {
      return (
        start: start.clamp(0, textLength),
        end: end.clamp(0, textLength),
      );
    }
    return (
      start: pageNumber == startPageNumber ? start.clamp(0, textLength) : 0,
      end: pageNumber == endPageNumber ? end.clamp(0, textLength) : textLength,
    );
  }
}

/// One search hit in a PDF document.
final class PdfSearchMatch {
  const PdfSearchMatch({
    required this.query,
    required this.pageNumber,
    required this.start,
    required this.end,
    required this.excerpt,
  });

  final String query;
  final int pageNumber;
  final int start;
  final int end;
  final String excerpt;
}

/// Immutable snapshot published by [PdfViewController].
final class PdfViewState {
  const PdfViewState({
    required this.zoom,
    required this.currentPage,
    required this.pageCount,
    required this.navigationRevision,
    this.selection,
    this.searchMatch,
  });

  final double zoom;
  final int currentPage;
  final int pageCount;
  final int navigationRevision;
  final PdfTextSelection? selection;
  final PdfSearchMatch? searchMatch;
}

/// Drives zoom, page navigation, text selection and search for [PdfView].
///
/// A controller may be kept while documents are replaced; [PdfView] attaches
/// the active document and clears page-dependent caches automatically.
final class PdfViewController extends ValueNotifier<PdfViewState> {
  PdfViewController({
    double initialZoom = 1,
    this.minimumZoom = 0.25,
    this.maximumZoom = 5,
  })  : assert(minimumZoom > 0),
        assert(maximumZoom >= minimumZoom),
        super(PdfViewState(
          zoom: initialZoom.clamp(minimumZoom, maximumZoom),
          currentPage: 1,
          pageCount: 0,
          navigationRevision: 0,
        ));

  final double minimumZoom;
  final double maximumZoom;
  PdfDocument? _document;
  final Map<int, PdfPageTextLayout> _textLayouts = <int, PdfPageTextLayout>{};

  double get zoom => value.zoom;
  int get currentPage => value.currentPage;
  int get pageCount => value.pageCount;
  PdfTextSelection? get selection => value.selection;
  String get selectedText => value.selection?.text ?? '';
  bool get hasSelection => selection != null && !selection!.isCollapsed;

  void attachDocument(PdfDocument document) {
    if (identical(document, _document)) return;
    _document = document;
    _textLayouts.clear();
    value = PdfViewState(
      zoom: value.zoom,
      currentPage: document.pageCount == 0 ? 0 : 1,
      pageCount: document.pageCount,
      navigationRevision: value.navigationRevision + 1,
    );
  }

  PdfPageTextLayout textLayoutFor(int pageNumber) {
    final PdfDocument? document = _document;
    if (document == null) {
      throw StateError('PdfViewController is not attached to a document.');
    }
    if (pageNumber < 1 || pageNumber > document.pageCount) {
      throw RangeError.range(pageNumber, 1, document.pageCount, 'pageNumber');
    }
    return _textLayouts.putIfAbsent(
      pageNumber,
      () => PdfTextExtractor(document.getPage(pageNumber)).extract(),
    );
  }

  void setZoom(double zoom) {
    if (!zoom.isFinite) return;
    final double next = zoom.clamp(minimumZoom, maximumZoom);
    if (next == value.zoom) return;
    _replace(zoom: next);
  }

  void zoomIn() => setZoom(value.zoom * 1.25);
  void zoomOut() => setZoom(value.zoom / 1.25);
  void resetZoom() => setZoom(1);

  /// Fits a page's width inside a viewport, leaving [padding] around it.
  void fitWidth({
    required double pageWidth,
    required double viewportWidth,
    double padding = 32,
  }) {
    if (pageWidth <= 0 || viewportWidth <= padding) return;
    setZoom((viewportWidth - padding) / pageWidth);
  }

  /// Fits the whole page inside a viewport, preserving its aspect ratio.
  void fitPage({
    required double pageWidth,
    required double pageHeight,
    required double viewportWidth,
    required double viewportHeight,
    double padding = 32,
  }) {
    if (pageWidth <= 0 ||
        pageHeight <= 0 ||
        viewportWidth <= padding ||
        viewportHeight <= padding) {
      return;
    }
    final double widthScale = (viewportWidth - padding) / pageWidth;
    final double heightScale = (viewportHeight - padding) / pageHeight;
    setZoom(widthScale < heightScale ? widthScale : heightScale);
  }

  void goToPage(int pageNumber) {
    if (value.pageCount == 0) return;
    final int next = pageNumber.clamp(1, value.pageCount);
    _replace(
      currentPage: next,
      navigationRevision: value.navigationRevision + 1,
    );
  }

  /// Updates the toolbar's visible-page state without issuing a scroll jump.
  void reportVisiblePage(int pageNumber) {
    if (value.pageCount == 0) return;
    final int next = pageNumber.clamp(1, value.pageCount);
    if (next == value.currentPage) return;
    _replace(currentPage: next);
  }

  void selectText(int pageNumber, int baseOffset, int extentOffset) {
    selectTextRange(pageNumber, baseOffset, pageNumber, extentOffset);
  }

  /// Selects text from an anchor on one page to an extent on another.
  void selectTextRange(
    int basePageNumber,
    int baseOffset,
    int extentPageNumber,
    int extentOffset,
  ) {
    final PdfPageTextLayout baseLayout = textLayoutFor(basePageNumber);
    final PdfPageTextLayout extentLayout = textLayoutFor(extentPageNumber);
    final int base = baseOffset.clamp(0, baseLayout.text.length);
    final int extent = extentOffset.clamp(0, extentLayout.text.length);
    final PdfTextSelection provisional = PdfTextSelection.range(
      basePageNumber: basePageNumber,
      extentPageNumber: extentPageNumber,
      baseOffset: base,
      extentOffset: extent,
      text: '',
    );
    _replace(
      selection: PdfTextSelection.range(
        basePageNumber: basePageNumber,
        extentPageNumber: extentPageNumber,
        baseOffset: base,
        extentOffset: extent,
        text: _textForSelection(provisional),
      ),
      clearSearchMatch: true,
    );
  }

  String _textForSelection(PdfTextSelection selection) {
    final StringBuffer result = StringBuffer();
    for (var page = selection.startPageNumber;
        page <= selection.endPageNumber;
        page++) {
      final PdfPageTextLayout layout = textLayoutFor(page);
      final ({int start, int end}) range =
          selection.rangeForPage(page, layout.text.length)!;
      if (result.isNotEmpty) result.write('\n');
      result.write(layout.text.substring(range.start, range.end));
    }
    return result.toString();
  }

  void clearSelection() {
    if (value.selection == null) return;
    _replace(clearSelection: true);
  }

  /// Selects all extracted text in the document, or only [pageNumber] when it
  /// is supplied for compatibility with earlier releases.
  void selectAll([int? pageNumber]) {
    final PdfDocument? document = _document;
    if (document == null || document.pageCount == 0) return;
    if (pageNumber != null) {
      final PdfPageTextLayout layout = textLayoutFor(pageNumber);
      selectText(pageNumber, 0, layout.text.length);
      return;
    }
    final int lastPage = document.pageCount;
    selectTextRange(
      1,
      0,
      lastPage,
      textLayoutFor(lastPage).text.length,
    );
  }

  /// Finds the next match, wrapping once at the end of the document.
  PdfSearchMatch? findNext(String query) {
    final PdfDocument? document = _document;
    final String needle = query.trim();
    if (document == null || document.pageCount == 0 || needle.isEmpty) {
      return null;
    }
    final String lowerNeedle = needle.toLowerCase();
    final PdfSearchMatch? previous = value.searchMatch;
    final bool continuing =
        previous != null && previous.query.toLowerCase() == lowerNeedle;
    final int firstPage = continuing ? previous.pageNumber : value.currentPage;

    for (var visited = 0; visited < document.pageCount; visited++) {
      final int pageNumber = (firstPage - 1 + visited) % document.pageCount + 1;
      final PdfPageTextLayout layout = textLayoutFor(pageNumber);
      final String haystack = layout.text.toLowerCase();
      final int from = continuing && visited == 0 ? previous.end : 0;
      final int index = haystack.indexOf(lowerNeedle, from);
      if (index < 0) continue;
      return _activateMatch(needle, pageNumber, layout, index);
    }

    // The first pass searched the starting page only after the previous hit.
    // Search its beginning last so "next" wraps to the document's first hit
    // instead of incorrectly reporting that a one-page PDF has no match.
    if (continuing) {
      final PdfPageTextLayout layout = textLayoutFor(firstPage);
      final int index = layout.text.toLowerCase().indexOf(lowerNeedle);
      if (index >= 0) {
        return _activateMatch(needle, firstPage, layout, index);
      }
    }

    _replace(clearSearchMatch: true, clearSelection: true);
    return null;
  }

  PdfSearchMatch _activateMatch(
    String query,
    int pageNumber,
    PdfPageTextLayout layout,
    int index,
  ) {
    final int end = index + query.length;
    final PdfSearchMatch match = PdfSearchMatch(
      query: query,
      pageNumber: pageNumber,
      start: index,
      end: end,
      excerpt: _excerpt(layout.text, index, end),
    );
    value = PdfViewState(
      zoom: value.zoom,
      currentPage: pageNumber,
      pageCount: value.pageCount,
      navigationRevision: value.navigationRevision + 1,
      selection: PdfTextSelection(
        pageNumber: pageNumber,
        baseOffset: index,
        extentOffset: end,
        text: layout.text.substring(index, end),
      ),
      searchMatch: match,
    );
    return match;
  }

  void _replace({
    double? zoom,
    int? currentPage,
    int? navigationRevision,
    PdfTextSelection? selection,
    PdfSearchMatch? searchMatch,
    bool clearSelection = false,
    bool clearSearchMatch = false,
  }) {
    value = PdfViewState(
      zoom: zoom ?? value.zoom,
      currentPage: currentPage ?? value.currentPage,
      pageCount: value.pageCount,
      navigationRevision: navigationRevision ?? value.navigationRevision,
      selection: clearSelection ? null : selection ?? value.selection,
      searchMatch: clearSearchMatch ? null : searchMatch ?? value.searchMatch,
    );
  }
}

String _excerpt(String text, int start, int end) {
  final int from = (start - 28).clamp(0, text.length);
  final int to = (end + 28).clamp(0, text.length);
  return text.substring(from, to).replaceAll(RegExp(r'\s+'), ' ').trim();
}
