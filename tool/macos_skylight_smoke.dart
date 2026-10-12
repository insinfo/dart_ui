/// The SkyLight strategy end to end: an [Application] on a WindowServer
/// window made without AppKit, input posted through the WindowServer the way
/// physical input arrives, and the pixels read back from outside.
///
/// `dart run tool/macos_skylight_smoke.dart`. Prints one `SKYLIGHT_*=PASS|FAIL`
/// line per check and `MACOS_SKYLIGHT_SMOKE=PASS|FAIL` last.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/skylight/skylight_window.dart';

final class _Point extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

/// Posts CG events to this process through the WindowServer.
final class _Poster {
  final DynamicLibrary _cg = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
  final DynamicLibrary _sl = DynamicLibrary.open(
      '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
  late final _mouse = _cg.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Uint32, _Point, Uint32),
      Pointer<Void> Function(
          Pointer<Void>, int, _Point, int)>('CGEventCreateMouseEvent');
  late final _key = _cg.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Uint16, Bool),
      Pointer<Void> Function(
          Pointer<Void>, int, bool)>('CGEventCreateKeyboardEvent');
  late final _setUnicode = _cg.lookupFunction<
      Void Function(Pointer<Void>, UnsignedLong, Pointer<Uint16>),
      void Function(Pointer<Void>, int,
          Pointer<Uint16>)>('CGEventKeyboardSetUnicodeString');
  late final _post = _sl.lookupFunction<Void Function(Int32, Pointer<Void>),
      void Function(int, Pointer<Void>)>('SLEventPostToPid');
  late final _release = DynamicLibrary.open('/System/Library/Frameworks/'
          'CoreFoundation.framework/CoreFoundation')
      .lookupFunction<Void Function(Pointer<Void>),
          void Function(Pointer<Void>)>('CFRelease');

  void _send(Pointer<Void> event) {
    if (event == nullptr) return;
    _post(pid, event);
    _release(event);
  }

  void click(Offset screen) {
    final Pointer<_Point> point = _alloc<_Point>(sizeOf<_Point>())
      ..ref.x = screen.dx
      ..ref.y = screen.dy;
    _send(_mouse(nullptr, 5, point.ref, 0)); // moved
    _send(_mouse(nullptr, 1, point.ref, 0)); // left down
    _send(_mouse(nullptr, 2, point.ref, 0)); // left up
    _free(point);
  }

  /// Press at [from], drag through to [to], release there - one step per
  /// [between], so the gesture sees a drag rather than a teleport.
  Future<void> drag(
      Offset from, Offset to, Future<void> Function() between) async {
    final Pointer<_Point> point = _alloc<_Point>(sizeOf<_Point>())
      ..ref.x = from.dx
      ..ref.y = from.dy;
    _send(_mouse(nullptr, 1, point.ref, 0));
    await between();
    for (var step = 1; step <= 8; step++) {
      point.ref
        ..x = from.dx + (to.dx - from.dx) * step / 8
        ..y = from.dy + (to.dy - from.dy) * step / 8;
      _send(_mouse(nullptr, 6, point.ref, 0)); // left dragged
      await between();
    }
    _send(_mouse(nullptr, 2, point.ref, 0));
    await between();
    _free(point);
  }

  void type(String text) {
    for (final int unit in text.codeUnits) {
      for (final bool down in <bool>[true, false]) {
        final Pointer<Void> event = _key(nullptr, 0, down);
        final Pointer<Uint16> buffer = _alloc<Uint16>(2)..value = unit;
        _setUnicode(event, 1, buffer);
        _free(buffer);
        _send(event);
      }
    }
  }

  late final _calloc = DynamicLibrary.process().lookupFunction<
      Pointer<Void> Function(IntPtr, IntPtr),
      Pointer<Void> Function(int, int)>('calloc');
  late final _freeFn = DynamicLibrary.process().lookupFunction<
      Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');
  Pointer<T> _alloc<T extends NativeType>(int bytes) =>
      _calloc(1, bytes).cast<T>();
  void _free(Pointer<NativeType> p) => _freeFn(p.cast());
}

