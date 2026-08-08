import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:poc_20_macos_three_backends/poc_20_macos_three_backends.dart';

// ---------------------------------------------------------------------------
// One suite, three backends.
//
// Every backend must answer the same six questions with the same lines, so the
// CI gate is identical for all of them and the comparison is not a matter of
// opinion:
//
//   CONFORMANCE_BACKEND=<kind>   which implementation ran
//   WINDOW_ID=<n>                the WindowServer owns a window
//   PRESENT=PASS                 a CPU framebuffer reached that window
//   PIXEL_WITNESS=PASS ...       screencapture(1) sees the frame from OUTSIDE
//   INPUT_EVENTS=<n>             input arrived through the real event route
//   TEARDOWN=PASS                every handle released, no _exit
//   CONFORMANCE=PASS             all of the above
//
// The pixel witness is what makes this more than self-reporting: a process can
// claim it drew a frame, but only the WindowServer can hand that frame to
// another program.
// ---------------------------------------------------------------------------

const int frameWidth = 480;
const int frameHeight = 320;

/// One fill colour per backend, all distinct from the desktop background, so a
/// capture left behind by another backend cannot pass for a fresh frame.
const Map<String, PixelSample> expectedCentres = <String, PixelSample>{
  'skylight': PixelSample(20, 120, 220),
  'appkit-native-host': PixelSample(220, 120, 20),
  'appkit-signal': PixelSample(120, 220, 20),
};

Uint8List solidBgraFrame(PixelSample colour) {
  final bytes = Uint8List(frameWidth * frameHeight * 4);
  for (var i = 0; i < bytes.length; i += 4) {
    bytes[i] = colour.blue;
    bytes[i + 1] = colour.green;
    bytes[i + 2] = colour.red;
    bytes[i + 3] = 255;
  }
  return bytes;
}

String get _workDirectory =>
    Platform.environment['CONFORMANCE_SHOTS'] ?? '/tmp/shots';

Future<void> main(List<String> arguments) async {
  final backend = arguments.isEmpty ? 'skylight' : arguments.first;
  switch (backend) {
    case 'skylight':
      runSkylightConformance();
    case 'appkit-native-host':
      if (arguments.length != 2) {
        stderr.writeln('usage: conformance appkit-native-host <host-binary>');
        exitCode = 64;
        return;
      }
      await runNativeHostConformance(arguments[1]);
    default:
      stderr.writeln('usage: conformance [skylight|appkit-native-host <bin>]');
      exitCode = 64;
  }
}

