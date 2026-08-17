library;

import 'dart:async';
import 'dart:isolate';

/// Signature accepted by [compute].
typedef ComputeCallback<M, R> = FutureOr<R> Function(M message);

/// Runs [callback] with [message] in a short-lived background isolate.
///
/// The callback, message and result must be sendable between isolates. Prefer
/// a top-level or static callback so it cannot accidentally capture UI state.
/// Errors and stack traces are forwarded to the returned future.
Future<R> compute<M, R>(
  ComputeCallback<M, R> callback,
  M message, {
  String? debugLabel,
}) =>
    Isolate.run<R>(
      () => callback(message),
      debugName: debugLabel,
    );
