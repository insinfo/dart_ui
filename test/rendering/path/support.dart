/// Shared fixtures for the path filler tests.
///
/// Not named `*_test.dart` so the runner does not try to execute it.
library;

import 'dart:math' as math;

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/path/coverage_span_sink.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

/// One reported span, kept whole so a test can assert on the runs themselves
/// and not only on the pixels they imply.
final class Span {
  const Span(this.y, this.xStart, this.xEnd, this.coverage);

  final int y;
  final int xStart;
  final int xEnd;
  final int coverage;

  @override
  bool operator ==(Object other) =>
      other is Span &&
      other.y == y &&
      other.xStart == xStart &&
      other.xEnd == xEnd &&
      other.coverage == coverage;

  @override
  int get hashCode => Object.hash(y, xStart, xEnd, coverage);

  @override
  String toString() => 'Span(y: $y, x: [$xStart, $xEnd), coverage: $coverage)';
}

/// Collects spans and lets a test read them back as a coverage grid.
final class SpanRecorder implements CoverageSpanSink {
  final List<Span> spans = <Span>[];
  final Map<int, Map<int, int>> _grid = <int, Map<int, int>>{};

  @override
  void span(int y, int xStart, int xEnd, int coverage) {
    spans.add(Span(y, xStart, xEnd, coverage));
    final row = _grid.putIfAbsent(y, () => <int, int>{});
    for (var x = xStart; x < xEnd; x++) {
      row[x] = coverage;
    }
  }

  /// Coverage at ([x], [y]), 0 where no span claimed the pixel.
  int at(int x, int y) => _grid[y]?[x] ?? 0;

  int get pixelCount {
    var total = 0;
    for (final row in _grid.values) {
      total += row.length;
    }
    return total;
  }

  /// An ASCII picture, for the reason on a failed expectation.
  String render(int width, int height) {
    final buffer = StringBuffer();
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final coverage = at(x, y);
        buffer.write(
          coverage == 0
              ? '.'
              : coverage == 255
                  ? '#'
                  : (coverage ~/ 26).toString(),
        );
      }
      buffer.writeln();
    }
    return buffer.toString();
  }
}

/// Asserts the parts of the [CoverageSpanSink] contract a sink is allowed to
/// rely on. Every filler test runs this, because a caller that trusts the
/// contract has no way to notice it being broken.
void expectSpanContract(SpanRecorder recorder, Rect clip) {
  var lastY = -1 << 30;
  var lastEnd = 0;
  for (final span in recorder.spans) {
    expect(span.coverage, greaterThan(0), reason: 'zero runs are not reported');
    expect(span.coverage, lessThanOrEqualTo(255));
    expect(span.xEnd, greaterThan(span.xStart), reason: 'empty run: $span');
    expect(span.y, greaterThanOrEqualTo(lastY), reason: 'y went backwards');
    if (span.y != lastY) {
      lastY = span.y;
      lastEnd = -1 << 30;
    }
    expect(span.xStart, greaterThanOrEqualTo(lastEnd), reason: 'overlap');
    lastEnd = span.xEnd;

    expect(span.y, greaterThanOrEqualTo(clip.top.floor()));
    expect(span.y, lessThan(clip.bottom.ceil()));
    expect(span.xStart, greaterThanOrEqualTo(clip.left.floor()));
    expect(span.xEnd, lessThanOrEqualTo(clip.right.ceil()));
  }
}

/// Coverage of the pixel at ([x], [y]) by [contours], estimated by sampling
/// [samples] x [samples] points inside it.
///
/// The independent reference the filler is checked against. Sampling rather
/// than area integration on purpose: it shares no arithmetic with the code
/// under test, so an error in the accumulation cannot cancel out. Its own
/// error against the true area is bounded by roughly `1 / (2 * samples)` per
/// edge crossing the pixel, which is why comparisons allow a few units of
/// 255.
int sampledCoverage(
  List<List<Offset>> contours,
  int x,
  int y,
  FillRule rule, {
  int samples = 64,
}) {
  var inside = 0;
  for (var sy = 0; sy < samples; sy++) {
    final py = y + (sy + 0.5) / samples;
    for (var sx = 0; sx < samples; sx++) {
      final px = x + (sx + 0.5) / samples;
      if (_isInside(contours, px, py, rule)) inside++;
    }
  }
  final total = samples * samples;
  return (inside * 255 / total + 0.5).floor();
}

bool _isInside(List<List<Offset>> contours, double px, double py, FillRule r) {
  var winding = 0;
  for (final contour in contours) {
    for (var i = 0; i < contour.length; i++) {
      final a = contour[i];
      final b = contour[(i + 1) % contour.length];
      // Half-open in y, so a vertex lying exactly on the ray is counted once.
      if (a.dy <= py) {
        if (b.dy > py && _isLeft(a, b, px, py) > 0) winding++;
      } else if (b.dy <= py && _isLeft(a, b, px, py) < 0) {
        winding--;
      }
    }
  }
  return r == FillRule.nonZero ? winding != 0 : winding.isOdd;
}

double _isLeft(Offset a, Offset b, double px, double py) =>
    (b.dx - a.dx) * (py - a.dy) - (px - a.dx) * (b.dy - a.dy);

/// Builds a closed contour from its corners.
Path polygonPath(List<Offset> points) {
  final builder = PathBuilder()..moveTo(points.first.dx, points.first.dy);
  for (var i = 1; i < points.length; i++) {
    builder.lineTo(points[i].dx, points[i].dy);
  }
  builder.close();
  return builder.build();
}

/// The corners of a five-pointed star, in the order that makes one
/// self-crossing contour: every second vertex of a regular pentagon.
///
/// This is the shape the two fill rules disagree about. Its centre pentagon is
/// wound twice, so non-zero fills it and even-odd leaves a hole.
List<Offset> starPoints(Offset centre, double radius) => <Offset>[
      for (var i = 0; i < 5; i++)
        Offset(
          centre.dx + radius * math.cos(-math.pi / 2 + i * 4 * math.pi / 5),
          centre.dy + radius * math.sin(-math.pi / 2 + i * 4 * math.pi / 5),
        ),
    ];
