import 'dart:io';

import 'package:test/test.dart';

import '../tool/parity.dart';
import '../tool/parity_catalog.dart';

/// The parity table may not claim what the editor does not have.
void main() {
  final editor = buildEditor();

  test('every command the table names is registered', () {
    final List<String> unknown = <String>[
      for (final ParityFeature feature in kParityCatalog)
        for (final String id in feature.commands)
          if (!editor.registry.contains(id)) '${feature.name}: $id',
    ];
    expect(unknown, isEmpty);
  });

  test('every test the table cites exists', () {
    final String tests = <String>[
      for (final FileSystemEntity file in Directory('test').listSync())
        if (file is File && file.path.endsWith('.dart'))
          file.readAsStringSync(),
    ].join('\n');
    final List<String> missing = <String>[
      for (final ParityFeature feature in kParityCatalog)
        if (feature.evidence != null && !tests.contains(feature.evidence!))
          feature.evidence!,
    ];
    expect(missing, isEmpty);
  });

  test('doc/paridade.md is the current measurement', () {
    expect(File('doc/paridade.md').readAsStringSync(),
        report(editor.registry, editor.menus),
        reason: 'run dart run tool/parity.dart and commit the result');
  });
}
