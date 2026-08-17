/// The application shell: `runApp`, `Application`, `WindowHost`.
///
/// One import for a `main` that wants to mount a widget tree on a real window.
/// It is re-exported from `package:dart_ui/dart_ui.dart`, which is the import
/// an application should use:
///
/// ```dart
/// import 'package:dart_ui/dart_ui.dart';
/// ```
///
/// This barrel stays because the layer is a unit: `Application` is useless
/// without `WindowHost`, and a reader looking for "how does a frame reach a
/// window" should find both in one place.
library;

export 'application.dart';
export 'application_info.dart';
export 'window_host.dart';
