/// Presents a real menu to inspect borders, rounded corners and highlighting.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/default_platform_resolver.dart'
    as platform;

Future<void> main(List<String> args) async {
  final options = ApplicationOptions.fromArguments(
      args.where((a) => a != '--hold').toList(),
      size: const Size(480, 360),
      visible: true,
      title: 'Menu surface smoke',
      environment: Platform.environment);
  final controller = MenuController();
  final app = await Application.start(
      rootWidget: Theme(
          data: ThemeData.fluentLight.adaptedToPlatform(),
          child: ColoredBox(
              color: ThemeData.fluentLight.surface,
              child: Center(
                  child: MenuAnchor(
                      controller: controller,
                      menuChildren: [
                        MenuItemButton(
                            onPressed: () {}, child: const Text('Open')),
                        MenuItemButton(
                            onPressed: () {}, child: const Text('Rename')),
                        const MenuItemButton(child: Text('Unavailable action')),
                        const MenuDivider(),
                        MenuItemButton(
                            onPressed: () {}, child: const Text('Properties')),
                      ],
                      child: const SizedBox(width: 120, height: 32))))),
      backends:
          platform.PlatformBackendResolver.defaultBackends(options: options),
      presentations: platform.PlatformBackendResolver.defaultPresentations(),
      options: options);
  final running = app.run();
  try {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    controller.open();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (app.popupsOf(app.primaryWindow).isEmpty ||
        app.popupsOf(app.primaryWindow).last.framesPresented == 0) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Menu did not present');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final menu = app.popupsOf(app.primaryWindow).last;
    app.handleEvent(KeyDownEvent(
        windowId: menu.id,
        generation: menu.nativeWindow.generation,
        timestamp: Duration.zero,
        physicalKey: logicalKeyArrowDown,
        logicalKey: logicalKeyArrowDown));
    stdout.writeln(
        'MENU_SURFACE=PASS backend=${app.backend.name} nativeOutline=${app.popupWindowsHaveOutline} alpha=${app.popupWindowsAreTransparent}');
    if (args.contains('--hold')) {
      await Future<void>.delayed(const Duration(seconds: 15));
    }
    controller.close();
    if (app.errors.isNotEmpty) throw StateError('${app.errors}');
  } finally {
    app.requestClose();
    await running;
    app.dispose();
    await app.closed;
  }
}
