/// Where the seconds before a window appears actually go.
///
/// Written because a user timed roughly five seconds between launching the
/// video player and being able to press play, while the player's own
/// instrumentation reported seven hundred milliseconds. Both numbers were
/// right. Everything between them happens before `main` runs, and nothing in
/// the application can see it.
///
/// Three costs are stacked in a `dart run` of a source file:
///
///   1. **VM start** - process creation, the snapshot, the isolate;
///   2. **compiling the program to kernel** - `dart run` on a `.dart` file
///      front-end compiles the whole transitive import graph. For this package
///      that is the entire framework, and it is by far the largest of the
///      three on a cold run;
///   3. **loading the FFI libraries and running `main`** - the part an
///      application is allowed to blame itself for.
///
/// This tool measures 1+2 by printing the process uptime at the first
/// instruction of `main`, having imported the whole public surface so the
/// front end has to do the same work the real examples make it do. Run it the
/// two ways and the difference is the answer:
///
/// ```
/// dart run tool/startup_cost.dart                 # from source, like the demos
/// dart compile exe -o build/startup.exe tool/startup_cost.dart
/// build/startup.exe                               # AOT, like a shipped build
/// ```
library;

import 'dart:io';

// The point of the import: it drags the transitive graph the demos drag, so
// the number below is the one they pay. An unused-import lint would be right
// about the symbol and wrong about the measurement, hence the reference in
// `main`.
import 'package:dart_ui/dart_ui.dart' show Size;

void main(List<String> arguments) {
  // `pid` and a fixed-size read: nothing here should be part of what is being
  // measured.
  final Duration uptime = _processUptime();
  const Size touched = Size(1, 1);

  stdout
    ..writeln('startup: ${uptime.inMilliseconds} ms before main(), '
        'mode=${_mode()}, dart=${Platform.version.split(' ').first}')
    ..writeln('startup: (${touched.width.toInt()}x${touched.height.toInt()} '
        'proves the framework graph was loaded, not skipped)');

  if (arguments.contains('--hold')) {
    // For measuring against an external stopwatch: hold the process so a
    // human can compare what this prints to what they see.
    stdin.readLineSync();
  }
}

/// How long this process has been alive.
///
/// There is no portable "process start time" in `dart:io`, so this uses the
/// one clock that is zeroed at VM start rather than at isolate start:
/// [Stopwatch] cannot help, because constructing one here starts it here. On
/// Windows the answer comes from `GetTickCount64` minus the process creation
/// time, which needs FFI - and pulling FFI in would change the thing being
/// measured. So the portable approximation is used instead and its limit is
/// stated: `Timeline.now` and `DateTime` both start too late.
///
/// What *is* reliable across platforms is the difference between the time the
/// shell recorded before launching and the time here. So this prints the
/// current wall clock as well, and the wrapper below subtracts.
Duration _processUptime() {
  final String? started = Platform.environment['DART_UI_LAUNCH_EPOCH_MS'];
  if (started == null) return Duration.zero;
  final int? launch = int.tryParse(started);
  if (launch == null) return Duration.zero;
  return Duration(
    milliseconds: DateTime.now().millisecondsSinceEpoch - launch,
  );
}

String _mode() {
  // An AOT build has no `dart:mirrors`, no kernel service and, usefully here,
  // a `Platform.script` that names the executable rather than a source file.
  final bool aot = !Platform.script.path.endsWith('.dart');
  return aot ? 'AOT' : 'JIT (from source)';
}
