/// `FlutterErrorDetails`: what an `ErrorWidget.builder` is handed.
///
/// Only the data class. Flutter's `FlutterError.onError` reporting hub is not
/// here: dart_ui reports through the window's `ErrorReporter`
/// (`ApplicationOptions.onError` for the whole application), which already
/// carries the phase and the widget path a stack trace cannot.
library;

/// One error caught by the framework, as Flutter describes it.
final class FlutterErrorDetails {
  const FlutterErrorDetails({
    required this.exception,
    this.stack,
    this.library = 'Flutter framework',
    this.context,
    this.silent = false,
  });

  /// What was thrown.
  final Object exception;

  /// Where it was thrown, when known.
  final StackTrace? stack;

  /// Which part of the framework caught it: `'widgets library'` for a build.
  final String? library;

  /// What the framework was doing, such as `'building MyWidget'`.
  final Object? context;

  /// Whether the error is expected and should not be logged loudly.
  final bool silent;

  /// The exception as one line of text, the way Flutter's console shows it.
  String exceptionAsString() {
    final Object error = exception;
    if (error is Error || error is Exception) {
      final String text = error.toString();
      return text.isEmpty ? error.runtimeType.toString() : text;
    }
    return error.toString();
  }

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer()
      ..write('Exception caught by ${library ?? 'an unknown library'}');
    if (context != null) buffer.write(' while $context');
    buffer.write(': ${exceptionAsString()}');
    return buffer.toString();
  }
}
