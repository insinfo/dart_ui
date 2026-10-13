/// Drags the Name column's divider in Details view on the real macOS host
/// and reports what each frame of the drag cost - so "the column drag
/// stutters" is a number before and after a change, not an impression.
/// Without accessibility: the host posts the mouse events into its own queue.
///
/// ```
/// dart run tool/macos_column_drag_probe.dart <folder> [--moves=240] [--hz=120]
///     [--delay=4] [--warmup=240] [--immediate] [--shot=file.png]
/// ```
///
/// Point it at a folder with a couple of hundred items. Prints the frames
/// presented during the drag, the per-phase means (build, layout, paint,
/// raster - raster being encode, GPU and present) and the p50/p95/max frame
/// totals, plus the column width the grid ended at (proof the drag landed).
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/engine/strings.dart';
import 'package:file_explorer/src/io/io_file_system.dart';
import 'package:file_explorer/src/ui/app.dart';

Future<void> main(List<String> args) async {
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();
  final String folder =
      args.where((String a) => !a.startsWith('--')).firstOrNull ??
          Directory.current.path;
  int option(String name, int fallback) =>
      args
          .where((String a) => a.startsWith('--$name='))
          .map((String a) => int.tryParse(a.substring(name.length + 3)))
          .firstOrNull ??
      fallback;
  final int moves = option('moves', 240);
  final int hz = option('hz', 120);
  final int delay = option('delay', 4);
  // Drags done first and not measured: under `dart run` the first frames of
  // a new code path are still being compiled.
  final int warmup = option('warmup', 0);
  final String? shot = args
      .where((String a) => a.startsWith('--shot='))
      .map((String a) => a.substring(7))
      .firstOrNull;
  final ExplorerModel model = ExplorerModel(
    fs: IoFileSystem(),
    places: const <Place, String>{},
    strings: ExplorerStrings.forLocale('pt'),
    start: FolderLocation(Directory(folder).absolute.path),
  );
  final options = ApplicationOptions.fromArguments(args,
      environment: Platform.environment,
      title: 'Column drag probe',
      size: const Size(1280, 800),
      titleBar: WindowTitleBar.hidden);
  final app = await Application.start(
    rootWidget: FileExplorerApp(model: model, dark: args.contains('--dark')),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );

  RenderDataGridHeader? findHeader(RenderBox? node) {
    if (node == null) return null;
    if (node is RenderDataGridHeader) return node;
    RenderDataGridHeader? found;
    node.visitChildren((RenderBox child) => found ??= findHeader(child));
    return found;
  }

  Timer(Duration(seconds: delay), () async {
    final NativeWindow main = app.primaryWindow.nativeWindow;
    if (main is! MacosWindow) {
      stderr.writeln('not the macOS host');
      exit(2);
    }
    // Unpaced, the frame times are the work itself; paced (the default,
    // FIFO) the present waits for the display and "raster" includes it.
    if (args.contains('--immediate')) {
      main.requestPresentMode(PresentMode.immediate);
    }
    final RenderDataGridHeader? header =
        findHeader(app.primaryWindow.pipelineOwner.root);
    if (header == null) {
      stderr.writeln('NO DATAGRID HEADER (is the folder empty?)');
      exit(1);
    }
    final Offset origin = header.globalOffset;
    final double startWidth = header.widths.first;
    // The divider after the first column, mid-height of the header.
    final double x0 = origin.dx + startWidth;
    final double y = origin.dy + header.size.height / 2;
    stderr.writeln(
        'HEADER at $origin width0=$startWidth rows=${model.tab.visible.length}');

    main
      ..synthesizeInput('SYNTH_POINTER enter')
      ..synthesizeInput('SYNTH_MOUSE move ${x0 - 0.5} $y 0 0 0');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (warmup > 0) {
      main.synthesizeInput('SYNTH_MOUSE down ${x0 - 0.5} $y 0 1 0');
      for (int i = 0; i < warmup; i++) {
        final int phase = i % 80;
        final double wx =
            x0 - 0.5 + (phase < 40 ? phase * 4.0 : (80 - phase) * 4.0);
        main.synthesizeInput('SYNTH_MOUSE drag $wx $y 0 1 0');
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
      main.synthesizeInput('SYNTH_MOUSE up ${x0 - 0.5} $y 0 1 0');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    final int framesBefore = app.framesPresented;
    app.statistics.clear();
    main.synthesizeInput('SYNTH_MOUSE down ${x0 - 0.5} $y 0 1 0');
    final Stopwatch clock = Stopwatch()..start();
    final Duration step = Duration(microseconds: 1000000 ~/ hz);
    double x = x0;
    for (int i = 0; i < moves; i++) {
      // A triangle wave of 160 px: wider, then narrower, as a hand does.
      final int phase = i % 80;
      x = x0 - 0.5 + (phase < 40 ? phase * 4.0 : (80 - phase) * 4.0);
      main.synthesizeInput('SYNTH_MOUSE drag $x $y 0 1 0');
      final Duration due = step * (i + 1);
      final Duration wait = due - clock.elapsed;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    // Hold still long enough for the last frame to land.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final double seconds = clock.elapsedMicroseconds / 1e6;
    if (shot != null) {
      await Process.run(
          'screencapture', <String>['-x', '-l${main.hostWindowNumber}', shot]);
      stderr.writeln('SHOT $shot');
    }
    main.synthesizeInput('SYNTH_MOUSE up $x $y 0 1 0');
    final int frames = app.framesPresented - framesBefore;
    final List<FrameTiming> timings = app.statistics.frames;
    double mean(int Function(FrameTiming t) of) => timings.isEmpty
        ? 0
        : timings.map(of).reduce((int a, int b) => a + b) /
            timings.length /
            1000;
    String ms(num us) => (us / 1000).toStringAsFixed(2);
    stderr
      ..writeln('MOVES $moves at ${hz}Hz in ${seconds.toStringAsFixed(2)} s')
      ..writeln('FRAMES $frames (${(frames / seconds).toStringAsFixed(1)} fps, '
          '${(frames / moves).toStringAsFixed(2)} per move)')
      ..writeln('MEAN build=${mean((t) => t.build).toStringAsFixed(2)} '
          'layout=${mean((t) => t.layout).toStringAsFixed(2)} '
          'paint=${mean((t) => t.paint).toStringAsFixed(2)} '
          'raster=${mean((t) => t.raster).toStringAsFixed(2)} ms')
      ..writeln('TOTAL p50=${ms(app.statistics.percentileTotal(50))} '
          'p95=${ms(app.statistics.percentileTotal(95))} '
          'max=${ms(app.statistics.worstTotal)} ms '
          '(over 16.7 ms: '
          '${app.statistics.framesOverBudget(const Duration(microseconds: 16667))}'
          '/${timings.length})')
      ..writeln('SLOW ${[
        for (final FrameTiming t in timings)
          if (t.total > 16667)
            '${ms(t.total)}=b${ms(t.build)}/l${ms(t.layout)}/p${ms(t.paint)}/r${ms(t.raster)}',
      ].join(' ')}')
      ..writeln('WIDTH ${startWidth.toStringAsFixed(1)} -> '
          '${findHeader(app.primaryWindow.pipelineOwner.root)?.widths.first.toStringAsFixed(1)}')
      ..writeln('DONE errors='
          '${app.primaryWindow.buildOwner.errorReporter.errors.length}');
    // Under tool/frame_timeline_trace.dart the recording is fetched after
    // the drag: stay alive for it.
    final int hold = option('hold', 0);
    if (hold > 0) await Future<void>.delayed(Duration(seconds: hold));
    exit(0);
  });
  await app.run();
}
