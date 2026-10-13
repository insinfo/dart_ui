/// Opens the vector editor, then maximizes (or resizes) its window after a
/// few seconds the way the window system does it, so a white window after
/// a zoom or a title-bar double click can be seen without touching the Mac.
///
/// ```
/// dart run tool/macos_resize_probe.dart --max     # AppKit zoom:, animated
/// dart run tool/macos_resize_probe.dart           # one programmatic resize
/// DART_UI_PRESENTATION=macos-iosurface dart run tool/macos_resize_probe.dart --max
/// ```
///
/// Capture the window afterwards (a `CGWindowList` lister plus
/// `screencapture -l<id>`); it must show the editor, not white. Prints the
/// framework errors at the end.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

import '../examples/vector_editor_demo/app.dart';

Future<void> main(List<String> args) async {
  FrameworkFonts.install();
  final options = ApplicationOptions.fromArguments(args,
      environment: Platform.environment,
      title: 'Resize probe',
      size: const Size(1000, 700));
  final app = await Application.start(
    rootWidget: const VectorEditorApp(),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  Timer(const Duration(seconds: 4), () {
    final NativeWindow window = app.primaryWindow.nativeWindow;
    if (window case final WindowStateControl w when args.contains('--max')) {
      stderr.writeln('maximize: ${w.requestState(WindowState.maximised)}');
    } else {
      window.setBounds(const Rect.fromLTWH(60, 60, 1500, 900));
      stderr.writeln('resized');
    }
  });
  Timer(const Duration(seconds: 9), () {
    final errors = app.primaryWindow.buildOwner.errorReporter.errors;
    stderr.writeln('errors: ${errors.length}');
    for (final e in errors.take(3)) {
      stderr.writeln('${e.cause}\n${e.stackTrace}');
    }
  });
  await app.run();
}
