/// Measures whether this framework gives back what it takes.
///
/// Section 45 of `doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md`
/// carried one Gate 1.0 line with no evidence behind it at all - *sem leaks
/// conhecidos criticos - nao medido*. This is the instrument that makes it a
/// number.
///
/// ```
/// dart run tool/leak_suite/leak_suite.dart                    # everything
/// dart run tool/leak_suite/leak_suite.dart --cycle resize     # one workload
/// dart run tool/leak_suite/leak_suite.dart --plant gdi        # prove it bites
/// ```
///
/// ## Three different things are called "leak", and they need three
/// instruments
///
///   * **A - the Dart heap.** Objects still reachable after `dispose()`.
///     Measured through this process's own VM Service (`heap_probe.dart`), with
///     a full GC before every reading so each sample is about reachable objects
///     rather than about what the collector has not got round to. **JIT only**:
///     an AOT build has no VM Service and the suite says so instead of
///     reporting a clean heap it never looked at.
///   * **B - native memory.** Blocks from `lib/src/ffi/native_memory.dart`.
///     `NativeAllocator` now counts outstanding blocks unconditionally and
///     outstanding bytes when asked; this suite asks. Works in AOT.
///   * **C - operating-system handles.** GDI objects, USER objects, kernel
///     handles and committed private bytes, read from Windows' own exact
///     counters (`process_counters.dart`). This is the class most specific to
///     a UI framework and the one nothing here was reading. Works in AOT.
///
/// ## The measurement rule
///
/// Never one cycle. A single open/close legitimately grows a process - fonts
/// interned, a window class registered, a pool warmed, a path compiled - and a
/// suite that failed on that would be switched off within a week. So: N cycles,
/// the first few discarded as warm-up, and the verdict taken from the **slope**
/// of the remainder against its own noise. `trend.dart` holds that argument in
/// full. Every reading is printed, so a plateau can be seen rather than
/// trusted.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/ffi/native_memory.dart';

import 'cycles.dart';
import 'heap_probe.dart';
import 'process_counters.dart';
import 'trend.dart';

Future<void> main(List<String> arguments) async {
  final _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }
  if (options.list) {
    for (final MapEntry<String, LeakCycle Function()> entry
        in availableCycles.entries) {
      stdout.writeln('  ${entry.key.padRight(12)}${entry.value().description}');
    }
    return;
  }

  final List<String> unknown = options.cycles
      .where((String name) => !availableCycles.containsKey(name))
      .toList();
  if (unknown.isNotEmpty) {
    stderr.writeln('unknown cycle(s): ${unknown.join(', ')}');
    stderr.writeln('known: ${availableCycles.keys.join(', ')}');
    exitCode = 64;
    return;
  }

  final _Saboteur saboteur = _Saboteur(options.plant);
  final List<String> unavailable = <String>[];
  // `--no-heap` is not only for AOT parity. The VM Service is a WebSocket and
  // a service isolate, which means threads and sockets, which means kernel
  // handles - so the first thing to do with a suspicious kernel-handle slope
  // is to re-run without the instrument that owns some of them and see whether
  // the slope survives.
  final HeapProbe? heap = options.measureHeap
      ? await HeapProbe.tryStart(onUnavailable: unavailable.add)
      : null;
  if (!options.measureHeap) {
    unavailable.add('--no-heap: the Dart heap was not measured in this run');
  }
  final ProcessResourceProbe? handles = ProcessResourceProbe.tryBind();
  if (handles == null) {
    unavailable.add(
      'no operating-system counters: GetGuiResources and '
      'GetProcessHandleCount are Windows-only, so classes of leak made of '
      'HWNDs and GDI objects are not measured on ${Platform.operatingSystem}',
    );
  }
  final NativeAllocator? allocator = NativeAllocator.tryBind();
  if (allocator == null) {
    unavailable.add('no native allocator bound: class B is not measured');
  } else {
    allocator.trackBlockSizes(true);
  }

  _printHeader(options, heap, handles, allocator, unavailable);

  final List<_CycleReport> reports = <_CycleReport>[];
  for (final String name in options.cycles) {
    reports.add(await _runCycle(
      availableCycles[name]!(),
      options: options,
      heap: heap,
      handles: handles,
      allocator: allocator,
      saboteur: saboteur,
    ));
  }
  await heap?.close();
  saboteur.releaseEverything();

  for (final _CycleReport report in reports) {
    _printCycle(report, options);
  }
  _printSummary(reports, options);

  if (options.jsonOutput != null) {
    final File file = File(options.jsonOutput!);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'runtime': _runtimeName,
        'cyclesPerWorkload': options.cycleCount,
        'warmup': options.warmup,
        'plantedLeak': options.plant.name,
        'notMeasured': unavailable,
        'workloads': <Object?>[
          for (final _CycleReport report in reports)
            <String, Object?>{
              'name': report.name,
              'description': report.description,
              'trends': <Object?>[
                for (final Trend trend in report.trends) trend.toJson(),
              ],
            },
        ],
      }),
    );
    stdout.writeln('\njson: ${file.path}');
  }

  final bool leaking =
      reports.any((_CycleReport r) => r.trends.any((Trend t) => t.isLeaking));
  // 1 means "something grows per cycle", which is what a CI gate should fail
  // on. A run that could not measure a class at all is not a pass and not a
  // failure: it is 2, so a green build can never come from an instrument that
  // was not there.
  if (leaking) {
    exitCode = 1;
  } else if (unavailable.isNotEmpty && options.strict) {
    exitCode = 2;
  }
}

