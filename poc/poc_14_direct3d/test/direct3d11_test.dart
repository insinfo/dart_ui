@TestOn('windows')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('creates and releases a D3D11 device and immediate context', () async {
    final packageDirectory = File('bin/main.dart').existsSync()
        ? Directory.current.path
        : '${Directory.current.path}${Platform.pathSeparator}'
            'poc${Platform.pathSeparator}poc_14_direct3d';
    final result = await Process.run(
      Platform.resolvedExecutable,
      const <String>['run', 'bin/main.dart'],
      workingDirectory: packageDirectory,
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('D3D11CreateDevice: success'));
    expect(result.stdout, contains('COM memory lifecycle validated'));
  });
}
