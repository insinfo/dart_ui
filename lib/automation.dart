/// Driving a running dart_ui application without a mouse: a local control
/// channel (JSON per line on a loopback port) over the application's
/// commands, menus and windows.
///
/// A separate library from `dart_ui.dart` because it needs `dart:io` sockets,
/// which a web build does not have.
library;

export 'src/automation/control_server.dart';
export 'src/automation/window_automation.dart';
