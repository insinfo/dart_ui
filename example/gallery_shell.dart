/// The part of a gallery `main` that is the same on every platform.
///
/// Everything here is argument parsing and report printing. It exists so the
/// four gallery examples differ *only* in the backend and the presentation
/// path they hand to `runApp` - which is the claim the Fase 6 gate actually
/// makes, and one that is hard to believe when each example carries its own
/// hundred lines of scaffolding.
///
/// Read `gallery_headless.dart` first; it is the one that needs no display
/// system and therefore runs anywhere, including in CI.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

/// The theme named on the command line, defaulting to the light one.
ThemeData galleryTheme(List<String> arguments) => arguments.contains('--dark')
    ? ThemeData.neutralDark
    : arguments.contains('--high-contrast')
        ? ThemeData.highContrastDark
        : ThemeData.neutralLight;

/// Options shared by every gallery example.
///
/// The frame budget is the load-bearing one. An example that only ever blocks
/// forever cannot be part of a gate, so `--frames 20` opens a real window,
/// presents twenty real frames, reports, and exits with a status CI can read.
ApplicationOptions galleryOptions(
  List<String> arguments, {
  required String title,
  int? frameBudget,
}) =>
    ApplicationOptions(
      title: title,
      size: galleryDesignSize,
      frameBudget: frameBudget ?? intArgument(arguments, '--frames') ?? 0,
      showDevOverlay: !arguments.contains('--no-overlay'),
      suspendWhenDeactivated: false,
      arguments: arguments,
      environment: Platform.environment,
      // Contained rather than fatal: one control whose build throws must not
      // take the window with it, and the error still reaches stderr.
      onError: (FrameworkError error) => stderr.writeln(error.describe()),
      onDiagnostic: (BackendDiagnostic diagnostic) =>
          stderr.writeln('present: $diagnostic'),
    );

int? intArgument(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return int.tryParse(arguments[index + 1]);
}

/// Prints the startup report and the gate summary; returns a process exit
/// code.
///
/// The counts come from the [Application] *after* teardown, which is possible
/// only because it snapshots them while the tree is still alive. That is not a
/// convenience: a summary printed before teardown would be a summary of an
/// application that had not finished, and the number the gate cares about -
/// "did every frame present?" - is only final once the loop has stopped.
int reportGallery(Application app, {required String tag}) {
  stdout.write(app.describeStartup());
  final budget = app.options.frameBudget;
  final passed = budget == 0 || app.framesPresented >= budget;
  stdout
    ..writeln('$tag=${passed ? 'PASS' : 'FAIL'}')
    ..writeln('frames=${app.framesPresented} '
        'rejected=${app.framesRejected} '
        'median=${app.statistics.percentileTotal(50)}us '
        'p99=${app.statistics.percentileTotal(99)}us')
    ..writeln('controls=${app.controlCount} '
        'semantics=${app.semanticNodeCount} '
        'errors=${app.errors.length}');
  return passed ? 0 : 1;
}

/// Prints a backend failure the way section 6.6 requires: every attempt, with
/// the library, symbol or device that was missing for each.
int reportUnavailable(Object error, {required String what}) {
  stderr
    ..writeln('$what is not available on this machine.')
    ..writeln(error.toString())
    ..writeln('The same gallery runs headless everywhere: '
        'dart run example/gallery_headless.dart --frames 4');
  return 2;
}
