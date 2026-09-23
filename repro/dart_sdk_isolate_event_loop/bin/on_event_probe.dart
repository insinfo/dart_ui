/// What `Isolate.onEvent` and `Isolate.handleEvent` do today when called from
/// an ordinary `main`, and whether `Isolate.create` is reachable from one.
///
/// Context for https://github.com/dart-lang/sdk/issues/64229. Does not call
/// `Isolate.pinToCurrentThread`, whose shutdown abort is a separate issue
/// (https://github.com/dart-lang/sdk/issues/64231).
///
/// ```
/// dart run bin/on_event_probe.dart
/// ```
library;

import 'dart:io';
import 'dart:isolate';

/// Runs [body] and returns the error type it threw, or `null`.
String? report(String name, void Function() body) {
  try {
    body();
    stdout.writeln('  $name : OK');
    return null;
  } on Object catch (error) {
    stdout.writeln('  $name : ${error.runtimeType}: $error');
    return '${error.runtimeType}';
  }
}

void main() {
  stdout
    ..writeln('SDK: ${Platform.version}')
    ..writeln('called from an ordinary main():');
  final String? onEvent = report('Isolate.current.onEvent = ...', () {
    Isolate.current.onEvent = (Isolate _) {};
  });
  final String? handleEvent = report('Isolate.current.handleEvent()', () {
    Isolate.current.handleEvent();
  });
  report('Isolate.create(...)', () {
    Isolate.create(debugName: 'probe');
  });
  stdout.writeln(
    onEvent == 'UnsupportedError' && handleEvent == 'UnsupportedError'
        ? 'RESULT=UNIMPLEMENTED onEvent and handleEvent throw UnsupportedError'
        : 'RESULT=CHANGED onEvent: ${onEvent ?? 'OK'}, '
              'handleEvent: ${handleEvent ?? 'OK'}',
  );
}
