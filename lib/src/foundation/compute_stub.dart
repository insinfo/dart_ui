library;

import 'dart:async';

/// Signature accepted by [compute].
typedef ComputeCallback<M, R> = FutureOr<R> Function(M message);

/// Runs [callback] asynchronously on platforms without Dart isolates.
///
/// Browsers execute Dart on their current event loop. Keeping the same API
/// lets shared applications move CPU work to an isolate on native platforms
/// without maintaining a separate web code path.
Future<R> compute<M, R>(
  ComputeCallback<M, R> callback,
  M message, {
  String? debugLabel,
}) =>
    Future<R>.sync(() => callback(message));