/// What the Dock sends when its tile is clicked: `kAEReopenApplication`
/// to [pid], from another process, as the Dock does.
void _sendReopen(int pid) {
  final DynamicLibrary ae = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreServices.framework/CoreServices');
  final _Poster memory = _Poster();
  final Pointer<Int32> target = memory._alloc<Int32>(4)..value = pid;
  final Pointer<Uint8> address = memory._alloc<Uint8>(16);
  final Pointer<Uint8> event = memory._alloc<Uint8>(16);
  final Pointer<Uint8> reply = memory._alloc<Uint8>(16);
  // typeKernelProcessID 'kpid'.
  ae.lookupFunction<
      Int16 Function(Uint32, Pointer<Int32>, IntPtr, Pointer<Uint8>),
      int Function(int, Pointer<Int32>, int,
          Pointer<Uint8>)>('AECreateDesc')(0x6B706964, target, 4, address);
  // 'aevt'/'rapp', kAutoGenerateReturnID, kAnyTransactionID.
  ae.lookupFunction<
          Int16 Function(
              Uint32, Uint32, Pointer<Uint8>, Int16, Int32, Pointer<Uint8>),
          int Function(int, int, Pointer<Uint8>, int, int, Pointer<Uint8>)>(
      'AECreateAppleEvent')(0x61657674, 0x72617070, address, -1, 0, event);
  // kAENoReply, kAEDefaultTimeout.
  final int rc = ae.lookupFunction<
      Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Int32, Long),
      int Function(Pointer<Uint8>, Pointer<Uint8>, int,
          int)>('AESendMessage')(event, reply, 1, -1);
  stdout.writeln('sent reopen to $pid: $rc');
}

