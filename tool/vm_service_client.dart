/// A JSON-RPC client for the Dart VM Service over `dart:io`'s WebSocket.
///
/// Lifted out of `tool/frame_timeline_trace.dart`, which wrote it first and
/// paid for the two discoveries below, when `tool/leak_suite/` needed the same
/// transport for `getAllocationProfile`. A second copy would have been a second
/// place for those discoveries to be forgotten.
///
/// ## Why not `package:vm_service`
///
/// This repository's pubspec has no runtime dependency beyond `meta` and that
/// is a rule, not an accident. `dart:io` is enough.
///
/// ## The transport, checked rather than assumed
///
/// The VM Service speaks JSON-RPC over two transports, and on Dart 3.6.2 they
/// are **not** equivalent:
///
///   * the **HTTP** endpoint answers `GET /<method>?param=value` and works for
///     every parameterless RPC - `getVersion`, `getVM`, `getVMTimeline`,
///     `clearVMTimeline` all return proper JSON-RPC envelopes. `POST /` with a
///     JSON-RPC body is **405 method not allowed**, so the usual "post the
///     envelope" recipe does not apply here;
///   * but `setVMTimelineFlags` takes `recordedStreams` as a **JSON array**,
///     and a query string cannot carry one. A repeated `?recordedStreams=Dart
///     &recordedStreams=GC` arrives as the single string `GC` and is rejected
///     as an invalid parameter; a JSON-encoded string is rejected too. There is
///     no HTTP spelling of that call.
///
/// So the WebSocket at `ws://host:port/ws` is the only transport that can do
/// everything, and it is the one used here for all of it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One connection to a running VM Service.
final class VmServiceClient {
  VmServiceClient._(this._socket) {
    _socket.listen(
      (Object? message) {
        final Map<String, Object?> reply =
            jsonDecode(message! as String) as Map<String, Object?>;
        final Completer<Map<String, Object?>?>? pending =
            _pending.remove(reply['id']);
        if (pending == null) return;
        final Object? error = reply['error'];
        if (error != null) {
          pending.completeError(StateError('VM Service error: $error'));
          return;
        }
        pending.complete(reply['result'] as Map<String, Object?>?);
      },
      onDone: _failPending,
      onError: (Object _) => _failPending(),
    );
  }

  /// Connects to the service at [serviceUri], which is the `http://` URI the
  /// VM prints on start-up.
  static Future<VmServiceClient> connect(Uri serviceUri) async {
    // `http://127.0.0.1:1234/` and `http://127.0.0.1:1234/AbC=/` both become
    // the same URI with `ws` and a `ws` segment appended - the auth-code form
    // keeps its code, which is what makes attaching to a VM the user started
    // without `--disable-service-auth-codes` work.
    final List<String> segments = <String>[
      ...serviceUri.pathSegments.where((String s) => s.isNotEmpty),
      'ws',
    ];
    final Uri wsUri = serviceUri.replace(
      scheme: serviceUri.scheme == 'https' ? 'wss' : 'ws',
      pathSegments: segments,
    );
    return VmServiceClient._(await WebSocket.connect(wsUri.toString()));
  }

  final WebSocket _socket;
  final Map<int, Completer<Map<String, Object?>?>> _pending =
      <int, Completer<Map<String, Object?>?>>{};
  int _nextId = 0;

  /// Calls [method] and completes with its `result` object.
  Future<Map<String, Object?>?> call(
    String method, [
    Map<String, Object?>? params,
  ]) {
    final int id = ++_nextId;
    final Completer<Map<String, Object?>?> completer =
        Completer<Map<String, Object?>?>();
    _pending[id] = completer;
    _socket.add(jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    return completer.future;
  }

  /// The id of the main isolate, which every heap RPC needs and which is not
  /// knowable in advance - it is a string such as `isolates/12345`, minted per
  /// run.
  Future<String> mainIsolateId() async {
    final Map<String, Object?> vm = await call('getVM') ?? const {};
    final List<Object?> isolates =
        (vm['isolates'] as List<Object?>?) ?? const <Object?>[];
    if (isolates.isEmpty) {
      throw StateError('the VM reports no isolates');
    }
    // The first is the main one; a program that spawned helpers would list
    // them after it, and measuring a helper's heap for the main isolate's
    // leak would be a silent wrong answer.
    return (isolates.first as Map<String, Object?>)['id']! as String;
  }

  void _failPending() {
    for (final Completer<Map<String, Object?>?> pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('the VM Service connection closed'));
      }
    }
    _pending.clear();
  }

  Future<void> close() => _socket.close();
}
