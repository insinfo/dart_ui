/// Opens the explorer on the real macOS host, right-clicks the list, opens
/// the View submenu and rests on a toolbar button for its tooltip, printing
/// where every window really is - so a submenu placed in the wrong spot, or a
/// popup drawn with the wrong frame, is caught as numbers and as a capture.
/// Without accessibility: the host posts the events into its own queue.
///
/// ```
/// dart run tool/macos_popup_probe.dart [folder] [--shots=dir] [--dark]
/// ```
///
/// Use a folder with few items: the right click lands at (700, 500) and has
/// to hit the empty part of the list to get the background menu.
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
  final bool dark = args.contains('--dark');
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
    rootWidget: FileExplorerApp(model: model, dark: dark),
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

  /// One window by its CGWindowID, shadow included and the rest
  /// transparent - what the window server composites, whatever is in front
  /// of it. The probe's application is never activated, so its menus sit
  /// behind the active application and a screen-region capture shows that
  /// application instead.
  Future<void> shootWindow(String name, ApplicationWindow w) async {
    final NativeWindow native = w.nativeWindow;
    if (native is! MacosWindow) return;
    final String path = '$shots/$name.png';
    await Process.run(
        'screencapture', <String>['-x', '-l${native.hostWindowNumber}', path]);
    stderr.writeln('SHOT $path');
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

  /// The on-screen windows front to back, from the window server, with
  /// ours marked - so "the menu sits directly above its owner, behind the
  /// application in front" is a line to read, not a capture to squint at.
  Future<void> zOrder(String label) async {
    final File script = File('${Directory.systemTemp.path}/dart_ui_zorder.js')
      ..writeAsStringSync(_zOrderScript);
    final ProcessResult result = await Process.run(
        'osascript', <String>['-l', 'JavaScript', script.path]);
    final Map<int, String> ours = <int, String>{
      for (final ApplicationWindow w in app.windows)
        if (w.nativeWindow case final MacosWindow m)
          m.hostWindowNumber: w.popupKind?.name ?? 'main',
    };
    final List<String> lines = (result.stdout as String).trim().split('\n');
    final List<String> order = <String>[];
    for (final String line in lines) {
      final int? number =
          int.tryParse(RegExp(r'#(\d+)').firstMatch(line)?.group(1) ?? '');
      final String? mine = ours[number];
      stderr.writeln('ZORDER $label ${mine == null ? '' : '[$mine] '}$line');
      order.add(mine ?? 'other');
    }
    // Ours must be one run - popups directly above their owner - unless the
    // application is the active one, in which case the menus may sit on the
    // pop-up level above everything.
    final int first = order.indexWhere((String o) => o != 'other');
    final int last = order.lastIndexOf('main');
    final bool contiguous = first >= 0 &&
        last >= first &&
        order.sublist(first, last + 1).every((String o) => o != 'other');
    stderr.writeln('ZORDER_OK $label contiguous=$contiguous');
  }

  Future<void> pause([int ms = 700]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Timer(const Duration(seconds: 4), () async {
    final NativeWindow main = app.primaryWindow.nativeWindow;
    if (main is! MacosWindow) {
      stderr.writeln('not the macOS host');
      exit(2);
    }
    await shoot('window', bounds(app.primaryWindow));
    // A right click on the empty part of the list.
    main
      ..synthesizeInput('SYNTH_MOUSE move 700 500 0 0 0')
      ..synthesizeInput('SYNTH_MOUSE down 700 500 1 1 0')
      ..synthesizeInput('SYNTH_MOUSE up 700 500 1 1 0');
    await pause();
    ApplicationWindow? firstPopup() => app.windows
        .where((ApplicationWindow w) => w.popupKind != null)
        .firstOrNull;
    // A cold popup host can take longer than the pause on a busy machine.
    if (firstPopup() == null) await pause(1500);
    report('MENU');
    final ApplicationWindow? menu = firstPopup();
    if (menu == null) {
      stderr.writeln('NO MENU');
      exit(1);
    }
    await shoot('menu', bounds(menu));
    await shootWindow('menu_window', menu);
    await zOrder('MENU');
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
    await zOrder('SUBMENU');
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
      // The parent with its "Exibir" row lit for the open submenu, and the
      // submenu itself.
      await shootWindow('menu_trail_window', popups[0]);
      await shootWindow('submenu_window', popups[1]);
    }
    // A click on the empty part of the list dismisses the chain (a panel
    // that never becomes key gets no Escape from its own queue), then rest
    // on the disabled Copy button for its tooltip.
    main
      ..synthesizeInput('SYNTH_MOUSE down 700 500 0 1 0')
      ..synthesizeInput('SYNTH_MOUSE up 700 500 0 1 0');
    await pause();
    report('CLOSED');
    main
      ..synthesizeInput('SYNTH_POINTER enter')
      ..synthesizeInput('SYNTH_MOUSE move 380 111 0 0 0')
      ..synthesizeInput('SYNTH_MOUSE move 385 111 0 0 0');
    await pause(1600);
    report('TOOLTIP');
    final ApplicationWindow? tip = app.windows
        .where((ApplicationWindow w) => w.popupKind == PopupKind.tooltip)
        .firstOrNull;
    if (tip != null) {
      await shoot('tooltip', bounds(tip));
      await shootWindow('tooltip_window', tip);
    }
    stderr.writeln('DONE errors='
        '${app.primaryWindow.buildOwner.errorReporter.errors.length}');
    exit(0);
  });
  await app.run();
}

const String _zOrderScript = r'''
ObjC.import('CoreGraphics');
ObjC.import('Foundation');
function run() {
  const list = ObjC.castRefToObject(
      $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0));
  const out = [];
  for (let i = 0; i < list.count && out.length < 12; i++) {
    const w = list.objectAtIndex(i);
    const layer = ObjC.unwrap(w.objectForKey('kCGWindowLayer'));
    if (layer < 0 || layer > 200 || layer == 20 || layer == 24) continue;
    const b = w.objectForKey('kCGWindowBounds');
    const width = ObjC.unwrap(b.objectForKey('Width'));
    const height = ObjC.unwrap(b.objectForKey('Height'));
    if (width < 40 || height < 20) continue;
    out.push('#' + ObjC.unwrap(w.objectForKey('kCGWindowNumber')) +
        ' L' + layer + ' ' + ObjC.unwrap(w.objectForKey('kCGWindowOwnerName')) +
        ' ' + width + 'x' + height);
  }
  return out.join('\n');
}
''';
