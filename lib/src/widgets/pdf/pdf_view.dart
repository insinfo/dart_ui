library;

import '../../geometry/offset.dart';
import '../../gestures/scale.dart';
import '../../graphics/color.dart';
import '../../layout/edge_insets.dart';
import '../../layout/render_box.dart';
import '../../layout/render_flex.dart';
import '../../layout/render_viewport.dart';
import '../../pdf/document/pdf_document.dart';
import '../../platform/input_events.dart';
import '../basic.dart';
import '../context_menu.dart';
import '../element.dart';
import '../gesture_detector.dart';
import '../menu.dart';
import '../pointer_router.dart';
import '../proxy.dart';
import '../scroll_view.dart';
import '../text_field.dart' show ClipboardScope;
import '../widget.dart';
import 'pdf_page_view.dart';
import 'pdf_view_controller.dart';

/// A virtualized, searchable PDF reader with page navigation, selectable text
/// and real page-scale zoom.
final class PdfView extends StatefulWidget {
  const PdfView({
    super.key,
    required this.document,
    this.controller,
    this.scrollDirection = Axis.vertical,
    this.pageSpacing = 16.0,
    this.initialZoom = 1,
    this.minimumZoom = 0.25,
    this.maximumZoom = 5,
    this.enableTextSelection = false,
    this.enableContextMenu = true,
    this.enablePinchZoom = false,
    this.backgroundColor = const Color(0xFFF1F5F9),
    this.pageColor = const Color(0xFFFFFFFF),
    this.onPageChanged,
    this.onTextSelectionStarted,
  })  : assert(pageSpacing >= 0),
        assert(initialZoom > 0),
        assert(minimumZoom > 0),
        assert(maximumZoom >= minimumZoom);

  final PdfDocument document;
  final PdfViewController? controller;
  final Axis scrollDirection;
  final double pageSpacing;
  final double initialZoom;
  final double minimumZoom;
  final double maximumZoom;
  final bool enableTextSelection;
  final bool enableContextMenu;
  final bool enablePinchZoom;
  final Color backgroundColor;
  final Color pageColor;

  /// Called with the one-based page number when the visible page changes.
  final void Function(int pageNumber)? onPageChanged;

  /// Called when a primary pointer starts a text selection.
  ///
  /// An editor commonly uses this to unfocus its search field without making
  /// the PDF surface itself a keyboard control.
  final void Function()? onTextSelectionStarted;

  @override
  State<PdfView> createState() => _PdfViewState();
}

final class _PdfViewState extends State<PdfView> {
  late PdfViewController _controller;
  late ScrollPosition _position;
  late int _lastNavigationRevision;
  late double _lastZoom;
  int? _pendingPage;
  double _pinchStartZoom = 1;
  bool _reportingScroll = false;

