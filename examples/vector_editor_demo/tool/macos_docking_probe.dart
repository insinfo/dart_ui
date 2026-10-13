/// Drives the vector editor's docking on macOS without touching the Mac:
/// drags the Objects panel to the left edge, then drags the Align tab out
/// of the layout so it floats in a window of its own. Capture the windows
/// between steps (a `CGWindowList` lister plus `screencapture -l<id>`).
///
/// ```
/// dart run tool/macos_docking_probe.dart
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';

import 'package:vector_editor_demo/src/ui/app.dart';

Future<void> main(List<String> args) async {
  FrameworkFonts.install();
  final options = ApplicationOptions.fromArguments(args,
      environment: Platform.environment,
      title: 'Docking probe',
      size: const Size(1400, 880));
  final app = await Application.start(
    rootWidget: const VectorEditorApp(),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  final NativeWindow native = app.primaryWindow.nativeWindow;
  Future<void> drag(Offset from, Offset to) async {
    if (native is! MacosWindow) return;
    void send(String verb, Offset at) => native.synthesizeInput(
        'SYNTH_MOUSE $verb ${at.dx.round()} ${at.dy.round()} 0 1 0');
    send('move', from);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    send('down', from);
    for (var i = 1; i <= 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      send('drag', Offset.lerp(from, to, i / 12)!);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    send('up', to);
  }

  Timer(const Duration(seconds: 5), () async {
    stderr.writeln('STEP objects-left');
    await drag(const Offset(1150, 577), const Offset(46, 450));
  });
  Timer(const Duration(seconds: 9), () async {
    stderr.writeln('STEP align-float');
    await drag(const Offset(1092, 111), const Offset(700, 40));
  });
  Timer(const Duration(seconds: 14), () {
    stderr.writeln(
        'STEP done errors=${app.primaryWindow.buildOwner.errorReporter.errors.length}');
    for (final e in app.primaryWindow.buildOwner.errorReporter.errors.take(3)) {
      stderr.writeln('${e.cause}\n${e.stackTrace}');
    }
  });
  await app.run();
}
