/// Starts the explorer the way `bin/file_explorer.dart` does, then performs
/// the window's Close item on the real macOS host - the same request as the
/// red button - and says whether the process ends.
///
/// ```
/// dart run tool/macos_close_probe.dart
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/io/io_file_system.dart';
import 'package:file_explorer/src/io/thumbnail_loader.dart';
import 'package:file_explorer/src/ui/app.dart';

Future<void> main(List<String> args) async {
  FrameworkFonts.install();
  final ExplorerModel model = ExplorerModel(
    fs: IoFileSystem(),
    places: const <Place, String>{},
    start: FolderLocation(Directory.current.absolute.path),
  );
  final ThumbnailWorkers thumbnails = ThumbnailWorkers();
  final Stopwatch sinceClose = Stopwatch();
  await runApp(
    FileExplorerApp(
      model: model,
      thumbnailLoader: thumbnails.load,
    ),
    options: ApplicationOptions.fromArguments(args,
        environment: Platform.environment,
        title: 'Close probe',
        size: const Size(900, 600)),
    onStarted: (Application app) {
      Timer(const Duration(seconds: 3), () {
        final NativeWindow native = app.primaryWindow.nativeWindow;
        stderr.writeln('CLOSE requested');
        sinceClose.start();
        if (native is MacosWindow) {
          native.synthesizeInput(
              'SYNTH_MENU ${base64.encode(utf8.encode('Close'))}');
        }
      });
    },
  );
  stderr.writeln('RUNAPP returned ${sinceClose.elapsedMilliseconds} ms '
      'after the close');
  thumbnails.close();
  model.dispose();
}
