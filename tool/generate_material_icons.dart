/// Generates `lib/src/material/icons.dart`: Flutter's `Icons` names, drawn
/// with the bundled classic Material Icons font.
///
/// ```
/// dart run tool/generate_material_icons.dart
/// ```
///
/// Two inputs:
///
///   * `assets/fonts/MaterialIcons-Regular.ttf` (Apache-2.0), whose GSUB
///     ligatures say which glyph each icon *name* is ("add" -> U+E145);
///   * Flutter's `material/icons.dart` under `referencias/flutter-master`
///     (BSD-3, not in the repository), whose doc comments say which icon
///     name each Dart identifier stands for (`ten_k` is "10k").
///
/// Flutter's own font numbers its glyphs differently, so its code points are
/// not reused: each identifier gets the code point the bundled font has for
/// the same name. The `_outlined`, `_rounded` and `_sharp` variants live in
/// fonts this repository does not ship, so they are drawn with the regular
/// glyph - the app compiles and shows the right symbol in the filled style.
/// A name the font does not have at all is left out (a compile error that
/// names the icon, rather than a blank square at run time).
library;

import 'dart:io';
import 'dart:typed_data';

const String _font = 'assets/fonts/MaterialIcons-Regular.ttf';
const String _flutterIcons =
    'referencias/flutter-master/packages/flutter/lib/src/material/icons.dart';
const String _output = 'lib/src/material/icons.dart';

void main() {
  final Map<String, int> byName = _ligatures(File(_font).readAsBytesSync());
  final String source = File(_flutterIcons).readAsStringSync();
  final RegExp entry = RegExp(
    r'<i class="material-icons(?:-[a-z]+)? md-36">([^<]+)</i>[^\n]*\n'
    r'\s*static const IconData (\w+) = IconData\(([^;]*)\);',
  );
  final Map<String, (int, bool)> icons = <String, (int, bool)>{};
  final List<String> missing = <String>[];
  for (final RegExpMatch m in entry.allMatches(source)) {
    final String iconName = m.group(1)!;
    final String identifier = m.group(2)!;
    final bool mirrors = m.group(3)!.contains('matchTextDirection: true');
    final int? codePoint = byName[iconName];
    if (codePoint == null) {
      missing.add(identifier);
      continue;
    }
    icons.putIfAbsent(identifier, () => (codePoint, mirrors));
  }
  final List<String> names = icons.keys.toList()..sort();
  final StringBuffer out = StringBuffer()
    ..writeln('// GENERATED FILE - DO NOT EDIT. '
        'See tool/generate_material_icons.dart.')
    ..writeln('//')
    ..writeln('// Identifiers: Flutter, packages/flutter/lib/src/material/'
        'icons.dart.')
    ..writeln('// Copyright 2014 The Flutter Authors. All rights reserved.')
    ..writeln('// Use of this source code is governed by a BSD-style license '
        'that can be')
    ..writeln('// found in the LICENSE file.')
    ..writeln('//')
    ..writeln('// Code points: the classic Material Icons font, '
        'assets/fonts/MaterialIcons-Regular.ttf,')
    ..writeln('// Copyright Google LLC, licensed under the Apache License 2.0.')
    ..writeln()
    ..writeln('// ignore_for_file: constant_identifier_names')
    ..writeln()
    ..writeln('/// Flutter\'s material icons.')
    ..writeln('library;')
    ..writeln()
    ..writeln("import '../widgets/icon.dart';")
    ..writeln()
    ..writeln('/// Flutter\'s `Icons`: `Icon(Icons.add)`, '
        '`Icons.arrow_back`, `Icons.home_outlined`.')
    ..writeln('///')
    ..writeln('/// Drawn with the bundled classic Material Icons font, '
        'which the framework')
    ..writeln('/// registers by itself. Differences from Flutter:')
    ..writeln('///')
    ..writeln('///   * the `_outlined`, `_rounded` and `_sharp` variants '
        'draw the regular')
    ..writeln('///     (filled) glyph - their fonts are not bundled;')
    ..writeln('///   * the ${missing.length} names the classic font has no '
        'glyph for are absent, so')
    ..writeln('///     using one is a compile error rather than an '
        'empty square;')
    ..writeln('///   * the code points are the classic font\'s, not '
        'Flutter\'s: compare icons')
    ..writeln('///     by name, not by `codePoint`.')
    ..writeln('abstract final class Icons {')
    ..writeln("  static const String _family = 'Material Icons';")
    ..writeln();
  for (final String name in names) {
    final (int codePoint, bool mirrors) = icons[name]!;
    final String hex = codePoint.toRadixString(16).toUpperCase();
    out.writeln(mirrors
        ? '  static const IconData $name = IconData(0x$hex, '
            'fontFamily: _family, matchTextDirection: true);'
        : '  static const IconData $name = '
            'IconData(0x$hex, fontFamily: _family);');
  }
  out.writeln('}');
  File(_output).writeAsStringSync(out.toString());
  stdout.writeln('${names.length} icons, ${missing.length} without a glyph');
}