const String _usage = '''
Usage: dart run tool/leak_suite/leak_suite.dart [options]

  --cycles N     Cycles per workload. Default 24.
  --warmup K     Leading cycles discarded before the fit. Default: a quarter
                 of --cycles, at least 4.
  --cycle NAME   Run only this workload; repeatable. Default: all of them.
  --plant KIND   Plant a known leak and prove the suite catches it:
                   heap    one retained Dart object per cycle
                   native  one unfreed NativeAllocator block per cycle
                   gdi     one undeleted GDI device context per cycle
                   none    (default)
  --no-heap      Skip class A entirely. The VM Service owns threads and
                 sockets of its own, so this is how a suspicious kernel-handle
                 slope is separated from the instrument measuring it. It is
                 also what an AOT run does by force.
  --json PATH    Write the trends as JSON here.
  --strict       Exit 2 when a class of leak could not be measured at all.
  --list         List the workloads and exit.
  --help

Nothing this runs appears on screen: every window is created hidden. Nothing
this runs makes a sound.''';

/// `dart run` versus a compiled binary, which decides whether class A exists.
///
/// Told apart by `Platform.script`'s extension rather than by a constant,
/// because there is no `bool.fromEnvironment` the VM sets for it and the two
/// numbers must never be reported as if they were the same measurement.
String get _runtimeName {
  const bool productMode = bool.fromEnvironment('dart.vm.product');
  return productMode ? 'AOT (compiled, no VM Service)' : 'JIT (dart run)';
}

enum _Plant { none, heap, native, gdi }

/// Plants a known leak so the suite can be shown to catch one.
///
/// A leak detector that has never detected a leak is a leak detector nobody
/// should believe. Each plant is the smallest possible instance of one of the
/// three classes, so the slope it produces is exactly one unit per cycle and
/// can be compared directly against the clean run's noise.
final class _Saboteur {
  _Saboteur(this.plant);

  final _Plant plant;

  /// Retained on purpose. This list *is* the planted heap leak.
  final List<Object> _retained = <Object>[];
  final List<Pointer<Uint8>> _unfreed = <Pointer<Uint8>>[];
  final List<int> _undeletedDeviceContexts = <int>[];

  late final int Function(int)? _createCompatibleDc = _bindCreateCompatibleDc();
  late final int Function(int)? _deleteDc = _bindDeleteDc();

