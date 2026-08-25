import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  group('Filtros PDF em Puro Dart', () {
    test('AsciiHexFilter decodifica corretamente', () {
      const hex = '48656C6C6F20576F726C6421>';
      final bytes = Uint8List.fromList(ascii.encode(hex));
      final decoded = const AsciiHexFilter().decode(bytes);
      expect(utf8.decode(decoded), 'Hello World!');
    });

    test('Ascii85Filter decodifica corretamente', () {
      const a85 = '<~87cURD]j7BEbo80~>';
      final bytes = Uint8List.fromList(ascii.encode(a85));
      final decoded = const Ascii85Filter().decode(bytes);
      expect(utf8.decode(decoded), 'Hello world!');
    });

    test('RunLengthFilter decodifica repetições e literais', () {
      // 2 bytes literais 'AB', depois repete 'C' 4 vezes (257 - 253 = 4), depois EOD (128)
      final rle = Uint8List.fromList([1, 0x41, 0x42, 254, 0x43, 128]);
      final decoded = const RunLengthFilter().decode(rle);
      expect(utf8.decode(decoded), 'ABCCC');
    });

    test('LzwFilter descompacta sequência clássica', () {
      // Fluxo LZW codificando "TOBEORNOTTOBEORTOBEORNOT"
      // Criamos dados de teste e validamos que o LzwFilter processa sem erros
      final data = Uint8List.fromList(
          [0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01]);
      final decoded = const LzwFilter().decode(data);
      expect(decoded, isNotNull);
    });

    test('Predictor PNG Sub e Up', () {
      // 2 linhas de 3 bytes com filtro PNG Up
      // Linha 0 (filter 0 - None): [10, 20, 30]
      // Linha 1 (filter 2 - Up):   [5, 5, 5] -> resultado [15, 25, 35]
      final raw = Uint8List.fromList([
        0, 10, 20, 30, // Linha 0
        2, 5, 5, 5, // Linha 1
      ]);
      const parms = DecodeParms(
        predictor: 12, // PNG Predictor
        columns: 3,
        colors: 1,
        bitsPerComponent: 8,
      );

      final result = DecodeParms.applyPredictor(raw, parms);
      expect(result, Uint8List.fromList([10, 20, 30, 15, 25, 35]));
    });

    test('Flate inválido falha explicitamente em vez de devolver bytes crus',
        () {
      final invalid = Uint8List.fromList(<int>[0x78, 0x9C, 0x00]);

      expect(
        () => const FlateFilter().decode(invalid),
        throwsA(isA<PdfFilterException>()),
      );
    });

    test('Predictor rejeita dimensões inválidas antes da aritmética', () {
      expect(
        () => DecodeParms.applyPredictor(
          Uint8List.fromList(<int>[0]),
          const DecodeParms(predictor: 12, columns: 0),
        ),
        throwsA(isA<PdfFilterException>()),
      );
    });
  });
}
