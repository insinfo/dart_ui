import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('Vector Serialization Tests (SVG & PDF)', () {
    test('VectorSvgCodec exports VectorDocument to SVG XML', () {
      final doc = VectorDocument(docUnits: DocUnit.mm);
      final methods = DocumentMethods(doc);
      final page = doc.getPage(0);
      final layer = doc.getPageLayers(page).first;

      final rect = methods.createRectangle(
        x: 20,
        y: 30,
        width: 100,
        height: 60,
        style: const VectorStyle(
          fill: FillDescriptor.solid(Color(0xFFE91E63)),
          stroke: StrokeDescriptor(color: Color(0xFF880E4F), width: 1.5),
        ),
      );
      methods.addObject(layer, rect);

      final svgXml = VectorSvgCodec.exportToSvg(doc);
      expect(svgXml.contains('<svg'), isTrue);
      expect(svgXml.contains('viewBox="0 0 595.276 841.89"'), isTrue);
      expect(svgXml.contains('<path'), isTrue);
    });

    test('VectorSvgCodec imports SVG XML into VectorDocument', () {
      const svgXml = '''
<svg xmlns="http://www.w3.org/2000/svg" width="400" height="300" viewBox="0 0 400 300">
  <rect x="50" y="50" width="100" height="80" fill="#2196F3" stroke="#0D47A1" stroke-width="2"/>
  <circle cx="200" cy="150" r="50" fill="#FFC107"/>
</svg>
''';

      final doc = VectorSvgCodec.importFromSvg(svgXml);
      expect(doc.pageCount, equals(1));
      final page = doc.getPage(0);
      final layer = doc.getPageLayers(page).first;

      expect(layer.children.length, equals(2));
      expect(layer.children.first, isA<VectorRectangle>());
      expect(layer.children.last, isA<VectorCircle>());
    });

    test('VectorPdfExporter exports VectorDocument to valid PDF bytes', () {
      final doc = VectorDocument(docUnits: DocUnit.mm);
      final methods = DocumentMethods(doc);
      final page = doc.getPage(0);
      final layer = doc.getPageLayers(page).first;

      final circle = methods.createCircle(
        cx: 150,
        cy: 150,
        rx: 60,
        ry: 60,
        style: const VectorStyle(
          fill: FillDescriptor.solid(Color(0xFF4CAF50)),
        ),
      );
      methods.addObject(layer, circle);

      final pdfBytes = VectorPdfExporter.exportToPdf(doc);
      expect(pdfBytes.length, greaterThan(64));

      // PDF magic signature %PDF-1.
      final magic = String.fromCharCodes(pdfBytes.sublist(0, 5));
      expect(magic, equals('%PDF-'));
    });
  });
}
