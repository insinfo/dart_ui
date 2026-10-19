/// Presents the real explorer with an integrated title bar for native inspection.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/default_platform_resolver.dart'
    as platform;
import 'package:file_explorer/src/engine/demo_disk.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/ui/app.dart';

Future<void> main(List<String> args) async {
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();
  final model = ExplorerModel(
      fs: demoDisk(),
      places: kDemoPlaces,
      start: const FolderLocation('/Users/ana/Documents'));
  final options = ApplicationOptions.fromArguments(
      args.where((a) => a != '--hold' && a != '--exercise').toList(),
      size: const Size(900, 650),
      title: 'Integrated title bar smoke',
      titleBar: WindowTitleBar.hidden,
      visible: true,
      environment: Platform.environment);
  final app = await Application.start(
      rootWidget: FileExplorerApp(model: model),
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
    if (args.contains('--exercise')) {
      if (native is! HiddenTitleBarWindow ||
          !(native as HiddenTitleBarWindow).isTitleBarHidden) {
        throw StateError('The backend did not integrate the title bar');
      }
      final caption = native as HiddenTitleBarWindow;
      final stateControl = native as WindowStateControl;
      Future<void> state(WindowState target) async {
        if (!stateControl.requestState(target)) {
          throw StateError('State request refused: $target');
        }
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (native.state != target) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('State timeout: $target, actual ${native.state}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final bounds = caption.systemButtons.value;
        if (target == WindowState.fullscreen
            ? !bounds.isEmpty
            : bounds.isEmpty) {
          throw StateError('Incorrect caption bounds in $target: $bounds');
        }
      }

      await state(WindowState.maximised);
      await state(WindowState.normal);
      await state(WindowState.fullscreen);
      await state(WindowState.normal);
      stdout.writeln('TITLEBAR_STATES=PASS backend=${app.backend.name}');
    }
    stdout.writeln('TITLEBAR_READY size=${native.clientSize}');
    if (native is HiddenTitleBarWindow) {
      stdout.writeln(
          'BUTTONS=${(native as HiddenTitleBarWindow).systemButtons.value}');
    }
    await Future<void>.delayed(
        Duration(seconds: args.contains('--hold') ? 15 : 1));
    if (app.errors.isNotEmpty) throw StateError('${app.errors}');
  } finally {
    app.requestClose();
    await running;
    app.dispose();
    await app.closed;
    model.dispose();
  }
}