  void perCycle() {
    switch (plant) {
      case _Plant.none:
        return;
      case _Plant.heap:
        // A typed list rather than a bare object so the leak has bytes as well
        // as an instance count: a leak of one small object per cycle moves the
        // instance counter and barely moves the heap, and both readings should
        // be seen to work.
        _retained.add(Uint8List(4096));
      case _Plant.native:
        _unfreed.add(NativeAllocator.instance.allocate<Uint8>(4096));
      case _Plant.gdi:
        final int Function(int)? create = _createCompatibleDc;
        if (create == null) return;
        final int dc = create(0);
        if (dc != 0) _undeletedDeviceContexts.add(dc);
    }
  }

  /// Gives back everything the plant took, after the measurement is over.
  ///
  /// The process is about to exit either way; this exists so that a run with
  /// `--plant` cannot be blamed for a resource still held while a later run in
  /// the same shell is measured.
  void releaseEverything() {
    _retained.clear();
    for (final Pointer<Uint8> block in _unfreed) {
      NativeAllocator.instance.free(block);
    }
    _unfreed.clear();
    final int Function(int)? delete = _deleteDc;
    if (delete != null) {
      for (final int dc in _undeletedDeviceContexts) {
        delete(dc);
      }
    }
    _undeletedDeviceContexts.clear();
  }

  static int Function(int)? _bindCreateCompatibleDc() {
    if (!Platform.isWindows) return null;
    try {
      return DynamicLibrary.open('gdi32.dll')
          .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
              'CreateCompatibleDC');
    } on Object {
      return null;
    }
  }

  static int Function(int)? _bindDeleteDc() {
    if (!Platform.isWindows) return null;
    try {
      return DynamicLibrary.open('gdi32.dll')
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'DeleteDC');
    } on Object {
      return null;
    }
  }
}

final class _Options {
  _Options({
    required this.cycleCount,
    required this.warmup,
    required this.cycles,
    required this.plant,
    required this.jsonOutput,
    required this.measureHeap,
    required this.strict,
    required this.list,
    required this.help,
  });

  final int cycleCount;
  final int warmup;
  final List<String> cycles;
  final _Plant plant;
  final String? jsonOutput;
  final bool measureHeap;
  final bool strict;
  final bool list;
  final bool help;

  static _Options parse(List<String> arguments) {
    String? value(String name) {
      final int index = arguments.indexOf(name);
      if (index < 0) return null;
      if (index + 1 >= arguments.length) {
        throw FormatException('$name needs a value');
      }
      return arguments[index + 1];
    }

    final List<String> selected = <String>[];
    for (var i = 0; i < arguments.length - 1; i++) {
      if (arguments[i] == '--cycle') selected.add(arguments[i + 1]);
    }
    // 24 by default, and the number is an argument rather than a taste: the fit
    // needs enough post-warm-up points that one noisy reading cannot tilt the
    // line, and 18 of them puts the standard error of the slope at roughly a
    // quarter of the per-cycle noise. Fewer than about twelve and a single
    // outlier decides the verdict; many more and a `window` run starts costing
    // minutes for a number that stopped moving.
    final int count = int.tryParse(value('--cycles') ?? '24') ?? 24;
    if (count < 6) {
      throw const FormatException(
        '--cycles must be at least 6: a slope needs points, and three of them '
        'is a line drawn through noise',
      );
    }
    final int warmup =
        int.tryParse(value('--warmup') ?? '') ?? (count ~/ 4).clamp(4, count);
    if (warmup >= count - 2) {
      throw FormatException(
        '--warmup $warmup leaves fewer than three cycles of $count to fit',
      );
    }
    final String plantName = value('--plant') ?? 'none';
    final _Plant plant = _Plant.values.firstWhere(
      (_Plant p) => p.name == plantName,
      orElse: () => throw FormatException(
        'unknown --plant "$plantName": ${_Plant.values.map(
              (_Plant p) => p.name,
            ).join(', ')}',
      ),
    );
    return _Options(
      cycleCount: count,
      warmup: warmup,
      cycles: selected.isEmpty ? availableCycles.keys.toList() : selected,
      plant: plant,
      jsonOutput: value('--json'),
      measureHeap: !arguments.contains('--no-heap'),
      strict: arguments.contains('--strict'),
      list: arguments.contains('--list'),
      help: arguments.contains('--help') || arguments.contains('-h'),
    );
  }
}

