/// The ten-thousand-node benchmark from the Fase 6 gate.
///
/// Section 36.1 asks for a methodology, not a number shouted into a log: each
/// case is warmed up, run a fixed number of times, and reported as a
/// distribution, because the mean of a UI frame time is the least interesting
/// statistic it has. The budgets in section 36.3 are what these are compared
/// against.
///
/// Run with:
///
/// ```
/// dart run benchmark/widget_tree_benchmark.dart
/// dart compile exe benchmark/widget_tree_benchmark.dart && ...
/// ```
///
/// The report prints whether assertions were on, which is the single biggest
/// difference between these numbers and a shipped build.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

const int nodeCount = 10000;
const int warmupIterations = 5;
const int measuredIterations = 20;

void main(List<String> arguments) {
  final bool verbose = arguments.contains('--verbose');
  final List<_Result> results = <_Result>[
    _benchmarkColdBuild(),
    _benchmarkRebuildUnchanged(),
    _benchmarkSetStateOneLeaf(),
    _benchmarkLayoutOnly(),
    _benchmarkPaintOnly(),
    _benchmarkHitTest(),
    _benchmarkVirtualizedList(),
    _benchmarkSemantics(),
  ];

  stdout
    ..writeln('dart_ui widget benchmark  ($nodeCount nodes, '
        'asserts ${_assertionsEnabled ? 'on' : 'off'})')
    ..writeln('${'case'.padRight(34)}  ${'median'.padLeft(9)}  '
        '${'p95'.padLeft(9)}  ${'worst'.padLeft(9)}');
  for (final _Result result in results) {
    stdout.writeln(
      '${result.name.padRight(34)}  ${_us(result.median).padLeft(9)}  '
      '${_us(result.p95).padLeft(9)}  ${_us(result.worst).padLeft(9)}',
    );
    if (verbose) stdout.writeln('    samples: ${result.samples}');
  }

  final _Result setState =
      results.firstWhere((_Result r) => r.name.startsWith('setState'));
  stdout
    ..writeln()
    ..writeln('Budget check (section 36.3):')
    ..writeln('  a one-leaf setState in a $nodeCount-node tree should stay '
        'far inside one 16.6 ms frame')
    ..writeln('  -> median ${_us(setState.median)}, '
        '${setState.median <= 16667 ? 'PASS' : 'FAIL'}');

  if (setState.median > 16667) exitCode = 1;
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

/// Mount a ten-thousand-node tree from nothing.
_Result _benchmarkColdBuild() => _measure('cold build', () {
      final _Harness harness = _Harness();
      harness
        ..mount(_wideTree(nodeCount))
        ..drawFrame();
      harness.dispose();
    });

/// Re-run the whole tree with an identical description.
_Result _benchmarkRebuildUnchanged() {
  final _Harness harness = _Harness()..mount(_wideTree(nodeCount));
  harness.drawFrame();
  final _Result result = _measure('rebuild, nothing changed', () {
    harness
      ..mount(_wideTree(nodeCount))
      ..drawFrame();
  });
  harness.dispose();
  return result;
}

/// The number that matters: one leaf changes in a huge tree.
///
/// Relayout boundaries and the dirty-list ordering are what keep this from
/// being proportional to the tree, and this case is how that claim is checked.
_Result _benchmarkSetStateOneLeaf() {
  final _Counter counter = _Counter();
  final _Harness harness = _Harness()
    ..mount(_treeWithOneMutableLeaf(nodeCount, counter));
  harness.drawFrame();

  final _Result result = _measure('setState on one leaf', () {
    counter.bump();
    harness.owner.buildScope();
    harness.drawFrame();
  });
  harness.dispose();
  return result;
}

/// Layout alone, with the tree already built.
_Result _benchmarkLayoutOnly() {
  final _Harness harness = _Harness()..mount(_wideTree(nodeCount));
  harness.drawFrame();
  final _Result result = _measure('layout, all dirty', () {
    harness.owner.renderRoot?.markNeedsLayout();
    harness.drawFrame();
  });
  harness.dispose();
  return result;
}

/// Paint alone: how long it takes to turn the tree into a display list.
_Result _benchmarkPaintOnly() {
  final _Harness harness = _Harness()..mount(_wideTree(nodeCount));
  harness.drawFrame();
  final _Result result = _measure('paint to display list', harness.drawFrame);
  harness.dispose();
  return result;
}

/// One pointer event through a ten-thousand-node tree.
_Result _benchmarkHitTest() {
  final _Harness harness = _Harness()..mount(_wideTree(nodeCount));
  harness.drawFrame();
  final _Result result = _measure('hit-test one pointer', () {
    harness.owner.dispatchPointerEvent(const PointerDownEvent(
      windowId: NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: Offset(20, 300),
      button: PointerButton.primary,
    ));
  });
  harness.dispose();
  return result;
}

/// The same node count as a virtualized list, which must cost far less.
_Result _benchmarkVirtualizedList() {
  final ScrollPosition scroll = ScrollPosition();
  final _Harness harness = _Harness(size: const Size(300, 400));
  Widget build() => ListBox(
        itemCount: nodeCount,
        controller: scroll,
        itemBuilder: (BuildContext context, int index) => Text('ITEM $index'),
      );
  harness.mount(build());
  harness.drawFrame();

  final _Result result = _measure('scroll a $nodeCount-item list', () {
    scroll.applyDelta(40);
    harness
      ..mount(build())
      ..drawFrame();
  });
  harness.dispose();
  return result;
}

/// Building the semantic tree for the whole thing.
_Result _benchmarkSemantics() {
  final _Harness harness = _Harness()..mount(_wideTree(nodeCount));
  harness.drawFrame();
  final _Result result = _measure(
    'semantics for the whole tree',
    () => harness.owner.buildSemantics(),
  );
  harness.dispose();
  return result;
}

// ---------------------------------------------------------------------------
// Tree shapes
// ---------------------------------------------------------------------------

/// A broad, shallow tree: rows of leaves inside one column.
///
/// Shallow on purpose. A deep tree measures recursion, and real UIs are wide;
/// the pathological-depth case belongs in its own benchmark rather than
/// silently dominating this one.
Widget _wideTree(int leaves) {
  const int perRow = 20;
  final int rows = (leaves / perRow).ceil();
  return Column(children: <Widget>[
    for (int row = 0; row < rows; row++)
      Row(children: <Widget>[
        for (int column = 0; column < perRow; column++)
          const SizedBox(
              width: 4, height: 4, child: ColoredBox(color: 0xFF204080)),
      ]),
  ]);
}

Widget _treeWithOneMutableLeaf(int leaves, _Counter counter) {
  const int perRow = 20;
  final int rows = (leaves / perRow).ceil();
  return Column(children: <Widget>[
    _CounterLeaf(counter: counter),
    for (int row = 0; row < rows; row++)
      Row(children: <Widget>[
        for (int column = 0; column < perRow; column++)
          const SizedBox(
              width: 4, height: 4, child: ColoredBox(color: 0xFF204080)),
      ]),
  ]);
}

/// A leaf whose state a benchmark can poke from outside the tree.
final class _Counter {
  void Function()? _onBump;
  int value = 0;

  void bump() {
    value++;
    _onBump?.call();
  }
}

final class _CounterLeaf extends StatefulWidget {
  const _CounterLeaf({required this.counter});

  final _Counter counter;

  @override
  State<_CounterLeaf> createState() => _CounterLeafState();
}

final class _CounterLeafState extends State<_CounterLeaf> {
  @override
  void initState() {
    super.initState();
    widget.counter._onBump = () {
      if (mounted) setState(() {});
    };
  }

  @override
  Widget build(BuildContext context) => Text('${widget.counter.value}');
}

// ---------------------------------------------------------------------------
// Harness and reporting
// ---------------------------------------------------------------------------

final class _Harness {
  _Harness({Size size = const Size(400, 3000)}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );
  }

  late final BuildOwner owner;
  final DisplayList _list = DisplayList();

  void mount(Widget widget) => owner.updateRoot(widget);

  /// Reuses one display list, because the encoder is an arena: allocating a
  /// fresh one per frame would measure the allocator rather than the tree.
  void drawFrame() {
    _list.reset();
    owner.pipelineOwner.drawFrame(_list);
  }

  void dispose() => owner.dispose();
}

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
///
/// Reported rather than inferred: `dart run` disables them, `dart test`
/// enables them, and an AOT build has neither them nor a way to ask. Printing
/// the fact is honest; guessing "AOT" from it would not be.
bool get _assertionsEnabled {
  bool enabled = false;
  assert(() {
    enabled = true;
    return true;
  }());
  return enabled;
}
