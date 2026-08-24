import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('CDR and VectorDocument Integration Tests', () {
    test('CdrTranslator serializes VectorDocument to valid RIFF CDR bytes', () {
      final doc = VectorDocument(docUnits: DocUnit.mm);
      final methods = DocumentMethods(doc);
      final page = doc.getPage(0);
      final layer = doc.getPageLayers(page).first;

      final rect = methods.createRectangle(
        x: 50,
        y: 60,
        width: 120,
        height: 80,
        style: const VectorStyle(
          fill: FillDescriptor.solid(Color(0xFFFF0000)),
          stroke: StrokeDescriptor(color: Color(0xFF0000FF), width: 2.0),
        ),
      );
      methods.addObject(layer, rect);

      final cdrBytes = CdrTranslator.toCdrBytes(doc);
      expect(cdrBytes.length, greaterThan(32));

      // Validate RIFF header
      final header = String.fromCharCodes(cdrBytes.sublist(0, 4));
      expect(header, equals('RIFF'));

      final format = String.fromCharCodes(cdrBytes.sublist(8, 12));
      expect(format, equals('CDR6'));
    });

    test('CdrDocument parses generated CDR bytes and converts back to VectorDocument', () {
      final doc = VectorDocument(docUnits: DocUnit.mm);
      final methods = DocumentMethods(doc);
      final page = doc.getPage(0);
      final layer = doc.getPageLayers(page).first;

      final circle = methods.createCircle(
        cx: 100,
        cy: 100,
        rx: 40,
        ry: 40,
        style: const VectorStyle(
          fill: FillDescriptor.solid(Color(0xFF00FF00)),
        ),
      );
      methods.addObject(layer, circle);

      final cdrBytes = CdrTranslator.toCdrBytes(doc);
      final cdrDoc = CdrDocument.fromBytes(Uint8List.fromList(cdrBytes));

      expect(cdrDoc.version, equals(CdrVersion.v6));
      expect(cdrDoc.paths.isNotEmpty, isTrue);

      final importedDoc = cdrDoc.toVectorDocument();
      expect(importedDoc.pageCount, greaterThanOrEqualTo(1));
    });
  });
}