  bool get _vertical => widget.scrollDirection == Axis.vertical;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ??
        PdfViewController(
          initialZoom: widget.initialZoom,
          minimumZoom: widget.minimumZoom,
          maximumZoom: widget.maximumZoom,
        );
    _controller.attachDocument(widget.document);
    _lastNavigationRevision = _controller.value.navigationRevision;
    _lastZoom = _controller.zoom;
    _controller.addListener(_onControllerChanged);
    _position = ScrollPosition(
      axis: _vertical ? ScrollAxis.vertical : ScrollAxis.horizontal,
    )..addListener(_onScrolled);
  }

  @override
  void didUpdateWidget(covariant PdfView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      _controller.removeListener(_onControllerChanged);
      _controller = widget.controller ??
          PdfViewController(
            initialZoom: widget.initialZoom,
            minimumZoom: widget.minimumZoom,
            maximumZoom: widget.maximumZoom,
          );
      _controller.addListener(_onControllerChanged);
      _lastZoom = _controller.zoom;
      _lastNavigationRevision = _controller.value.navigationRevision;
    }
    if (!identical(widget.document, oldWidget.document) ||
        !identical(widget.controller, oldWidget.controller)) {
      _controller.attachDocument(widget.document);
      _lastNavigationRevision = _controller.value.navigationRevision;
      _pendingPage = 1;
    }
    if (widget.scrollDirection != oldWidget.scrollDirection) {
      _position.removeListener(_onScrolled);
      _position = ScrollPosition(
        axis: _vertical ? ScrollAxis.vertical : ScrollAxis.horizontal,
      )..addListener(_onScrolled);
      _pendingPage = _controller.currentPage;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _position.removeListener(_onScrolled);
    super.dispose();
  }

  void _onControllerChanged(PdfViewState state) {
    if (!mounted) return;
    final bool zoomChanged = state.zoom != _lastZoom;
    final bool navigationChanged =
        state.navigationRevision != _lastNavigationRevision;
    _lastZoom = state.zoom;
    _lastNavigationRevision = state.navigationRevision;
    if (zoomChanged || navigationChanged) {
      _pendingPage = state.currentPage;
    }
    setState(() {});
    // A page-only jump can use the current geometry immediately. A zoom jump
    // waits for ListView to publish its newly scaled content extent.
    if (navigationChanged && !zoomChanged) _navigateIfReady();
  }

  void _onScrolled(ScrollPosition position) {
    if (!mounted) return;
    if (_pendingPage != null) _navigateIfReady();
    if (_reportingScroll || widget.document.pageCount == 0) return;
    final int page = _pageForOffset(position.pixels);
    if (page == _controller.currentPage) return;
    _reportingScroll = true;
    _controller.reportVisiblePage(page);
    _reportingScroll = false;
    widget.onPageChanged?.call(page);
  }

  void _navigateIfReady() {
    final int? page = _pendingPage;
    if (page == null || _position.contentExtent <= 0) return;
    _pendingPage = null;
    _position.jumpTo(_offsetForPage(page));
  }

  double _offsetForPage(int pageNumber) {
    var offset = 0.0;
    final int end = pageNumber.clamp(1, widget.document.pageCount);
    for (var page = 1; page < end; page++) {
      final item = widget.document.getPage(page);
      offset += (_vertical ? item.height : item.width) * _controller.zoom;
      offset += widget.pageSpacing;
    }
    return offset;
  }

  int _pageForOffset(double offset) {
    final double probe = offset + _position.viewportExtent * 0.20;
    var cursor = 0.0;
    for (var page = 1; page <= widget.document.pageCount; page++) {
      final item = widget.document.getPage(page);
      final double extent =
          (_vertical ? item.height : item.width) * _controller.zoom;
      if (probe < cursor + extent + widget.pageSpacing) return page;
      cursor += extent + widget.pageSpacing;
    }
    return widget.document.pageCount;
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (details.pointerCount >= 2) _pinchStartZoom = _controller.zoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount >= 2) {
      _controller.setZoom(_pinchStartZoom * details.scale);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.document.pageCount == 0) {
      return const Center(child: Text('O PDF não contém páginas.'));
    }

    final firstPage = widget.document.getPage(1);
    Widget reader = ListView.builder(
      key: ValueKey<ScrollPosition>(_position),
      itemCount: widget.document.pageCount,
      axis: _vertical ? ScrollAxis.vertical : ScrollAxis.horizontal,
      controller: _position,
      mouseDragEnabled: !widget.enableTextSelection,
      estimatedItemExtent:
          (_vertical ? firstPage.height : firstPage.width) * _controller.zoom +
              widget.pageSpacing,
      cacheExtent:
          (_vertical ? firstPage.height : firstPage.width) * _controller.zoom,
      itemBuilder: (BuildContext context, int index) {
        final page = widget.document.getPage(index + 1);
        final bool trailing = index + 1 < widget.document.pageCount;
        final selection = _controller.selection;
        return Padding(
          padding: _vertical
              ? EdgeInsets.only(bottom: trailing ? widget.pageSpacing : 0)
              : EdgeInsets.only(right: trailing ? widget.pageSpacing : 0),
          child: Center(
            child: PdfPageView(
              page: page,
              scale: _controller.zoom,
              backgroundColor: widget.pageColor,
              // A resolver, not an eager extraction: extracting text layout
              // re-interprets the page's whole content stream, and paying
              // that for every realized page made the first frame of a
              // freshly opened document visibly slow. The controller caches
              // per page, so selection, search and this resolver agree.
              textLayoutResolver: widget.enableTextSelection
                  ? () => _controller.textLayoutFor(index + 1)
                  : null,
              selection: selection,
              enableTextSelection: widget.enableTextSelection,
              onSelectionChanged: widget.enableTextSelection
                  ? (int base, int extent) =>
                      _controller.selectText(index + 1, base, extent)
                  : null,
            ),
          ),
        );
      },
    );
    if (widget.enableTextSelection) {
      reader = _PdfSelectionRegion(
        document: widget.document,
        controller: _controller,
        position: _position,
        scrollDirection: widget.scrollDirection,
        pageSpacing: widget.pageSpacing,
        onSelectionStarted: widget.onTextSelectionStarted,
        child: reader,
      );
    }
    if (widget.enablePinchZoom) {
      reader = GestureDetector(
        behavior: GestureHitTestBehavior.deferToChild,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        child: reader,
      );
    }
    if (widget.enableTextSelection && widget.enableContextMenu) {
      reader = ContextMenuRegion(
        itemsBuilder: () {
          final bool hasSelection = _controller.hasSelection;
          return <MenuItem>[
            MenuItem(
              label: 'Copiar',
              shortcut: 'Ctrl+C',
              enabled: hasSelection,
              disabledReason: hasSelection ? null : 'Nenhum texto selecionado',
              onSelected: hasSelection
                  ? () {
                      ClipboardScope.of(context)
                          .writeText(_controller.selectedText);
                    }
                  : null,
            ),
            MenuItem(
              label: 'Selecionar tudo',
              shortcut: 'Ctrl+A',
              onSelected: _controller.selectAll,
            ),
            if (hasSelection) ...<MenuItem>[
              const MenuItem.separator(),
              MenuItem(
                label: 'Limpar seleção',
                onSelected: _controller.clearSelection,
              ),
            ],
          ];
        },
        child: reader,
      );
    }
    return ColoredBox(color: widget.backgroundColor, child: reader);
  }
}

