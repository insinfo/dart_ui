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
}
