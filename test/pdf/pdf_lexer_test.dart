import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  group('PdfLexer', () {
    test('tokeniza delimitadores, nomes, números e booleanos', () {
      const src = '''
        % Comentário de cabeçalho
        << /Type /Catalog /Pages 2 0 R /Version 1.7 /IsActive true /Count 42 >>
      ''';
      final bytes = Uint8List.fromList(utf8.encode(src));
      final lexer = PdfLexer(ByteReader(bytes));

      final t1 = lexer.nextToken();
      expect(t1.isDelimiter('<<'), isTrue);

      final t2 = lexer.nextToken();
      expect(t2.type, PdfTokenType.name);
      expect(t2.text, 'Type');

      final t3 = lexer.nextToken();
      expect(t3.type, PdfTokenType.name);
      expect(t3.text, 'Catalog');

      final t4 = lexer.nextToken();
      expect(t4.type, PdfTokenType.name);
      expect(t4.text, 'Pages');

      final t5 = lexer.nextToken();
      expect(t5.type, PdfTokenType.number);
      expect(t5.numberValue, 2);

      final t6 = lexer.nextToken();
      expect(t6.type, PdfTokenType.number);
      expect(t6.numberValue, 0);

      final t7 = lexer.nextToken();
      expect(t7.isKeyword('R'), isTrue);
    });

    test('tokeniza strings literais com escapes e parênteses aninhados', () {
      const src = r' (Hello (Nested) World\n\t) ';
      final bytes = Uint8List.fromList(utf8.encode(src));
      final lexer = PdfLexer(ByteReader(bytes));

      final token = lexer.nextToken();
      expect(token.type, PdfTokenType.string);
      expect(token.stringBytes, isNotNull);
      expect(utf8.decode(token.stringBytes!), 'Hello (Nested) World\n\t');
    });

    test('tokeniza hex strings', () {
      const src = ' <48656C6C6F> ';
      final bytes = Uint8List.fromList(utf8.encode(src));
      final lexer = PdfLexer(ByteReader(bytes));

      final token = lexer.nextToken();
      expect(token.type, PdfTokenType.hexString);
      expect(utf8.decode(token.stringBytes!), 'Hello');
    });
  });
}
