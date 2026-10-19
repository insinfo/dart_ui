/// Exercises context replacement through real native popup lifetimes.
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
  final options = ApplicationOptions.fromArguments(args,
      size: const Size(1000, 700),
      title: 'Context menu replacement smoke',
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
    model.tab.visible =
        model.tab.visible.where((e) => !e.isDirectory).take(2).toList();
    model.notify();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final owner = app.primaryWindow;
    if (!app.canOpenPopupWindows) {
      throw StateError('Native popup support required');
    }
    Offset at(String name) {
      RenderText? found;
      void visit(RenderBox box) {
        if (box is RenderText && box.text == name) found = box;
        box.visitChildren(visit);
      }

      visit(owner.buildOwner.renderRoot!);
      if (found == null) throw StateError('Missing file label: $name');
      return found!.localToGlobal(const Offset(2, 2));
    }

    void click(Offset position) {
      app.handleEvent(PointerDownEvent(
          windowId: owner.id,
          generation: owner.nativeWindow.generation,
          timestamp: Duration.zero,
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: position,
          button: PointerButton.secondary));
      app.handleEvent(PointerUpEvent(
          windowId: owner.id,
          generation: owner.nativeWindow.generation,
          timestamp: const Duration(milliseconds: 1),
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: position,
          button: PointerButton.secondary));
    }

    Future<ApplicationWindow> menu() async {
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (true) {
        final popups = app.popupsOf(owner);
        if (popups.length == 1 && popups.single.framesPresented > 0) {
          return popups.single;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Native menu did not present');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    final first = model.tab.visible.first;
    final second = model.tab.visible.last;
    click(at(second.name));
    var old = await menu();
    click(at(first.name));
    var replacement = await menu();
    if (!old.isDisposed ||
        identical(old, replacement) ||
        model.tab.selection.length != 1 ||
        !model.tab.selection.contains(first.path)) {
      throw StateError(
          'One secondary press must select and open the other file');
    }
    old = replacement;
    click(Offset(owner.nativeWindow.clientSize.width - 24,
        owner.nativeWindow.clientSize.height - 100));
    replacement = await menu();
    if (!old.isDisposed ||
        identical(old, replacement) ||
        model.tab.selection.isNotEmpty) {
      throw StateError(
          'One secondary press on blank space must open the folder menu');
    }
    old = replacement;
    click(at(first.name));
    replacement = await menu();
    if (!old.isDisposed ||
        identical(old, replacement) ||
        !model.tab.selection.contains(first.path)) {
      throw StateError('The folder menu must be replaceable by a file menu');
    }
    if (app.errors.isNotEmpty) throw StateError('${app.errors}');
    stdout.writeln('CONTEXT_RETARGET=PASS backend=${app.backend.name}');
  } finally {
    app.requestClose();
    await running;
    app.dispose();
    await app.closed;
    model.dispose();
  }
}
