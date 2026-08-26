/// Os digests puro-Dart, **executados** sob o dart2js.
///
/// Compilar não basta, e é essa a lição que este arquivo guarda. O gate de
/// `test/backends/web/web_compilation_test.dart` provava que o backend web
/// *compila*, e passava verde enquanto `Crypto.md5`, `Crypto.sha1` e
/// `Crypto.sha256` lançavam `UnsupportedError` na primeira chamada real:
/// `ByteData.setUint64` não existe no dart2js, e o padding de cada um deles
/// escrevia o campo de comprimento com ele. O erro é de execução, não de
/// compilação, então nenhum portão de compilação jamais o veria.
///
/// O backend web usa `PureDartCryptoBackend` como fallback de todos os hashes
/// (a Web Crypto API é assíncrona, e esta interface é síncrona), então esse
/// caminho é o que a web de fato executa — não um detalhe interno.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Vetores conhecidos, para o teste falhar por resultado errado e não apenas
/// por exceção — um padding truncado dá digest errado sem lançar nada.
const Map<String, String> _expected = <String, String>{
  'md5': '900150983cd24fb0d6963f7d28e17f72',
  'sha1': 'a9993e364706816aba3e25717850c26c9cd0d89d',
  'sha256': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  'sha384': 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed'
      '8086072ba1e7cc2358baeca134c825a7',
  'sha512': 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
      '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
};

const String _probe = r'''
import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_ui/src/crypto/crypto.dart';

void main() {
  final Uint8List input = Uint8List.fromList(ascii.encode('abc'));
  final Map<String, Uint8List Function(Uint8List)> hashes =
      <String, Uint8List Function(Uint8List)>{
    'md5': Crypto.md5,
    'sha1': Crypto.sha1,
    'sha256': Crypto.sha256,
    'sha384': Crypto.sha384,
    'sha512': Crypto.sha512,
  };
  final StringBuffer out = StringBuffer();
  for (final MapEntry<String, Uint8List Function(Uint8List)> e
      in hashes.entries) {
    final String hex = e.value(input)
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    out.writeln('${e.key}=$hex');
  }
  print(out.toString().trim());
}
''';

/// Onde o `node` estiver ausente não há o que executar; o teste diz isso em vez
/// de passar sem ter verificado nada.
String? _findNode() {
  final ProcessResult probe = Process.runSync(
    Platform.isWindows ? 'where' : 'which',
    <String>['node'],
    runInShell: true,
  );
  if (probe.exitCode != 0) return null;
  final String out = (probe.stdout as String).trim();
  if (out.isEmpty) return null;
  return out.split(RegExp(r'[\r\n]+')).first.trim();
}

void main() {
  final String? node = _findNode();

  late Directory work;

  setUpAll(() {
    work = Directory.systemTemp.createTempSync('dart_ui_crypto_js');
  });

  tearDownAll(() {
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  test(
    'os hashes puro-Dart rodam sob o dart2js e batem com os vetores conhecidos',
    () {
      // A sonda tem de morar **dentro** do pacote: fora dele o dart2js nao
      // resolve `package:dart_ui`. `.dart_tool` e ignorado pelo git e ja e
      // territorio de artefato.
      final Directory toolDir =
          Directory('${Directory.current.path}/.dart_tool')
            ..createSync(recursive: true);
      final File source = File('${toolDir.path}/crypto_web_probe.dart')
        ..writeAsStringSync(_probe);
      addTearDown(() {
        if (source.existsSync()) source.deleteSync();
      });
      final String outputPath = '${work.path}/probe.js';

      final ProcessResult compiled = Process.runSync(
        Platform.resolvedExecutable,
        <String>['compile', 'js', '-o', outputPath, source.path],
        workingDirectory: Directory.current.path,
      );
      expect(
        compiled.exitCode,
        0,
        reason: 'dart compile js recusou a sonda de crypto:\n'
            '${compiled.stdout}\n${compiled.stderr}',
      );

      final ProcessResult ran = Process.runSync(node!, <String>[outputPath]);
      expect(
        ran.exitCode,
        0,
        reason: 'a sonda compilou mas falhou ao executar sob o dart2js. '
            'É exatamente a classe de defeito que este teste existe para pegar '
            '— `setUint64` compila e lança em tempo de execução.\n'
            '${ran.stdout}\n${ran.stderr}',
      );

      final Map<String, String> got = <String, String>{
        for (final String line in const LineSplitter()
            .convert((ran.stdout as String).trim())
            .where((String l) => l.contains('=')))
          line.split('=').first: line.split('=').last,
      };

      expect(got.keys, unorderedEquals(_expected.keys));
      for (final MapEntry<String, String> e in _expected.entries) {
        expect(got[e.key], e.value, reason: '${e.key} divergiu sob o dart2js');
      }
    },
    skip: node == null
        ? 'node não encontrado no PATH; sem ele não há como executar a saída '
            'do dart2js'
        : null,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
