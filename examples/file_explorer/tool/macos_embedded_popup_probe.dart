/// The explorer on the fourth macOS backend, `appkitEmbedded` - AppKit in
/// the Dart process, every window in it - right-clicking the list, opening
/// the View submenu, and closing the window with the red button's
/// `performClose:`, printing where every window is and whose child it is.
///
/// Built as a `.app` whose executable is the patched Dart runtime (run from
/// the repository root):
///
/// ```
/// dart run tool/macos/build_app.dart \
///     examples/file_explorer/tool/macos_embedded_popup_probe.dart \
///     -o build/ExplorerEmbeddedProbe.app
/// build/ExplorerEmbeddedProbe.app/Contents/MacOS/macos_embedded_popup_probe \
///     [folder] [--shots=dir]
/// ```
///
/// Use a folder with few items: the right click lands at (700, 500) and has
/// to hit the empty part of the list to get the background menu. The process
/// ends by itself once the window closes; the last line is `DONE`.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/embedded/embedded_window.dart';
import 'package:dart_ui/src/ffi/objc_runtime.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/engine/strings.dart';
import 'package:file_explorer/src/io/io_file_system.dart';
import 'package:file_explorer/src/ui/app.dart';

Future<void> main(List<String> args) async {
  final Stopwatch sinceMain = Stopwatch()..start();
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();
  final String folder =
      args.where((String a) => !a.startsWith('--')).firstOrNull ??
          Directory.systemTemp.path;
  final String shots = args
          .where((String a) => a.startsWith('--shots='))
          .map((String a) => a.substring(8))
          .firstOrNull ??
      Directory.systemTemp.path;
  final ExplorerModel model = ExplorerModel(
    fs: IoFileSystem(),
    places: const <Place, String>{},
    strings: ExplorerStrings.forLocale('pt'),
    start: FolderLocation(Directory(folder).absolute.path),
  );
  final ApplicationOptions options = ApplicationOptions.fromArguments(
      args.where((String a) => !a.startsWith('--shots=')).toList(),
      environment: Platform.environment,
      title: 'Embedded popup probe',
      size: const Size(1100, 700),
      titleBar: WindowTitleBar.hidden);
  final Application app = await Application.start(
    rootWidget: FileExplorerApp(model: model),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  stderr.writeln('BACKEND ${app.windowingSelection.chosen?.name} '
      'presentation ${app.presentationSelection.chosen?.name} '
      'started ${sinceMain.elapsedMilliseconds} ms after main');

  Rect bounds(ApplicationWindow w) {
    final Offset o = w.nativeWindow.clientToScreen(Offset.zero);
    final Size s = w.nativeWindow.clientSize;
    return Rect.fromLTWH(o.dx, o.dy, s.width, s.height);
  }

  int number(ApplicationWindow w) => switch (w.nativeWindow) {
        final MacosEmbeddedWindow n => n.windowNumber,
        _ => 0,
      };

  int parent(ApplicationWindow w) {
    final NativeWindow native = w.nativeWindow;
    if (native is! MacosEmbeddedWindow) return 0;
    final Pointer<ObjCObject> parent =
        objcSendPointer(native.nativeWindow, objcSelector('parentWindow'));
    return parent == nullptr
        ? 0
        : objcSendUnsigned(parent, objcSelector('windowNumber'));
  }

  void report(String label) {
    for (final ApplicationWindow w in app.windows) {
      stderr.writeln('$label ${w.popupKind?.name ?? 'main'} #${number(w)} '
          'parent #${parent(w)} ${bounds(w)}');
    }
  }

  Future<void> shootWindow(String name, ApplicationWindow w) async {
    final String path = '$shots/$name.png';
    await Process.run('screencapture', <String>['-x', '-l${number(w)}', path]);
    stderr.writeln('SHOT $path');
  }

  Future<void> pause([int ms = 700]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Timer(const Duration(seconds: 3), () async {
    final NativeWindow main = app.primaryWindow.nativeWindow;
    if (main is! MacosEmbeddedWindow) {
      stderr.writeln('not the embedded backend: ${main.runtimeType}');
      exit(2);
    }
    await shootWindow('embedded_window', app.primaryWindow);
    main
      ..synthesizeInput('SYNTH_MOUSE move 700 500 0 0 0')
      ..synthesizeInput('SYNTH_MOUSE down 700 500 1 1 0')
      ..synthesizeInput('SYNTH_MOUSE up 700 500 1 1 0');
    await pause();
    report('MENU');
    final ApplicationWindow? menu = app.windows
        .where((ApplicationWindow w) => w.popupKind != null)
        .firstOrNull;
    if (menu == null) {
      stderr.writeln('NO MENU');
    } else {
      final NativeWindow menuNative = menu.nativeWindow;
      if (menuNative is MacosEmbeddedWindow) {
        menuNative
          ..synthesizeInput('SYNTH_POINTER enter')
          ..synthesizeInput('SYNTH_MOUSE move 40 16 0 0 0');
        await pause(900);
        menuNative
          ..synthesizeInput('SYNTH_MOUSE down 40 16 0 1 0')
          ..synthesizeInput('SYNTH_MOUSE up 40 16 0 1 0');
      }
      await pause(900);
      report('SUBMENU');
      final List<ApplicationWindow> popups = app.windows
          .where((ApplicationWindow w) => w.popupKind != null)
          .toList();
      if (popups.length >= 2) {
        final Rect a = bounds(popups[0]);
        final Rect b = bounds(popups[1]);
        stderr.writeln('SUBMENU_GAP x=${(b.left - a.right).toStringAsFixed(1)} '
            'dy=${(b.top - a.top).toStringAsFixed(1)}');
        await shootWindow('embedded_menu_trail', popups[0]);
        await shootWindow('embedded_submenu', popups[1]);
        // The main window's capture shows its child windows over it.
        await shootWindow('embedded_window_with_menus', app.primaryWindow);
      }
    }
    // The red button's message, then the process ends on its own.
    stderr.writeln('CLOSE ${sinceMain.elapsedMilliseconds} ms after main');
    objcSendVoid1(main.nativeWindow, objcSelector('performClose:'), 0);
  });
  await app.run();
  app.dispose();
  await app.closed;
  model.dispose();
  stderr.writeln('DONE ${sinceMain.elapsedMilliseconds} ms after main, errors='
      '${app.primaryWindow.buildOwner.errorReporter.errors.length}');
}
