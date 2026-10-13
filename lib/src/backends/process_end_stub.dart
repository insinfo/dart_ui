/// Without `dart:io` there is no process to end: a browser tab outlives the
/// application inside it. See `process_end_io.dart`.
library;

import '../app/application.dart';

/// How long the process may outlive its last window before it is ended.
const Duration kProcessEndGrace = Duration(seconds: 1);

/// Does nothing here; see `process_end_io.dart`.
bool endProcessWithLastWindow(
  Application application, {
  Duration grace = kProcessEndGrace,
}) =>
    false;

/// Does nothing here; see `process_end_io.dart`.
void cancelProcessEnd() {}
