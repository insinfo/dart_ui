import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/crypto/crypto.dart';
import 'package:dart_ui/src/crypto/dart/pure_dart_crypto_backend.dart';
import 'package:test/test.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Referência independente do backend ativo: o que o caminho nativo produzir
/// tem que bater com isto.
const PureDartCryptoBackend _pure = PureDartCryptoBackend();

Uint8List _ascii(String value) => Uint8List.fromList(ascii.encode(value));

void main() {
  group('MD5 incremental (Crypto.md5Sink)', () {
    test('sem dados devolve o digest da entrada vazia', () {
      expect(
          _hex(Crypto.md5Sink().close()), 'd41d8cd98f00b204e9800998ecf8427e');
    });

    test('bate com o vetor RFC 1321 quando alimentado byte a byte', () {
      final sink = Crypto.md5Sink();
      for (final byte in _ascii('abc')) {
        sink.add([byte]);
      }

      expect(_hex(sink.close()), '900150983cd24fb0d6963f7d28e17f72');
    });

    test('close() e idempotente', () {
      final sink = Crypto.md5Sink()..add(_ascii('abc'));
      final first = _hex(sink.close());

      expect(_hex(sink.close()), first);
    });

    test('add() apos close() e erro', () {
      final sink = Crypto.md5Sink()..add(_ascii('abc'));
      sink.close();

      expect(() => sink.add(_ascii('def')), throwsStateError);
    });

    // O padding do MD5 muda de forma conforme o resto cai antes, em cima ou
    // depois do byte 56 do bloco de 64 - e o caminho incremental so acerta se
    // costurar os pedacos sem olhar para onde cada `add` termina.
    test('independe de como a entrada e fatiada', () {
      final million = Uint8List(1000000)..fillRange(0, 1000000, 0x61);
      const expected = '7707d6ae4e027c70eea2a935c2296f21';

      expect(_hex(Crypto.md5(million)), expected,
          reason: 'one-shot precisa bater antes de comparar o incremental');

      for (final chunk in [1, 7, 55, 56, 57, 63, 64, 65, 127, 1000, 4096]) {
        final sink = Crypto.md5Sink();
        for (var offset = 0; offset < million.length; offset += chunk) {
          final end = (offset + chunk).clamp(0, million.length);
          sink.add(Uint8List.sublistView(million, offset, end));
        }

        expect(_hex(sink.close()), expected, reason: 'pedacos de $chunk bytes');
      }
    });

    test('acompanha o Dart puro em tamanhos ao redor das fronteiras de bloco',
        () {
      var seed = 12345;
      int next() => seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;

      for (final size in [0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 1023, 9973]) {
        final data = Uint8List(size);
        for (var i = 0; i < size; i++) {
          data[i] = next() & 0xFF;
        }
        final expected = _hex(_pure.md5(data));

        expect(_hex(Crypto.md5(data)), expected,
            reason: 'one-shot, $size bytes');

        // Fatias de tamanho irregular, para nao alinhar com bloco nenhum.
        final sink = Crypto.md5Sink();
        var offset = 0;
        while (offset < size) {
          final end = (offset + (next() % 17) + 1).clamp(0, size);
          sink.add(Uint8List.sublistView(data, offset, end));
          offset = end;
        }

        expect(_hex(sink.close()), expected,
            reason: 'incremental, $size bytes');
      }
    });
  });

  group('Digests one-shot no backend ativo', () {
    test('MD5 atende aos vetores RFC 1321', () {
      expect(
          _hex(Crypto.md5(Uint8List(0))), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(
          _hex(Crypto.md5(_ascii('abc'))), '900150983cd24fb0d6963f7d28e17f72');
      expect(
          _hex(Crypto.md5(
              _ascii('The quick brown fox jumps over the lazy dog'))),
          '9e107d9d372bb6826bd81d3542a419d6');
    });

    test('SHA-384 e SHA-512 atendem aos vetores NIST', () {
      expect(
          _hex(Crypto.sha384(_ascii('abc'))),
          'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed'
          '8086072ba1e7cc2358baeca134c825a7');
      expect(
          _hex(Crypto.sha512(_ascii('abc'))),
          'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
          '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f');
    });
  });
}
