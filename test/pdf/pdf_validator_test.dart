import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  test('accepts a generated document and reports its page count', () {
    final builder = PdfDocumentBuilder()..addPage();
    final report = const PdfValidator().validate(builder.build());

    expect(report.isValid, isTrue);
    expect(report.pageCount, 1);
    expect(report.signatureCount, 0);
    expect(report.issues, isEmpty);
  });

  test('rejects data without a PDF header', () {
    final report = const PdfValidator().validate(
      Uint8List.fromList(utf8.encode('não é PDF')),
    );

    expect(report.isValid, isFalse);
    expect(report.issues.single.code, 'header.invalid');
  });

  test('reports a missing EOF marker without inventing structural failure', () {
    final bytes = PdfDocumentBuilder()..addPage();
    final complete = bytes.build();
    final text = latin1.decode(complete);
    final truncated = Uint8List.fromList(
      latin1.encode(text.substring(0, text.lastIndexOf('%%EOF'))),
    );
    final report = const PdfValidator().validate(truncated);

    expect(report.issues.map((issue) => issue.code), contains('eof.missing'));
  });
}
