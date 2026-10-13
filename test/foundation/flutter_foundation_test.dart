/// Flutter's foundation names: the callback typedefs, the build-mode
/// constants and debugPrint.
library;

import 'dart:async';

import 'package:dart_ui/src/foundation/basic_types.dart';
import 'package:dart_ui/src/foundation/constants.dart';
import 'package:dart_ui/src/foundation/print.dart';
import 'package:test/test.dart';

void main() {
  test('the typedefs are the plain function types', () async {
    int calls = 0;
    void tap() => calls++;
    void add(int v) => calls += v;
    int read() => calls;
    Future<void> tapLater() async => calls++;
    Future<void> addLater(int v) async => calls += v;
    Future<int> readLater() async => calls;

    final VoidCallback onTap = tap;
    final void Function() plain = onTap;
    plain();
    final ValueChanged<int> changed = add;
    final ValueSetter<int> setter = changed;
    setter(10);
    final ValueGetter<int> getter = read;
    final AsyncCallback later = tapLater;
    final AsyncValueSetter<int> laterSet = addLater;
    final AsyncValueGetter<int> laterGet = readLater;
    await later();
    await laterSet(100);
    expect(getter(), 112);
    expect(await laterGet(), 112);
  });

  test('exactly one build mode, debug under dart test', () {
    expect(<bool>[kDebugMode, kProfileMode, kReleaseMode].where((b) => b),
        hasLength(1));
    expect(kDebugMode, isTrue);
    expect(kIsWeb, isFalse);
  });

  group('debugPrint', () {
    late DebugPrintCallback original;
    setUp(() => original = debugPrint);
    tearDown(() => debugPrint = original);

    test('can be replaced to capture or silence logging', () {
      final List<String?> captured = <String?>[];
      debugPrint = (String? message, {int? wrapWidth}) => captured.add(message);
      debugPrint('hello');
      expect(captured, <String?>['hello']);
    });

    test('wraps long lines and keeps everything, throttled', () async {
      final List<String> printed = <String>[];
      await runZoned(
        () async {
          debugPrintThrottled('alpha beta gamma delta', wrapWidth: 11);
          debugPrintThrottled('  indented words here', wrapWidth: 12);
          debugPrintThrottled(null);
          await debugPrintDone;
        },
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) =>
              printed.add(line),
        ),
      );
      expect(printed, <String>[
        'alpha beta',
        'gamma delta',
        '  indented',
        '  words here',
        'null',
      ]);
    });

    test('a burst beyond the per-second budget is delivered later, whole',
        () async {
      final List<String> printed = <String>[];
      final String line = 'x' * 1000;
      await runZoned(
        () async {
          for (int i = 0; i < 14; i++) {
            debugPrintThrottled(line);
          }
          expect(printed.length, lessThan(14), reason: 'throttled');
          await debugPrintDone;
        },
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String l) =>
              printed.add(l),
        ),
      );
      expect(printed, hasLength(14));
    });

    test('debugPrintSynchronously prints at once', () {
      final List<String> printed = <String>[];
      runZoned(
        () => debugPrintSynchronously('a\nb'),
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String l) =>
              printed.add(l),
        ),
      );
      expect(printed, <String>['a', 'b']);
    });
  });
}
