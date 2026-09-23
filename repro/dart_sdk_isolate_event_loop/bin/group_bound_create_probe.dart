/// `Isolate.create` from inside a `NativeCallable.isolateGroupBound` callback
/// on a foreign OS thread - the state its own guard asks for ("inside the
/// isolate group, outside any isolate").
///
/// This is the case that hung in the earlier Windows-only probe mentioned in
/// https://github.com/dart-lang/sdk/issues/64229. Compiles only on SDKs that
/// still expose `Isolate.create` publicly (3.13.x stable); on a dev SDK after
/// https://github.com/dart-lang/sdk/issues/64285 it fails to compile, and
/// `bin/run_all.dart` reports that as `API_REMOVED`.
///
/// ```
/// dart run bin/group_bound_create_probe.dart --wait=blocking|async [--shutdown]
/// ```
///
/// With `--shutdown` the callback also calls `shutdownSync()` on the isolate
/// it created before returning. Without it the created isolate is left alive,
/// which on 3.13.3 makes the VM wait for it forever at exit.
library;

import 'dart:ffi';
import 'dart:isolate';

import 'package:dart_sdk_isolate_event_loop/group_bound.dart';
import 'package:dart_sdk_isolate_event_loop/native.dart';

void _body(Pointer<Void> argument) {
  final Pointer<Int32> slots = argument.cast<Int32>();
  slots[1] = kEntered;
  try {
    final Isolate created = Isolate.create(
      debugName: 'created-from-group-bound',
    );
    slots[1] = kCreateOk;
    if (slots[0] == 1) {
      try {
        created.shutdownSync();
        slots[1] = kCreateShutdownOk;
      } on Object {
        slots[1] = kShutdownError;
      }
    }
  } on StateError {
    slots[1] = kCreateStateError;
  } on Object {
    slots[1] = kCreateOtherError;
  }
}

int _windowsStart(Pointer<Void> argument) {
  _body(argument);
  return 0;
}

int _posixStart(Pointer<Void> argument) {
  _body(argument);
  return 0;
}

Future<void> main(List<String> args) => runGroupBoundCase(
  args,
  label: 'Isolate.create',
  windows: () => NativeCallable<WinThreadStart>.isolateGroupBound(
    _windowsStart,
    exceptionalReturn: 1,
  ),
  posix: () => NativeCallable<PosixThreadStart>.isolateGroupBound(
    _posixStart,
    exceptionalReturn: 1,
  ),
);
