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
import 'package:dart_ui/src/backends/macos/macos_drag_drop.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';

const int _shift = 1 << 17;
const int _command = 1 << 20;
const int _function = 1 << 23;
const int _option = 1 << 19;

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
  final dropped = <List<String>>[];
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
        SizedBox(
          width: 280,
          height: 60,
          child: DropTarget(
            formats: const <String>[DragFormats.uriList],
            onDrop: (DropDetails details) async {
              dropped.add(await details.data.readFilePaths());
              return DragAction.copy;
            },
            child: const ColoredBox(color: Color(0xFF203040)),
          ),
        ),
      ],
    ),
    backends: PlatformBackendResolver.defaultBackends(),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: ApplicationOptions(
      title: 'dart_ui input smoke (application)',
      size: const Size(320, 180),
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
    // Shown explicitly, as `Application.run` would: this smoke pumps by hand,
    // and AppKit dispatches keys only to a window that is on screen - the
    // event monitor still sees them, the view does not.
    native.show();
    await _pump(app, const Duration(milliseconds: 400));

    native
      ..synthesizeInput('SYNTH_MOUSE down 140 60 0 1 0')
      ..synthesizeInput('SYNTH_MOUSE up 140 60 0 1 0');
    await _pump(app, const Duration(milliseconds: 300));
    record('INPUT_APP_BUTTON', presses == 1, 'presses=$presses');

    // Accessibility, as VoiceOver reaches it: the host's view is a group of
    // NSAccessibilityElements built from the framework's semantic tree. The
    // first question from a client makes the host say A11Y_REQUESTED and the
    // framework publish; the second sees the tree. Then the button is pressed
    // through accessibilityPerformPress and must count, as a click does.
    await native.debugAccessibilityDump();
    await _pump(app, const Duration(milliseconds: 300));
    final List<String> tree = await native.debugAccessibilityDump();
    final bool hasButton =
        tree.any((String line) => line.contains(':AXButton:${_b64('press')}'));
    final bool hasField =
        tree.any((String line) => line.contains(':AXTextField:'));
    record('INPUT_APP_A11Y_TREE', hasButton && hasField,
        'elements=${tree.length} ${tree.take(4).join(' | ')}');
    final int pressesBefore = presses;
    final bool pressed = await native.debugAccessibilityPress('press');
    await _pump(app, const Duration(milliseconds: 200));
    record('INPUT_APP_A11Y_PRESS', pressed && presses == pressesBefore + 1,
        'pressed=$pressed presses=$presses');

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

    // Dead keys, through the real layout. The keys are posted with *empty*
    // characters, so AppKit translates them from the key code and the
    // modifiers with the layout the user has selected - which is what makes
    // this a test of the layout's dead-key state and not of this file's
    // strings. AppKit composes inside the NSEvent: the dead key arrives with
    // no characters and the next one already carries the accented letter, so
    // no input method client is involved.
    final String layout = await _keyboardLayout();
    final List<(int, int)>? deadKeys = switch (layout) {
      // ABNT2: the acute key beside P, then e; the tilde key, then a.
      'com.apple.keylayout.Brazilian-ABNT2' => <(int, int)>[
          (0x21, 0), (0x0E, 0), (0x27, 0), (0x00, 0), //
        ],
      // US and ABC: Option+E is the acute, Option+N the tilde.
      'com.apple.keylayout.US' || 'com.apple.keylayout.ABC' => <(int, int)>[
          (0x0E, _option), (0x0E, 0), (0x2D, _option), (0x00, 0), //
        ],
      _ => null,
    };
    if (deadKeys == null) {
      stdout.writeln('INPUT_APP_DEAD_KEYS=SKIP layout=$layout has no sequence '
          'in this smoke');
    } else {
      controller.value = '';
      for (final (int keyCode, int flags) in deadKeys) {
        native
          ..synthesizeInput('SYNTH_KEY down $keyCode $flags - -')
          ..synthesizeInput('SYNTH_KEY up $keyCode $flags - -');
      }
      await _pump(app, const Duration(milliseconds: 400));
      record('INPUT_APP_DEAD_KEYS', controller.value == 'éã',
          'layout=$layout value="${controller.value}"');
    }

    // An input method's preedit, shown in the field as a composition, then
    // replaced by what it commits. The calls are the ones an input method
    // makes, made directly (SYNTH_IME): a method that marks text is not
    // guaranteed to be installed. The runner's US layout reaches the same path
    // through a real one, Option+E in the dead-key check above.
    controller.value = '';
    native.synthesizeInput('SYNTH_IME mark ${_b64('にほ')} 2');
    await _pump(app, const Duration(milliseconds: 300));
    final bool composing = controller.isComposing;
    final String preedit = controller.value;
    native.synthesizeInput('SYNTH_IME commit ${_b64('日本')}');
    await _pump(app, const Duration(milliseconds: 300));
    record(
        'INPUT_APP_IME',
        composing &&
            preedit == 'にほ' &&
            controller.value == '日本' &&
            !controller.isComposing,
        'preedit="$preedit" composing=$composing '
            'committed="${controller.value}" '
            'composingAfter=${controller.isComposing}');

    // The press-and-hold accent menu: hold 'e', pick 'é', and AppKit calls
    // insertText:replacementRange: with the range of the 'e'. The host
    // measures that range against the text the field pushed
    // (IME_SURROUNDING) and sends IME_DELETE ahead of the 'é'. Before
    // 12/10/2026 it answered selectedRange with (0, 0) and ignored the range,
    // and the field read "cafeé".
    controller
      ..value = 'cafe'
      // The caret after the 'e', where it is when the key is held: setting the
      // value keeps the previous scene's caret, and a replacement range that
      // is not next to the caret cannot be expressed as a deletion around it.
      ..setSelection(4, 4);
    await _pump(app, const Duration(milliseconds: 200));
    native.synthesizeInput('SYNTH_IME replace ${_b64('é')} 3 1');
    await _pump(app, const Duration(milliseconds: 300));
    record('INPUT_APP_ACCENT_MENU', controller.value == 'café',
        'value="${controller.value}"');

    // Files dropped on a DropTarget: the host's NSDraggingDestination, given
    // a drag over a private pasteboard (SYNTH_DRAG), through the widget
    // tree's drop routing. Paths are ASCII on purpose: macOS hands a path back
    // decomposed (NFD), and comparing that is not what this checks.
    const String paths = '/tmp/dart_ui_drop_a.pdf\n/tmp/dart_ui_drop_b.svg';
    const int copyOrMove = 1 | 16;
    native
      ..synthesizeInput('SYNTH_DRAG enter 140 100 $copyOrMove ${_b64(paths)} -')
      ..synthesizeInput('SYNTH_DRAG over 140 110 $copyOrMove - -');
    await _pump(app, const Duration(milliseconds: 250));
    native.synthesizeInput('SYNTH_DRAG drop 140 110 $copyOrMove - -');
    await _pump(app, const Duration(milliseconds: 300));
    record(
        'INPUT_APP_DROP_FILES',
        dropped.length == 1 &&
            dropped.single.join(',') ==
                '/tmp/dart_ui_drop_a.pdf,/tmp/dart_ui_drop_b.svg',
        'drops=${dropped.length} paths=${dropped.firstOrNull}');

    // The same drag over the text field, where no target is: nothing may land.
    // This checks the outcome only - the widget routing alone would keep it
    // off the DropTarget. That the framework answers DROP_RESPONSE 0 there is
    // pinned by macos_drag_drop_test.dart, and that the host then declines the
    // drop (no DRAG=DROP) was checked against the host binary directly.
    native
      ..synthesizeInput('SYNTH_DRAG enter 140 20 $copyOrMove ${_b64(paths)} -')
      ..synthesizeInput('SYNTH_DRAG over 140 21 $copyOrMove - -');
    await _pump(app, const Duration(milliseconds: 250));
    native.synthesizeInput('SYNTH_DRAG drop 140 21 $copyOrMove - -');
    await _pump(app, const Duration(milliseconds: 300));
    record('INPUT_APP_DROP_REFUSED', dropped.length == 1,
        'drops=${dropped.length} (one, from the check above)');

    // Dragging out (DRAG_START): a press in the window, which AppKit needs to
    // begin a session from, then startDrag. With no real button held the
    // session cannot travel anywhere, so what this checks is the plumbing -
    // the host's NSDraggingSource began a session and reported its end, and
    // the future completed with an action rather than hanging or throwing.
    native.synthesizeInput('SYNTH_MOUSE down 140 110 0 1 0');
    await _pump(app, const Duration(milliseconds: 150));
    DragAction? dragOut;
    Object? dragOutFailure;
    unawaited(const MacosDragDropBackend()
        .startDrag(
            DragRequest(window: native, data: MemoryDragData.text('dart_ui')))
        .then((DragAction action) => dragOut = action,
            onError: (Object error) => dragOutFailure = error));
    for (var i = 0; i < 30 && dragOut == null && dragOutFailure == null; i++) {
      await _pump(app, const Duration(milliseconds: 100));
    }
    native.synthesizeInput('SYNTH_MOUSE up 140 110 0 1 0');
    await _pump(app, const Duration(milliseconds: 100));
    record('INPUT_APP_DRAG_OUT', dragOut != null,
        'action=$dragOut failure=$dragOutFailure');

    // Cmd+A, Cmd+C: Command arrives as meta, and the field reads the Mac
    // convention, so this is copy - checked from outside the process.
    final String saved = await _pbpaste();
    // Whatever the checks above left in the field: Cmd+A, Cmd+C must copy it
    // all, and Cmd+V at the end must double it.
    final String before = controller.value;
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
          before.isNotEmpty &&
              copied == before &&
              controller.value == '$before$before',
          'pbpasteAfterCmdC="$copied" valueAfterCmdV="${controller.value}"');
    } finally {
      await _pbcopy(saved);
    }

    // Window state, asked for from Dart and read back from AppKit: zoom:,
    // miniaturize: and toggleFullScreen: in the host, each answered by the
    // WINDOW=STATE it reports. Full screen animates for about a second each
    // way, hence the longer waits.
    Future<bool> becomes(WindowState wanted, Duration timeout) async {
      final DateTime deadline = DateTime.now().add(timeout);
      while (native.state != wanted && DateTime.now().isBefore(deadline)) {
        await _pump(app, const Duration(milliseconds: 50));
      }
      return native.state == wanted;
    }

    final List<String> steps = <String>[];
    for (final (WindowState wanted, int seconds) in <(WindowState, int)>[
      (WindowState.maximised, 3),
      (WindowState.normal, 3),
      (WindowState.minimised, 3),
      (WindowState.normal, 3),
      (WindowState.fullscreen, 6),
      (WindowState.maximised, 6),
      (WindowState.normal, 3),
    ]) {
      final bool sent = (native as WindowStateControl).requestState(wanted);
      final bool reached = await becomes(wanted, Duration(seconds: seconds));
      steps.add('${wanted.name}=${sent && reached}');
    }
    record('INPUT_APP_WINDOW_STATE',
        steps.every((String step) => step.endsWith('true')), steps.join(' '));

    // Last, because it ends the run: Window > Close (Cmd+W) from the main
    // menu the host installs is the close button's request. For the last
    // window that is a request to close the application, so the application
    // goes to `closing` and leaves the teardown to dispose - the documented
    // policy in application.dart.
    native.synthesizeInput('SYNTH_MENU ${_b64('Close')}');
    // Up to three seconds: the restore just above animates, and the host
    // reads its next command when the animation lets go of the main thread.
    final DateTime closeDeadline =
        DateTime.now().add(const Duration(seconds: 3));
    while (app.state != ApplicationLifecycleState.closing &&
        DateTime.now().isBefore(closeDeadline)) {
      await _pump(app, const Duration(milliseconds: 50));
    }
    record('INPUT_APP_MENU_CLOSE',
        app.state == ApplicationLifecycleState.closing, 'state=${app.state}');
  } finally {
    app.dispose();
    await app.closed;
  }
}

/// The keyboard layout the user has selected, or US when it cannot be read.
Future<String> _keyboardLayout() async {
  final ProcessResult result = await Process.run('defaults', const <String>[
    'read',
    'com.apple.HIToolbox',
    'AppleCurrentKeyboardLayoutInputSourceID',
  ]);
  final String layout = (result.stdout as String).trim();
  return result.exitCode == 0 && layout.isNotEmpty
      ? layout
      : 'com.apple.keylayout.US';
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
