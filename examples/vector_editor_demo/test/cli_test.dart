import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vector_editor_demo/src/cli/vector_cli.dart';

/// The engine with no window: a script of commands in, a drawing out.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('vector_cli'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a script draws, and the drawing is written', () async {
    final File script = File('${dir.path}/script.json')
      ..writeAsStringSync(jsonEncode(<Object?>[
        <String, Object?>{
          'command': 'shape.rectangle',
          'params': <String, Object?>{
            'x': 10,
            'y': 10,
            'width': 80,
            'height': 40,
          },
        },
        <String, Object?>{
          'command': 'object.fill',
          'params': <String, Object?>{'color': '#ff8800'},
        },
        <String, Object?>{
          'command': 'shape.text',
          'params': <String, Object?>{'x': 10, 'y': 90, 'text': 'from a CLI'},
        },
      ]));
    final String svg = '${dir.path}/out.svg';
    final StringBuffer out = StringBuffer();
    final int code = await runVectorCli(
        <String>['run', script.path, '--out', svg],
        out: out);
    expect(code, 0, reason: '$out');
    final String written = File(svg).readAsStringSync();
    expect(written, contains('from a CLI'));
    expect(written.toLowerCase(), contains('ff8800'));
  });

  test('a failing command stops the script with exit code 1', () async {
    final StringBuffer out = StringBuffer();
    final int code = await runVectorCli(<String>['exec', 'object.toCurves'],
        out: out, err: StringBuffer());
    expect(code, 1);
    expect(out.toString(), contains('nothing is selected'));
  });

  test('a command that would need a dialog says which parameter to give',
      () async {
    final StringBuffer out = StringBuffer();
    await runVectorCli(<String>['exec', 'file.save'], out: out);
    expect(out.toString(), contains('give a \\"path\\"'));
  });

  test('commands lists the catalogue as JSON', () async {
    final StringBuffer out = StringBuffer();
    expect(await runVectorCli(<String>['commands'], out: out), 0);
    final List<Object?> commands = jsonDecode(out.toString()) as List<Object?>;
    expect(commands.length, greaterThan(60));
  });
}
