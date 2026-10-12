/// Proves macOS input reaches the framework, from the AppKit event queue on.
///
/// Every event below is an `NSEvent` the AppKit host builds and posts into its
/// own queue (`MacosWindow.synthesizeInput`), so it is dequeued, seen by the
/// host's event monitor, printed as an `INPUT=` line, parsed, translated and
/// delivered exactly as a real one is. What this cannot prove is the part
/// before the queue - the WindowServer routing a physical click to the right
/// process - and that part is AppKit's, unchanged by any of this.
///
/// Two halves:
///
///   * **the backend** (`INPUT_EVENT_*`): each synthetic event comes out of
///     `NativeWindow.events` as the framework event it should, field by field;
///   * **the application** (`INPUT_APP_*`): a click activates a real `Button`
///     and keys type into a real `TextField`, through hit testing, focus and
///     the text pipeline.
///
/// ```
/// bash lib/src/backends/macos/native/build_host.sh
/// DART_UI_MACOS_HOST=lib/src/backends/macos/native/build/dart_ui_macos_host \
///   dart run tool/macos_input_smoke.dart
/// ```
///
/// Exits 0 on `MACOS_INPUT_SMOKE=PASS`, 1 on `=FAIL`, and 2 off macOS.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/macos_backend.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';

const int _shift = 1 << 17;
const int _command = 1 << 20;
const int _function = 1 << 23;

String _b64(String text) =>
    text.isEmpty ? '-' : base64.encode(utf8.encode(text));

Future<void> main() async {
  if (!Platform.isMacOS) {
    stderr
        .writeln('MACOS_INPUT_SMOKE=SKIP platform=${Platform.operatingSystem}');
    exitCode = 2;
    return;
  }

  var verdict = 'PASS';
  var reason = '';
  void record(String key, bool passed, String detail) {
    stdout.writeln('$key=${passed ? 'PASS' : 'FAIL'} $detail');
    if (!passed && verdict == 'PASS') {
      verdict = 'FAIL';
      reason = key;
    }
  }

  try {
    await _backendHalf(record);
    await _applicationHalf(record);
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('MACOS_INPUT_SMOKE threw: $error')
      ..writeln(stackTrace);
    verdict = 'FAIL';
    if (reason.isEmpty) reason = 'threw ${error.runtimeType}';
  }

  stdout.writeln(
      'MACOS_INPUT_SMOKE=$verdict${verdict == 'PASS' ? '' : ' $reason'}');
  exitCode = verdict == 'PASS' ? 0 : 1;
}

// ---------------------------------------------------------------------------
// The backend: one synthetic event in, one framework event out
// ---------------------------------------------------------------------------

Future<void> _backendHalf(void Function(String, bool, String) record) async {
  final backend = MacosWindowingBackend();
  final BackendProbeResult probe = backend.probe();
  if (!probe.supported) {
    record('INPUT_EVENT_BACKEND', false, 'probe: ${probe.diagnostics}');
    return;
  }
  await backend.initialize();
  final window = await backend.createWindow(const WindowOptions(
    title: 'dart_ui input smoke',
    size: Size(320, 200),
    position: Offset(160, 160),
  )) as MacosWindow;
  final events = <PlatformInputEvent>[];
  final crossings = <String>[];
  // One listener: the window's stream is single-subscription.
  final StreamSubscription<PlatformWindowEvent> subscription =
      window.events.listen((PlatformWindowEvent event) {
    if (event is PlatformInputEvent) events.add(event);
    if (event is WindowPointerEnterEvent) crossings.add('enter');
    if (event is WindowPointerLeaveEvent) crossings.add('leave');
  });

  /// Sends [commands] and returns what came out.
  Future<List<PlatformInputEvent>> send(List<String> commands) async {
    events.clear();
    for (final String command in commands) {
      window.synthesizeInput(command);
    }
    final Stopwatch waited = Stopwatch()..start();
    var last = -1;
    // Until the stream has been quiet for 150 ms, at most two seconds.
    while (waited.elapsedMilliseconds < 2000) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (events.length == last) break;
      last = events.length;
    }
    return List<PlatformInputEvent>.of(events);
  }

  try {
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // --- a primary click ----------------------------------------------------
    var out = await send(<String>[
      'SYNTH_MOUSE down 20 30 0 1 0',
      'SYNTH_MOUSE up 20 30 0 1 0',
    ]);
    final down = out.whereType<PointerDownEvent>().firstOrNull;
    final up = out.whereType<PointerUpEvent>().firstOrNull;
    record(
        'INPUT_EVENT_CLICK',
        down != null &&
            up != null &&
            down.button == PointerButton.primary &&
            down.clickCount == 1 &&
            down.logicalPosition == const Offset(20, 30) &&
            up.button == PointerButton.primary,
        'events=${_names(out)} position=${down?.logicalPosition} '
            'button=${down?.button.name} clickCount=${down?.clickCount}');

    // --- the second press of a right double click, and the back button ------
    out = await send(<String>[
      'SYNTH_MOUSE down 40 50 1 2 0',
      'SYNTH_MOUSE up 40 50 1 2 0',
      'SYNTH_MOUSE down 41 51 3 1 0',
      'SYNTH_MOUSE up 41 51 3 1 0',
    ]);
    final downs = out.whereType<PointerDownEvent>().toList();
    record(
        'INPUT_EVENT_BUTTONS',
        downs.length == 2 &&
            downs[0].button == PointerButton.secondary &&
            downs[0].clickCount == 2 &&
            downs[1].button == PointerButton.back,
        'downs=${downs.map((e) => '${e.button.name}x${e.clickCount}').toList()}');

    // --- move and drag ----------------------------------------------------
    out = await send(<String>[
      'SYNTH_MOUSE move 60 70 0 0 0',
      'SYNTH_MOUSE drag 61.5 72.25 0 0 0',
    ]);
    final moves = out.whereType<PointerMoveEvent>().toList();
    record(
        'INPUT_EVENT_MOVE',
        moves.length == 2 &&
            moves[1].logicalPosition == const Offset(61.5, 72.25),
        'moves=${moves.map((e) => e.logicalPosition).toList()}');

    // --- Cmd+C: a shortcut, with no text --------------------------------------
    out = await send(<String>[
      'SYNTH_KEY down 8 $_command ${_b64('c')} ${_b64('c')}',
      'SYNTH_KEY up 8 $_command ${_b64('c')} ${_b64('c')}',
    ]);
    final cmdC = out.whereType<KeyDownEvent>().firstOrNull;
    record(
        'INPUT_EVENT_SHORTCUT',
        cmdC != null &&
            cmdC.logicalKey == 0x43 &&
            cmdC.physicalKey == 8 &&
            cmdC.modifiers.contains(KeyModifier.meta) &&
            !cmdC.modifiers.contains(KeyModifier.control) &&
            out.whereType<TextInputEvent>().isEmpty &&
            out.whereType<KeyUpEvent>().length == 1,
        'events=${_names(out)} logicalKey=0x${cmdC?.logicalKey.toRadixString(16)} '
            'modifiers=${cmdC?.modifiers.map((m) => m.name).toList()}');

    // --- ç on the ABNT2 key: text from the layout, VK from the position ------
    out = await send(<String>[
      'SYNTH_KEY down 41 0 ${_b64('ç')} ${_b64('ç')}',
      'SYNTH_KEY up 41 0 ${_b64('ç')} ${_b64('ç')}',
    ]);
    final cedilla = out.whereType<KeyDownEvent>().firstOrNull;
    final cedillaText = out.whereType<TextInputEvent>().firstOrNull;
    record(
        'INPUT_EVENT_LAYOUT_TEXT',
        cedilla?.logicalKey == 0xBA && cedillaText?.text == 'ç',
        'logicalKey=0x${cedilla?.logicalKey.toRadixString(16)} '
            'text=${cedillaText?.text}');

    // --- a modifier alone, each side ----------------------------------------
    out = await send(<String>[
      'SYNTH_KEY down 56 $_shift - -',
      'SYNTH_KEY up 56 0 - -',
      'SYNTH_KEY down 60 $_shift - -',
      'SYNTH_KEY up 60 0 - -',
    ]);
    final shifts = out.whereType<KeyEvent>().toList();
    record(
        'INPUT_EVENT_MODIFIER_KEYS',
        shifts.length == 4 &&
            shifts[0] is KeyDownEvent &&
            shifts[0].logicalKey == 0x10 &&
            shifts[0].location == KeyLocation.left &&
            shifts[0].modifiers.contains(KeyModifier.shift) &&
            shifts[1] is KeyUpEvent &&
            !shifts[1].modifiers.contains(KeyModifier.shift) &&
            shifts[2].location == KeyLocation.right,
        'events=${shifts.map((e) => '${e.runtimeType}/${e.location.name}').toList()}');

    // --- an arrow: AppKit's U+F702 is not text ------------------------------
    // --- a keypad digit: numpad location, and the digit is text --------------
    out = await send(<String>[
      'SYNTH_KEY down 123 $_function ${_b64('')} ${_b64('')}',
      'SYNTH_KEY up 123 $_function ${_b64('')} ${_b64('')}',
      'SYNTH_KEY down 83 0 ${_b64('1')} ${_b64('1')}',
      'SYNTH_KEY up 83 0 ${_b64('1')} ${_b64('1')}',
    ]);
    final keys = out.whereType<KeyDownEvent>().toList();
    final texts = out.whereType<TextInputEvent>().map((e) => e.text).toList();
    record(
        'INPUT_EVENT_NAVIGATION',
        keys.length == 2 &&
            keys[0].logicalKey == 0x25 &&
            keys[1].logicalKey == 0x61 &&
            keys[1].location == KeyLocation.numpad &&
            texts.length == 1 &&
            texts.single == '1',
        'keys=${keys.map((e) => '0x${e.logicalKey.toRadixString(16)}').toList()} '
            'texts=$texts');

    // --- the pointer crossing the window edge ---------------------------------
    // Without it hover is never cleared: a button left through the edge stays
    // lit.
    crossings.clear();
    await send(<String>['SYNTH_POINTER enter', 'SYNTH_POINTER leave']);
    record('INPUT_EVENT_POINTER_CROSSING', crossings.join(',') == 'enter,leave',
        'crossings=$crossings');

    // --- scrolling: a wheel in lines, a trackpad in points -------------------
    out = await send(<String>[
      'SYNTH_SCROLL 10 12 0 -3 0',
      'SYNTH_SCROLL 10 12 0 25 1',
    ]);
    final scrolls = out.whereType<PointerScrollEvent>().toList();
    record(
        'INPUT_EVENT_SCROLL',
        scrolls.length == 2 &&
            scrolls[0].scrollDelta.dy == 3 &&
            scrolls[0].scrollDeltaUnit == ScrollDeltaUnit.lines &&
            scrolls[0].logicalPosition == const Offset(10, 12) &&
            scrolls[1].scrollDelta.dy == -25 &&
            scrolls[1].scrollDeltaUnit == ScrollDeltaUnit.pixels,
        'scrolls=${scrolls.map((e) => '${e.scrollDelta.dy}${e.scrollDeltaUnit.name}').toList()}');
  } finally {
    await subscription.cancel();
    await backend.shutdown();
  }
}

// ---------------------------------------------------------------------------
// The application: a click on a Button, keys into a TextField
// ---------------------------------------------------------------------------

Future<void> _applicationHalf(
    void Function(String, bool, String) record) async {
  final controller = TextEditingController();
  var presses = 0;
  final Application app = await Application.start(
    rootWidget: Column(
      children: <Widget>[
        SizedBox(
          width: 280,
          height: 40,
          child: TextField(controller: controller, label: 'name'),
        ),
        SizedBox(
          width: 280,
          height: 40,
          child: Button(label: 'press', onPressed: () => presses++),
        ),
      ],
    ),
    backends: PlatformBackendResolver.defaultBackends(),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: ApplicationOptions(
      title: 'dart_ui input smoke (application)',
      size: const Size(320, 120),
      environment: Platform.environment,
    ),
  );
  try {
    final ApplicationWindow window = app.primaryWindow;
    final NativeWindow native = window.nativeWindow;
    if (native is! MacosWindow) {
      record('INPUT_APP', false, 'the window is ${native.runtimeType}');
      return;
    }
    await _pump(app, const Duration(milliseconds: 400));

    native
      ..synthesizeInput('SYNTH_MOUSE down 140 60 0 1 0')
      ..synthesizeInput('SYNTH_MOUSE up 140 60 0 1 0');
    await _pump(app, const Duration(milliseconds: 300));
    record('INPUT_APP_BUTTON', presses == 1, 'presses=$presses');

    native
      ..synthesizeInput('SYNTH_MOUSE down 140 20 0 1 0')
      ..synthesizeInput('SYNTH_MOUSE up 140 20 0 1 0');
    await _pump(app, const Duration(milliseconds: 200));
    // o, l, then á as AppKit delivers it once a dead key resolved: one key
    // press whose characters are the composed letter.
    for (final (int keyCode, String text) in <(int, String)>[
      (0x1F, 'o'),
      (0x25, 'l'),
      (0x00, 'á'),
    ]) {
      native
        ..synthesizeInput(
            'SYNTH_KEY down $keyCode 0 ${_b64(text)} ${_b64(text)}')
        ..synthesizeInput(
            'SYNTH_KEY up $keyCode 0 ${_b64(text)} ${_b64(text)}');
    }
    await _pump(app, const Duration(milliseconds: 300));
    final String typed = controller.value;
    record('INPUT_APP_TYPING', typed == 'olá', 'value="$typed"');

    // Delete (Backspace) is a key, not text: AppKit's U+007F must not land in
    // the document, and the key must remove the last character.
    native
      ..synthesizeInput('SYNTH_KEY down 51 0 ${_b64('\x7f')} ${_b64('\x7f')}')
      ..synthesizeInput('SYNTH_KEY up 51 0 ${_b64('\x7f')} ${_b64('\x7f')}');
    await _pump(app, const Duration(milliseconds: 300));
    record('INPUT_APP_BACKSPACE', controller.value == 'ol',
        'value="${controller.value}"');

    // Cmd+A, Cmd+C: Command arrives as meta, and the field reads the Mac
    // convention, so this is copy - checked from outside the process.
    final String saved = await _pbpaste();
    try {
      native
        ..synthesizeInput(
            'SYNTH_KEY down 0 $_command ${_b64('a')} ${_b64('a')}')
        ..synthesizeInput('SYNTH_KEY up 0 $_command ${_b64('a')} ${_b64('a')}')
        ..synthesizeInput(
            'SYNTH_KEY down 8 $_command ${_b64('c')} ${_b64('c')}')
        ..synthesizeInput('SYNTH_KEY up 8 $_command ${_b64('c')} ${_b64('c')}');
      await _pump(app, const Duration(milliseconds: 500));
      final String copied = await _pbpaste();
      // Cmd+Right to the end, then Cmd+V.
      native
        ..synthesizeInput('SYNTH_KEY down 124 ${_command | _function} '
            '${_b64('\uF703')} ${_b64('\uF703')}')
        ..synthesizeInput('SYNTH_KEY up 124 ${_command | _function} '
            '${_b64('\uF703')} ${_b64('\uF703')}')
        ..synthesizeInput(
            'SYNTH_KEY down 9 $_command ${_b64('v')} ${_b64('v')}')
        ..synthesizeInput('SYNTH_KEY up 9 $_command ${_b64('v')} ${_b64('v')}');
      await _pump(app, const Duration(milliseconds: 500));
      record(
          'INPUT_APP_COMMAND_SHORTCUTS',
          copied == 'ol' && controller.value == 'olol',
          'pbpasteAfterCmdC="$copied" valueAfterCmdV="${controller.value}"');
    } finally {
      await _pbcopy(saved);
    }
  } finally {
    app.dispose();
    await app.closed;
  }
}

Future<String> _pbpaste() async {
  final ProcessResult result =
      await Process.run('pbpaste', const <String>[], stdoutEncoding: utf8);
  return result.stdout as String;
}

Future<void> _pbcopy(String text) async {
  final Process process = await Process.start('pbcopy', const <String>[]);
  process.stdin.add(utf8.encode(text));
  await process.stdin.close();
  await process.exitCode;
}

String _names(List<PlatformInputEvent> events) =>
    events.map((e) => e.runtimeType.toString()).join(',');

Future<void> _pump(Application app, Duration duration) async {
  final DateTime deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    if (app.isDisposed) return;
    if (!app.backend.pumpEvents(timeout: const Duration(milliseconds: 4))) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
    app.requestFrame();
    await app.drawPendingFrames();
  }
}
