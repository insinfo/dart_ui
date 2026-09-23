/// Does a `NativeCallable.isolateGroupBound` callback that does nothing but
/// write a marker ever run on a foreign OS thread - and does that depend on
/// what the isolate that built it is doing?
///
/// Follow-up asked for in https://github.com/dart-lang/sdk/issues/64229. Uses
/// only public API that is still present after the unship in
/// https://github.com/dart-lang/sdk/issues/64285.
///
/// ```
/// dart run bin/group_bound_trivial_probe.dart --wait=blocking|async
/// ```
library;

import 'dart:ffi';

import 'package:dart_sdk_isolate_event_loop/group_bound.dart';
import 'package:dart_sdk_isolate_event_loop/native.dart';

void _body(Pointer<Void> argument) {
  final Pointer<Int32> slots = argument.cast<Int32>();
  slots[1] = kEntered;
  slots[1] = kTrivialDone;
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
  label: 'trivial',
  windows: () => NativeCallable<WinThreadStart>.isolateGroupBound(
    _windowsStart,
    exceptionalReturn: 1,
  ),
  posix: () => NativeCallable<PosixThreadStart>.isolateGroupBound(
    _posixStart,
    exceptionalReturn: 1,
  ),
);
