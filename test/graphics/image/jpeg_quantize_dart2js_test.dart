// O ramo do dart2js do seletor do JPEG, executado no dart2js.
//
// `jpeg_data.dart` corta em `dart.library.js`, entao `_jpeg_quantize_html.dart`
// so e escolhido pelos backends JavaScript -- e nenhum teste da VM executa o
// que o dart2js de fato executa. `test/backends/web/web_compilation_test.dart`
// prova que o dart2js *aceita* o programa; este arquivo prova que o resultado
// esta certo, que e a outra metade da exigencia do item 4 da secao 69 do
// roteiro.
//
// Ele tambem carrega uma armadilha deliberada: afirma que o ramo *sem* o
// contorno da resposta errada no dart2js. Se um dia esse teste falhar, e
// porque o dart2js passou a acertar os deslocamentos, e a divisao inteira pode
// ser apagada.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'jpeg_quantize_js_probe.dart' as probe;

/// A sonda, relativa a raiz do pacote -- de onde `dart test` roda.
const String _probePath = 'test/graphics/image/jpeg_quantize_js_probe.dart';

String? _nodeExecutable() {
  final String? path = Platform.environment['PATH'];
  if (path == null) {
    return null;
  }
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  for (final String dir in path.split(Platform.isWindows ? ';' : ':')) {
    if (dir.isEmpty) {
      continue;
    }
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) {
      return candidate.path;
    }
  }
  return null;
}

void main() {
  final String? node = _nodeExecutable();

  group('o ramo do dart2js, executado no dart2js', () {
    late Directory output;
    late Map<String, String> lines;

    setUpAll(() {
      if (node == null) {
        return;
      }
      output = Directory.systemTemp.createTempSync('dart_ui_jpeg_js');
      final String js = '${output.path}${Platform.pathSeparator}probe.js';
      final ProcessResult compiled = Process.runSync(
        Platform.resolvedExecutable,
        <String>['compile', 'js', '-O2', '-o', js, _probePath],
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );
      expect(compiled.exitCode, 0,
          reason: 'dart compile js recusou a sonda:\n'
              '${compiled.stdout}\n${compiled.stderr}');

      final ProcessResult ran = Process.runSync(node, <String>[js],
          stdoutEncoding: systemEncoding, stderrEncoding: systemEncoding);
      expect(ran.exitCode, 0,
          reason: 'o node recusou a sonda:\n${ran.stdout}\n${ran.stderr}');

      lines = <String, String>{};
      for (final String line in (ran.stdout as String).split('\n')) {
        final int eq = line.indexOf('=');
        if (eq > 0) {
          lines[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
        }
      }
    });

    tearDownAll(() {
      if (node != null && output.existsSync()) {
        output.deleteSync(recursive: true);
      }
    });

    test('decodifica os mesmos bytes que a VM', () {
      expect(lines['html'], probe.htmlBranchDigest(),
          reason: 'o ramo escolhido pelo dart2js decodificou os blocos de '
              'sonda de um jeito no dart2js e de outro na VM. O contorno de '
              '`shiftR`/`shiftL` em `_jpeg_quantize_html.dart` existe '
              'exatamente para que isso nao aconteca.');
    });

    test('o contorno de 32 bits ainda e necessario', () {
      expect(lines['io'], isNot(probe.ioBranchDigest()),
          reason: 'o ramo sem contorno (`_jpeg_quantize_io.dart`, o que a VM e '
              'o dart2wasm usam) passou a dar o mesmo resultado no dart2js. Se '
              'isso e estavel, o dart2js deixou de precisar do contorno e a '
              'divisao em dois arquivos pode ser apagada, junto com o '
              '`if (dart.library.js)` em `jpeg_data.dart`.');
    });
  }, skip: node == null ? 'node nao esta no PATH' : null);
}
