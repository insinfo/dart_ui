import 'dart:io';

import 'package:test/test.dart';

/// The editor's layering: the engine is the drawing and the commands that
/// change it, and runs with no window; the UI shows it. An engine file that
/// imports a UI file would make the engine need a window, so this fails on
/// the first one.
void main() {
  test('the engine imports nothing from the UI', () {
    final List<String> violations = <String>[];
    for (final FileSystemEntity entity
        in Directory('lib/src/engine').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final List<String> lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (!line.startsWith('import ') && !line.startsWith('export ')) {
          continue;
        }
        if (line.contains('/ui/') || line.contains("'../ui")) {
          violations.add('${entity.path}:${i + 1}: $line');
        }
      }
    }
    expect(violations, isEmpty);
  });

  test('the engine has files to check', () {
    expect(
      Directory('lib/src/engine')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
      isNotEmpty,
    );
  });
}
