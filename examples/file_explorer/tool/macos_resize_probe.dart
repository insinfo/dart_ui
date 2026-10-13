/// Grows the explorer's window the way dragging its corner does, on the real
/// macOS host, and measures whether each step of the resize got a frame of
/// its size - so "the window goes white while I resize it" is a number and a
/// set of captures. Without accessibility: the host drives its own resize.
///
/// ```
/// dart run tool/macos_resize_probe.dart <folder> [--steps=120] [--ms=16]
///     [--dw=400] [--dh=200] [--mode=live|bounds] [--shots=dir] [--dark]
/// ```
///
/// `--mode=live` (the default) sends `SYNTH_LIVE_RESIZE`: a timer in the host
/// calls `setFrame:display:` once per step on the main thread, as AppKit's
/// resize loop does, and the host writes back per step how long it waited
/// for the frame and whether one of the new size arrived. Set
/// `DART_UI_MACOS_SYNC_RESIZE=0` to see the same sweep without the wait.
/// `--mode=bounds` resizes from Dart with `setBounds`, which works with any
/// host binary - the way to measure a host built before the live resize.
///
/// While it runs it captures the window with `screencapture -l` as fast as
/// that allows and reports, per capture, how much of the strip along the
/// right edge differs from what the explorer draws there at rest: white, or
/// anything that is not a frame of the current size.
library;

