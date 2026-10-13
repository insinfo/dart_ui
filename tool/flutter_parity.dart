/// Measures how much of Flutter's public API dart_ui offers under the same
/// name, and writes `doc/paridade_flutter.md`.
///
/// ```sh
/// dart run tool/flutter_parity.dart            # regenerate the table
/// dart run tool/flutter_parity.dart --refresh  # re-read Flutter first
/// ```
///
/// Flutter's names come from `tool/flutter_parity/flutter_api.tsv`, a
/// snapshot of the public API of `referencias/flutter-master` (which is not in
/// the repository); `--refresh` rebuilds it from there. dart_ui's names are
/// read from `lib/*.dart` every time. Priorities, differences and what does
/// not apply are in `tool/flutter_parity/catalog.dart`.
library;

import 'dart:io';

import 'flutter_parity/catalog.dart';
import 'flutter_parity/scan.dart';

const String snapshotPath = 'tool/flutter_parity/flutter_api.tsv';
const String reportPath = 'doc/paridade_flutter.md';
const String _flutterRoot = 'referencias/flutter-master/packages/flutter/lib';

const List<String> flutterLibraries = <String>[
  'foundation',
  'animation',
  'physics',
  'scheduler',
  'gestures',
  'semantics',
  'painting',
  'services',
  'rendering',
  'widgets',
  'material',
  'cupertino',
];

void main(List<String> args) {
  if (args.contains('--refresh')) {
    final List<ApiName> names = readFlutter(_flutterRoot);
    final String lines = <String>[
      '# Public API of Flutter (packages/flutter/lib), read by '
          'tool/flutter_parity.dart --refresh. Library, kind, name.',
      for (final ApiName n in names) n.toTsv(),
    ].join('\n');
    File(snapshotPath).writeAsStringSync('$lines\n');
    stdout.writeln('wrote $snapshotPath (${names.length} names)');
  }
  File(reportPath).writeAsStringSync(report());
  stdout.writeln('wrote $reportPath');
}

/// Flutter's public names under [root], each under the library whose
/// `lib/src/` folder declares it, or the `dart:` library it re-exports.
List<ApiName> readFlutter(String root) {
  final Map<String, ApiName> byName = <String, ApiName>{};
  for (final String library in flutterLibraries) {
    exportedNames('$root/$library.dart')
        .forEach((String name, (String, String) where) {
      final (String kind, String file) = where;
      final String owner = file.startsWith('dart:')
          ? file
          : RegExp(r'/lib/src/(\w+)/').firstMatch(file)?.group(1) ?? library;
      byName[name] ??= ApiName(owner, kind, name);
    });
  }
  final List<ApiName> names = byName.values.toList()
    ..sort((ApiName a, ApiName b) {
      final int byLibrary = a.library.compareTo(b.library);
      return byLibrary != 0 ? byLibrary : a.name.compareTo(b.name);
    });
  return names;
}

List<ApiName> readSnapshot() => <ApiName>[
      for (final String line in File(snapshotPath).readAsLinesSync())
        if (line.isNotEmpty && !line.startsWith('#')) ApiName.fromTsv(line),
    ];

/// Every public name dart_ui's libraries offer.
Set<String> readDartUi() => <String>{
      for (final FileSystemEntity file in Directory('lib').listSync())
        if (file is File && file.path.endsWith('.dart'))
          ...exportedNames(file.path).keys,
    };

enum Status { done, partial, missing, notApplicable }

final class Row {
  Row(this.api, this.status, this.priority, this.note);
  final ApiName api;
  final Status status;
  final String priority;
  final String note;
}

List<Row> measure(List<ApiName> flutter, Set<String> ours) => <Row>[
      for (final ApiName api in flutter)
        () {
          // dart:io and dart:typed_data are the Dart SDK's, there for both;
          // a package Flutter re-exports is a dependency either may take.
          final String? na =
              (api.library.startsWith('dart:') && api.library != 'dart:ui') ||
                      (api.library.startsWith('package:') &&
                          !kP0.contains(api.name))
                  ? 'from the Dart SDK or a package, the same for both'
                  : notApplicable(api.name);
          final String priority = priorityOf(api.library, api.name);
          if (na != null && !kP0.contains(api.name)) {
            return Row(api, Status.notApplicable, 'N/A', na);
          }
          final String? partial = kPartial[api.name];
          if (partial != null && ours.contains(api.name)) {
            return Row(api, Status.partial, priority, partial);
          }
          if (ours.contains(api.name)) {
            return Row(api, Status.done, priority, '');
          }
          return Row(api, Status.missing, priority, '');
        }(),
    ];

String _mark(Status s) => switch (s) {
      Status.done => '✅',
      Status.partial => '🟡',
      Status.missing => '❌',
      Status.notApplicable => '—',
    };

String _percent(Iterable<Row> rows) {
  final List<Row> counted =
      rows.where((Row r) => r.status != Status.notApplicable).toList();
  if (counted.isEmpty) return '-';
  final double score = counted.fold<double>(
      0,
      (double sum, Row r) =>
          sum +
          (r.status == Status.done
              ? 1
              : r.status == Status.partial
                  ? 0.5
                  : 0));
  return '${(100 * score / counted.length).floor()}%';
}

String _summaryRow(String label, Iterable<Row> rows) {
  int count(Status s) => rows.where((Row r) => r.status == s).length;
  final int total =
      rows.where((Row r) => r.status != Status.notApplicable).length;
  return '| $label | ${count(Status.done)} | ${count(Status.partial)} | '
      '${count(Status.missing)} | $total | ${_percent(rows)} |';
}

