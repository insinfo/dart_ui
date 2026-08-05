@TestOn('windows')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('creates and releases an ID3D12Device', () async {
    final packageDirectory = File('bin/main.dart').existsSync()
        ? Directory.current.path
        : '${Directory.current.path}${Platform.pathSeparator}'
            'poc${Platform.pathSeparator}poc_15_direct3d12';
    final result = await Process.run(
      Platform.resolvedExecutable,
      const <String>['run', 'bin/main.dart'],
      workingDirectory: packageDirectory,
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('D3D12CreateDevice: success'));
    expect(result.stdout, contains('Direct3D 12 FFI binding works'));
  });
}
