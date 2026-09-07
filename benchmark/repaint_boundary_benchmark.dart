/// What a repaint boundary is worth, measured on the frame it exists for.
///
/// The roadmap (§67, item 3) calls damage tracking "a maior lacuna de
/// desempenho do framework e a que mais cresce com o tamanho da aplicação".
/// This file is the number behind that sentence, and it is deliberately
/// arranged so that the number can come out *small*: every case is run twice
/// on the same tree with [PipelineOwner.repaintBoundaryCaching] flipped, so
/// what is reported is not "paint is fast" but "this feature moved paint by
/// this much", which is the only claim worth making about an optimisation.
///
/// The shape under test is the one the feature is for: a wide tree of panels,
/// each panel a repaint boundary, and exactly one leaf in one panel changing
/// per frame. Two controls sit next to it and matter as much as the headline:
///
///   * **no boundaries at all**, which is what the framework did before, and
///     which says how much of paint is walk rather than encode;
///   * **every panel dirty**, the frame where the cache can do nothing but
///     still has to record, which is where a caching scheme pays for itself in
///     the wrong direction.
///
/// Run with:
///
/// ```
/// dart run benchmark/repaint_boundary_benchmark.dart
/// dart compile exe benchmark/repaint_boundary_benchmark.dart && ...
/// ```
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

/// Panels across the tree, and leaves inside each one.
///
/// The product is the node count; the split is what the benchmark is about. A
/// boundary saves the walk of everything under it, so a tree of many small
/// panels and a tree of few large ones are different measurements and both are
/// reported.
const int panelCount = 200;
const int leavesPerPanel = 50;

const int warmupIterations = 5;
const int measuredIterations = 30;

void main(List<String> arguments) {
  final bool verbose = arguments.contains('--verbose');
  final List<_Result> results = <_Result>[
    _oneLeafPerFrame(boundaries: false, caching: false),
    _oneLeafPerFrame(boundaries: true, caching: false),
    _oneLeafPerFrame(boundaries: true, caching: true),
    _nothingChanges(boundaries: true, caching: false),
    _nothingChanges(boundaries: true, caching: true),
    _everyPanelDirty(caching: false),
    _everyPanelDirty(caching: true),
    _panelsMove(caching: false),
    _panelsMove(caching: true),
  ];

  stdout
    ..writeln('dart_ui repaint boundary benchmark  '
        '($panelCount panels x $leavesPerPanel leaves = '
        '${panelCount * leavesPerPanel} leaves, '
        'asserts ${_assertionsEnabled ? 'on' : 'off'})')
    ..writeln('paint only: flushLayout is run first and is not in the timing.')
    ..writeln()
    ..writeln('${'case'.padRight(46)}  ${'median'.padLeft(9)}  '
        '${'p95'.padLeft(9)}  ${'worst'.padLeft(9)}');
  for (final _Result result in results) {
    stdout.writeln(
      '${result.name.padRight(46)}  ${_us(result.median).padLeft(9)}  '
      '${_us(result.p95).padLeft(9)}  ${_us(result.worst).padLeft(9)}',
    );
    if (verbose) stdout.writeln('    samples: ${result.samples}');
  }

  stdout.writeln();
  _speedup(results, 'one leaf, boundaries, cache off',
      'one leaf, boundaries, cache on');
  _speedup(results, 'nothing changed, cache off', 'nothing changed, cache on');
  _speedup(
      results, 'every panel dirty, cache off', 'every panel dirty, cache on');
  _speedup(results, 'panels moved, cache off', 'panels moved, cache on');

  stdout
    ..writeln()
    ..writeln('BUDGET paint.boundary-one-leaf-cached '
        '${_byName(results, 'one leaf, boundaries, cache on').median}')
    ..writeln('BUDGET paint.boundary-one-leaf-uncached '
        '${_byName(results, 'one leaf, boundaries, cache off').median}');
}

/// Prints `before -> after` with the ratio, and says plainly when there is not
/// one. A benchmark that reports only the winning column is how a feature that
/// does nothing survives.
void _speedup(List<_Result> results, String before, String after) {
  final _Result a = _byName(results, before);
  final _Result b = _byName(results, after);
  final double ratio = a.median / (b.median == 0 ? 1 : b.median);
  stdout.writeln(
    '${before.padRight(34)} ${_us(a.median).padLeft(9)}  ->  '
    '${_us(b.median).padLeft(9)}   '
    '${ratio >= 1.05 ? '${ratio.toStringAsFixed(2)}x faster' : ratio <= 0.95 ? '${(1 / ratio).toStringAsFixed(2)}x SLOWER' : 'no difference'}',
  );
}

_Result _byName(List<_Result> results, String name) =>
    results.firstWhere((_Result r) => r.name == name);

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

/// The headline: one leaf of one panel changes colour per frame.
_Result _oneLeafPerFrame({required bool boundaries, required bool caching}) {
  final _Scene scene = _Scene(boundaries: boundaries, caching: caching);
  scene.frame();
  int tick = 0;
  return _measure(
    boundaries
        ? 'one leaf, boundaries, cache ${caching ? 'on' : 'off'}'
        : 'one leaf, no boundaries',
    () {
      scene.victim.color = (tick++).isEven ? 0xFFCC3311 : 0xFF11CC33;
      scene.frame();
    },
  );
}

/// The frame nobody touched, which is most of them in a real application: a
/// blinking caret, a hovered button, a window that just came back to the front.
_Result _nothingChanges({required bool boundaries, required bool caching}) {
  final _Scene scene = _Scene(boundaries: boundaries, caching: caching);
  scene.frame();
  return _measure(
    'nothing changed, cache ${caching ? 'on' : 'off'}',
    scene.frame,
  );
}

