/// The Flutter parity table is a measurement, not a claim: it must be the
/// current one, and its catalog may name only what Flutter has.
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/flutter_parity.dart';
import '../../tool/flutter_parity/catalog.dart';
import '../../tool/flutter_parity/scan.dart' show ApiName;

void main() {
  final Set<String> flutter = <String>{
    for (final ApiName api in readSnapshot()) api.name,
  };

  test('doc/paridade_flutter.md is the current measurement', () {
    expect(File(reportPath).readAsStringSync(), report(),
        reason: 'run dart run tool/flutter_parity.dart and commit the result');
  });

  test('the catalog names only what Flutter has', () {
    expect(kP0.difference(flutter), isEmpty, reason: 'kP0');
    expect(kPartial.keys.toSet().difference(flutter), isEmpty,
        reason: 'kPartial');
    expect(kNotApplicable.keys.toSet().difference(flutter), isEmpty,
        reason: 'kNotApplicable');
  });

  test('a partial entry is a name dart_ui has', () {
    final Set<String> ours = readDartUi();
    expect(kPartial.keys.where((String n) => !ours.contains(n)), isEmpty,
        reason: 'a name missing here is ❌, not 🟡');
  });

  test('the reader finds what dart_ui is known to export', () {
    final Set<String> ours = readDartUi();
    for (final String name in <String>[
      'Flow',
      'NestedScrollView',
      'SliverAppBar',
      'Hero',
      'ValueNotifier',
    ]) {
      expect(ours, contains(name));
    }
  });
}