/// The table, as `doc/paridade_flutter.md` holds it.
String report({List<ApiName>? flutter, Set<String>? ours}) {
  final List<Row> rows =
      measure(flutter ?? readSnapshot(), ours ?? readDartUi());
  final StringBuffer out = StringBuffer()
    ..writeln('# Paridade de API com o Flutter')
    ..writeln()
    ..writeln(
        'Gerado por `dart run tool/flutter_parity.dart`; não edite à mão. '
        'As regras estão em [AGENTS_FLUTTER.md](AGENTS_FLUTTER.md) e o histórico '
        'em [DIARIO_FLUTTER.md](DIARIO_FLUTTER.md).')
    ..writeln()
    ..writeln(
        'Cada nome público do Flutter (`packages/flutter/lib`) é procurado '
        'na API pública do `dart_ui` (`lib/*.dart`). ✅ existe com o mesmo nome; '
        '🟡 existe mas difere (a nota diz em quê) e conta metade; ❌ falta; — não '
        'se aplica, com o motivo. O nome existir não prova a mesma assinatura: '
        'divergências conhecidas ficam em `tool/flutter_parity/catalog.dart`, e '
        'na dúvida se marca para baixo.')
    ..writeln()
    ..writeln('## Por prioridade')
    ..writeln()
    ..writeln('| Prioridade | ✅ | 🟡 | ❌ | total | paridade |')
    ..writeln('|---|---|---|---|---|---|');
  for (final String p in <String>['P0', 'P1', 'P2']) {
    out.writeln(_summaryRow(p, rows.where((Row r) => r.priority == p)));
  }
  out
    ..writeln(_summaryRow('**todas**', rows))
    ..writeln()
    ..writeln('P0: o que um app ou pacote típico usa primeiro. P1: o resto do '
        'núcleo e do Material. P2: Cupertino. Fora da conta: '
        '${rows.where((Row r) => r.status == Status.notApplicable).length} '
        'nomes que não se aplicam.')
    ..writeln()
    ..writeln('## Por biblioteca')
    ..writeln()
    ..writeln('| Biblioteca | ✅ | 🟡 | ❌ | total | paridade |')
    ..writeln('|---|---|---|---|---|---|');
  final List<String> libraries = <String>{
    for (final Row r in rows) r.api.library,
  }.toList()
    ..sort();
  for (final String library in libraries) {
    out.writeln(_summaryRow(
        '`$library`', rows.where((Row r) => r.api.library == library)));
  }

  out
    ..writeln()
    ..writeln('## P0, nome a nome')
    ..writeln()
    ..writeln('| | Nome | Biblioteca | Tipo | Nota |')
    ..writeln('|---|---|---|---|---|');
  final List<Row> p0 = rows.where((Row r) => r.priority == 'P0').toList()
    ..sort((Row a, Row b) {
      final int byStatus = b.status.index.compareTo(a.status.index);
      return byStatus != 0 ? -byStatus : a.api.name.compareTo(b.api.name);
    });
  for (final Row r in p0) {
    out.writeln('| ${_mark(r.status)} | `${r.api.name}` | ${r.api.library} | '
        '${r.api.kind} | ${r.note} |');
  }
  final Set<String> p0Missing = kP0.difference(<String>{
    for (final Row r in rows) r.api.name,
  });
  if (p0Missing.isNotEmpty) {
    out
      ..writeln()
      ..writeln('Nomes do P0 que o snapshot do Flutter não tem (erro no '
          'catálogo): ${(p0Missing.toList()..sort()).map((String n) => '`$n`').join(', ')}.');
  }

  for (final String p in <String>['P1', 'P2']) {
    out
      ..writeln()
      ..writeln('## $p por biblioteca')
      ..writeln();
    for (final String library in libraries) {
      final List<Row> here = rows
          .where((Row r) => r.priority == p && r.api.library == library)
          .toList();
      if (here.isEmpty) continue;
      String names(Status s) => (here
              .where((Row r) => r.status == s)
              .map((Row r) => r.api.name)
              .toList()
            ..sort())
          .map((String n) => '`$n`')
          .join(', ');
      out
        ..writeln('### `$library` (${_percent(here)})')
        ..writeln();
      final String missing = names(Status.missing);
      if (missing.isNotEmpty) {
        out
          ..writeln('❌ $missing')
          ..writeln();
      }
      for (final Row r in here.where((Row r) => r.status == Status.partial)) {
        out
          ..writeln('🟡 `${r.api.name}`: ${r.note}')
          ..writeln();
      }
      final String done = names(Status.done);
      if (done.isNotEmpty) {
        out
          ..writeln('✅ $done')
          ..writeln();
      }
    }
  }

  out
    ..writeln('## Não se aplica')
    ..writeln();
  final Map<String, List<String>> byReason = <String, List<String>>{};
  for (final Row r in rows.where((Row r) => r.status == Status.notApplicable)) {
    (byReason[r.note] ??= <String>[]).add(r.api.name);
  }
  for (final MapEntry<String, List<String>> e in (byReason.entries.toList()
    ..sort(
        (MapEntry<String, List<String>> a, MapEntry<String, List<String>> b) =>
            a.key.compareTo(b.key)))) {
    out.writeln(
        '- ${e.key}: ${(e.value..sort()).map((String n) => '`$n`').join(', ')}');
  }
  return out.toString();
}
