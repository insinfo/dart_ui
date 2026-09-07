import 'package:dart_ui/pdf.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:test/test.dart';

void main() {
  PdfDocument document(String label, int pages) {
    final builder = PdfDocumentBuilder(title: label, author: 'Autor');
    for (var index = 0; index < pages; index++) {
      final page = builder.addPage(
        width: (200 + index).toDouble(),
        height: (300 + index).toDouble(),
      );
      page.drawText('$label ${index + 1}', const Offset(20, 30));
    }
    return PdfDocument.fromBytes(builder.build());
  }

  test('merge remaps object graphs and preserves page content', () {
    final merged = PdfDocument.fromBytes(PdfDocumentComposer.merge(
      <PdfDocument>[document('A', 2), document('B', 1)],
      title: 'Documento unido',
      author: 'dart_ui',
    ));

    expect(merged.pageCount, 3);
    expect(merged.title, 'Documento unido');
    expect(merged.author, 'dart_ui');
    expect(merged.getPage(1).width, 200);
    expect(merged.getPage(2).width, 201);
    expect(merged.getPage(3).width, 200);
    expect(
      merged.getPage(3).renderToMemory().commands.join('\n'),
      contains('B 1'),
    );
  });

  test('split creates independently parseable one-page documents', () {
    final parts = PdfDocumentComposer.split(document('Parte', 3));

    expect(parts, hasLength(3));
    for (var index = 0; index < parts.length; index++) {
      final part = PdfDocument.fromBytes(parts[index]);
      expect(part.pageCount, 1);
      expect(part.getPage(1).width, 200 + index);
      expect(
        part.getPage(1).renderToMemory().commands.join('\n'),
        contains('Parte ${index + 1}'),
      );
    }
  });

  test('selective composition supports page extraction and reordering', () {
    final source = document('Página', 3);
    final composer = PdfDocumentComposer(title: 'Reordenado')
      ..addDocument(source, pages: <int>[3, 1]);
    final result = PdfDocument.fromBytes(composer.build());

    expect(result.pageCount, 2);
    expect(result.getPage(1).width, 202);
    expect(result.getPage(2).width, 200);
  });

  test('optimize Flate-compresses suitable streams without changing content',
      () {
    final builder = PdfDocumentBuilder();
    final page = builder.addPage();
    for (var index = 0; index < 200; index++) {
      page.drawText('linha repetida para compressão', Offset(20, 20.0 + index));
    }
    final original = builder.build();
    final optimized = PdfDocumentComposer.optimize(
      PdfDocument.fromBytes(original),
    );
    final result = PdfDocument.fromBytes(optimized);

    expect(optimized.length, lessThan(original.length));
    expect(result.pageCount, 1);
    expect(
      result.getPage(1).renderToMemory().commands.join('\n'),
      contains('linha repetida para compressão'),
    );
  });
}
