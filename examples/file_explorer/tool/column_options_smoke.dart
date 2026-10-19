/// Presents the real column chooser and verifies its native-rendered lifetime.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/default_platform_resolver.dart'
    as platform;
import 'package:file_explorer/src/engine/demo_disk.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/engine/strings.dart';
import 'package:file_explorer/src/ui/app.dart';
import 'package:file_explorer/src/ui/explorer_window.dart';

Future<void> main(List<String> args) async {
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();
  late ExplorerWindowState explorer;
  final model = ExplorerModel(
      fs: demoDisk(),
      strings: ExplorerStrings.portuguese,
      places: kDemoPlaces,
      start: const FolderLocation('/Users/ana/Documents'));
  final options = ApplicationOptions.fromArguments(
      args.where((a) => a != '--hold').toList(),
      size: const Size(900, 650),
      title: 'Column options smoke',
      titleBar: WindowTitleBar.hidden,
      visible: true,
      environment: Platform.environment);
  final app = await Application.start(
      rootWidget:
          FileExplorerApp(model: model, onReady: (window) => explorer = window),
      backends:
          platform.PlatformBackendResolver.defaultBackends(options: options),
      presentations: platform.PlatformBackendResolver.defaultPresentations(),
      options: options);
  final running = app.run();
  try {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await model.idle;
    final native = app.primaryWindow.nativeWindow;
    native.setBounds(const Rect.fromLTWH(60, 60, 900, 600));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (app.errors.isNotEmpty) throw StateError('${app.errors}');
    explorer.registry.execute('column.choose');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (app.primaryWindow.buildOwner.modalDepth == 0) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Column chooser did not open');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (app.errors.isNotEmpty) throw StateError('${app.errors}');
    stdout.writeln('COLUMN_OPTIONS=PASS backend=${app.backend.name}');
    await Future<void>.delayed(
        Duration(seconds: args.contains('--hold') ? 15 : 1));
    app.handleEvent(KeyDownEvent(
        windowId: app.primaryWindow.id,
        generation: native.generation,
        timestamp: Duration.zero,
        physicalKey: logicalKeyEscape,
        logicalKey: logicalKeyEscape));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (app.primaryWindow.buildOwner.modalDepth != 0) {
      throw StateError('Column chooser did not dismiss');
    }
    if (app.errors.isNotEmpty) throw StateError('${app.errors}');
    stdout.writeln('COLUMN_OPTIONS_LIFETIME=PASS');
  } finally {
    app.requestClose();
    await running;
    app.dispose();
    await app.closed;
    model.dispose();
  }
}
