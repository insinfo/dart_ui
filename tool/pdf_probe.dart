import 'dart:io';

import 'package:dart_ui/pdf.dart';

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    stderr.writeln('Usage: dart run tool/pdf_probe.dart <document.pdf>');
    exitCode = 64;
    return;
  }

  final total = Stopwatch()..start();
  final file = File(arguments.first);
  final bytes =
      _measure('read ${file.lengthSync()} bytes', file.readAsBytesSync);
  final document = _measure('parse xref and page tree', () {
    return PdfDocument.fromBytes(bytes);
  });
  stdout.writeln('pages: ${document.pageCount}');
  _measure('resolve page geometry', () {
    for (final page in document.pages) {
      page.size;
    }
  });
  if (arguments.contains('--render-first')) {
    _measure('render first page to display list', () {
      document.getPage(1).renderToMemory();
    });
  }
  if (arguments.contains('--render-all')) {
    for (final page in document.pages) {
      _measure('render page ${page.pageNumber}', page.renderToMemory);
    }
  }
  if (arguments.contains('--validate')) {
    final report =
        _measure('validate', () => const PdfValidator().validate(bytes));
    stdout.writeln('validation issues: ${report.issues.length}');
    for (final issue in report.issues) {
      stdout.writeln('${issue.severity.name} ${issue.code}: ${issue.message}');
    }
  }
  if (arguments.contains('--optimize')) {
    final optimized = _measure(
      'rewrite and optimize',
      () => PdfDocumentComposer.optimize(document),
    );
    stdout.writeln('optimized bytes: ${optimized.length}');
  }
  if (arguments.contains('--images')) {
    final images = _measure(
      'inventory images without decoding',
      () => const PdfImageInventory().inspect(document),
    );
    stdout.writeln('images: ${images.length}');
    for (final image in images) {
      stdout.writeln(
        '  ${image.objectNumber ?? '-'}: ${image.width}x${image.height}, '
        '${image.encodedBytes} encoded bytes, ${image.filters.join('+')}',
      );
    }
  }
  stdout.writeln('total: ${total.elapsedMilliseconds} ms');
}

T _measure<T>(String label, T Function() action) {
  final stopwatch = Stopwatch()..start();
  final result = action();
  stdout.writeln('$label: ${stopwatch.elapsedMilliseconds} ms');
  return result;
}
