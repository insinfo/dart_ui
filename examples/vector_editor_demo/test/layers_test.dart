import 'dart:io';

import 'package:test/test.dart';

/// The editor's layering, as ports and adapters: the engine is the drawing,
/// the edits and the commands, and imports no user interface - so a command
/// line, a server or another UI framework can drive it. The window is one
/// adapter over it, the command line another.
void main() {
  /// The import and export lines of every Dart file under [dir].
  Map<String, List<String>> directives(String dir) => <String, List<String>>{
        for (final FileSystemEntity entity
            in Directory(dir).listSync(recursive: true))
          if (entity is File && entity.path.endsWith('.dart'))
            entity.path: <String>[
              for (final String line in entity.readAsLinesSync())
                if (line.startsWith('import ') || line.startsWith('export '))
                  line,
            ],
      };

  for (final String layer in <String>['lib/src/engine', 'lib/src/cli']) {
    test('$layer imports only the headless dart_ui libraries', () {
      const Set<String> allowed = <String>{
        'package:dart_ui/commands.dart',
        'package:dart_ui/vector.dart',
      };
      final List<String> violations = <String>[];
      directives(layer).forEach((String path, List<String> lines) {
        for (final String line in lines) {
          final String uri = RegExp(r"'([^']+)'").firstMatch(line)!.group(1)!;
          final bool ok = uri.startsWith('dart:') ||
              allowed.contains(uri) ||
              (!uri.startsWith('package:') && !uri.contains('/ui/'));
          if (!ok) violations.add('$path: $line');
        }
      });
      expect(violations, isEmpty,
          reason:
              'the engine runs with no window: no widgets, no dart_ui.dart');
    });
  }

  test('the command line uses the engine and nothing of the window', () {
    final List<String> violations = <String>[
      for (final String line
          in directives('bin')['bin/vector_cli.dart'] ?? const <String>[])
        if (line.contains('/ui/') || line.contains('dart_ui/dart_ui.dart'))
          line,
    ];
    expect(violations, isEmpty);
  });

  test('the engine has files to check', () {
    expect(directives('lib/src/engine'), isNotEmpty);
  });
}