import 'dart:async';
import 'dart:convert';
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
  String? text(String name) => args
      .where((String a) => a.startsWith('--$name='))
      .map((String a) => a.substring(name.length + 3))
      .firstOrNull;
  int number(String name, int fallback) =>
      int.tryParse(text(name) ?? '') ?? fallback;
  final String folder =
      args.where((String a) => !a.startsWith('--')).firstOrNull ??
          Directory.current.path;
  final int steps = number('steps', 120);
  final int stepMs = number('ms', 16);
  final int dw = number('dw', 400);
  final int dh = number('dh', 200);
  final String mode = text('mode') ?? 'live';
  final String shots = text('shots') ?? Directory.systemTemp.path;
  final ExplorerModel model = ExplorerModel(
    fs: IoFileSystem(),
    places: const <Place, String>{},
    strings: ExplorerStrings.forLocale('pt'),
    start: FolderLocation(Directory(folder).absolute.path),
  );
  final options = ApplicationOptions.fromArguments(args,
      environment: Platform.environment,
      title: 'Resize probe',
      size: const Size(1000, 640),
      titleBar: WindowTitleBar.hidden);
  final app = await Application.start(
    rootWidget: FileExplorerApp(model: model, dark: args.contains('--dark')),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );

  Timer(const Duration(seconds: 6), () async {
    final NativeWindow main = app.primaryWindow.nativeWindow;
    if (main is! MacosWindow) {
      stderr.writeln('not the macOS host');
      exit(2);
    }
    final int id = main.hostWindowNumber;
    Directory(shots).createSync(recursive: true);

    // Decoding is done after the sweep: a PNG decoded on this isolate holds
    // up the application it is measuring.
    Future<String?> shoot(String name) async {
      final String path = '$shots/$name.png';
      final ProcessResult r = await Process.run(
          'screencapture', <String>['-x', '-o', '-l$id', path]);
      if (r.exitCode != 0 || !File(path).existsSync()) return null;
      return path;
    }

    DecodedImage? decode(String? path) {
      if (path == null) return null;
      try {
        return decodePng(File(path).readAsBytesSync());
      } on Object {
        return null;
      }
    }

    Future<DecodedImage?> capture(String name) async =>
        decode(await shoot(name));

    // The explorer at rest: the colours down its right edge are what every
    // frame of the right size has there.
    final DecodedImage? rest = await capture('resize_rest');
    if (rest == null) {
      stderr.writeln('capture failed (Screen Recording permission?)');
      exit(1);
    }
    final List<int> reference = _rightEdge(rest);

    final String report =
        '${Directory.systemTemp.createTempSync('resize_probe').path}/report';
    final int framesBefore = app.framesPresented;
    app.statistics.clear();
    stderr.writeln('SWEEP_START');
    final Stopwatch clock = Stopwatch()..start();
    bool sweeping = true;
    if (mode == 'live') {
      main.synthesizeInput('SYNTH_LIVE_RESIZE $dw $dh $steps $stepMs '
          '${base64.encode(utf8.encode(report))}');
      unawaited(() async {
        while (!File(report).existsSync()) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        sweeping = false;
      }());
    } else {
      final Offset origin = main.clientToScreen(Offset.zero);
      final Size start = main.clientSize;
      unawaited(() async {
        for (int i = 1; i <= steps; i++) {
          main.setBounds(Rect.fromLTWH(origin.dx, origin.dy,
              start.width + dw * i / steps, start.height + dh * i / steps));
          await Future<void>.delayed(Duration(milliseconds: stepMs));
        }
        sweeping = false;
      }());
    }

    final List<String> paths = <String>[];
    int index = 0;
    while (sweeping) {
      final String? path = await shoot('resize_${index++}');
      if (path != null) paths.add(path);
    }
    final double seconds = clock.elapsedMicroseconds / 1e6;
    stderr.writeln('SWEEP_END');
    final List<String> verdicts = <String>[];
    int exposedShots = 0;
    for (final String path in paths) {
      final DecodedImage? shot = decode(path);
      if (shot == null) continue;
      final double off = _mismatch(_rightEdge(shot), reference);
      if (off > 0.2) exposedShots++;
      verdicts.add('${shot.width}x${shot.height}:'
          '${(off * 100).toStringAsFixed(0)}%');
    }
    final int frames = app.framesPresented - framesBefore;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final DecodedImage? end = await capture('resize_end');
    stderr
      ..writeln('MODE $mode steps=$steps every ${stepMs}ms, '
          '+${dw}x$dh pt in ${seconds.toStringAsFixed(2)} s')
      ..writeln('FRAMES $frames presented during the sweep '
          '(${(frames / steps).toStringAsFixed(2)} per step)');
    final List<FrameTiming> timings = app.statistics.frames;
    double mean(int Function(FrameTiming t) of) => timings.isEmpty
        ? 0
        : timings.map(of).reduce((int a, int b) => a + b) /
            timings.length /
            1000;
    stderr.writeln(
        'FRAME MEAN build=${mean((t) => t.build).toStringAsFixed(2)} '
        'layout=${mean((t) => t.layout).toStringAsFixed(2)} '
        'paint=${mean((t) => t.paint).toStringAsFixed(2)} '
        'raster=${mean((t) => t.raster).toStringAsFixed(2)} ms, '
        'p50=${(app.statistics.percentileTotal(50) / 1000).toStringAsFixed(2)} '
        'p95=${(app.statistics.percentileTotal(95) / 1000).toStringAsFixed(2)} ms');
    if (File(report).existsSync()) {
      for (final String line in File(report).readAsLinesSync()) {
        stderr.writeln('HOST $line');
      }
    }
    stderr
      ..writeln('SHOTS ${verdicts.length}, right edge off the rest frame in '
          '$exposedShots: ${verdicts.join(' ')}')
      ..writeln('END ${end == null ? '-' : '${end.width}x${end.height} '
          'off=${(_mismatch(_rightEdge(end), reference) * 100).toStringAsFixed(0)}%'}')
      ..writeln('SHOTS_DIR $shots')
      ..writeln('DONE errors='
          '${app.primaryWindow.buildOwner.errorReporter.errors.length}');
    exit(0);
  });
  await app.run();
}

/// The colours of the column six device pixels in from the right edge,
/// between a third and two thirds of the height - the explorer's background
/// beside its file list, in a frame that fills the window.
List<int> _rightEdge(DecodedImage image) {
  final int x = image.width - 6;
  return <int>[
    for (int y = image.height ~/ 3; y < image.height * 2 ~/ 3; y += 4)
      image.argbAt(x, y),
  ];
}

/// The fraction of [sample] further than a few levels from [reference]'s
/// dominant colour.
double _mismatch(List<int> sample, List<int> reference) {
  final Map<int, int> counts = <int, int>{};
  for (final int c in reference) {
    counts[c] = (counts[c] ?? 0) + 1;
  }
  final int expected =
      counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  int off = 0;
  for (final int c in sample) {
    int d = 0;
    for (final int shift in <int>[16, 8, 0]) {
      final int delta = ((c >> shift) & 0xFF) - ((expected >> shift) & 0xFF);
      if (delta.abs() > d) d = delta.abs();
    }
    if (d > 4) off++;
  }
  return sample.isEmpty ? 0 : off / sample.length;
}
