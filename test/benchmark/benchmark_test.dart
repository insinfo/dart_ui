import 'dart:typed_data';

import 'package:dart_ui/src/cdr/document/cdr_document.dart';
import 'package:dart_ui/src/pdf/document/pdf_document.dart';
import 'package:test/test.dart';

void main() {
  group('Engine Performance & Stress Benchmarks', () {
    test('PdfDocument - Stress Parsing', () {
      // Cria um dummy PDF em memória
      final dummyPdfBytes = Uint8List.fromList([
        0x25,
        0x50,
        0x44,
        0x46,
        0x2D,
        0x31,
        0x2E,
        0x37,
        0x0A,
        0x78,
        0x72,
        0x65,
        0x66,
        0x0A,
        0x30,
        0x20,
        0x30,
        0x0A,
        0x74,
        0x72,
        0x61,
        0x69,
        0x6C,
        0x65,
        0x72,
        0x0A,
        0x3C,
        0x3C,
        0x3E,
        0x3E,
        0x0A,
        0x73,
        0x74,
        0x61,
        0x72,
        0x74,
        0x78,
        0x72,
        0x65,
        0x66,
        0x0A,
        0x39,
        0x0A,
        0x25,
        0x25,
        0x45,
        0x4F,
        0x46,
        0x0A
      ]);

      final stopwatch = Stopwatch()..start();

      const iterations = 10000;
      for (var i = 0; i < iterations; i++) {
        PdfDocument.fromBytes(dummyPdfBytes);
      }

      stopwatch.stop();
      final ms = stopwatch.elapsedMilliseconds;

      print(
          'Parsed $iterations PDFs in ${ms}ms (${(iterations / (ms == 0 ? 1 : ms) * 1000).toStringAsFixed(2)} docs/sec)');

      // Valida performance mínima (menos de 5 segundos para 10k parse cycles)
      expect(ms, lessThan(5000));
    });

    test('CdrDocument - Stress Parsing', () {
      final cdrBytes = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, // 'RIFF'
        0x00, 0x00, 0x00, 0x00, // Size (0)
        0x43, 0x44, 0x52, 0x36, // 'CDR6'
        0x76, 0x72, 0x73, 0x6E // 'vrsn'
      ]);

      final stopwatch = Stopwatch()..start();

      const iterations = 50000;
      for (var i = 0; i < iterations; i++) {
        CdrDocument.fromBytes(cdrBytes);
      }

      stopwatch.stop();
      final ms = stopwatch.elapsedMilliseconds;

      print(
          'Parsed $iterations CDRs in ${ms}ms (${(iterations / (ms == 0 ? 1 : ms) * 1000).toStringAsFixed(2)} docs/sec)');

      // Valida performance mínima
      expect(ms, lessThan(3000));
    });
  });
}