void runSkylightConformance() {
  print('CONFORMANCE_BACKEND=skylight');
  final expectedCentre = expectedCentres['skylight']!;
  final backend = SkylightBackend();
  var failures = 0;

  void check(bool condition, String failure) {
    if (!condition) {
      failures++;
      print('FAILURE: $failure');
    }
  }

  try {
    backend.initializeSync();
    final window = backend.createWindowSync(
      const MacosWindowOptions(width: frameWidth, height: frameHeight),
    );
    print('WINDOW_ID=${window.id}');
    check(window.id > 0, 'no window id');

    final events = <MacosInputEvent>[];
    backend.inputEvents.listen(events.add);

    backend.presentSync(
      window,
      MacosFrame(
        width: frameWidth,
        height: frameHeight,
        bytesPerRow: frameWidth * 4,
        bgraPremultiplied: solidBgraFrame(expectedCentre),
      ),
    );
    print('PRESENT=PASS');

    // Input, through the WindowServer, the way physical input arrives.
    var injected = 0;
    double injectX() => 260 + (injected % 8) * 23;
    double injectY() => 240 + (injected % 5) * 17;
    backend.injectSyntheticInput(x: injectX(), y: injectY());
    injected++;
    var pumped = 0;
    for (var round = 0; round < 60 && backend.report.eventsRead < 4; round++) {
      pumped += backend.pumpSync(slices: 2);
      if (round % 12 == 11) {
        backend.injectSyntheticInput(x: injectX(), y: injectY());
        injected++;
      }
    }
    print('INPUT_EVENTS=${backend.report.eventsRead}');
    print('INPUT_EVENT_TYPES=${backend.report.eventTypes}');
    print('MACH_MESSAGES=${backend.report.machMessages} '
        'extraReads=${backend.report.extraReads}');
    print('POINTER_INPUT='
        '${events.any((e) => e.kind == MacosInputKind.pointerMove) ? 1 : 0}');
    print('INPUT_EVENTS_DECODED=${events.map((e) => e.kind.name).toList()}');
    check(
        backend.report.eventsRead > 0,
        'no input event arrived (pumped '
        '$pumped)');
    check(backend.threadIsStable, 'the isolate migrated OS threads');

    // Outside witness runs AFTER the input phase on purpose: screencapture(1)
    // grabs the display and spawns two processes, and pointerMove never
    // arrived when it ran in between. Key events are posted to a pid and come
    // through regardless; a pointer move is only worth reporting to whoever is
    // under the pointer.
    final witness = WindowPixelWitness(workDirectory: _workDirectory)
        .capture(window.id, label: 'skylight');
    final centre = witness.centre;
    if (centre != null && centre.matches(expectedCentre)) {
      print('PIXEL_WITNESS=PASS centre=$centre '
          'size=${witness.width}x${witness.height}');
    } else {
      print('PIXEL_WITNESS=FAIL centre=$centre '
          'size=${witness.width}x${witness.height} '
          'expected=$expectedCentre failure=${witness.failure}');
      failures++;
    }

    final failuresBeforeTeardown = failures;
    final stopped = backend.shutdownSync();
    print('REGISTRATION_ATTEMPTS=${backend.report.registrationAttempts}');
    print('TEARDOWN_STEPS=${backend.report.teardownSteps}');
    print('MISSING_SYMBOLS=${backend.report.missingSymbols}');
    check(stopped, 'shutdown was refused');
    check(backend.state == MacosBackendState.stopped, 'state is not stopped');
    check(backend.shutdownSync() == false, 'shutdown is not idempotent');
    print(
        failures == failuresBeforeTeardown ? 'TEARDOWN=PASS' : 'TEARDOWN=FAIL');
  } catch (error, stack) {
    failures++;
    print('CONFORMANCE_ERROR: $error');
    print(stack);
    // Best effort: a failed run must still not leak the WindowServer handles.
    try {
      backend.shutdownSync();
    } catch (_) {}
  }

  print(failures == 0 ? 'CONFORMANCE=PASS' : 'CONFORMANCE=FAIL ($failures)');
  // No _exit: returning from main is part of what this suite proves.
  if (failures != 0) exitCode = 1;
}

// ---------------------------------------------------------------------------
// Backend 3. The window, the frame and the teardown all happen in the native
// host; Dart drives them over the protocol and verifies from outside. The
// interesting part is that input reaches a Dart process at all: the events are
// posted to the HOST's pid, dequeued by the host's AppKit loop, and reported
// back over stdout.
// ---------------------------------------------------------------------------