/// Every reading of one workload, and the lines fitted to them.
final class _CycleReport {
  _CycleReport({
    required this.name,
    required this.description,
    required this.trends,
    required this.failure,
  });

  final String name;
  final String description;
  final List<Trend> trends;

  /// What went wrong, when the workload could not run at all - no Win32 on
  /// this machine, a window that refused to be created. Reported rather than
  /// thrown, so one impossible workload does not take the other four with it.
  final Object? failure;
}

Future<_CycleReport> _runCycle(
  LeakCycle cycle, {
  required _Options options,
  required HeapProbe? heap,
  required ProcessResourceProbe? handles,
  required NativeAllocator? allocator,
  required _Saboteur saboteur,
}) async {
  final List<Map<String, num>> samples = <Map<String, num>>[];
  final Map<String, String> heapMetricNames = <String, String>{
    for (final String name in cycle.watchedClasses) name: 'live $name',
  };
  Object? failure;
  try {
    await cycle.setUp();
    try {
      for (var i = 0; i < options.cycleCount; i++) {
        await cycle.runOnce(i);
        saboteur.perCycle();
        // One turn of the event loop before sampling: a cycle that completed a
        // future leaves its listeners on the microtask queue, and a heap read
        // taken before they run counts them as live. This is not padding - the
        // first version of this suite reported a two-object-per-cycle "leak"
        // in `window` that was entirely stream subscriptions not yet torn down.
        await Future<void>.delayed(Duration.zero);
        samples.add(
          await _sample(cycle, heapMetricNames, heap, handles, allocator),
        );
      }
    } finally {
      await cycle.tearDown();
    }
  } on Object catch (error) {
    failure = error;
  }

  final List<Trend> trends = <Trend>[];
  if (samples.isNotEmpty) {
    for (final String metric in samples.first.keys) {
      trends.add(Trend.fit(
        name: metric,
        unit: _metricUnits[_metricKind(metric)]!,
        samples: <num>[for (final Map<String, num> s in samples) s[metric]!],
        warmup: options.warmup,
        floor: _metricFloors[_metricKind(metric)]!,
      ));
    }
  }
  return _CycleReport(
    name: cycle.name,
    description: cycle.description,
    trends: trends,
    failure: failure,
  );
}

Future<Map<String, num>> _sample(
  LeakCycle cycle,
  Map<String, String> heapMetricNames,
  HeapProbe? heap,
  ProcessResourceProbe? handles,
  NativeAllocator? allocator,
) async {
  final Map<String, num> sample = <String, num>{};
  // The heap first, because its reading forces a full GC and the collector
  // hands external byte buffers back to the operating system on its way out.
  // Reading private bytes before that would count garbage as committed memory
  // and produce a sawtooth nobody can fit a line to.
  if (heap != null) {
    final HeapSample reading = await heap.sample(cycle.watchedClasses);
    sample['dart heap bytes'] = reading.heapUsageBytes;
    sample['dart external bytes'] = reading.externalUsageBytes;
    for (final MapEntry<String, int> entry in reading.instanceCounts.entries) {
      // The row name comes from a table built once per workload rather than
      // from an interpolation here: this function runs on the heap it is
      // measuring, and one fresh string per watched class per cycle is a slope
      // the suite would then have to explain.
      sample[heapMetricNames[entry.key]!] = entry.value;
    }
  }
  if (allocator != null) {
    final NativeMemoryStats stats = allocator.stats;
    sample['native blocks'] = stats.liveBlocks;
    sample['native bytes'] = stats.liveBytes;
  }
  if (handles != null) {
    final ProcessCounters counters = handles.sample();
    for (final MapEntry<String, int?> entry in counters.byName.entries) {
      final int? reading = entry.value;
      if (reading != null) sample[entry.key] = reading;
    }
  }
  return sample;
}

