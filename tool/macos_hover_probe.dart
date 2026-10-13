/// Moves the pointer over the vector editor and in and out of its window
/// for a while, so a flicker on hover can be caught by capturing the window
/// meanwhile (`screencapture -l<id>` in a loop). Without accessibility: the
/// host posts the events into its own queue.
///
/// ```
/// dart run tool/macos_hover_probe.dart
/// ```
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';

import '../examples/vector_editor_demo/app.dart';

Future<void> main(List<String> args) async {
  FrameworkFonts.install();
  final options = ApplicationOptions.fromArguments(args,
      environment: Platform.environment,
      title: 'Hover probe',
      size: const Size(1400, 880));
  final app = await Application.start(
    rootWidget: const VectorEditorApp(),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  final NativeWindow native = app.primaryWindow.nativeWindow;
  Timer(const Duration(seconds: 4), () async {
    if (native is! MacosWindow) return;
    stderr.writeln('HOVER start');
    if (args.contains('--dwell')) {
      // Rest on each standard-toolbar button long enough for its tooltip.
      for (var x = 20; x <= 420; x += 26) {
        native.synthesizeInput('SYNTH_MOUSE move $x 46 0 0 0');
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
      stderr.writeln('HOVER done');
      return;
    }
    final start = DateTime.now();
    var i = 0;
    while (DateTime.now().difference(start).inSeconds < 8) {
      i++;
      final double t = i / 20;
      final x = 700 + 600 * math.sin(t);
      final y = 440 + 380 * math.cos(t * 1.3);
      native
          .synthesizeInput('SYNTH_MOUSE move ${x.round()} ${y.round()} 0 0 0');
      if (i % 15 == 0) native.synthesizeInput('SYNTH_POINTER leave');
      if (i % 15 == 3) native.synthesizeInput('SYNTH_POINTER enter');
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    stderr.writeln('HOVER done '
        'errors=${app.primaryWindow.buildOwner.errorReporter.errors.length} '
        'presented=${app.primaryWindow.framesPresented}');
  });
  await app.run();
}
