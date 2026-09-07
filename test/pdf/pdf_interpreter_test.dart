import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_ui/dart_ui.dart';
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

    test('preserva o modo de renderização de texto no dispositivo', () {
      final dev = PdfMemoryOutputDevice();
      PdfContentInterpreter(device: dev).execute(
        Uint8List.fromList(utf8.encode('BT /F1 12 Tf 2 Tr (contorno) Tj ET')),
      );

      expect(dev.commands.single, contains('mode: fillAndStroke'));
    });

    test('v usa o ponto atual como primeiro controle da curva', () {
      final dev = PdfMemoryOutputDevice();
      PdfContentInterpreter(device: dev).execute(
        Uint8List.fromList(utf8.encode('10 20 m 30 40 50 60 v S')),
      );

      final path = dev.paths.single;
      expect(path.verbAt(1), verbCubicTo);
      expect(path.pointAt(1), const Offset(10, 20));
      expect(path.pointAt(2), const Offset(30, 40));
      expect(path.pointAt(3), const Offset(50, 60));
    });

    test('gs aplica transparência e parâmetros de linha de ExtGState', () {
      final resources = PdfDict(<String, PdfObject>{
        'ExtGState': PdfDict(<String, PdfObject>{
          'fade': PdfDict(<String, PdfObject>{
            'CA': const PdfNumber(0.75),
            'ca': const PdfNumber(0.25),
            'LW': const PdfNumber(3),
            'LC': const PdfNumber(1),
            'LJ': const PdfNumber(2),
            'ML': const PdfNumber(8),
            'D': const PdfArray(<PdfObject>[
              PdfArray(<PdfObject>[PdfNumber(2), PdfNumber(1)]),
              PdfNumber(0.5),
            ]),
          }),
        }),
      });
      final interpreter = PdfContentInterpreter(
        device: PdfMemoryOutputDevice(),
        resources: resources,
      )..execute(Uint8List.fromList(utf8.encode('/fade gs')));

      expect(interpreter.currentState.strokeAlpha, 0.75);
      expect(interpreter.currentState.fillAlpha, 0.25);
      expect(interpreter.currentState.lineWidth, 3);
      expect(interpreter.currentState.lineCap, PdfLineCap.round);
      expect(interpreter.currentState.lineJoin, PdfLineJoin.bevel);
      expect(interpreter.currentState.miterLimit, 8);
      expect(interpreter.currentState.dashPattern, <double>[2, 1]);
      expect(interpreter.currentState.dashPhase, 0.5);
    });
  });
}
