import 'package:poc_19_event_loop_metrics/poc_19_event_loop_metrics.dart';
import 'package:test/test.dart';

void main() {
  group('Stats', () {
    test('empty sample set is all zeros', () {
      final stats = Stats.fromMicros(const <int>[]);
      expect(stats.count, 0);
      expect(stats.meanUs, 0);
      expect(stats.p50Us, 0);
      expect(stats.maxUs, 0);
    });

    test('single sample reports that sample everywhere', () {
      final stats = Stats.fromMicros(const <int>[42]);
      expect(stats.count, 1);
      expect(stats.meanUs, 42);
      expect(stats.p50Us, 42);
      expect(stats.p95Us, 42);
      expect(stats.maxUs, 42);
    });

    test('percentiles use nearest rank and never read out of bounds', () {
      final samples = List<int>.generate(100, (index) => index + 1);
      final stats = Stats.fromMicros(samples);
      expect(stats.count, 100);
      expect(stats.p50Us, 50);
      expect(stats.p95Us, 95);
      expect(stats.p99Us, 99);
      expect(stats.maxUs, 100);
      expect(stats.meanUs, closeTo(50.5, 0.001));
    });

    test('input order does not change the result', () {
      final ascending = Stats.fromMicros(const <int>[1, 2, 3, 4, 5]);
      final descending = Stats.fromMicros(const <int>[5, 4, 3, 2, 1]);
      expect(descending.p50Us, ascending.p50Us);
      expect(descending.maxUs, ascending.maxUs);
      expect(descending.meanUs, ascending.meanUs);
    });

    test('does not mutate the caller list', () {
      final samples = <int>[3, 1, 2];
      Stats.fromMicros(samples);
      expect(samples, <int>[3, 1, 2]);
    });
  });
}
