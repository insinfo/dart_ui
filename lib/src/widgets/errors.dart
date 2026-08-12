/// Framework errors that name the tree location they came from.
///
/// A stack trace tells you which method threw. In a UI framework that is
/// rarely the useful question - `performLayout` threw, but *whose*? Section
/// 37.5 asks for crash diagnostics that survive contact with a real bug
/// report, which means the error has to carry the widget path, the phase it
/// happened in, and whatever the framework knew at the time.
///
/// The second job here is containment. One widget whose `build` throws must
/// not take the window down: the frame is finished with an error placeholder
/// where that subtree should have been, the error is recorded, and the rest of
/// the application keeps running. A framework that lets one bad build kill the
/// process makes the *other* ninety-nine widgets untestable.
library;

/// Which pipeline phase an error escaped from.
enum FrameworkPhase { build, layout, paint, hitTest, input, semantics }

/// One error, with the context needed to find it again.
final class FrameworkError implements Exception {
  FrameworkError({
    required this.phase,
    required this.cause,
    this.stackTrace,
    this.widgetPath = const <String>[],
    this.context,
  });

  final FrameworkPhase phase;

  /// What was actually thrown.
  final Object cause;

  final StackTrace? stackTrace;

  /// The chain of widget types from the root down to the failure, which is the
  /// piece a stack trace cannot supply.
  final List<String> widgetPath;

  /// A one-line description of what the framework was doing.
  final String? context;

  /// The failing location, deepest first, as a single line.
  String get location =>
      widgetPath.isEmpty ? '<detached>' : widgetPath.reversed.join(' < ');

  /// A report suitable for a log or a bug tracker.
  String describe() {
    final StringBuffer buffer = StringBuffer()
      ..writeln('dart_ui error during ${phase.name}')
      ..writeln('  cause: $cause');
    if (context != null) buffer.writeln('  while: $context');
    buffer.writeln('  at:    $location');
    final StackTrace? trace = stackTrace;
    if (trace != null) {
      final List<String> lines = trace.toString().split('\n');
      // The first frames are the framework's own rethrow path and say nothing
      // about the bug; a handful of user frames is what gets read.
      for (final String line in lines.take(8)) {
        if (line.trim().isEmpty) continue;
        buffer.writeln('         $line');
      }
    }
    return buffer.toString();
  }

  @override
  String toString() => 'FrameworkError(${phase.name}: $cause at $location)';
}

/// Where framework errors go.
///
/// A single sink rather than exceptions propagating to the frame loop: the
/// loop has no way to attribute an exception to a widget, and by the time it
/// arrives the tree has already been half-updated.
final class ErrorReporter {
  ErrorReporter({
    this.onError,
    this.rethrowErrors = false,
    this.capacity = 64,
  });

  /// Called for every error, in addition to being recorded. A shell sends this
  /// to a log or a crash reporter.
  final void Function(FrameworkError error)? onError;

  /// Whether [guard] rethrows after reporting.
  ///
  /// True in the default reporter, and that default is deliberate: containment
  /// is something an application *opts into* by installing a reporter that
  /// draws a placeholder. Making it the default would mean an unattended
  /// framework silently discards exceptions, and a test suite that passes
  /// while every build throws is worse than no test suite.
  final bool rethrowErrors;

  /// How many errors are retained. A bounded list, because a diagnostic that
  /// grows without limit fails exactly in the long sessions it exists for.
  final int capacity;

  final List<FrameworkError> _errors = <FrameworkError>[];

  List<FrameworkError> get errors => List<FrameworkError>.unmodifiable(_errors);

  bool get hasErrors => _errors.isNotEmpty;

  void report(FrameworkError error) {
    if (_errors.length >= capacity) _errors.removeAt(0);
    _errors.add(error);
    onError?.call(error);
  }

  /// Runs [action], attributing anything it throws to a tree location.
  ///
  /// Returns whether it completed. A reporter with [rethrowErrors] set still
  /// rethrows - the value of passing through here is the [FrameworkError],
  /// which names the widget path a bare stack trace cannot.
  bool guard(
    FrameworkPhase phase,
    void Function() action, {
    List<String> widgetPath = const <String>[],
    String? context,
  }) {
    try {
      action();
      return true;
    } catch (error, stack) {
      report(FrameworkError(
        phase: phase,
        cause: error,
        stackTrace: stack,
        widgetPath: widgetPath,
        context: context,
      ));
      if (rethrowErrors) rethrow;
      return false;
    }
  }

  void clear() => _errors.clear();
}

/// The default reporter, used when no owner supplies one.
///
/// Records *and* rethrows: it makes errors attributable without making them
/// disappear. An application shell replaces it with a containing reporter once
/// it has somewhere to draw a placeholder and somewhere to send the report.
final ErrorReporter defaultErrorReporter = ErrorReporter(rethrowErrors: true);
