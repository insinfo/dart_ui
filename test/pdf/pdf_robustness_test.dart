import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  group('PDF malformed input boundaries', () {
    test('a bad startxref falls back to object repair and recovers the catalog',
        () {
      const source = '%PDF-1.4\n'
          '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'
          '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'
          '3 0 obj\n<< /Type /Page /Parent 2 0 R '
          '/MediaBox [0 0 200 300] >>\nendobj\n'
          'startxref\n7\n%%EOF';

      final document = PdfDocument.fromBytes(_bytes(source));

      expect(document.pageCount, 1);
      expect(document.getPage(1).width, 200);
      expect(document.getPage(1).height, 300);
    });

    test('nested arrays stop at the configured structural limit', () {
      final parser = PdfParser(
        PdfLexer(ByteReader(_bytes('[[[[0]]]]'))),
        limits: const PdfLimits(maxObjectNesting: 3),
      );

      expect(parser.parseObject, throwsA(isA<PdfFormatException>()));
    });

    test('a circular page tree terminates without overflowing the stack', () {
      const source = '%PDF-1.4\n'
          '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'
          '2 0 obj\n<< /Type /Pages /Kids [2 0 R] /Count 1 >>\nendobj\n'
          'startxref\n999999\n%%EOF';

      final document = PdfDocument.fromBytes(_bytes(source));

      expect(document.pageCount, 0);
    });

    test('an absurd classic xref count is bounded and repaired quickly', () {
      const prefix = '%PDF-1.4\n'
          '1 0 obj\n<< /Type /Catalog >>\nendobj\n';
      final source = '$prefix'
          'xref\n0 2147483647\n'
          'trailer\n<< /Size 2147483647 /Root 1 0 R >>\n'
          'startxref\n${latin1.encode(prefix).length}\n%%EOF';

      final document = PdfDocument.fromBytes(
        _bytes(source),
        limits: const PdfLimits(maxXRefEntries: 32),
      );

      expect(document.pageCount, 0);
    });
  });
}

Uint8List _bytes(String value) => Uint8List.fromList(latin1.encode(value));
