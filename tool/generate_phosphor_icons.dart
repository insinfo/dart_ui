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

String _identifier(String iconName) {
  final List<String> parts = iconName.split('-');
  final StringBuffer result = StringBuffer(parts.first);
  for (final String part in parts.skip(1)) {
    result
      ..write(part[0].toUpperCase())
      ..write(part.substring(1));
  }
  var value = result.toString();
  if (RegExp(r'^\d').hasMatch(value)) value = 'icon$value';
  if (_dartKeywords.contains(value)) value = '${value}Icon';
  return value;
}

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/generate_phosphor_icons.dart '
      '<selection.json> <output.dart>',
    );
    exitCode = 64;
    return;
  }

  final Map<String, Object?> selection =
      jsonDecode(File(arguments[0]).readAsStringSync()) as Map<String, Object?>;
  final List<Object?> icons = selection['icons']! as List<Object?>;
  final Map<String, int> generated = <String, int>{};
  for (final Object? rawIcon in icons) {
    final Map<String, Object?> icon = rawIcon! as Map<String, Object?>;
    final Map<String, Object?> properties =
        icon['properties']! as Map<String, Object?>;
    final int codePoint = properties['code']! as int;
    final List<String> aliases =
        (properties['name']! as String).split(',').map((String name) {
      return name.trim();
    }).toList(growable: false);
    for (final String alias in aliases) {
      final String identifier = _identifier(alias);
      if (generated.putIfAbsent(identifier, () => codePoint) != codePoint) {
        throw StateError('Conflicting generated identifier: $identifier');
      }
    }
  }

  final StringBuffer output = StringBuffer()
    ..writeln('// GENERATED FILE - DO NOT EDIT.')
    ..writeln('// Source: @phosphor-icons/web 2.1.2, regular/selection.json')
    ..writeln('// License: MIT, Copyright (c) 2020-2021 Phosphor Icons')
    ..writeln()
    ..writeln("import 'icon.dart';")
    ..writeln()
    ..writeln('/// Phosphor Icons 2.1.2 regular glyphs.')
    ..writeln('///')
    ..writeln(
        '/// The bundled font is registered automatically by the framework.')
    ..writeln('/// Use these values with [Icon], for example:')
    ..writeln('/// `Icon(PhosphorIcons.floppyDisk)`.')
    ..writeln('abstract final class PhosphorIcons {')
    ..writeln("  static const String fontFamily = 'Phosphor';")
    ..writeln();
  for (final MapEntry<String, int> entry in generated.entries) {
    output.writeln(
      '  static const IconData ${entry.key} = '
      'IconData(0x${entry.value.toRadixString(16).toUpperCase()}, '
      'fontFamily: fontFamily);',
    );
  }
  output.writeln('}');
  File(arguments[1]).writeAsStringSync(output.toString());
}
