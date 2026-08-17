import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

Framebuffer _render(PdfPageView widget, Size viewport) {
  final PipelineOwner pipeline = PipelineOwner(
    rootConstraints: BoxConstraints.tight(viewport),
  );
  final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
    ..updateRoot(widget);
  addTearDown(owner.dispose);
  pipeline.flushLayout();
  final DisplayList list = DisplayList();
  pipeline.flushPaint(list);
  final Framebuffer surface = Framebuffer.allocate(
    width: viewport.width.round(),
    height: viewport.height.round(),
  )..clear(0, 0, 0, 255);
  rasterizeDisplayList(list, surface);
  return surface;
}

int _argbAt(Framebuffer surface, int x, int y) {
  final int offset = surface.offsetOf(x, y);
  return surface.pixels[offset + 3] << 24 |
      surface.pixels[offset + 2] << 16 |
      surface.pixels[offset + 1] << 8 |
      surface.pixels[offset];
}

void main() {
  test('PDF pages paint vector content through the ordinary display list', () {
    final PdfDocumentBuilder builder = PdfDocumentBuilder();
    builder.addPage(width: 20, height: 20).drawRect(
          const Rect.fromLTWH(5, 5, 10, 10),
          fillColor: 0xFFFF0000,
        );
    final PdfPage page = PdfDocument.fromBytes(builder.build()).getPage(1);

    final Framebuffer surface = _render(
      PdfPageView(page: page),
      const Size(20, 20),
    );

    expect(_argbAt(surface, 10, 10), 0xFFFF0000);
    expect(_argbAt(surface, 1, 1), 0xFFFFFFFF);
  });

  test('page scale participates in natural layout and painting', () {
    final PdfDocumentBuilder builder = PdfDocumentBuilder();
    builder.addPage(width: 10, height: 10).drawRect(
          const Rect.fromLTWH(0, 0, 10, 10),
          fillColor: 0xFF2563EB,
        );
    final PdfPage page = PdfDocument.fromBytes(builder.build()).getPage(1);

    final Framebuffer surface = _render(
      PdfPageView(page: page, scale: 2),
      const Size(20, 20),
    );

    expect(_argbAt(surface, 18, 18), 0xFF2563EB);
  });

  test('mouse drag reports a selectable range from PDF text geometry', () {
    final PdfDocumentBuilder builder = PdfDocumentBuilder();
    builder.addPage(width: 300, height: 100).drawText(
          'Texto selecionavel',
          const Offset(30, 40),
          fontSize: 16,
        );
    final PdfPage page = PdfDocument.fromBytes(builder.build()).getPage(1);
    final PdfPageTextLayout layout = PdfTextExtractor(page).extract();
    final Rect bounds = layout.fragments.single.bounds;
    int base = -1;
    int extent = -1;
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(300, 100)),
      ),
    );
    addTearDown(owner.dispose);
    owner.updateRoot(PdfPageView(
      page: page,
      textLayout: layout,
      enableTextSelection: true,
      onSelectionChanged: (int nextBase, int nextExtent) {
        base = nextBase;
        extent = nextExtent;
      },
    ));
    owner.pipelineOwner.flushLayout();

    owner
        .dispatchPointerEvent(_down(Offset(bounds.left + 1, bounds.center.dy)));
    owner.dispatchPointerEvent(
      _move(Offset(bounds.right - 1, bounds.center.dy)),
    );
    owner.dispatchPointerEvent(_up(Offset(bounds.right - 1, bounds.center.dy)));

    expect(base, 0);
    expect(extent, greaterThan(10));
  });
}

const NativeWindowId _window = NativeWindowId(1);

PointerDownEvent _down(Offset position) => PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 1,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );

PointerMoveEvent _move(Offset position) => PointerMoveEvent(
      windowId: _window,
      generation: 1,
      timestamp: const Duration(milliseconds: 10),
      pointerId: 1,
      kind: PointerKind.mouse,
      logicalPosition: position,
    );

PointerUpEvent _up(Offset position) => PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: const Duration(milliseconds: 20),
      pointerId: 1,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );
