/// A small dart_ui application for the embedded macOS backend - a button, a
/// counter and a context menu with a submenu - that can drive itself and
/// report what it saw.
///
/// ```
/// dart run tool/macos/build_app.dart tool/macos/embedded_demo.dart \
///     -o build/EmbeddedDemo.app
/// open build/EmbeddedDemo.app                         # by hand
/// DART_UI_EMBEDDED_PROBE=/tmp/shots \
///     build/EmbeddedDemo.app/Contents/MacOS/embedded_demo   # self-probe
/// ```
///
/// With `DART_UI_EMBEDDED_PROBE=<dir>` (or `--probe=<dir>`) it waits for its
/// first frame, then - through the window's `synthesizeInput`, which posts
/// NSEvents into AppKit's own queue, no accessibility permission needed -
/// clicks the button, right-clicks for the context menu, hovers its
/// submenu row, and closes the window with `performClose:` as the red
/// button does. Every step prints a `PROBE` line - backend, presentation,
/// frames, window numbers, bounds, parent windows, the window order - and
/// `screencapture -l` captures each window into the directory. The process
/// ends when the window closes; the last line is `PROBE exit`.
///
/// Built any other way it runs on whatever backend the resolver picks, and
/// the probe says so.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/embedded/embedded_window.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';
import 'package:dart_ui/src/ffi/objc_runtime.dart';

final Stopwatch _sinceMain = Stopwatch()..start();

Future<void> main(List<String> arguments) async {
  _sinceMain.start(); // A lazy top-level: touched first thing.
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();
  final String? probe = arguments
          .where((String a) => a.startsWith('--probe='))
          .map((String a) => a.substring(8))
          .firstOrNull ??
      Platform.environment['DART_UI_EMBEDDED_PROBE'];
  final ValueNotifier<int> clicks = ValueNotifier<int>(0);
  final ValueNotifier<String> chosen = ValueNotifier<String>('-');
  final ApplicationOptions options = ApplicationOptions.fromArguments(
    arguments.where((String a) => !a.startsWith('--probe=')).toList(),
    environment: Platform.environment,
    title: 'dart_ui embedded',
    size: const Size(640, 420),
  );
  final Application app = await Application.start(
    rootWidget: _Demo(clicks: clicks, chosen: chosen),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  _log('started ${_sinceMain.elapsedMilliseconds} ms after main; '
      'backend ${app.windowingSelection.chosen?.name}, presentation '
      '${app.presentationSelection.chosen?.name}');
  if (probe != null) {
    unawaited(_probe(
        app, Directory(probe)..createSync(recursive: true), clicks, chosen));
  }
  await app.run();
  _log('run returned ${_sinceMain.elapsedMilliseconds} ms after main');
  // What runApp does after its loop: tear the windows and the backend down,
  // so nothing keeps the isolate - and with it the process - alive.
  app.dispose();
  await app.closed;
  _log('exit (closed ${_sinceMain.elapsedMilliseconds} ms after main)');
}

void _log(String line) => stderr.writeln('PROBE $line');

final class _Demo extends StatelessWidget {
  const _Demo({required this.clicks, required this.chosen});

  final ValueNotifier<int> clicks;
  final ValueNotifier<String> chosen;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xFF1E2430),
        child: ContextMenuArea(
          menuChildren: () => <Widget>[
            MenuItemButton(
              onPressed: () => chosen.value = 'Copy',
              child: const Text('Copiar'),
            ),
            SubmenuButton(
              menuChildren: <Widget>[
                for (final String view in <String>[
                  'Ícones',
                  'Lista',
                  'Detalhes'
                ])
                  MenuItemButton(
                    onPressed: () {
                      _log('pressed $view');
                      chosen.value = view;
                    },
                    child: Text(view),
                  ),
              ],
              child: const Text('Exibir'),
            ),
            MenuItemButton(
              onPressed: () => chosen.value = 'About',
              child: const Text('Sobre o dart_ui'),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'AppKit no processo do Dart (appkitEmbedded)',
                  style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 18),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 160,
                  height: 36,
                  child: Button(
                    label: 'Clique aqui',
                    onPressed: () => clicks.value++,
                  ),
                ),
                const SizedBox(height: 16),
                ValueListenableBuilder<int>(
                  valueListenable: clicks,
                  builder: (BuildContext context, int count, _) => Text(
                    'cliques: $count',
                    style: const TextStyle(color: Color(0xFFB8C4D6)),
                  ),
                ),
                ValueListenableBuilder<String>(
                  valueListenable: chosen,
                  builder: (BuildContext context, String item, _) => Text(
                    'menu: $item',
                    style: const TextStyle(color: Color(0xFFB8C4D6)),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Clique com o botão direito para o menu.',
                  style: TextStyle(color: Color(0xFF7F8BA0)),
                ),
              ],
            ),
          ),
        ),
      );
}

Future<void> _probe(Application app, Directory shots, ValueNotifier<int> clicks,
    ValueNotifier<String> chosen) async {
  Future<void> pause([int ms = 600]) =>
      Future<void>.delayed(Duration(milliseconds: ms));
  // The first frame: Application.start returns before it.
  while (app.primaryWindow.framesPresented == 0) {
    await pause(20);
  }
  _log('first frame ${_sinceMain.elapsedMilliseconds} ms after main');
  await pause(400);
  final NativeWindow main = app.primaryWindow.nativeWindow;
  if (main is! MacosEmbeddedWindow && main is! MacosWindow) {
    _log('not a macOS window (${main.runtimeType}); nothing to drive');
    return;
  }
  Rect bounds(NativeWindow w) {
    final Offset o = w.clientToScreen(Offset.zero);
    return Rect.fromLTWH(o.dx, o.dy, w.clientSize.width, w.clientSize.height);
  }

  Future<void> shoot(String name, NativeWindow window) async {
    final String path = '${shots.path}/$name.png';
    final ProcessResult result = await Process.run(
        'screencapture', <String>['-x', '-o', '-l${_number(window)}', path]);
    _log('shot $name -> $path (exit ${result.exitCode})');
  }

  List<NativeWindow> popups() => <NativeWindow>[
        for (final ApplicationWindow w in app.windows)
          if (w.popupKind != null) w.nativeWindow,
      ];

  int parentNumber(NativeWindow window) {
    // The host backend's windows live in other processes: no parent here.
    if (window is! MacosEmbeddedWindow) return -1;
    final MacosEmbeddedWindow w = window;
    final Pointer<ObjCObject> parent =
        objcSendPointer(w.nativeWindow, objcSelector('parentWindow'));
    return parent == nullptr
        ? 0
        : objcSendUnsigned(parent, objcSelector('windowNumber'));
  }

  /// The application's windows front to back, as AppKit orders them.
  String order() {
    if (main is! MacosEmbeddedWindow) return '(other processes)';
    final Pointer<ObjCObject> application = objcSendPointer(
        objcClass('NSApplication'), objcSelector('sharedApplication'));
    final Pointer<ObjCObject> ordered =
        objcSendPointer(application, objcSelector('orderedWindows'));
    final int count = objcSendUnsigned(ordered, objcSelector('count'));
    return <String>[
      for (var i = 0; i < count; i++)
        '${objcSendUnsigned(objcSendPointer1(ordered, objcSelector('objectAtIndex:'), i), objcSelector('windowNumber'))}',
    ].join(' > ');
  }

  _log('main window #${_number(main)} bounds ${bounds(main)} '
      'scale ${main.renderScale} surfaces ${main.surfaces.map((s) => s.kind)}');
  await shoot('1_main', main);

  // The button: 24 px padding, the title, 16 px, then 160x36.
  final ApplicationWindow primary = app.primaryWindow;
  final int framesBefore = primary.framesPresented;
  _synth(main, <String>[
    'SYNTH_MOUSE move 100 80 0 0 0',
    'SYNTH_MOUSE down 100 80 0 1 0',
    'SYNTH_MOUSE up 100 80 0 1 0',
  ]);
  await pause();
  _log('click: counter ${clicks.value} (expected 1), frames '
      '$framesBefore -> ${primary.framesPresented}');
  await shoot('2_after_click', main);

  // A right click on the empty lower part: the context menu.
  final Stopwatch menuOpen = Stopwatch()..start();
  _synth(main, <String>[
    'SYNTH_MOUSE move 300 300 0 0 0',
    'SYNTH_MOUSE down 300 300 1 1 0',
    'SYNTH_MOUSE up 300 300 1 1 0',
  ]);
  while (popups().isEmpty && menuOpen.elapsedMilliseconds < 3000) {
    await pause(5);
  }
  _log('menu opened after ${menuOpen.elapsedMilliseconds} ms');
  await pause();
  final List<NativeWindow> menus = popups();
  if (menus.isEmpty) {
    _log('FAIL no menu window');
  } else {
    final NativeWindow menu = menus.first;
    _log('menu #${_number(menu)} bounds ${bounds(menu)} parent '
        '#${parentNumber(menu)} (main #${_number(main)}); '
        'right click was at ${main.clientToScreen(const Offset(300, 300))}');
    _log('order ${order()}');
    await shoot('3_menu', menu);
    // Hover "Exibir", the second row: the submenu opens beside it.
    final Stopwatch submenuOpen = Stopwatch()..start();
    _synth(menu, <String>[
      'SYNTH_POINTER enter',
      'SYNTH_MOUSE move 40 46 0 0 0',
    ]);
    while (popups().length < 2 && submenuOpen.elapsedMilliseconds < 3000) {
      await pause(5);
    }
    _log('submenu opened after ${submenuOpen.elapsedMilliseconds} ms');
    await pause();
    final List<NativeWindow> chain = popups();
    if (chain.length < 2) {
      _log('FAIL no submenu window (${chain.length} popups)');
    } else {
      final NativeWindow submenu = chain[1];
      final Rect a = bounds(menu);
      final Rect b = bounds(submenu);
      _log('submenu #${_number(submenu)} bounds $b parent '
          '#${parentNumber(submenu)} (menu #${_number(menu)}); '
          'gap x=${(b.left - a.right).toStringAsFixed(1)} '
          'dy=${(b.top - a.top).toStringAsFixed(1)}');
      _log('order ${order()}');
      await shoot('4_menu_with_submenu', menu);
      await shoot('5_submenu', submenu);
      final String region = '${(a.left - 20).round()},${(a.top - 20).round()},'
          '${(b.right - a.left + 40).round()},'
          '${((b.bottom > a.bottom ? b.bottom : a.bottom) - a.top + 40).round()}';
      await Process.run('screencapture',
          <String>['-x', '-R$region', '${shots.path}/6_region.png']);
      _log('shot 6_region -R$region');
      // Choose "Lista", the submenu's second row.
      _synth(submenu, <String>[
        'SYNTH_POINTER enter',
        'SYNTH_MOUSE move 40 46 0 0 0',
      ]);
      await pause(300);
      _synth(submenu, <String>['SYNTH_MOUSE down 40 46 0 1 0']);
      await pause(150);
      _log('after press: popups ${popups().length}');
      _synth(submenu, <String>['SYNTH_MOUSE up 40 46 0 1 0']);
      await pause();
      _log('chosen "${chosen.value}" (expected Lista); popups left '
          '${popups().length}');
    }
  }
  await shoot('7_final', main);
  // The red button's message: windowShouldClose: -> close request -> the
  // framework closes the window -> run() returns -> the process ends.
  _log('performClose: on #${_number(main)} '
      '${_sinceMain.elapsedMilliseconds} ms after main');
  switch (main) {
    case final MacosEmbeddedWindow w:
      objcSendVoid1(w.nativeWindow, objcSelector('performClose:'), 0);
    case final MacosWindow w:
      // The host's Window > Close, which sends the same performClose:.
      w.synthesizeInput('SYNTH_MENU ${base64.encode(utf8.encode('Close'))}');
  }
}

/// The window number `screencapture -l` takes, on either macOS backend.
int _number(NativeWindow window) => switch (window) {
      final MacosEmbeddedWindow w => w.windowNumber,
      final MacosWindow w => w.hostWindowNumber,
      _ => 0,
    };

/// The same `SYNTH_*` lines on either backend: the embedded window posts
/// them into AppKit's queue in this process, the host's window sends them to
/// its host process.
void _synth(NativeWindow window, List<String> commands) {
  for (final String command in commands) {
    switch (window) {
      case final MacosEmbeddedWindow w:
        w.synthesizeInput(command);
      case final MacosWindow w:
        w.synthesizeInput(command);
    }
  }
}
