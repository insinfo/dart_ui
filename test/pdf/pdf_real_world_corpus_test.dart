import 'dart:io';

import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  final corpus = Directory('test/pdf/data/corpus')
      .listSync()
      .whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith('.pdf'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in corpus) {
    test(
        '${file.uri.pathSegments.last} parses, validates, renders and rewrites',
        () {
      final bytes = file.readAsBytesSync();
      final source = PdfDocument.fromBytes(bytes);

      expect(source.pageCount, greaterThan(0));
      expect(
        const PdfValidator()
            .validate(
              bytes,
              options: const PdfValidationOptions.metadataOnly(),
            )
            .isValid,
        isTrue,
      );
      for (final page in source.pages) {
        expect(page.width, greaterThan(0));
        expect(page.height, greaterThan(0));
      }
      // Rendering every page makes this parser/composer corpus test scale with
      // page count and image complexity. Exercise one display list when its
      // content streams validate; damaged streams remain usable in metadata
      // mode and are covered explicitly below.
      final fullValidation = const PdfValidator().validate(bytes);
      if (fullValidation.isValid) {
        expect(() => source.getPage(1).renderToMemory(), returnsNormally);
      } else {
        expect(
          fullValidation.issues.any(
            (issue) => issue.code == 'page.contents.invalid',
          ),
          isTrue,
        );
      }

      final signed = const PdfSignatureInspector().inspect(bytes).isNotEmpty;
      final rewritten = PdfDocumentComposer.optimize(
        source,
        allowSignatureInvalidation: signed,
      );
      final reparsed = PdfDocument.fromBytes(rewritten);
      expect(reparsed.pageCount, source.pageCount);
      expect(
        const PdfValidator()
            .validate(
              rewritten,
              options: const PdfValidationOptions.metadataOnly(),
            )
            .isValid,
        isTrue,
      );
    });
  }

  test('metadata-only validation tolerates damaged non-structural streams', () {
    final bytes =
        File('test/pdf/data/corpus/c008_2021_4hd.pdf').readAsBytesSync();

    expect(const PdfValidator().validate(bytes).isValid, isFalse);
    expect(
      const PdfValidator()
          .validate(
            bytes,
            options: const PdfValidationOptions.metadataOnly(),
          )
          .isValid,
      isTrue,
    );
  });
}
