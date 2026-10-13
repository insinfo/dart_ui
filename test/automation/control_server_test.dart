import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ui/automation.dart';
import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

final class _Echo implements AutomationHost {
  @override
  Iterable<String> get methods => const <String>['echo', 'fail', 'boom'];

  @override
  FutureOr<Object?> handle(String method, Map<String, Object?> params) =>
      switch (method) {
        'echo' => params,
        'fail' => throw const CommandError('refused'),
        'boom' => throw StateError('bug'),
        _ => throw CommandError('unknown `$method`'),
      };
}

/// One connection, read line by line.
final class _Client {
  _Client(this.socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_lines.add, onDone: () => done = true);
  }

  final Socket socket;
  final StreamController<String> _lines = StreamController<String>();
  late final StreamIterator<String> _reader = StreamIterator(_lines.stream);
  bool done = false;

  Future<Map<String, Object?>> send(String line) async {
    socket.write('$line\n');
    await socket.flush();
    if (!await _reader.moveNext()) throw StateError('closed');
    return jsonDecode(_reader.current) as Map<String, Object?>;
  }
}

void main() {
  late ControlServer server;
  late _Client client;

  setUp(() async {
    server = await ControlServer.start(port: 0, host: _Echo());
    client = _Client(await Socket.connect('127.0.0.1', server.port));
  });

  tearDown(() async {
    client.socket.destroy();
    await server.close();
  });

  test('a request is answered with its id and result', () async {
    expect(
      await client.send('{"id": 3, "method": "echo", "params": {"a": 1}}'),
      <String, Object?>{
        'id': 3,
        'ok': true,
        'result': <String, Object?>{'a': 1},
      },
    );
    expect((await client.send('{"method": "app.methods"}'))['result'],
        <String>['echo', 'fail', 'boom']);
  });

  test('a refusal is an error reply and the connection stays open', () async {
    expect(await client.send('{"id": 1, "method": "fail"}'),
        <String, Object?>{'id': 1, 'ok': false, 'error': 'refused'});
    final boom = await client.send('{"id": 2, "method": "boom"}');
    expect(boom['ok'], isFalse);
    expect(boom['error'], contains('internal error'));
    expect((await client.send('{"id": 3, "method": "echo"}'))['ok'], isTrue);
  });

  test('a line that is not a request closes the connection', () async {
    final reply = await client.send('GET / HTTP/1.1');
    expect(reply['ok'], isFalse);
    expect(reply['error'], contains('closing'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(client.done, isTrue);
  });
}