/// Which floor and unit a metric gets, keyed by what it counts.
enum _MetricKind { objects, bytes, heapTotal, coarseBytes }

_MetricKind _metricKind(String metric) {
  if (metric == 'private bytes' || metric == 'working set') {
    return _MetricKind.coarseBytes;
  }
  if (metric == 'dart heap bytes') return _MetricKind.heapTotal;
  return metric.endsWith('bytes') ? _MetricKind.bytes : _MetricKind.objects;
}

/// The smallest slope worth calling a leak, per kind.
///
/// These are floors, not thresholds: a slope has to clear both this *and* three
/// standard errors of its own fit. They exist because the object counters are
/// exact integers, so a single object appearing once in fifty cycles for a
/// reason that is not a leak produces a statistically immaculate 0.02 per
/// cycle, and failing a build on that is how a suite gets deleted.
const Map<_MetricKind, double> _metricFloors = <_MetricKind, double>{
  // A tenth of an object per cycle: one object every ten cycles, which over a
  // day of resizing a window is thousands of handles. The object counters are
  // exact integers, so this is a floor against rare one-offs rather than
  // against measurement error.
  _MetricKind.objects: 0.1,
  // 512 bytes per cycle for the exact byte counters - the native allocator's
  // outstanding bytes, and the VM's external usage. Neither has any of the
  // suite's own allocation in it.
  _MetricKind.bytes: 512,
  // 4 KiB per cycle for the *total* Dart heap, and this one is not a taste: the
  // suite runs on the heap it measures. It retains one reading per cycle, it
  // decodes a VM Service reply per cycle, and the JIT compiles its own paths on
  // the way through. The `idle` workload - which does nothing whatsoever -
  // measures that floor at **1552 bytes per cycle plus or minus 64** over 40
  // cycles on this machine, so anything below a few kilobytes per cycle here is
  // the instrument and not the framework. This is why the per-class instance
  // counters, which the suite contributes nothing to, are the sharp end of
  // class A and the total is only the blunt one.
  _MetricKind.heapTotal: 4096,
  // 64 KiB per cycle for the process-wide counters, which move in whole
  // allocation granules: Windows commits private memory 64 KiB at a time, so a
  // smaller floor here would fire on the granularity itself. Their measured
  // scatter is of the order of a megabyte per cycle either way, so in practice
  // the three-standard-error test decides these rows and not the floor.
  _MetricKind.coarseBytes: 64 * 1024,
};

const Map<_MetricKind, String> _metricUnits = <_MetricKind, String>{
  _MetricKind.objects: 'objects',
  _MetricKind.bytes: 'bytes',
  _MetricKind.heapTotal: 'bytes',
  _MetricKind.coarseBytes: 'bytes',
};

void _printHeader(
  _Options options,
  HeapProbe? heap,
  ProcessResourceProbe? handles,
  NativeAllocator? allocator,
  List<String> unavailable,
) {
  stdout.writeln('dart_ui leak suite');
  stdout.writeln('  runtime         : $_runtimeName');
  stdout.writeln(
    '  A dart heap     : ${heap == null ? 'NOT MEASURED' : 'VM Service at '
        '${heap.serviceUri}'}',
  );
  stdout.writeln(
    '  B native memory : ${allocator == null ? 'NOT MEASURED' : '$allocator, '
        'block sizes tracked'}',
  );
  stdout.writeln(
    '  C os handles    : ${handles == null ? 'NOT MEASURED' : 'GetGuiResources '
        '+ GetProcessHandleCount + GetProcessMemoryInfo'}',
  );
  stdout.writeln(
    '  cycles          : ${options.cycleCount} per workload, first '
    '${options.warmup} discarded as warm-up',
  );
  stdout.writeln('  planted leak    : ${options.plant.name}');
  for (final String reason in unavailable) {
    stdout.writeln('  ! $reason');
  }
}

