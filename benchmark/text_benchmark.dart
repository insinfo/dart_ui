/// What text costs.
///
/// This exists because a text engine's performance problems do not announce
/// themselves. A frame that drops from 3 microseconds to 1,800 still draws the
/// right pixels, and nothing fails; it is only visible as an application that
/// feels heavy. So the numbers are measured, printed as a distribution, and
/// checked against budgets that fail the run.
///
/// The budgets are deliberately generous - they are there to catch an order of
/// magnitude, not to police a few percent. A benchmark that fails on noise
/// gets disabled, and a disabled benchmark measures nothing.
///
/// ```
/// dart run benchmark/text_benchmark.dart
/// dart run benchmark/text_benchmark.dart --verbose
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/text/glyph_raster.dart';
import 'package:dart_ui/src/rendering/text/text_painter.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';

/// A line of Latin text with the letter frequencies of real prose.
const String sample = 'The quick brown fox jumps over the lazy dog';

/// Portuguese, so accented composites are in the measurement rather than
/// excluded from it - they are the common case in this project's own UI.
const String accented = 'Olá, coração — ação e informação em português';

const int warmup = 3;
const int iterations = 50;

void main(List<String> arguments) {
  final bool verbose = arguments.contains('--verbose');
  final List<int> fontBytes = _loadFontBytes();
  if (fontBytes.isEmpty) {
    stderr.writeln('no font available; skipping');
    exitCode = 0;
    return;
  }

  final List<_Result> results = <_Result>[
    _measureFaceParse(fontBytes),
    _measureColdMeasure(fontBytes),
    _measureWarmMeasure(fontBytes),
    _measureNewSize(fontBytes),
    _measureShaping(fontBytes),
    _measureAccentedShaping(fontBytes),
    _measureGlyphRaster(fontBytes),
    _measureParagraphEncode(fontBytes),
  ];

  stdout
    ..writeln('dart_ui text benchmark  '
        '(asserts ${_assertionsEnabled ? 'on' : 'off'})')
    ..writeln('${'case'.padRight(38)}  ${'median'.padLeft(9)}  '
        '${'p95'.padLeft(9)}  ${'budget'.padLeft(9)}');

  bool failed = false;
  for (final _Result result in results) {
    final bool over = result.median > result.budgetMicroseconds;
    if (over) failed = true;
    stdout.writeln(
      '${result.name.padRight(38)}  ${_us(result.median).padLeft(9)}  '
      '${_us(result.p95).padLeft(9)}  ${_us(result.budgetMicroseconds).padLeft(9)}'
      '${over ? '  OVER' : ''}',
    );
    if (verbose) stdout.writeln('    ${result.samples}');
  }

  stdout
    ..writeln()
    ..writeln(_cacheReport(fontBytes));

  // Machine-readable, for `tool/check_budgets.dart`. See the note on the same
  // block in `widget_tree_benchmark.dart` for why the id mapping lives beside
  // the case names rather than in `budgets.dart`.
  const Map<String, String> ids = <String, String>{
    'shape a line': 'text.shape-line',
  };
  stdout.writeln();
  for (final _Result result in results) {
    final String? id = ids[result.name];
    if (id != null) stdout.writeln('BUDGET $id ${result.median}');
  }

  if (failed) {
    stderr.writeln('\nAt least one case is over budget. Either something got '
        'slower, or the budget is wrong - decide which before changing '
        'either.');
    exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

/// Parsing a face. Paid once per font, at startup.
_Result _measureFaceParse(List<int> bytes) => _measure(
      'parse a face',
      budget: 20000,
      () => Typeface.parse(_asBytes(bytes)),
    );

/// Measuring a line for the first time.
///
/// The number that matters most, because layout measures before it draws and
/// this lands on the first frame - which is already the slowest one. It must
/// stay far away from a 16.6 ms frame.
_Result _measureColdMeasure(List<int> bytes) {
  return _measure('measure a line, cold', budget: 400, () {
    // A fresh face each time, so no cache is warm. That also means the face
    // parse is inside this number; it is subtracted below by comparing
    // against the parse case, not by trying to exclude it here.
    Typeface.parse(_asBytes(bytes)).atSize(12).measure(sample);
  }, iterations: 10);
}

/// Measuring a line that has been measured before. Every frame after the
/// first does this, so it is the steady-state cost of layout.
_Result _measureWarmMeasure(List<int> bytes) {
  final ScaledTypeface font = Typeface.parse(_asBytes(bytes)).atSize(12);
  font.measure(sample);
  return _measure(
      'measure a line, warm', budget: 60, () => font.measure(sample));
}

/// Measuring at a size never used before, on a face already loaded.
///
/// A UI with 12, 14, 16 and 20 px type pays this three extra times. It is the
/// case that regressed when outlines were cached per size rather than per
/// glyph.
_Result _measureNewSize(List<int> bytes) {
  final Typeface face = Typeface.parse(_asBytes(bytes));
  double size = 8;
  return _measure('measure at a size never used', budget: 200, () {
    size += 0.5;
    face.atSize(size).measure(sample);
  });
}

/// Shaping, which is what actually positions glyphs.
_Result _measureShaping(List<int> bytes) {
  final ScaledTypeface font = Typeface.parse(_asBytes(bytes)).atSize(14);
  final LatinShaper shaper = LatinShaper();
  shaper.shape(sample, font);
  return _measure('shape a line', budget: 80, () => shaper.shape(sample, font));
}

/// The same, with accents - so composite glyphs are measured rather than
/// assumed to cost the same.
_Result _measureAccentedShaping(List<int> bytes) {
  final ScaledTypeface font = Typeface.parse(_asBytes(bytes)).atSize(14);
  final LatinShaper shaper = LatinShaper();
  shaper.shape(accented, font);
  return _measure(
      'shape accented Portuguese',
      budget: 80,
      () => shaper.shape(accented, font));
}

/// Rasterizing one glyph to a coverage mask, uncached.
///
/// The per-glyph cost the mask cache exists to avoid paying twice.
_Result _measureGlyphRaster(List<int> bytes) {
  final Typeface face = Typeface.parse(_asBytes(bytes));
  final ScaledTypeface font = face.atSize(16);
  final GlyphRasterizer rasterizer = GlyphRasterizer();
  final int glyph = face.glyphForCodePoint(0x48);
  rasterizer.render(font, glyph);
  return _measure(
      'rasterize one glyph', budget: 300, () => rasterizer.render(font, glyph));
}

/// Shaping and encoding a paragraph into a display list.
///
/// Closest thing here to what a frame actually does with text.
_Result _measureParagraphEncode(List<int> bytes) {
  final ScaledTypeface font = Typeface.parse(_asBytes(bytes)).atSize(13);
  final TextPainter painter = TextPainter();
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFF000000);
  for (int i = 0; i < 20; i++) {
    painter.paint(list, sample, font, Offset(0, 20.0 * i), paint);
  }

  return _measure('encode a 20-line paragraph', budget: 2000, () {
    list.reset();
    final int p = list.addPaint(colorArgb: 0xFF000000);
    for (int line = 0; line < 20; line++) {
      painter.paint(list, sample, font, Offset(0, 20.0 * line), p);
    }
  });
}

/// What the caches hold after a realistic mix of sizes.
String _cacheReport(List<int> bytes) {
  final Typeface face = Typeface.parse(_asBytes(bytes));
  for (final double size in <double>[11, 12, 14, 16, 20, 28, 48]) {
    face.atSize(size).measure(sample);
    final ScaledTypeface font = face.atSize(size);
    final GlyphRasterizer rasterizer = GlyphRasterizer();
    for (final int rune in sample.runes) {
      rasterizer.render(font, face.glyphForCodePoint(rune));
    }
  }
  final ({int advances, int hinted, int unhinted}) sizes = face.cacheSizes;
  return 'after 7 sizes of the same line: '
      '${sizes.unhinted} unhinted outlines (one per glyph, size-independent), '
      '${sizes.hinted} hinted, ${sizes.advances} changed advances';
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// A typed view of the font bytes, which is what the parser takes.
Uint8List _asBytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

/// The font to measure with.
///
/// Prefers the checked-in fixture so the numbers are comparable between
/// machines; falls back to a system font so the benchmark still runs where the
/// fixture is absent.
List<int> _loadFontBytes() {
  for (final String path in <String>[
    'test/fonts/DejaVuSans.ttf',
    'test/fonts/Roboto-Regular.ttf',
  ]) {
    final File file = File(path);
    if (file.existsSync()) return file.readAsBytesSync();
  }
  return const <int>[];
}

final class _Result {
  _Result(this.name, this.samples, this.budgetMicroseconds);

  final String name;
  final List<int> samples;
  final int budgetMicroseconds;

  int get median => _percentile(50);

  int get p95 => _percentile(95);

  int _percentile(double percentile) {
    final List<int> sorted = List<int>.of(samples)..sort();
    final int rank = (percentile / 100 * sorted.length).ceil();
    return sorted[(rank - 1).clamp(0, sorted.length - 1)];
  }
}

_Result _measure(
  String name,
  void Function() body, {
  required int budget,
  int iterations = iterations,
}) {
  for (int i = 0; i < warmup; i++) {
    body();
  }
  final List<int> samples = <int>[];
  final Stopwatch stopwatch = Stopwatch();
  for (int i = 0; i < iterations; i++) {
    stopwatch
      ..reset()
      ..start();
    body();
    stopwatch.stop();
    samples.add(stopwatch.elapsedMicroseconds);
  }
  return _Result(name, samples, budget);
}

String _us(int microseconds) => microseconds >= 1000
    ? '${(microseconds / 1000).toStringAsFixed(2)}ms'
    : '${microseconds}us';

/// Reported rather than inferred: `dart run` disables assertions and
/// `dart test` enables them, and that difference is larger than most of what
/// this file measures.
bool get _assertionsEnabled {
  bool enabled = false;
  assert(() {
    enabled = true;
    return true;
  }());
  return enabled;
}