/// Every ligature in [font]'s GSUB table, as icon name -> code point.
Map<String, int> _ligatures(Uint8List font) {
  final ByteData d = ByteData.sublistView(font);
  final Map<String, int> tables = <String, int>{};
  final int count = d.getUint16(4);
  for (int i = 0; i < count; i++) {
    final int at = 12 + 16 * i;
    tables[String.fromCharCodes(font.sublist(at, at + 4))] =
        d.getUint32(at + 8);
  }
  final (Map<int, int> glyphToChar, Map<int, int> glyphToCode) =
      _cmap(d, tables['cmap']!);
  final Map<String, int> out = <String, int>{};
  final int gsub = tables['GSUB']!;
  final int lookups = gsub + d.getUint16(gsub + 8);
  final int lookupCount = d.getUint16(lookups);
  for (int l = 0; l < lookupCount; l++) {
    final int lookup = lookups + d.getUint16(lookups + 2 + 2 * l);
    int type = d.getUint16(lookup);
    final int subCount = d.getUint16(lookup + 4);
    for (int s = 0; s < subCount; s++) {
      int sub = lookup + d.getUint16(lookup + 6 + 2 * s);
      if (type == 7) {
        type = d.getUint16(sub + 2);
        sub = sub + d.getUint32(sub + 4);
      }
      if (type != 4) continue;
      final List<int> covered = _coverage(d, sub + d.getUint16(sub + 2));
      final int setCount = d.getUint16(sub + 4);
      for (int k = 0; k < setCount; k++) {
        final int set = sub + d.getUint16(sub + 6 + 2 * k);
        final int ligCount = d.getUint16(set);
        for (int g = 0; g < ligCount; g++) {
          final int lig = set + d.getUint16(set + 2 + 2 * g);
          final int glyph = d.getUint16(lig);
          final int components = d.getUint16(lig + 2);
          final List<int> chars = <int>[glyphToChar[covered[k]] ?? 0];
          for (int c = 1; c < components; c++) {
            chars.add(glyphToChar[d.getUint16(lig + 2 + 2 * c)] ?? 0);
          }
          final int? code = glyphToCode[glyph];
          if (code == null || chars.contains(0)) continue;
          out.putIfAbsent(String.fromCharCodes(chars), () => code);
        }
      }
    }
  }
  return out;
}

/// The glyphs of a coverage table, in coverage order.
List<int> _coverage(ByteData d, int at) {
  final int format = d.getUint16(at);
  final int n = d.getUint16(at + 2);
  if (format == 1) {
    return <int>[for (int i = 0; i < n; i++) d.getUint16(at + 4 + 2 * i)];
  }
  final List<int> out = <int>[];
  for (int i = 0; i < n; i++) {
    final int r = at + 4 + 6 * i;
    for (int g = d.getUint16(r); g <= d.getUint16(r + 2); g++) {
      out.add(g);
    }
  }
  return out;
}

/// The (3, 1) format 4 subtable, split into the ASCII the names are spelled
/// with (glyph -> character) and everything above it (glyph -> code point).
(Map<int, int>, Map<int, int>) _cmap(ByteData d, int cmap) {
  final Map<int, int> ascii = <int, int>{};
  final Map<int, int> icons = <int, int>{};
  final int count = d.getUint16(cmap + 2);
  for (int i = 0; i < count; i++) {
    final int rec = cmap + 4 + 8 * i;
    if (d.getUint16(rec) != 3 || d.getUint16(rec + 2) != 1) continue;
    final int t = cmap + d.getUint32(rec + 4);
    if (d.getUint16(t) != 4) continue;
    final int segX2 = d.getUint16(t + 6);
    final int ends = t + 14;
    final int starts = ends + segX2 + 2;
    final int deltas = starts + segX2;
    final int ranges = deltas + segX2;
    for (int s = 0; s < segX2 ~/ 2; s++) {
      final int end = d.getUint16(ends + 2 * s);
      final int start = d.getUint16(starts + 2 * s);
      final int delta = d.getUint16(deltas + 2 * s);
      final int range = d.getUint16(ranges + 2 * s);
      for (int c = start; c <= end && c != 0xFFFF; c++) {
        int glyph;
        if (range == 0) {
          glyph = (c + delta) & 0xFFFF;
        } else {
          final int at = ranges + 2 * s + range + 2 * (c - start);
          glyph = d.getUint16(at);
          if (glyph != 0) glyph = (glyph + delta) & 0xFFFF;
        }
        if (glyph == 0) continue;
        if (c < 0x80) {
          ascii[glyph] = c;
        } else {
          icons.putIfAbsent(glyph, () => c);
        }
      }
    }
  }
  return (ascii, icons);
}
