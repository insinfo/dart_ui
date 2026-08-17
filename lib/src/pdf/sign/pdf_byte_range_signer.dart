import 'dart:typed_data';
import 'dart:convert';
import '../../crypto/crypto.dart';

/// Gerencia a alocação de espaço e o cálculo de /ByteRange no documento PDF.
class PdfByteRangeSigner {
  /// Retorna um documento PDF com um espaço reservado em branco para a assinatura.
  /// No mundo real, isso exigiria um salvamento incremental adicionando o dicionário /Sig.
  Uint8List allocateSpace(Uint8List documentBytes, {int signatureSize = 8192}) {
    final builder = BytesBuilder();
    builder.add(documentBytes);

    // Simula a adição de um dicionário /Sig ao final (Incremental Update).
    // O PDF signature space é preenchido com zeros em hex (<00000...000>).
    final placeholder = '<${List.filled(signatureSize, '0').join()}>';

    final sigDict = '''
100 0 obj
<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /ETSI.CAdES.detached
   /Contents $placeholder
   /ByteRange [ 0 0000000000 0000000000 0000000000 ]
>>
endobj
''';
    builder.add(utf8.encode(sigDict));

    return builder.takeBytes();
  }

  /// Calcula o array ByteRange exato [ 0 A B C ].
  List<int> calculateByteRange(
      Uint8List documentBytes, int placeholderStart, int placeholderLength) {
    final a = placeholderStart;
    final b = placeholderStart + placeholderLength;
    final c = documentBytes.length - b;
    return [0, a, b, c];
  }

  /// Hasheia os bytes especificados pelo ByteRange.
  Uint8List hashByteRange(Uint8List documentBytes, List<int> byteRange) {
    assert(byteRange.length == 4);
    final a = byteRange[1];
    final b = byteRange[2];
    final c = byteRange[3];

    final part1 = documentBytes.sublist(0, a);
    final part2 = documentBytes.sublist(b, b + c);

    final builder = BytesBuilder();
    builder.add(part1);
    builder.add(part2);

    return Crypto.sha256(builder.takeBytes());
  }
}