Future<void> runNativeHostConformance(String hostBinary) async {
  print('CONFORMANCE_BACKEND=appkitNativeHost');
  final expectedCentre = expectedCentres['appkit-native-host']!;
  var failures = 0;

  void check(bool condition, String failure) {
    if (!condition) {
      failures++;
      print('FAILURE: $failure');
    }
  }

  final host = await Process.start(hostBinary, const ['--command-stdin']);
  final lines = <String>[];
  final inputs = <String>[];
  final viewInputs = <String>[];
  final stdoutDone = host.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    lines.add(line);
    print('HOST: $line');
    if (line.startsWith('INPUT=')) inputs.add(line.substring(6));
    if (line.startsWith('VIEW_INPUT=')) viewInputs.add(line.substring(11));
  }).asFuture<void>();
  final hostStderr = host.stderr.transform(utf8.decoder).join();

  Future<bool> waitForLine(bool Function(String line) predicate,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (lines.any(predicate)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return false;
  }

  try {
    check(
        await waitForLine((l) => l == 'PROTOCOL=3'),
        'host never announced '
        'protocol 3');
    check(lines.contains('MAIN_THREAD=1'), 'host does not own thread 0');
    final idLine = lines.firstWhere((l) => l.startsWith('WINDOW_ID='),
        orElse: () => 'WINDOW_ID=0');
    final windowId = int.parse(idLine.split('=').last);
    print('WINDOW_ID=$windowId');
    check(windowId > 0, 'no window id');

    // A real CPU framebuffer crosses the process boundary: header line, then
    // exactly that many raw octets.
    final frame = solidBgraFrame(expectedCentre);
    host.stdin.write('FRAME $frameWidth $frameHeight ${frame.length}\n');
    host.stdin.add(frame);
    await host.stdin.flush();
    final framed = await waitForLine((l) => l.startsWith('FRAME_OK'));
    print(framed ? 'PRESENT=PASS' : 'PRESENT=FAIL');
    check(framed, 'host did not acknowledge the frame');

    final witness = WindowPixelWitness(workDirectory: _workDirectory)
        .capture(windowId, label: 'appkit-native-host');
    final centre = witness.centre;
    if (centre != null && centre.matches(expectedCentre)) {
      print('PIXEL_WITNESS=PASS centre=$centre '
          'size=${witness.width}x${witness.height}');
    } else {
      print('PIXEL_WITNESS=FAIL centre=$centre '
          'size=${witness.width}x${witness.height} '
          'expected=$expectedCentre failure=${witness.failure}');
      failures++;
    }

    // Input is posted to the host process, not to this one.
    final input = SyntheticInput();
    check(input.postTo(host.pid), 'could not create synthetic events');
    await waitForLine((l) => l.startsWith('INPUT='),
        timeout: const Duration(seconds: 3));
    if (inputs.isEmpty) input.postTo(host.pid);
    await waitForLine((l) => l.startsWith('INPUT='),
        timeout: const Duration(seconds: 3));
    // The first INPUT line only proves the path is open; the rest of the burst
    // is still in flight, and counting it here is what makes the numbers below
    // match what the host actually reported.
    await Future<void>.delayed(const Duration(milliseconds: 750));
    print('INPUT_EVENTS=${inputs.length}');
    print('INPUT_EVENT_KINDS=$inputs');
    print('VIEW_INPUT_EVENTS=${viewInputs.length} $viewInputs');
    check(inputs.isNotEmpty, 'the host dequeued no input');
    check(viewInputs.isNotEmpty, 'no input reached the responder chain');

    host.stdin.writeln('CLOSE');
    await host.stdin.flush();
    final closed = await waitForLine((l) => l == 'CLOSE_OK');
    final tornDown = await waitForLine((l) => l == 'TEARDOWN=PASS');
    await host.stdin.close();
    final status = await host.exitCode.timeout(const Duration(seconds: 10));
    check(closed, 'host did not acknowledge CLOSE');
    check(status == 0, 'host exited with status $status');
    print(tornDown && status == 0 ? 'TEARDOWN=PASS' : 'TEARDOWN=FAIL');
    check(tornDown, 'host did not report an ordered teardown');
  } on Object catch (error, stack) {
    failures++;
    print('CONFORMANCE_ERROR: $error');
    print(stack);
    host.kill(ProcessSignal.sigkill);
  }

  await stdoutDone;
  final errors = await hostStderr;
  if (errors.isNotEmpty) stderr.write(errors);
  print(failures == 0 ? 'CONFORMANCE=PASS' : 'CONFORMANCE=FAIL ($failures)');
  if (failures != 0) exitCode = 1;
}
