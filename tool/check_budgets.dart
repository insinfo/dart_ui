/// Runs the benchmarks and fails when a measured case is over its budget.
///
/// This is the half of section 36 that a benchmark alone cannot be. A
/// benchmark answers "how long did that take, on this machine, just now". A
/// gate answers "is this slower than we agreed to tolerate", every push, on a
/// machine nobody chose. The second question is the one that catches a
/// regression before a release, and it needs the budgets to be written down
/// beforehand - which is what `benchmark/budgets.dart` is.
///
/// ```
/// dart run tool/check_budgets.dart            # run and enforce
/// dart run tool/check_budgets.dart --report   # run, print, enforce nothing
/// ```
///
/// ## What it deliberately does not do
///
/// **It does not compare against a stored baseline.** Tracking the previous
/// run's numbers on a shared CI runner measures the runner's neighbours as
/// much as the code, and a gate that flaps is a gate people learn to re-run
/// until it passes. A fixed ceiling, argued in `budgets.dart` and loose enough
/// to survive a noisy machine, catches the regressions that matter - a
/// quadratic loop, a cache that stopped hitting - and stays quiet otherwise.
///
/// **It does not fail on a case with no budget.** Adding a measurement should
/// never be blocked on agreeing a ceiling for it. Those are printed as
/// `unbudgeted` so they are visible without being enforced.
///
/// It *does* fail on a budget with no measurement: an id in `budgets.dart` that
/// nothing emits means a case was renamed or deleted and quietly left the gate,
/// which looks identical to passing.
library;

import 'dart:io';

import '../benchmark/budgets.dart';

/// The benchmarks to run, in the order their output should appear.
const List<String> _benchmarks = <String>[
  'benchmark/widget_tree_benchmark.dart',
  'benchmark/text_benchmark.dart',
];

Future<void> main(List<String> arguments) async {
  final bool reportOnly = arguments.contains('--report');
  final Map<String, int> measured = <String, int>{};
  final List<String> failures = <String>[];
  final List<String> warnings = <String>[];

  for (final String path in _benchmarks) {
    stdout.writeln('== $path');
    final ProcessResult result =
        await Process.run(Platform.resolvedExecutable, <String>['run', path]);
    final String out = '${result.stdout}';
    stdout.write(out);
    if (result.exitCode != 0) {
      // Reported, not fatal, and the distinction is deliberate.
      //
      // Some benchmarks carry their own inline ceilings, written before this
      // file existed. Those are the author's notes to themselves; the gate is
      // `budgets.dart`, which is reviewed and carries an argument per number.
      // Folding the two together would mean a benchmark could tighten the
      // build gate by editing a literal, with no review of the ceiling.
      //
      // It is surfaced loudly because it still means something: as of writing,
      // `measure a line, cold` in the text benchmark reports ~560 us against
      // its own 400 us note, reproducibly across runs. That is a real finding
      // and it is why this line prints rather than being swallowed.
      warnings.add('$path exited ${result.exitCode} - an inline ceiling of '
          'its own was missed. Not a gate failure; see the case table above.');
    }
    for (final String line in out.split('\n')) {
      final String trimmed = line.trim();
      if (!trimmed.startsWith('BUDGET ')) continue;
      final List<String> parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length != 3) {
        failures.add('malformed budget line in $path: $trimmed');
        continue;
      }
      final int? micros = int.tryParse(parts[2]);
      if (micros == null) {
        failures.add('unparseable measurement in $path: $trimmed');
        continue;
      }
      measured[parts[1]] = micros;
    }
  }

  stdout
    ..writeln()
    ..writeln('Budgets (section 36.3)')
    ..writeln('${'case'.padRight(30)}  ${'median'.padLeft(10)}  '
        '${'budget'.padLeft(10)}  verdict');

  for (final MapEntry<String, int> entry in measured.entries) {
    final Budget? budget = budgetFor(entry.key);
    if (budget == null) {
      stdout.writeln('${entry.key.padRight(30)}  '
          '${_us(entry.value).padLeft(10)}  ${'-'.padLeft(10)}  unbudgeted');
      continue;
    }
    final bool over = entry.value > budget.medianMicroseconds;
    stdout.writeln('${entry.key.padRight(30)}  '
        '${_us(entry.value).padLeft(10)}  '
        '${_us(budget.medianMicroseconds).padLeft(10)}  '
        '${over ? 'OVER' : 'ok'}');
    if (over) {
      failures.add(
        '${budget.id} is over budget: ${_us(entry.value)} against a ceiling '
        'of ${_us(budget.medianMicroseconds)}.\n  Why that ceiling: '
        '${budget.rationale}\n  Either something got slower or the budget is '
        'wrong. Decide which before changing either.',
      );
    }
  }

  for (final Budget budget in budgets) {
    if (measured.containsKey(budget.id)) continue;
    failures.add(
      'no benchmark emitted "BUDGET ${budget.id}". A case was renamed or '
      'removed and its budget stopped being checked, which is indistinguishable '
      'from passing. Re-point it or delete the budget deliberately.',
    );
  }

  if (warnings.isNotEmpty) {
    stdout.writeln('\n${warnings.length} warning(s):');
    for (final String warning in warnings) {
      stdout.writeln('  ! $warning');
    }
  }

  if (failures.isEmpty) {
    stdout.writeln('\nAll budgets met.');
    return;
  }

  stderr.writeln('\n${failures.length} problem(s):');
  for (final String failure in failures) {
    stderr.writeln('  - $failure');
  }
  if (reportOnly) {
    stdout.writeln('\n--report given: not failing the run.');
    return;
  }
  exitCode = 1;
}

String _us(int microseconds) => microseconds >= 1000
    ? '${(microseconds / 1000).toStringAsFixed(2)} ms'
    : '$microseconds us';
