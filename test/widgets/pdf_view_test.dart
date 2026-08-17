import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

PdfDocument _document() {
  final PdfDocumentBuilder builder = PdfDocumentBuilder();
  for (var page = 1; page <= 3; page++) {
    builder.addPage(width: 300, height: 400).drawText(
          'Conteudo da pagina $page',
          const Offset(30, 50),
          fontSize: 14,
        );
  }
  return PdfDocument.fromBytes(builder.build());
}

void _settle(BuildOwner owner, {int maxPasses = 20}) {
  for (var pass = 0; pass < maxPasses; pass++) {
    if (owner.hasScheduledBuilds) owner.buildScope();
    owner.pipelineOwner.drawFrame(DisplayList());
    if (!owner.hasScheduledBuilds) return;
  }
  throw StateError('PdfView did not settle after $maxPasses passes.');
}

T _find<T extends RenderBox>(RenderBox root) {
  T? result;
  void visit(RenderBox node) {
    if (node is T) result ??= node;
    if (result == null) node.visitChildren(visit);
  }

  visit(root);
  if (result == null) throw StateError('$T not found');
  return result!;
}

void main() {
  test('zoom and page navigation settle without rebuilding indefinitely', () {
    final PdfViewController controller = PdfViewController();
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(800, 600)),
      ),
    );
    addTearDown(owner.dispose);
    owner.updateRoot(PdfView(
      document: _document(),
      controller: controller,
      enableTextSelection: true,
      enablePinchZoom: true,
    ));
    _settle(owner);

    controller.zoomIn();
    _settle(owner);
    expect(controller.zoom, 1.25);
    expect(_find<RenderPdfPage>(owner.renderRoot!).scale, 1.25);

    controller.goToPage(3);
    _settle(owner);
    expect(controller.currentPage, 3);
    expect(_find<RenderScrollGestures>(owner.renderRoot!).position.pixels,
        greaterThan(0));
  });
}
