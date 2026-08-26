// Carga do `jpeg_quantize_dart2js_test.dart`. Nao e um `_test.dart`: ele e
// compilado com `dart compile js` e executado no Node, e tambem chamado
// diretamente da VM, para que os dois resultados possam ser comparados.
//
// A saida e o hexadecimal cru dos blocos decodificados, nao um hash: um hash
// de 32 bits calculado em Dart e ele proprio sujeito ao `int` de 53 bits do
// dart2js, que e justamente o que esta sob teste.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/codecs/formats/jpeg/_jpeg_quantize_html.dart'
    as html_impl;
import 'package:dart_ui/src/graphics/image/codecs/formats/jpeg/_jpeg_quantize_io.dart'
    as io_impl;

typedef QuantizeAndInverse = void Function(Int16List quantizationTable,
    Int32List coefBlock, Uint8List dataOut, Int32List dataIn);

/// Quantos blocos entram na assinatura.
const int probeBlocks = 16;

/// Blocos deterministicos, com a forma de um bloco de JPEG real: DC grande e
/// coeficientes AC caindo depressa.
List<Int32List> probeCoefficients() {
  var state = 0x2BAD5EED;
  int next() {
    var x = state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    state = x & 0xFFFFFFFF;
    return state;
  }

  return List<Int32List>.generate(probeBlocks, (_) {
    final block = Int32List(64);
    block[0] = (next() % 512) - 256;
    for (var i = 1; i < 64; i++) {
      block[i] = ((next() % 128) - 64) >> (i ~/ 16);
    }
    return block;
  });
}

Int16List probeQuantizationTable() {
  final table = Int16List(64);
  for (var i = 0; i < 64; i++) {
    table[i] = 1 + ((i * 7) % 96);
  }
  return table;
}

/// Roda [quantize] sobre os blocos de sonda e devolve a saida em hexadecimal.
String probeDigest(QuantizeAndInverse quantize) {
  final table = probeQuantizationTable();
  final buffer = StringBuffer();
  final out = Uint8List(64);
  for (final Int32List block in probeCoefficients()) {
    quantize(table, block, out, Int32List(64));
    for (final int byte in out) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
  }
  return buffer.toString();
}

String htmlBranchDigest() => probeDigest(html_impl.quantizeAndInverse);

String ioBranchDigest() => probeDigest(io_impl.quantizeAndInverse);

void main() {
  print('html=${htmlBranchDigest()}');
  print('io=${ioBranchDigest()}');
}