/// The adversarial frame: every panel dirty, so every cache is dropped and
/// re-recorded and every one of those recordings is then copied into the
/// frame. If caching costs anything, it costs it here.
_Result _everyPanelDirty({required bool caching}) {
  final _Scene scene = _Scene(boundaries: true, caching: caching);
  scene.frame();
  int tick = 0;
  return _measure('every panel dirty, cache ${caching ? 'on' : 'off'}', () {
    final int color = (tick++).isEven ? 0xFFCC3311 : 0xFF11CC33;
    for (final _Block block in scene.firstLeafOfEachPanel) {
      block.color = color;
    }
    scene.frame();
  });
}

/// Scrolling, in the only form this tree can express it: every panel is moved
/// by a pixel, and nothing inside any of them changes. The translated splice
/// is the whole of what is being measured.
_Result _panelsMove({required bool caching}) {
  final _Scene scene = _Scene(boundaries: true, caching: caching);
  scene.frame();
  int tick = 0;
  return _measure('panels moved, cache ${caching ? 'on' : 'off'}', () {
    scene.column.scrollBy((tick++).isEven ? 1.0 : -1.0);
    scene.frame();
  });
}

// ---------------------------------------------------------------------------
// The tree
// ---------------------------------------------------------------------------

final class _Scene {
  _Scene({required bool boundaries, required bool caching}) {
    final List<RenderBox> panels = <RenderBox>[];
    for (int p = 0; p < panelCount; p++) {
      final List<RenderBox> leaves = <RenderBox>[];
      for (int leaf = 0; leaf < leavesPerPanel; leaf++) {
        final _Block block = _Block(color: 0xFF204080);
        if (leaf == 0) firstLeafOfEachPanel.add(block);
        if (p == 0 && leaf == 0) victim = block;
        leaves.add(block);
      }
      final RenderBox panel = _Row(leaves);
      panels.add(boundaries ? RenderRepaintBoundary(child: panel) : panel);
    }
    column = _Column(panels);
    owner = PipelineOwner(
      rootConstraints: BoxConstraints.tight(const Size(1200, 900)),
    )
      ..repaintBoundaryCaching = caching
      ..root = column;
  }

  final List<_Block> firstLeafOfEachPanel = <_Block>[];
  late final _Block victim;
  late final _Column column;
  late final PipelineOwner owner;

  /// One arena reused, because the encoder is one: a fresh [DisplayList] per
  /// frame would measure the allocator rather than the tree.
  final DisplayList _list = DisplayList();

  void frame() {
    _list.reset();
    owner
      ..flushLayout()
      ..flushPaint(_list);
  }
}

/// A leaf that fills its box with one colour.
final class _Block extends RenderBox {
  _Block({required int color}) : _color = color;

  int _color;

  set color(int value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    size = constraints.constrain(const Size(6, 6));
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final int paint = list.addPaint(colorArgb: _color);
    list.drawRect(
      offset.dx,
      offset.dy,
      offset.dx + size.width,
      offset.dy + size.height,
      paint,
    );
  }
}

/// Children in a horizontal line, each its own relayout boundary.
final class _Row extends RenderBoxContainer<BoxParentData> {
  _Row(List<RenderBox> children) {
    for (final RenderBox child in children) {
      add(child);
    }
  }

  @override
  void performLayout() {
    double x = 0;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(BoxConstraints.tight(const Size(6, 6)));
      childParentData(child).offset = Offset(x, 0);
      x += 6;
    }
    size = constraints.constrain(Size(x, 6));
  }
}

/// Children stacked vertically, with a scroll offset the benchmark can nudge.
///
/// The offset is applied here rather than by a transform node on purpose: it
/// moves the children's [BoxParentData.offset] without re-laying any of them
/// out, which is exactly the arrangement under which a boundary that moved
/// still owns a valid recording.
final class _Column extends RenderBoxContainer<BoxParentData> {
  _Column(List<RenderBox> children) {
    for (final RenderBox child in children) {
      add(child);
    }
  }

  double _scroll = 0;

  void scrollBy(double delta) {
    _scroll += delta;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    double y = _scroll;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(BoxConstraints.loose(constraints.biggest));
      childParentData(child).offset = Offset(0, y);
      y += 6;
    }
    size = constraints.biggest;
  }
}

// ---------------------------------------------------------------------------
// Reporting - the same shape as widget_tree_benchmark.dart
// ---------------------------------------------------------------------------

final class _Result {
  _Result(this.name, this.samples);

  final String name;
  final List<int> samples;

  int get median => _percentile(50);

  int get p95 => _percentile(95);

  int get worst => samples.reduce((int a, int b) => a > b ? a : b);

  int _percentile(double percentile) {
    final List<int> sorted = List<int>.of(samples)..sort();
    final int rank = (percentile / 100 * sorted.length).ceil();
    return sorted[(rank - 1).clamp(0, sorted.length - 1)];
  }
}

_Result _measure(String name, void Function() body) {
  for (int i = 0; i < warmupIterations; i++) {
    body();
  }
  final List<int> samples = <int>[];
  final Stopwatch stopwatch = Stopwatch();
  for (int i = 0; i < measuredIterations; i++) {
    stopwatch
      ..reset()
      ..start();
    body();
    stopwatch.stop();
    samples.add(stopwatch.elapsedMicroseconds);
  }
  return _Result(name, samples);
}

String _us(int microseconds) => microseconds >= 1000
    ? '${(microseconds / 1000).toStringAsFixed(2)}ms'
    : '${microseconds}us';

/// Whether assertions are on, which is the single biggest thing separating
/// these numbers from the ones a shipped build produces.
bool get _assertionsEnabled {
  bool enabled = false;
  assert(() {
    enabled = true;
    return true;
  }());
  return enabled;
}
