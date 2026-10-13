/// A local control channel: JSON requests, one per line, on a loopback port.
///
/// What lets an agent, a script or a test drive a running application
/// without a mouse - and without accessibility permissions, screen readers
/// or pixel coordinates guessed from a screenshot. The application decides
/// what it answers through an [AutomationHost]; `WindowAutomation` is the
/// standard one, over a command registry and a window.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../commands/command.dart';

/// What a [ControlServer] asks for each request.
abstract interface class AutomationHost {
  /// The methods [handle] answers, for `app.methods`.
  Iterable<String> get methods;

  /// Answers [method] with a JSON-serialisable result. Throws
  /// [CommandError] for an error reply; any other exception is reported as
  /// an internal error, never as a crash.
  FutureOr<Object?> handle(String method, Map<String, Object?> params);
}

/// Serves an [AutomationHost] on `127.0.0.1:port`.
///
/// One JSON object per line: `{"id": 1, "method": "...", "params": {...}}`,
/// answered `{"id": 1, "ok": true, "result": ...}` or
/// `{"id": 1, "ok": false, "error": "..."}`. Requests on one connection are
/// answered in order.
///
/// **Only requests are read.** A line that is not a JSON object with a
/// string `method`, or is longer than [maxLineBytes], gets one error reply
/// and the connection is closed: a browser's cross-origin request to the
/// port cannot smuggle a command in its body, because its request line is
/// refused first. Loopback only, and no authentication - enable it only
/// while it is used.
final class ControlServer {
  ControlServer._(
      this._server, this._host, this.maxLineBytes, this.maxConnections);

  static Future<ControlServer> start({
    required int port,
    required AutomationHost host,
    int maxLineBytes = 4 << 20,
    int maxConnections = 16,
  }) async {
    if (port < 0 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'not a TCP port');
    }
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    final ControlServer control =
        ControlServer._(server, host, maxLineBytes, maxConnections);
    server.listen(control._accept);
    return control;
  }

  final ServerSocket _server;
  final AutomationHost _host;
  final int maxLineBytes;
  final int maxConnections;
  final Set<Socket> _clients = <Socket>{};

  /// The port actually bound - the one asked for, or the system's pick for 0.
  int get port => _server.port;

  void _accept(Socket socket) {
    if (_clients.length >= maxConnections) {
      socket.write('${jsonEncode(<String, Object?>{
            'ok': false,
            'error': 'too many connections ($maxConnections); closing',
          })}\n');
      unawaited(socket.close());
      return;
    }
    _clients.add(socket);
    final List<int> pending = <int>[];
    Future<void> queue = Future<void>.value();
    var closed = false;

    void closeWith(String error, Object? id) {
      if (closed) return;
      closed = true;
      socket.write('${jsonEncode(<String, Object?>{
            if (id != null) 'id': id,
            'ok': false,
            'error': '$error; closing the connection',
          })}\n');
      unawaited(socket.close());
    }

    socket.listen(
      (List<int> bytes) {
        if (closed) return;
        for (final int byte in bytes) {
          if (byte != 0x0A) {
            pending.add(byte);
            if (pending.length > maxLineBytes) {
              closeWith('line longer than $maxLineBytes bytes', null);
              return;
            }
            continue;
          }
          final List<int> line = List<int>.of(pending);
          pending.clear();
          queue = queue.then((_) async {
            if (closed) return;
            final String? reply = await _answer(line, closeWith);
            if (reply != null && !closed) socket.write('$reply\n');
          });
        }
      },
      onDone: () {
        closed = true;
        _clients.remove(socket);
      },
      onError: (Object _) {
        closed = true;
        _clients.remove(socket);
      },
      cancelOnError: true,
    );
  }

  /// The reply to one request line, or null when the line was blank or the
  /// connection is being closed.
  Future<String?> _answer(
    List<int> bytes,
    void Function(String error, Object? id) closeWith,
  ) async {
    final String text;
    try {
      text = utf8.decode(bytes).trim();
    } on FormatException {
      closeWith('the request is not UTF-8', null);
      return null;
    }
    if (text.isEmpty) return null;
    final Object? request;
    try {
      request = jsonDecode(text);
    } on FormatException {
      closeWith('the request is not JSON', null);
      return null;
    }
    if (request is! Map<String, Object?> || request['method'] is! String) {
      closeWith('a request is an object with a string "method"', null);
      return null;
    }
    final Object? id = request['id'];
    final Object? params = request['params'];
    if (params != null && params is! Map<String, Object?>) {
      return jsonEncode(<String, Object?>{
        if (id != null) 'id': id,
        'ok': false,
        'error': '"params" must be an object',
      });
    }
    final String method = request['method']! as String;
    try {
      final Object? result = method == 'app.methods'
          ? _host.methods.toList()
          : await _host.handle(
              method, (params as Map<String, Object?>?) ?? <String, Object?>{});
      return jsonEncode(<String, Object?>{
        if (id != null) 'id': id,
        'ok': true,
        'result': result,
      });
    } on CommandError catch (error) {
      return jsonEncode(<String, Object?>{
        if (id != null) 'id': id,
        'ok': false,
        'error': error.message,
      });
    } on Object catch (error) {
      return jsonEncode(<String, Object?>{
        if (id != null) 'id': id,
        'ok': false,
        'error': 'internal error in $method: $error',
      });
    }
  }

  Future<void> close() async {
    for (final Socket client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
    await _server.close();
  }
}