final class _PdfSelectionRegion extends SingleChildRenderObjectWidget {
  const _PdfSelectionRegion({
    required this.document,
    required this.controller,
    required this.position,
    required this.scrollDirection,
    required this.pageSpacing,
    required this.onSelectionStarted,
    required super.child,
  });

  final PdfDocument document;
  final PdfViewController controller;
  final ScrollPosition position;
  final Axis scrollDirection;
  final double pageSpacing;
  final void Function()? onSelectionStarted;

  @override
  RenderPdfSelectionRegion createRenderObject(BuildContext context) =>
      RenderPdfSelectionRegion(
        document: document,
        controller: controller,
        position: position,
        scrollDirection: scrollDirection,
        pageSpacing: pageSpacing,
        onSelectionStarted: onSelectionStarted,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderPdfSelectionRegion object,
  ) {
    object
      ..document = document
      ..controller = controller
      ..position = position
      ..scrollDirection = scrollDirection
      ..pageSpacing = pageSpacing
      ..onSelectionStarted = onSelectionStarted;
  }
}

/// Owns a drag selection at document level, so pointer capture can cross from
/// the page where the drag began into neighbouring pages.
final class RenderPdfSelectionRegion extends RenderSingleChildBox
    implements PointerEventTarget {
  RenderPdfSelectionRegion({
    required PdfDocument document,
    required PdfViewController controller,
    required ScrollPosition position,
    required Axis scrollDirection,
    required double pageSpacing,
    this.onSelectionStarted,
    super.child,
  })  : _document = document,
        _controller = controller,
        _position = position,
        _scrollDirection = scrollDirection,
        _pageSpacing = pageSpacing;

  PdfDocument _document;
  PdfViewController _controller;
  ScrollPosition _position;
  Axis _scrollDirection;
  double _pageSpacing;
  void Function()? onSelectionStarted;
  int? _pointer;
  int _anchorPage = 1;
  int _anchorOffset = 0;

  bool get _vertical => _scrollDirection == Axis.vertical;

  set document(PdfDocument value) => _document = value;
  set controller(PdfViewController value) => _controller = value;
  set position(ScrollPosition value) => _position = value;
  set scrollDirection(Axis value) => _scrollDirection = value;
  set pageSpacing(double value) => _pageSpacing = value;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child.size);
    child.parentData!.offset = Offset.zero;
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void handlePointerEvent(PointerEvent event) {
    switch (event) {
      case PointerDownEvent(
          button: PointerButton.primary,
          kind: PointerKind.mouse || PointerKind.stylus,
          clickCount: 1,
        ):
        final ({int page, int offset})? hit =
            _textPositionAt(event.logicalPosition);
        if (hit == null) return;
        _pointer = event.pointerId;
        _anchorPage = hit.page;
        _anchorOffset = hit.offset;
        onSelectionStarted?.call();
        _controller.selectTextRange(
          _anchorPage,
          _anchorOffset,
          hit.page,
          hit.offset,
        );
      case PointerMoveEvent() when event.pointerId == _pointer:
        _autoScroll(event.logicalPosition);
        final ({int page, int offset})? hit =
            _textPositionAt(event.logicalPosition);
        if (hit == null) return;
        _controller.selectTextRange(
          _anchorPage,
          _anchorOffset,
          hit.page,
          hit.offset,
        );
      case PointerUpEvent() when event.pointerId == _pointer:
      case PointerCancelEvent() when event.pointerId == _pointer:
        _pointer = null;
      default:
        break;
    }
  }

  void _autoScroll(Offset globalPosition) {
    final Offset local = globalToLocal(globalPosition);
    final double coordinate = _vertical ? local.dy : local.dx;
    final double extent = _vertical ? size.height : size.width;
    final double overflow = coordinate < 0
        ? coordinate
        : coordinate > extent
            ? coordinate - extent
            : 0;
    if (overflow != 0) {
      _position.applyDelta(overflow.clamp(-32.0, 32.0));
    }
  }

  ({int page, int offset})? _textPositionAt(Offset globalPosition) {
    if (_document.pageCount == 0 || !hasSize) return null;
    final Offset local = globalToLocal(globalPosition);
    final double contentMain =
        (_vertical ? local.dy : local.dx) + _position.pixels;
    var cursor = 0.0;
    for (var pageNumber = 1; pageNumber <= _document.pageCount; pageNumber++) {
      final page = _document.getPage(pageNumber);
      final double zoom = _controller.zoom;
      final double pageMain = (_vertical ? page.height : page.width) * zoom;
      final bool last = pageNumber == _document.pageCount;
      if (contentMain <= cursor + pageMain + (last ? 0 : _pageSpacing)) {
        final double pageCross = (_vertical ? page.width : page.height) * zoom;
        final double viewportCross = _vertical ? size.width : size.height;
        final double crossStart = (viewportCross - pageCross) / 2;
        final double main = (contentMain - cursor).clamp(0.0, pageMain);
        final double cross = ((_vertical ? local.dx : local.dy) - crossStart)
            .clamp(0.0, pageCross);
        final Offset pageOffset = _vertical
            ? Offset(cross / zoom, main / zoom)
            : Offset(main / zoom, cross / zoom);
        return (
          page: pageNumber,
          offset: _controller
              .textLayoutFor(pageNumber)
              .positionForOffset(pageOffset),
        );
      }
      cursor += pageMain + _pageSpacing;
    }
    final int lastPage = _document.pageCount;
    return (
      page: lastPage,
      offset: _controller.textLayoutFor(lastPage).text.length,
    );
  }
}
