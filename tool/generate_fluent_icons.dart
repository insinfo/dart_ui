/// Generates `lib/src/widgets/fluent_icons.dart` from the code point map of
/// Fluent UI System Icons' resizable font.
///
/// ```
/// dart run tool/generate_fluent_icons.dart FluentSystemIcons-Resizable.json
/// ```
///
/// The map and the font come from
/// https://github.com/microsoft/fluentui-system-icons/tree/main/fonts (MIT).
library;

import 'dart:convert';
import 'dart:io';

const Set<String> _dartKeywords = <String>{
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};

/// `ic_fluent_folder_add_20_filled` -> `folderAddFilled`.
String _identifier(String key) {
  final RegExpMatch? m =
      RegExp(r'^ic_fluent_(.+)_\d+_(regular|filled)$').firstMatch(key);
  if (m == null) throw FormatException('unexpected key', key);
  final List<String> parts = m.group(1)!.split('_');
  final StringBuffer out = StringBuffer(parts.first);
  for (final String part in parts.skip(1)) {
    if (part.isEmpty) continue;
    out
      ..write(part[0].toUpperCase())
      ..write(part.substring(1));
  }
  if (m.group(2) == 'filled') out.write('Filled');
  var name = out.toString();
  if (RegExp(r'^[0-9]').hasMatch(name)) {
    name = 'icon${name[0].toUpperCase()}${name.substring(1)}';
  }
  if (_dartKeywords.contains(name)) name = '${name}Icon';
  return name;
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/generate_fluent_icons.dart <json>');
    exit(64);
  }
  final Map<String, Object?> map =
      (jsonDecode(File(args.first).readAsStringSync()) as Map<String, Object?>);
  final Map<String, int> icons = <String, int>{};
  for (final MapEntry<String, Object?> e in map.entries) {
    icons.putIfAbsent(_identifier(e.key), () => e.value! as int);
  }
  final List<String> names = icons.keys.toList()..sort();
  final StringBuffer out = StringBuffer()
    ..writeln(
        '// GENERATED FILE - DO NOT EDIT. See tool/generate_fluent_icons.dart.')
    ..writeln('// Source: microsoft/fluentui-system-icons, fonts/'
        'FluentSystemIcons-Resizable.json')
    ..writeln('// License: MIT, Copyright (c) 2020 Microsoft Corporation')
    ..writeln()
    ..writeln("import 'icon.dart';")
    ..writeln()
    ..writeln(
        '/// Fluent UI System Icons - the icons of Windows 11 and Microsoft 365,')
    ..writeln('/// regular and filled (`folder`, `folderFilled`).')
    ..writeln('///')
    ..writeln(
        '/// The bundled resizable font is registered by the framework; one glyph')
    ..writeln(
        '/// per icon, drawn at any size: `Icon(FluentIcons.folderFilled, size: 48)`.')
    ..writeln('abstract final class FluentIcons {')
    ..writeln("  static const String fontFamily = 'FluentSystemIcons';")
    ..writeln();
  for (final String name in names) {
    final String hex = icons[name]!.toRadixString(16).toUpperCase();
    out.writeln('  static const IconData $name = '
        'IconData(0x$hex, fontFamily: fontFamily);');
  }
  out.writeln('}');
  File('lib/src/widgets/fluent_icons.dart').writeAsStringSync(out.toString());
  stdout.writeln('${names.length} icons');
}
