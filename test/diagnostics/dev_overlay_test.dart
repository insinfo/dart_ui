import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const Duration budget = Duration(microseconds: 16667);

void main() {
  // The overlay draws its numbers with the interface font, so the command
  // counts below would otherwise depend on whether this machine has one.
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('frame statistics', () {
    test('the ring keeps a bounded history', () {
      final stats = FrameStatistics(capacity: 4);
      for (int i = 0; i < 20; i++) {
        stats.record(FrameTiming(build: i * 100));
      }

      expect(stats.count, 4);
      // A diagnostic that grew without bound would fail in exactly the long
      // sessions it exists to explain.
      expect(stats.frames, hasLength(4));
    });

    test('the average and the worst come from the recorded frames', () {
      final stats = FrameStatistics()
        ..record(const FrameTiming(build: 1000))
        ..record(const FrameTiming(build: 3000));

      expect(stats.averageTotal, 2000);
      expect(stats.worstTotal, 3000);
    });

    test('a percentile finds the tail an average hides', () {
      final stats = FrameStatistics();
      // Fifty-nine fast frames and one very slow one: the mean looks healthy
      // and the p99 does not, which is the whole reason to report both.
      for (int i = 0; i < 59; i++) {
        stats.record(const FrameTiming(build: 4000));
      }
      stats.record(const FrameTiming(build: 40000));

      expect(stats.averageTotal, lessThan(5000));
      expect(stats.percentileTotal(99), 40000);
      expect(stats.percentileTotal(50), 4000);
    });

    test('frames over budget are counted', () {
      final stats = FrameStatistics()
        ..record(const FrameTiming(build: 8000))
        ..record(const FrameTiming(build: 20000))
        ..record(const FrameTiming(build: 30000));

      expect(stats.framesOverBudget(budget), 2);
    });

    test('an empty history answers zero rather than dividing by it', () {
      final stats = FrameStatistics();

      expect(stats.averageTotal, 0);
      expect(stats.worstTotal, 0);
      expect(stats.percentileTotal(99), 0);
      expect(stats.framesOverBudget(budget), 0);
    });

    test('a timing totals its phases', () {
      const timing = FrameTiming(build: 1, layout: 2, paint: 4, raster: 8);
      expect(timing.total, 15);
    });
  });

  group('the overlay itself', () {
    test('it draws nothing when there is nothing to report', () {
      final list = DisplayList();

      DevOverlay(statistics: FrameStatistics())
          .paint(list, const Rect.fromLTWH(0, 0, 200, 100));

      expect(list.commandCount, 0);
    });

    test('it emits commands and leaves the clip stack balanced', () {
      final stats = FrameStatistics();
      for (int i = 0; i < 10; i++) {
        stats.record(const FrameTiming(build: 5000));
      }
      final list = DisplayList();

      DevOverlay(statistics: stats)
          .paint(list, const Rect.fromLTWH(0, 0, 200, 100));

      expect(list.commandCount, greaterThan(10));

      // An overlay that leaked a save would corrupt the *next* frame, which is
      // the hardest kind of bug to attribute back here.
      final reader = DisplayListReader(list);
      int depth = 0;
      while (reader.moveNext()) {
        if (reader.opcode == opSave) depth++;
        if (reader.opcode == opRestore) depth--;
        expect(depth, greaterThanOrEqualTo(0));
      }
      expect(depth, 0);
    });

    test('a slow frame is drawn differently from a fast one', () {
      final fast = FrameStatistics();
      final slow = FrameStatistics();
      for (int i = 0; i < 10; i++) {
        fast.record(const FrameTiming(build: 4000));
        slow.record(const FrameTiming(build: 40000));
      }

      expect(
        _paintColors(DevOverlay(statistics: fast)),
        isNot(_paintColors(DevOverlay(statistics: slow))),
      );
    });

    test('the chart can be turned off', () {
      final stats = FrameStatistics();
      for (int i = 0; i < 30; i++) {
        stats.record(const FrameTiming(build: 5000));
      }

      final withChart = DisplayList();
      DevOverlay(statistics: stats)
          .paint(withChart, const Rect.fromLTWH(0, 0, 300, 200));
      final withoutChart = DisplayList();
      DevOverlay(statistics: stats, showChart: false)
          .paint(withoutChart, const Rect.fromLTWH(0, 0, 300, 200));

      expect(withoutChart.commandCount, lessThan(withChart.commandCount));
    });

    test('it still draws its panel when there is no font', () {
      final FontRegistry installed = FontRegistry.instance;
      FontRegistry.instance = FontRegistry(search: () => null);
      addTearDown(() => FontRegistry.instance = installed);

      final stats = FrameStatistics();
      for (int i = 0; i < 10; i++) {
        stats.record(const FrameTiming(build: 5000));
      }
      final list = DisplayList();

      DevOverlay(statistics: stats)
          .paint(list, const Rect.fromLTWH(0, 0, 200, 100));

      // A diagnostic overlay is the last thing that should crash when the
      // machine is missing something: no numbers, but the panel and the chart
      // still say whether frames are over budget.
      final reader = DisplayListReader(list);
      int rects = 0;
      int runs = 0;
      while (reader.moveNext()) {
        if (reader.opcode == opDrawRect) rects++;
        if (reader.opcode == opDrawGlyphRun) runs++;
      }
      expect(rects, greaterThan(10));
      expect(runs, 0);
    });
  });
}

/// The colours an overlay actually *draws with*, which is how "green bars" and
/// "red bars" are told apart without asserting on pixel output.
///
/// Registered paints are not enough: the overlay declares both a good and a
/// bad colour every frame and only uses one of them, so a set built from the
/// paint table would be identical either way.
Set<int> _paintColors(DevOverlay overlay) {
  final list = DisplayList();
  overlay.paint(list, const Rect.fromLTWH(0, 0, 200, 100));
  final reader = DisplayListReader(list);
  final Set<int> colors = <int>{};
  while (reader.moveNext()) {
    if (reader.opcode != opDrawRect) continue;
    colors.add(list.paintColor(reader.intAt(0)));
  }
  return colors;
}
