/// Summary of a microsecond sample set.
final class Stats {
  const Stats({
    required this.count,
    required this.meanUs,
    required this.p50Us,
    required this.p95Us,
    required this.p99Us,
    required this.maxUs,
  });

  factory Stats.fromMicros(List<int> samples) {
    if (samples.isEmpty) {
      return const Stats(
        count: 0,
        meanUs: 0,
        p50Us: 0,
        p95Us: 0,
        p99Us: 0,
        maxUs: 0,
      );
    }
    final sorted = List<int>.of(samples)..sort();
    var total = 0;
    for (final sample in sorted) {
      total += sample;
    }
    return Stats(
      count: sorted.length,
      meanUs: total / sorted.length,
      p50Us: _percentile(sorted, 0.50),
      p95Us: _percentile(sorted, 0.95),
      p99Us: _percentile(sorted, 0.99),
      maxUs: sorted.last,
    );
  }

  final int count;
  final double meanUs;
  final int p50Us;
  final int p95Us;
  final int p99Us;
  final int maxUs;

  /// Nearest-rank percentile over an already sorted list.
  static int _percentile(List<int> sorted, double fraction) {
    final rank = (fraction * sorted.length).ceil();
    final index = rank <= 0 ? 0 : rank - 1;
    return sorted[index >= sorted.length ? sorted.length - 1 : index];
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'count': count,
        'meanUs': meanUs,
        'p50Us': p50Us,
        'p95Us': p95Us,
        'p99Us': p99Us,
        'maxUs': maxUs,
      };
}
