/// What the Dart 3.13 isolate/event-loop API actually does when a plain Dart
/// program calls it.
///
/// The members are declared in `dart:isolate` and marked `@Since("3.13")`. This
/// probe calls every one of them from an ordinary `main` and prints what came
/// back, so the difference between "declared", "implemented" and "reachable
/// from Dart" is measured instead of inferred from the doc comments.
///
/// Excluded from the analyzer with the rest of `tool/sdk313/`: the package
/// declares `^3.6.0` and these members do not exist there.
///
/// ```
/// D:/referencias_libs_pdf/dartsdk-3.13.3/bin/dart.exe run tool/sdk313/api_surface_probe.dart
/// ```
library;

import 'dart:io';
import 'dart:isolate';

/// Runs [body] and reports what it did, without letting a throw end the probe.
void report(String name, void Function() body) {
  try {
    body();
    stdout.writeln('  $name : OK');
  } on Object catch (error) {
    stdout.writeln('  $name : ${error.runtimeType}: $error');
  }
}

void noop() {}

void main(List<String> args) {
  // Pinning is opt-in here because it is the suspect for the shutdown crash
  // this probe hit, and attributing a crash to the wrong call is worse than
  // not reporting it. `--no-pin` isolates the variable.
  final bool pin = !args.contains('--no-pin');
  stdout
    ..writeln('SDK reported by the running VM: ${Platform.version}')
    ..writeln('called from an ordinary main(), which always runs inside an '
        'isolate:');

  if (pin) {
    report('Isolate.pinToCurrentThread()', () {
      final bool pinned = Isolate.pinToCurrentThread();
      stdout.writeln('    returned $pinned');
    });
  } else {
    stdout.writeln('  Isolate.pinToCurrentThread() : skipped (--no-pin)');
  }

  report('Isolate.current.isPinnedToCurrentThread', () {
    stdout.writeln('    ${Isolate.current.isPinnedToCurrentThread}');
  });

  report('Isolate.create(...)', () {
    Isolate.create(debugName: 'probe');
  });

  report('Isolate.current.runSync(noop)', () {
    Isolate.current.runSync(noop);
  });

  report('Isolate.current.onEvent = ...', () {
    Isolate.current.onEvent = _notify;
  });

  report('Isolate.current.handleEvent()', () {
    Isolate.current.handleEvent();
  });

  // Not called: its contract is "returns once the isolate has no open
  // keep-alive receive ports", which for this program would be a hang rather
  // than a result. Named here so the omission is deliberate and visible.
  stdout.writeln('  Isolate.current.runEventLoopSync() : not called on '
      'purpose (would not return)');
}

/// Must be deeply immutable to be assigned to `onEvent`; a top-level function
/// reference is.
void _notify(Isolate isolate) {}
