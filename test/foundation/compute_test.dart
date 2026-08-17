import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

int _currentIsolateId(Object? _) => Isolate.current.hashCode;

int _double(int value) => value * 2;

Never _fail(Object? _) => throw StateError('background failure');

PdfDocument _parsePdf(Uint8List bytes) => PdfDocument.fromBytes(bytes);

void main() {
  test('compute executes on a different native isolate', () async {
    final int worker = await compute<Object?, int>(
      _currentIsolateId,
      null,
      debugLabel: 'compute.test',
    );

    expect(worker, isNot(Isolate.current.hashCode));
  });

  test('compute returns values and forwards typed failures', () async {
    expect(await compute<int, int>(_double, 21), 42);
    await expectLater(
      compute<Object?, Never>(_fail, null),
      throwsA(isA<StateError>()),
    );
  });

  test('parsed PDF model crosses the isolate boundary intact', () async {
    final PdfDocumentBuilder builder = PdfDocumentBuilder();
    builder
        .addPage(width: 240, height: 320)
        .drawText('Isolate PDF', const Offset(20, 40));

    final PdfDocument document = await compute<Uint8List, PdfDocument>(
      _parsePdf,
      builder.build(),
      debugLabel: 'pdf.parse.test',
    );

    expect(document.pageCount, 1);
    expect(
      PdfTextExtractor(document.getPage(1)).extract().text,
      contains('Isolate PDF'),
    );
  });
}
