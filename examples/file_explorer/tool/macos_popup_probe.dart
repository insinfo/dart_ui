/// Opens the explorer on the real macOS host, right-clicks the list, opens
/// the View submenu and rests on a toolbar button for its tooltip, printing
/// where every window really is - so a submenu placed in the wrong spot, or a
/// popup drawn with the wrong frame, is caught as numbers and as a capture.
/// Without accessibility: the host posts the events into its own queue.
///
/// ```
/// dart run tool/macos_popup_probe.dart [folder] [--shots=dir]
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';
import 'package:file_explorer/src/engine/explorer_model.dart';
import 'package:file_explorer/src/engine/location.dart';
import 'package:file_explorer/src/engine/strings.dart';
import 'package:file_explorer/src/io/io_file_system.dart';
import 'package:file_explorer/src/ui/app.dart';

Future<void> main(List<String> args) async {
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();
  final String folder =
      args.where((String a) => !a.startsWith('--')).firstOrNull ??
          Directory.current.path;
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
  final options = ApplicationOptions.fromArguments(args,
      environment: Platform.environment,
      title: 'Popup probe',
      size: const Size(1100, 700),
      titleBar: WindowTitleBar.hidden);
  final app = await Application.start(
    rootWidget: FileExplorerApp(model: model, dark: false),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );

  Rect bounds(ApplicationWindow w) {
    final Offset o = w.nativeWindow.clientToScreen(Offset.zero);
    final Size s = w.nativeWindow.clientSize;
    return Rect.fromLTWH(o.dx, o.dy, s.width, s.height);
  }

  void report(String label) {
    for (final ApplicationWindow w in app.windows) {
      stderr.writeln('$label ${w.popupKind?.name ?? 'main'} ${bounds(w)}');
    }
  }

  Future<void> shoot(String name, Rect r) async {
    final Rect area = r.inflate(24);
    final String path = '$shots/$name.png';
    await Process.run('screencapture', <String>[
      '-x',
      '-R${area.left.round()},${area.top.round()},'
          '${area.width.round()},${area.height.round()}',
      path,
    ]);
    stderr.writeln('SHOT $path');
  }

  Future<void> pause([int ms = 700]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Timer(const Duration(seconds: 4), () async {
    final NativeWindow main = app.primaryWindow.nativeWindow;
    if (main is! MacosWindow) {
      stderr.writeln('not the macOS host');
      exit(2);
    }
    // A right click on the empty part of the list.
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
      exit(1);
    }
    await shoot('menu', bounds(menu));
    // Into its first item, "View": the submenu opens beside it.
    final NativeWindow menuNative = menu.nativeWindow;
    if (menuNative is MacosWindow) {
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
      await shoot(
          'submenu',
          Rect.fromLTRB(
            a.left < b.left ? a.left : b.left,
            a.top < b.top ? a.top : b.top,
            a.right > b.right ? a.right : b.right,
            a.bottom > b.bottom ? a.bottom : b.bottom,
          ));
    }
    // Escape, then rest on the copy button for its tooltip.
    main.synthesizeInput('SYNTH_KEY down 53 0 Gw== -');
    main.synthesizeInput('SYNTH_KEY up 53 0 Gw== -');
    await pause();
    main.synthesizeInput('SYNTH_MOUSE move 156 112 0 0 0');
    await pause(1600);
    report('TOOLTIP');
    final ApplicationWindow? tip = app.windows
        .where((ApplicationWindow w) => w.popupKind == PopupKind.tooltip)
        .firstOrNull;
    if (tip != null) await shoot('tooltip', bounds(tip));
    stderr.writeln('DONE errors='
        '${app.primaryWindow.buildOwner.errorReporter.errors.length}');
    exit(0);
  });
  await app.run();
}
