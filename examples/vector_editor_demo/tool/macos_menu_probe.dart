/// Puts the vector editor's menus in the macOS menu bar and drives them
/// without accessibility: `SYNTH_MENU` performs an item as a click would,
/// `SYNTH_KEY` posts a shortcut through AppKit's key-equivalent path.
///
/// ```
/// dart run tool/macos_menu_probe.dart [--shot <dir>]
/// ```
///
/// With `--shot`, captures the top of the screen with the menus installed
/// (`screencapture -R`), which needs screen recording permission.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';
import 'package:vector_editor_demo/src/engine/editor_model.dart';
import 'package:vector_editor_demo/src/ui/app.dart';
import 'package:vector_editor_demo/src/ui/main_window.dart';

Future<void> main(List<String> args) async {
  FrameworkFonts.install();
  final options = ApplicationOptions.fromArguments(args,
      environment: Platform.environment,
      title: 'Menu probe',
      size: const Size(1400, 880));
  final app = await Application.start(
    rootWidget: const VectorEditorApp(),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  final NativeWindow native = app.primaryWindow.nativeWindow;
  final int shotAt = args.indexOf('--shot');
  final String? shotDir = shotAt >= 0 ? args[shotAt + 1] : null;

  Future<void> pause([int ms = 600]) =>
      Future<void>.delayed(Duration(milliseconds: ms));
  void menu(String title) => (native as MacosWindow)
      .synthesizeInput('SYNTH_MENU ${base64.encode(utf8.encode(title))}');
  final List<String> failures = <String>[];
  void check(String what, bool ok) {
    stderr.writeln('MENU ${ok ? 'ok  ' : 'FAIL'} $what');
    if (!ok) failures.add(what);
  }

  Timer(const Duration(seconds: 4), () async {
    if (native is! MacosWindow) {
      stderr.writeln('MENU not a MacosWindow');
      exit(2);
    }
    final BuildOwner owner = app.primaryWindow.buildOwner;
    final EditorModel model = _findState(owner).model;
    check('the window offers the system menu bar', model.nativeMenuAvailable);

    model.setNativeMenuBar(true);
    await pause();
    if (shotDir != null) {
      await Process.run('screencapture',
          <String>['-x', '-R0,0,1100,30', '$shotDir/menubar.png']);
      await Process.run('screencapture', <String>[
        '-x',
        '-l${native.hostWindowNumber}',
        '$shotDir/window.png'
      ]);
    }

    menu('Theme: Light');
    await pause();
    check('a native item runs its command', model.themeMode.name == 'light');

    model.deselect();
    // Command+A, posted to the application: AppKit offers it to the view
    // before the menu, and the view hands it to the framework as a key.
    native.synthesizeInput('SYNTH_KEY down 0 1048576 '
        '${base64.encode(utf8.encode('a'))} '
        '${base64.encode(utf8.encode('a'))}');
    native.synthesizeInput('SYNTH_KEY up 0 1048576 '
        '${base64.encode(utf8.encode('a'))} '
        '${base64.encode(utf8.encode('a'))}');
    await pause();
    check('Command+A still selects all', model.selection.hasSelection);

    menu('Use the macOS menu bar');
    await pause();
    check('the toggle puts the menus back in the window', !model.nativeMenuBar);

    menu('Theme: Dark');
    await pause();
    check('the system bar no longer has the editor menus',
        model.themeMode.name == 'light');

    final int errors = app.primaryWindow.buildOwner.errorReporter.errors.length;
    check('no framework errors', errors == 0);
    stderr.writeln('MENU done failures=${failures.length}');
    exit(failures.isEmpty ? 0 : 1);
  });
  await app.run();
}

MainWindowState _findState(BuildOwner owner) {
  MainWindowState? found;
  void walk(Element element) {
    if (found != null) return;
    if (element is StatefulElement && element.state is MainWindowState) {
      found = element.state as MainWindowState;
      return;
    }
    element.visitChildren(walk);
  }

  final Element? root = owner.rootElement;
  if (root != null) walk(root);
  return found ?? (throw StateError('the editor window is not mounted'));
}