Future<void> main(List<String> arguments) async {
  if (arguments.length == 2 && arguments.first == '--send-reopen') {
    _sendReopen(int.parse(arguments[1]));
    return;
  }
  if (!Platform.isMacOS) {
    stdout.writeln('MACOS_SKYLIGHT_SMOKE=SKIP not macOS');
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

  final TextEditingController controller = TextEditingController();
  var presses = 0;
  final Application app = await Application.start(
    rootWidget: Column(
      children: <Widget>[
        SizedBox(
          width: 300,
          height: 40,
          child: TextField(controller: controller, label: 'name'),
        ),
        SizedBox(
          width: 300,
          height: 40,
          child: Button(label: 'press', onPressed: () => presses++),
        ),
        const Expanded(child: ColoredBox(color: Color(0xFF2060C0))),
      ],
    ),
    backends: PlatformBackendResolver.defaultBackends(),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: ApplicationOptions(
      title: 'dart_ui SkyLight smoke',
      size: const Size(320, 240),
      requestedBackend: 'macos-skylight',
      allowExperimentalBackends: true,
      environment: Platform.environment,
    ),
  );
  final _Poster poster = _Poster();
  try {
    final NativeWindow native = app.primaryWindow.nativeWindow;
    record('SKYLIGHT_BACKEND', native is SkylightWindow,
        'backend=${app.backend.name} window=${native.runtimeType}');
    if (native is! SkylightWindow) return;
    native.show();
    await _pump(app, const Duration(milliseconds: 500));

    // Pixels, from outside the process.
    final String shot = '${Directory.systemTemp.path}/dart_ui_skylight.png';
    final ProcessResult capture = Process.runSync('screencapture',
        <String>['-x', '-o', '-l${native.windowNumber}', shot]);
    final bool captured = capture.exitCode == 0 && File(shot).existsSync();
    record('SKYLIGHT_CAPTURE', captured,
        'window=${native.windowNumber} file=$shot');

    // The content sits below the framework's 32 px title bar and its rule.
    const double bar = 33;
    Offset screen(Offset client) => native.clientToScreen(client);

    poster.click(screen(const Offset(150, bar + 60)));
    await _pump(app, const Duration(milliseconds: 400));
    record('SKYLIGHT_CLICK', presses == 1, 'presses=$presses');

    poster.click(screen(const Offset(150, bar + 20)));
    await _pump(app, const Duration(milliseconds: 200));
    poster.type('olá');
    await _pump(app, const Duration(milliseconds: 400));
    record('SKYLIGHT_TYPING', controller.value == 'olá',
        'value="${controller.value}"');

    // The title bar moves the window: there is no compositor to do it, so
    // the window follows the drag itself.
    final Offset before = native.clientToScreen(Offset.zero);
    await poster.drag(
        screen(const Offset(60, 16)),
        screen(const Offset(140, 56)),
        () => _pump(app, const Duration(milliseconds: 40)));
    await _pump(app, const Duration(milliseconds: 200));
    final Offset after = native.clientToScreen(Offset.zero);
    record(
        'SKYLIGHT_MOVE',
        (after - before - const Offset(80, 40)).distance < 2,
        'moved by ${after - before}');

    // The drawn maximise button fills the display; again restores.
    final Size normal = native.clientSize;
    poster.click(screen(Offset(native.clientSize.width - 64, 16)));
    await _pump(app, const Duration(milliseconds: 400));
    final Size maximised = native.clientSize;
    poster.click(screen(Offset(native.clientSize.width - 64, 16)));
    await _pump(app, const Duration(milliseconds: 400));
    record(
        'SKYLIGHT_MAXIMIZE',
        maximised.width > normal.width * 2 && native.clientSize == normal,
        'normal=$normal maximised=$maximised restored=${native.clientSize}');

    // The drawn minimise button sends the window to the Dock; a click on
    // the app's tile - the reopen Apple Event, sent here from another
    // process as the Dock sends it - brings it back.
    poster.click(screen(Offset(native.clientSize.width - 112, 16)));
    await _pump(app, const Duration(milliseconds: 800));
    final WindowState minimisedState = native.state;
    final bool hidden = !native.isOnScreen;
    final ProcessResult reopen = Process.runSync(Platform.resolvedExecutable,
        <String>[Platform.script.toFilePath(), '--send-reopen', '$pid']);
    final Stopwatch reopened = Stopwatch()..start();
    while (native.state == WindowState.minimised &&
        reopened.elapsed < const Duration(seconds: 3)) {
      await _pump(app, const Duration(milliseconds: 50));
    }
    await _pump(app, const Duration(milliseconds: 600));
    record(
        'SKYLIGHT_MINIMIZE',
        native.canMinimize &&
            minimisedState == WindowState.minimised &&
            hidden &&
            native.state == WindowState.normal &&
            native.isOnScreen,
        'canMinimize=${native.canMinimize} minimised=$minimisedState '
            'hidden=$hidden restored=${native.state} '
            'onScreen=${native.isOnScreen} '
            'sender="${'${reopen.stdout}'.trim()}${reopen.stderr}"');

    // The frame's close button, top right.
    poster.click(screen(Offset(native.clientSize.width - 20, 16)));
    final Stopwatch waited = Stopwatch()..start();
    while (app.state != ApplicationLifecycleState.closing &&
        waited.elapsed < const Duration(seconds: 3)) {
      await _pump(app, const Duration(milliseconds: 50));
    }
    record('SKYLIGHT_CLOSE_BUTTON',
        app.state == ApplicationLifecycleState.closing, 'state=${app.state}');
  } on Object catch (error, stack) {
    stderr
      ..writeln('MACOS_SKYLIGHT_SMOKE threw: $error')
      ..writeln(stack);
    verdict = 'FAIL';
    reason = 'threw ${error.runtimeType}';
  } finally {
    app.dispose();
    await app.closed;
  }
  stdout.writeln(
      'MACOS_SKYLIGHT_SMOKE=$verdict${verdict == 'PASS' ? '' : ' $reason'}');
  exitCode = verdict == 'PASS' ? 0 : 1;
}

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