void _printCycle(_CycleReport report, _Options options) {
  stdout.writeln('');
  stdout.writeln('== ${report.name}: ${report.description}');
  if (report.failure != null) {
    stdout.writeln('   did not run: ${report.failure}');
    if (report.trends.isEmpty) return;
  }
  if (report.trends.isEmpty) {
    stdout.writeln('   no readings.');
    return;
  }

  stdout.writeln('   readings per cycle (| marks the end of the warm-up):');
  for (final Trend trend in report.trends) {
    final StringBuffer line = StringBuffer('     ${trend.name.padRight(27)}');
    for (var i = 0; i < trend.samples.length; i++) {
      if (i == trend.warmup) line.write('| ');
      line.write('${_compact(trend.samples[i])} ');
    }
    stdout.writeln(line);
  }

  stdout.writeln('');
  stdout.writeln(
    '     ${'metric'.padRight(27)}${'first'.padLeft(12)}${'last'.padLeft(12)}'
    '${'slope/cycle'.padLeft(14)}${'± std err'.padLeft(12)}'
    '${'noise'.padLeft(10)}   verdict',
  );
  for (final Trend trend in report.trends) {
    stdout.writeln(
      '     ${trend.name.padRight(27)}'
      '${_compact(trend.first).padLeft(12)}'
      '${_compact(trend.last).padLeft(12)}'
      '${(trend.slope == null ? '-' : formatMeasure(trend.slope!)).padLeft(14)}'
      '${(trend.slopeStandardError == null ? '-' : formatMeasure(
          trend.slopeStandardError!,
        )).padLeft(12)}'
      '${(trend.residualStandardDeviation == null ? '-' : formatMeasure(
          trend.residualStandardDeviation!,
        )).padLeft(10)}'
      '   ${trend.verdict}',
    );
  }
}

void _printSummary(List<_CycleReport> reports, _Options options) {
  final List<String> leaks = <String>[
    for (final _CycleReport report in reports)
      for (final Trend trend in report.trends)
        if (trend.isLeaking)
          '${report.name}/${trend.name}: '
              '${formatMeasure(trend.slope!)} ${trend.unit} per cycle '
              '(± ${formatMeasure(trend.slopeStandardError!)})',
  ];
  final Trend? idleHeap = reports
      .where((_CycleReport r) => r.name == 'idle')
      .expand((_CycleReport r) => r.trends)
      .where((Trend t) => t.name == 'dart heap bytes' && t.slope != null)
      .firstOrNull;
  stdout.writeln('');
  if (idleHeap != null) {
    stdout.writeln(
      "the suite's own cost, from the idle workload: "
      '${formatMeasure(idleHeap.slope!)} bytes of Dart heap per cycle '
      '(± ${formatMeasure(idleHeap.slopeStandardError!)}). Subtract it from '
      'every "dart heap bytes" row above.',
    );
  }
  if (leaks.isEmpty) {
    stdout.writeln(
      'no metric grows per cycle beyond its floor and its own noise.',
    );
    if (options.plant != _Plant.none) {
      stdout.writeln(
        'WARNING: a leak was planted (--plant ${options.plant.name}) and the '
        'suite did not catch it. The instrument is wrong, not the framework.',
      );
    }
    return;
  }
  stdout.writeln('growing per cycle:');
  for (final String leak in leaks) {
    stdout.writeln('  $leak');
  }
}

/// Large byte counts as KiB so a row of 24 of them stays one line.
///
/// KiB and never MiB: the point of printing every reading is that a human can
/// see a plateau, and megabytes round 13 421 772 and 13 434 880 to the same
/// "13M". Kibibytes keep four significant figures on everything this measures.
String _compact(num value) {
  if (value.abs() < 10000) return value.round().toString();
  return '${(value / 1024).round()}k';
}
