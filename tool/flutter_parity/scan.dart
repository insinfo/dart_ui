/// Reads a package's public API from its source: the library files' `export`
/// directives (with `show` and `hide`) followed to the files that declare
/// things, and the public top-level names those files declare.
///
/// The same reader serves Flutter (to refresh the snapshot) and dart_ui, so
/// both sides of the comparison are measured the same way. It reads text, not
/// an analyzer model: a declaration at column 0 is what it counts, which is
/// how both code bases are formatted.
library;

import 'dart:io';

/// One public top-level name.
final class ApiName {
  const ApiName(this.library, this.kind, this.name);

  /// For Flutter, the library under `lib/src/` that declares it (`widgets`,
  /// `material`, ...) or `dart:ui` for what the framework re-exports from the
  /// engine; for dart_ui, the public library file.
  final String library;

  /// `class`, `mixin`, `enum`, `typedef`, `function`, `variable` or `const`.
  final String kind;
  final String name;

  String toTsv() => '$library\t$kind\t$name';

  static ApiName fromTsv(String line) {
    final List<String> parts = line.split('\t');
    return ApiName(parts[0], parts[1], parts[2]);
  }
}

final RegExp _export = RegExp(
    r'''^export\s+'([^']+)'(?:\s+if\s*\([^)]*\)\s*'[^']+')*\s*((?:show|hide)\s+[^;]+)?;''',
    multiLine: true);

final RegExp _type = RegExp(
    r'^(?:(?:abstract|base|final|sealed|interface|mixin)\s+)*'
    r'(class|mixin|enum|extension\s+type)\s+(?:const\s+)?([A-Za-z]\w*)',
    multiLine: true);

final RegExp _typedef = RegExp(r'^typedef\s+([A-Za-z]\w*)', multiLine: true);

/// A top-level function: a return type, a lower-case name, then `(` or `<`.
final RegExp _function = RegExp(
    r'^(?:external\s+)?(?:[A-Za-z][\w<>?,. ]*[\w>?]|void|bool|int|double|num|String|dynamic|Object\??)\s+'
    r'([a-z]\w*)\s*[<(]',
    multiLine: true);

/// A top-level variable with a lower-case name: `rootBundle`.
final RegExp _variable = RegExp(
    r'^(?:final|const)\s+(?:[A-Z][\w<>?, ]*\s+)?([a-z]\w*)\s*=',
    multiLine: true);

/// A top-level constant named the Flutter way, `kSomething`.
final RegExp _constant =
    RegExp(r'^const\s+(?:[\w<>?, ]+\s+)?(k[A-Z]\w*)\s*=', multiLine: true);

Set<String> _names(String clause) => clause
    .replaceFirst(RegExp(r'^(show|hide)\s+'), '')
    .split(RegExp(r'[\s,]+'))
    .where((String n) => n.isNotEmpty && n != 'show' && n != 'hide')
    .toSet();

/// What [file] declares at the top level, public names only.
List<(String kind, String name)> declarations(String source) {
  final List<(String, String)> found = <(String, String)>[];
  for (final RegExpMatch m in _type.allMatches(source)) {
    final String kind =
        m.group(1)!.startsWith('extension') ? 'class' : m.group(1)!;
    found.add((kind, m.group(2)!));
  }
  for (final RegExpMatch m in _typedef.allMatches(source)) {
    found.add(('typedef', m.group(1)!));
  }
  for (final RegExpMatch m in _function.allMatches(source)) {
    found.add(('function', m.group(1)!));
  }
  for (final RegExpMatch m in _variable.allMatches(source)) {
    if (!m.group(1)!.startsWith(RegExp('k[A-Z]'))) {
      found.add(('variable', m.group(1)!));
    }
  }
  for (final RegExpMatch m in _constant.allMatches(source)) {
    found.add(('const', m.group(1)!));
  }
  return <(String, String)>[
    for (final (String kind, String name) in found)
      if (!name.startsWith('_')) (kind, name),
  ];
}

/// The public names [libraryFile] makes visible, each with the file that
/// declares it; names re-exported from `dart:` libraries come with the
/// library URI as their file.
///
/// [show] and [hide] are the filter of the directive that led here.
Map<String, (String kind, String file)> exportedNames(
  String libraryFile, {
  Set<String>? show,
  Set<String> hide = const <String>{},
  Set<String>? visiting,
}) {
  final Set<String> seen = visiting ?? <String>{};
  final String path = File(libraryFile).absolute.path;
  final Map<String, (String, String)> out = <String, (String, String)>{};
  if (!seen.add('$path|${show?.join(',')}|${hide.join(',')}')) return out;
  final File file = File(path);
  if (!file.existsSync()) return out;
  final String source = file.readAsStringSync();
  bool visible(String name) =>
      (show == null || show.contains(name)) && !hide.contains(name);

  for (final (String kind, String name) in declarations(source)) {
    if (visible(name)) out[name] = (kind, path);
  }
  for (final RegExpMatch m in _export.allMatches(source)) {
    final String uri = m.group(1)!;
    final String? clause = m.group(2);
    Set<String>? innerShow;
    Set<String> innerHide = const <String>{};
    if (clause != null && clause.startsWith('show')) innerShow = _names(clause);
    if (clause != null && clause.startsWith('hide')) innerHide = _names(clause);
    if (uri.startsWith('dart:') || uri.startsWith('package:')) {
      // The engine's types (Color, Offset, Canvas, ...): only a `show` list
      // says which.
      for (final String name in innerShow ?? const <String>{}) {
        if (visible(name)) out[name] = ('class', uri.split('/').first);
      }
      continue;
    }
    final String target = File(path).parent.uri.resolve(uri).toFilePath();
    // The narrower of the two filters applies.
    final Set<String>? effectiveShow = innerShow == null
        ? show
        : show == null
            ? innerShow
            : innerShow.intersection(show);
    final Map<String, (String, String)> inner = exportedNames(
      target,
      show: effectiveShow,
      hide: <String>{...hide, ...innerHide},
      visiting: seen,
    );
    out.addAll(inner);
  }
  return out;
}
