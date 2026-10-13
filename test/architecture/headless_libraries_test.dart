import 'dart:io';

import 'package:test/test.dart';

/// The libraries an engine with no window is built on must not reach a
/// widget, a layout or a windowing backend - not even through an import of
/// an import. Otherwise "the engine runs from a command line" is a claim and
/// not a property.
void main() {
  /// Every file reachable from [entry] through import and export
  /// directives, inside lib/.
  Set<String> reachable(String entry) {
    final Set<String> seen = <String>{};
    final List<String> queue = <String>[entry];
    // A whole directive, conditional alternatives included:
    // `import 'a.dart' if (dart.library.io) 'b.dart' as x;`
    final RegExp directive =
        RegExp(r'^(?:import|export)\s[^;]*;', multiLine: true);
    final RegExp uri = RegExp(r"'([^']+)'");
    while (queue.isNotEmpty) {
      final String path = queue.removeLast();
      if (!seen.add(path)) continue;
      final String source = File(path).readAsStringSync();
      for (final RegExpMatch statement in directive.allMatches(source)) {
        for (final RegExpMatch target in uri.allMatches(statement.group(0)!)) {
          final String name = target.group(1)!;
          if (name.startsWith('dart:') || name.startsWith('package:')) continue;
          queue.add(File(path).parent.uri.resolve(name).toFilePath());
        }
      }
    }
    return seen;
  }

  for (final String library in <String>[
    'lib/commands.dart',
    'lib/vector.dart'
  ]) {
    test('$library reaches no widget, layout or backend', () {
      final String root = Directory.current.absolute.path;
      final List<String> forbidden = <String>[
        for (final String path in reachable('$root/$library'))
          if (RegExp(r'/lib/src/(widgets|layout|backends|app|gestures)/')
              .hasMatch(path))
            path.substring(root.length + 1),
      ]..sort();
      expect(forbidden, isEmpty);
    });
  }
}
