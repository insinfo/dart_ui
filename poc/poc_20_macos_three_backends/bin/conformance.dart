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

/// Distinct from the desktop background and from every other backend's fill, so
/// a stale capture cannot pass for a fresh one.
const PixelSample expectedCentre = PixelSample(20, 120, 220);

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
    default:
      stderr.writeln('usage: conformance [skylight]');
      exitCode = 64;
  }
}

void runSkylightConformance() {
  print('CONFORMANCE_BACKEND=skylight');
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

    // Outside witness. Runs between pump slices; the Mach port queues in the
    // meantime, so nothing is lost.
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

    // Input, through the WindowServer, the way physical input arrives.
    backend.injectSyntheticInput();
    var pumped = 0;
    for (var round = 0; round < 40 && backend.report.eventsRead < 3; round++) {
      pumped += backend.pumpSync(slices: 2);
      if (round == 20) backend.injectSyntheticInput();
    }
    print('INPUT_EVENTS=${backend.report.eventsRead}');
    print('INPUT_EVENT_TYPES=${backend.report.eventTypes}');
    print('INPUT_EVENTS_DECODED=${events.map((e) => e.kind.name).toList()}');
    check(backend.report.eventsRead > 0, 'no input event arrived (pumped '
        '$pumped)');
    check(backend.threadIsStable, 'the isolate migrated OS threads');

    final failuresBeforeTeardown = failures;
    final stopped = backend.shutdownSync();
    print('TEARDOWN_STEPS=${backend.report.teardownSteps}');
    print('MISSING_SYMBOLS=${backend.report.missingSymbols}');
    check(stopped, 'shutdown was refused');
    check(backend.state == MacosBackendState.stopped, 'state is not stopped');
    check(backend.shutdownSync() == false, 'shutdown is not idempotent');
    print(failures == failuresBeforeTeardown ? 'TEARDOWN=PASS' : 'TEARDOWN=FAIL');
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
