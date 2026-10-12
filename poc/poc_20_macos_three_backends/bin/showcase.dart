import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poc_20_macos_three_backends/poc_20_macos_three_backends.dart';

// ---------------------------------------------------------------------------
// Showcase for backends 1 and 3: open the window, paint the backend's labelled
// frame, and keep it on screen until it is closed. Backend 2 lives with the
// signal-hijack probes: `probe showcase-signal` in poc_03.
//
//   showcase skylight [seconds]
//   showcase appkit-native-host <host-binary> [seconds]
//
// seconds = 0 (the default) means "until closed": the X painted into the
// SkyLight frame (it has no window frame of its own) or Ctrl+C, and the red
// button for the native host.
// tool/run_showcase.sh builds all three and opens them side by side.
// ---------------------------------------------------------------------------

Future<void> main(List<String> arguments) async {
  final backend = arguments.isEmpty ? '' : arguments.first;
  switch (backend) {
    case 'skylight':
      runSkylightShowcase(_seconds(arguments.elementAtOrNull(1)));
    case 'appkit-native-host' when arguments.length >= 2:
      await runNativeHostShowcase(
          arguments[1], _seconds(arguments.elementAtOrNull(2)));
    default:
      stderr.writeln('usage: showcase skylight [seconds]\n'
          '       showcase appkit-native-host <host-binary> [seconds]');
      exitCode = 64;
  }
}

int _seconds(String? argument) => int.tryParse(argument ?? '') ?? 0;

/// Backend 1. Everything stays synchronous for the same reason as in the
/// conformance suite: the event source lives on this thread's run loop, and an
/// await could resume the isolate on another VM worker.
void runSkylightShowcase(int seconds) {
  const spec = showcaseSkylight;
  print('SHOWCASE_BACKEND=skylight');
  final backend = SkylightBackend(log: (_) {});
  try {
    backend.initializeSync();
    final window = backend.createWindowSync(MacosWindowOptions(
      width: showcaseFrameWidth,
      height: showcaseFrameHeight,
      title: spec.title,
      left: spec.left,
      top: spec.top,
    ));
    backend.presentSync(
      window,
      MacosFrame(
        width: showcaseFrameWidth,
        height: showcaseFrameHeight,
        bytesPerRow: showcaseFrameWidth * 4,
        bgraPremultiplied:
            showcaseBgraFrame(spec, footer: 'PID $pid  JANELA ${window.id}'),
      ),
    );
    print('WINDOW_ID=${window.id}');
    print('PID=$pid');
    print(seconds > 0
        ? 'holding for ${seconds}s'
        : 'holding until the painted X is clicked (or Ctrl+C)');

    // The close button is a button the way AppKit's are: press inside, release
    // inside. Event locations are global top-left; the frame is drawn at
    // (spec.left, spec.top).
    final events = <MacosInputKind, int>{};
    var pressedOnClose = false;
    var closeRequested = false;
    backend.inputEvents.listen((event) {
      final count = events[event.kind] = (events[event.kind] ?? 0) + 1;
      if (count == 1) print('INPUT first ${event.kind.name}');
      final x = (event.x ?? -1) - spec.left;
      final y = (event.y ?? -1) - spec.top;
      final onClose = showcaseCloseBoxHit(x, y);
      switch (event.kind) {
        case MacosInputKind.pointerDown:
          print('INPUT pointerDown at window $x,$y'
              '${onClose ? ' (close button)' : ''}');
          pressedOnClose = onClose;
        case MacosInputKind.pointerUp:
          closeRequested = pressedOnClose && onClose;
          pressedOnClose = false;
        default:
      }
    });

    // The run loop keeps turning so the WindowServer sees a live client and
    // input keeps being drained; 0.25s per round keeps the deadline honest
    // and a click on the X answered promptly.
    final deadline =
        seconds > 0 ? DateTime.now().add(Duration(seconds: seconds)) : null;
    while (!closeRequested &&
        (deadline == null || DateTime.now().isBefore(deadline))) {
      backend.pumpSync(slices: 5);
    }
    if (closeRequested) print('closed by the painted close button');
    print('INPUT_EVENTS=$events');
    print('INPUT_EVENT_TYPES=${backend.report.eventTypes}');
  } finally {
    final stopped = backend.shutdownSync();
    print('TEARDOWN=${stopped ? 'PASS' : 'SKIPPED'} '
        '${backend.report.teardownSteps}');
  }
}

/// Backend 3. The host owns the window; this process only sends it the frame,
/// which is the point - Dart pixels on a window whose main thread is native.
Future<void> runNativeHostShowcase(String hostBinary, int seconds) async {
  const spec = showcaseAppKitNativeHost;
  print('SHOWCASE_BACKEND=appkitNativeHost');
  final host = await Process.start(hostBinary, <String>[
    '--command-stdin',
    '--top-left',
    '${spec.left},${spec.top}',
    '--title',
    spec.title,
  ]);
  final lines = StreamController<String>.broadcast();
  final seen = <String>[];
  var inputs = 0;
  host.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    seen.add(line);
    lines.add(line);
    if (line.startsWith('INPUT=')) {
      if (inputs++ == 0) print('HOST: $line (first input)');
    } else if (!line.startsWith('VIEW_INPUT=')) {
      print('HOST: $line');
    }
  });
  host.stderr.transform(utf8.decoder).listen(stderr.write);

  Future<String?> waitFor(bool Function(String) test) async {
    for (final line in seen) {
      if (test(line)) return line;
    }
    return lines.stream
        .firstWhere(test)
        .timeout(const Duration(seconds: 10), onTimeout: () => '');
  }

  // Ctrl+C closes the window the orderly way, so the host still tears down.
  var hostExited = false;
  unawaited(host.exitCode.then((_) => hostExited = true));
  final sigint = ProcessSignal.sigint.watch().listen((_) {
    if (!hostExited) host.stdin.writeln('CLOSE');
  });
  try {
    final idLine = await waitFor((l) => l.startsWith('WINDOW_ID='));
    final windowId = idLine?.split('=').last ?? '?';
    final frame =
        showcaseBgraFrame(spec, footer: 'PID ${host.pid}  JANELA $windowId');
    host.stdin.write(
        'FRAME $showcaseFrameWidth $showcaseFrameHeight ${frame.length}\n');
    host.stdin.add(frame);
    await host.stdin.flush();
    await waitFor((l) => l.startsWith('FRAME_OK'));
    print(seconds > 0
        ? 'holding for ${seconds}s'
        : 'holding until the window is closed');

    if (seconds > 0) {
      final closed = await host.exitCode
          .timeout(Duration(seconds: seconds), onTimeout: () => -1);
      if (closed == -1) {
        host.stdin.writeln('CLOSE');
        await host.stdin.flush();
      }
    }
    final status = await host.exitCode;
    print('HOST_EXIT=$status INPUT_EVENTS=$inputs');
    if (status != 0) exitCode = 1;
  } finally {
    await sigint.cancel();
    await lines.close();
  }
}
