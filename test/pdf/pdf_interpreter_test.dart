import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  group('PdfContentInterpreter e PdfOutputDevice', () {
    test('interpreta comandos de caminho, cores e transformações', () {
      const content = '''
        q
        1 0 0 1 50 100 cm
        1 0 0 rg
        0 1 0 RG
        2 w
        10 10 200 150 re
        B
        Q
      ''';

      final dev = PdfMemoryOutputDevice();
      final interpreter = PdfContentInterpreter(device: dev);
      interpreter.execute(Uint8List.fromList(utf8.encode(content)));

      expect(dev.commands.contains('save'), isTrue);
      expect(dev.commands.any((c) => c.startsWith('transform')), isTrue);
      expect(
          dev.commands
              .any((c) => c.startsWith('fill') && c.contains('0xffff0000')),
          isTrue);
      expect(
          dev.commands
              .any((c) => c.startsWith('stroke') && c.contains('0xff00ff00')),
          isTrue);
      expect(dev.commands.contains('restore'), isTrue);
      expect(dev.paths.length, 2); // 1 fill + 1 stroke para 'B'
    });

    test('interpreta comandos de texto', () {
      const content = '''
        BT
        /F1 16 Tf
        100 200 Td
        (Documento Gerado com Sucesso) Tj
        ET
      ''';

      final dev = PdfMemoryOutputDevice();
      final interpreter = PdfContentInterpreter(device: dev);
      interpreter.execute(Uint8List.fromList(utf8.encode(content)));

      expect(
          dev.commands.any((c) => c.contains('Documento Gerado com Sucesso')),
          isTrue);
    });
  });
}
