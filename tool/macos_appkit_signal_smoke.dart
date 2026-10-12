/// The AppKit signal strategy end to end: an [Application] in a real
/// `NSWindow` made in this process on a main thread taken from the VM by a
/// signal, input posted through the WindowServer, pixels read from outside.
///
/// `dart run tool/macos_appkit_signal_smoke.dart`. Prints one
/// `APPKIT_SIGNAL_*=PASS|FAIL` line per check and
/// `MACOS_APPKIT_SIGNAL_SMOKE=PASS|FAIL` last.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/appkit_signal/appkit_signal_window.dart';

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

  late final _setField = _cg.lookupFunction<
      Void Function(Pointer<Void>, Uint32, Int64),
      void Function(Pointer<Void>, int, int)>('CGEventSetIntegerValueField');
  int window = 0;

  Pointer<Void> _tagged(Pointer<Void> event) {
    if (event != nullptr && window != 0) {
      _setField(event, 91, window);
      _setField(event, 92, window);
    }
    return event;
  }

  void click(Offset screen) {
    final Pointer<_Point> point = _alloc<_Point>(sizeOf<_Point>())
      ..ref.x = screen.dx
      ..ref.y = screen.dy;
    _send(_tagged(_mouse(nullptr, 5, point.ref, 0))); // moved
    _send(_tagged(_mouse(nullptr, 1, point.ref, 0))); // left down
    _send(_tagged(_mouse(nullptr, 2, point.ref, 0))); // left up
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

Future<void> main() async {
  if (!Platform.isMacOS) {
    stdout.writeln('MACOS_APPKIT_SIGNAL_SMOKE=SKIP not macOS');
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
      title: 'dart_ui AppKit signal smoke',
      size: const Size(320, 240),
      requestedBackend: 'macos-appkit-signal',
      allowExperimentalBackends: true,
      environment: Platform.environment,
    ),
  );
  final _Poster poster = _Poster();
  try {
    final NativeWindow native = app.primaryWindow.nativeWindow;
    record('APPKIT_SIGNAL_BACKEND', native is AppKitSignalWindow,
        'backend=${app.backend.name} window=${native.runtimeType}');
    if (native is! AppKitSignalWindow) return;
    native.show();
    native.activate();
    poster.window = native.windowNumber;
    await _pump(app, const Duration(milliseconds: 600));

    final String shot =
        '${Directory.systemTemp.path}/dart_ui_appkit_signal.png';
    final ProcessResult capture = Process.runSync('screencapture',
        <String>['-x', '-o', '-l${native.windowNumber}', shot]);
    record(
        'APPKIT_SIGNAL_CAPTURE',
        capture.exitCode == 0 && File(shot).existsSync(),
        'window=${native.windowNumber} file=$shot');

    native.debugPostClick(const Offset(150, 60));
    await _pump(app, const Duration(milliseconds: 400));
    record('APPKIT_SIGNAL_CLICK', presses == 1, 'presses=$presses');

    native.debugPostClick(const Offset(150, 20));
    await _pump(app, const Duration(milliseconds: 200));
    poster.type('olá');
    await _pump(app, const Duration(milliseconds: 400));
    record('APPKIT_SIGNAL_TYPING', controller.value == 'olá',
        'value="${controller.value}"');

    // zoom: and back, through the framework's state request.
    final Size normal = native.clientSize;
    native.requestState(WindowState.maximised);
    await _pump(app, const Duration(milliseconds: 800));
    final Size maximised = native.clientSize;
    native.requestState(WindowState.normal);
    await _pump(app, const Duration(milliseconds: 800));
    record(
        'APPKIT_SIGNAL_MAXIMIZE',
        maximised.width > normal.width * 2 &&
            (native.clientSize.width - normal.width).abs() < 1,
        'normal=$normal maximised=$maximised restored=${native.clientSize}');

    // performClose: - what the red button, Cmd+W and Window > Close send.
    // A click on the button itself runs inside AppKit's own tracking loop,
    // which a process-posted event cannot reach without Accessibility
    // permission; the message is the part this backend owns.
    native.debugPerformClose();
    final Stopwatch waited = Stopwatch()..start();
    while (app.state != ApplicationLifecycleState.closing &&
        waited.elapsed < const Duration(seconds: 3)) {
      await _pump(app, const Duration(milliseconds: 50));
    }
    record('APPKIT_SIGNAL_CLOSE_BUTTON',
        app.state == ApplicationLifecycleState.closing, 'state=${app.state}');
  } on Object catch (error, stack) {
    stderr
      ..writeln('MACOS_APPKIT_SIGNAL_SMOKE threw: $error')
      ..writeln(stack);
    verdict = 'FAIL';
    reason = 'threw ${error.runtimeType}';
  } finally {
    app.dispose();
    await app.closed;
  }
  stdout.writeln('MACOS_APPKIT_SIGNAL_SMOKE=$verdict'
      '${verdict == 'PASS' ? '' : ' $reason'}');
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
