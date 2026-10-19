/// Opens the real properties window and verifies independent native lifetime.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/default_platform_resolver.dart'
    as platform;
import 'package:file_explorer/src/engine/demo_disk.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/ui/app.dart';
import 'package:file_explorer/src/ui/explorer_window.dart';

Future<void> main(List<String> args) async {
  final model = ExplorerModel(
      fs: demoDisk(),
      places: kDemoPlaces,
      start: const FolderLocation('/Users/ana/Documents'));
  late ExplorerWindowState explorer;
  final options = ApplicationOptions.fromArguments(
      args.where((a) => a != '--hold').toList(),
      size: const Size(900, 650),
      title: 'Properties window smoke',
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
    if (native is WindowStateControl) {
      final accepted =
          (native as WindowStateControl).requestState(WindowState.maximised);
      if (accepted) {
        final limit = DateTime.now().add(const Duration(seconds: 10));
        while (native.state != WindowState.maximised) {
          if (DateTime.now().isAfter(limit)) {
            throw StateError('Owner did not finish maximising');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
    }
    final beforeSize = native.clientSize;
    final beforeOrigin =
        app.hasScreenCoordinates ? native.clientToScreen(Offset.zero) : null;
    final beforeState = native.state;
    explorer.registry.execute('select.byName', {'prefix': 'license'});
    explorer.registry.execute('file.properties');
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (app.windows.length < 2 || app.windows.last.framesPresented == 0) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Properties did not present');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final panel = app.windows.last;
    if (panel.ownerId != app.primaryWindow.id ||
        panel.kind != WindowKind.dialog ||
        app.primaryWindow.buildOwner.modalDepth != 0) {
      throw StateError('Properties must be owned and non-modal');
    }
    if (app.canOpenPopupWindows &&
        identical(panel.popupHost, app.primaryWindow.popupHost)) {
      throw StateError('Independent windows must own their popup coordinates');
    }
    explorer.registry.execute('select.byName', {'prefix': 'annual'});
    if (!model.tab.selection.single.endsWith('Annual Report 2025.pdf')) {
      throw StateError('Owner input was blocked');
    }
    stdout.writeln('PROPERTIES_WINDOW=PASS backend=${app.backend.name}');
    if (args.contains('--hold')) {
      await Future<void>.delayed(const Duration(seconds: 15));
    }
    panel.close();
    if (app.primaryWindow.isDisposed || app.windows.length != 1) {
      throw StateError('Closing Properties must keep its owner');
    }
    if (app.errors.isNotEmpty) throw StateError('${app.errors}');
    if (native.clientSize != beforeSize ||
        (beforeOrigin != null &&
            native.clientToScreen(Offset.zero) != beforeOrigin) ||
        native.state != beforeState) {
      throw StateError('Closing Properties changed owner geometry/state: '
          'before=$beforeSize/$beforeOrigin/$beforeState '
          'after=${native.clientSize}/${app.hasScreenCoordinates ? native.clientToScreen(Offset.zero) : null}/${native.state}');
    }
    stdout.writeln(
        'PROPERTIES_GEOMETRY=PASS size=$beforeSize state=$beforeState');
    stdout.writeln('PROPERTIES_LIFETIME=PASS');
  } finally {
    app.requestClose();
    await running;
    app.dispose();
    await app.closed;
    model.dispose();
  }
}
