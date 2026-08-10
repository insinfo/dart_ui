import 'dart:io';

import 'package:dart_ui/src/backends/macos/host_locator.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late Set<String> executableFiles;

  String path(String name) =>
      File('${sandbox.path}${Platform.pathSeparator}$name').absolute.path;

  String createFile(String name) {
    final file = File(path(name))..writeAsStringSync('host fixture');
    return file.absolute.path;
  }

  MacosHostLocation resolve({
    String? explicitPath,
    Map<String, String> environment = const <String, String>{},
  }) {
    return MacosHostLocator.resolve(
      explicitPath: explicitPath,
      environment: environment,
      isExecutableFile: executableFiles.contains,
    );
  }

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('dart_ui_host_locator_');
    executableFiles = <String>{};
  });

  tearDown(() {
    sandbox.deleteSync(recursive: true);
  });

  test('explicit path wins before environment and directory candidates', () {
    final explicit = createFile('explicit-host');
    final environmentHost = createFile('environment-host');
    final directory = Directory(path('host-dir'))..createSync();
    final directoryHost = File(
      '${directory.path}${Platform.pathSeparator}$hostBinaryName',
    )..writeAsStringSync('directory host');
    executableFiles.addAll(<String>[
      explicit,
      environmentHost,
      directoryHost.absolute.path,
    ]);

    final result = resolve(
      explicitPath: explicit,
      environment: <String, String>{
        hostBinaryEnvironmentVariable: environmentHost,
        hostDirectoryEnvironmentVariable: directory.path,
      },
    );

    expect(result.binaryPath, explicit);
    expect(result.origin, 'option hostBinaryPath');
    expect(
      result.searched.where((entry) => entry.startsWith('option ')),
      <String>['option hostBinaryPath: $explicit'],
    );
    expect(
      result.searched,
      isNot(contains(startsWith('$hostBinaryEnvironmentVariable:'))),
    );
  });

  test('environment path is tried after an absent explicit path', () {
    final missingExplicit = path('missing-explicit-host');
    final environmentHost = createFile('environment-host');
    executableFiles.add(environmentHost);

    final result = resolve(
      explicitPath: missingExplicit,
      environment: <String, String>{
        hostBinaryEnvironmentVariable: environmentHost,
      },
    );

    expect(result.binaryPath, environmentHost);
    expect(result.origin, hostBinaryEnvironmentVariable);
    final candidates = result.searched
        .where((entry) =>
            entry.startsWith('option hostBinaryPath:') ||
            entry.startsWith('$hostBinaryEnvironmentVariable:'))
        .toList();
    expect(candidates, <String>[
      'option hostBinaryPath: $missingExplicit',
      '$hostBinaryEnvironmentVariable: $environmentHost',
    ]);
  });

  test('directory environment appends the production host basename', () {
    final directory = Directory(path('host-dir'))..createSync();
    final directoryHost = File(
      '${directory.path}${Platform.pathSeparator}$hostBinaryName',
    )..writeAsStringSync('directory host');
    executableFiles.add(directoryHost.absolute.path);

    final result = resolve(
      environment: <String, String>{
        hostDirectoryEnvironmentVariable: directory.path,
      },
    );

    expect(result.binaryPath, directoryHost.absolute.path);
    expect(result.origin, hostDirectoryEnvironmentVariable);
    expect(
      result.searched,
      contains(
        '$hostDirectoryEnvironmentVariable: ${directoryHost.absolute.path}',
      ),
    );
  });

  test('present non-executable host has a permission diagnostic', () {
    final nonExecutable = createFile('non-executable-host');

    final result = resolve(explicitPath: nonExecutable);

    expect(result.found, isFalse);
    final diagnostic = result.diagnostics.firstWhere(
      (entry) =>
          entry.kind == DiagnosticKind.permissionDenied &&
          entry.detail == 'option hostBinaryPath: $nonExecutable',
    );
    expect(diagnostic.message, contains('not executable'));
  });

  test('absent host reports every attempted location and build hint', () {
    final missing = path('missing-host');

    final result = resolve(
      explicitPath: missing,
      environment: const <String, String>{},
    );

    expect(result.found, isFalse);
    expect(
      result.searched,
      contains('option hostBinaryPath: $missing'),
    );
    final diagnostic = result.diagnostics.last;
    expect(diagnostic.kind, DiagnosticKind.missingLibrary);
    expect(diagnostic.message, contains(hostBinaryName));
    expect(diagnostic.detail, contains('searched ${result.searched.length}'));
    expect(diagnostic.detail, contains('clang -fobjc-arc'));
  });
}
