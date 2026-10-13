/// Starts the editor with `--control`, draws a picture through the control
/// channel alone - no mouse, no accessibility - and saves what it shows.
///
/// ```
/// dart run tool/control_probe.dart [out_dir]
/// ```
///
/// Prints one `CONTROL ok|FAIL` line per step and exits non-zero on a
/// failure.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final Directory out =
      Directory(args.isNotEmpty ? args.first : 'control_probe_out')
        ..createSync(recursive: true);
  final int port = 7900 + DateTime.now().millisecond % 90;
  final Process editor = await Process.start(
    Platform.resolvedExecutable,
    <String>['run', 'bin/vector_editor_demo.dart', '--control', '$port'],
  );
  final Completer<void> listening = Completer<void>();
  editor.stderr.transform(utf8.decoder).listen((String text) {
    if (text.contains('control channel on') && !listening.isCompleted) {
      listening.complete();
    }
  });
  unawaited(editor.stdout.drain<void>());
  final List<String> failures = <String>[];
  try {
    await listening.future.timeout(const Duration(seconds: 90));
    final Socket socket = await Socket.connect('127.0.0.1', port);
    final StreamIterator<String> replies = StreamIterator<String>(socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()));
    var id = 0;

    Future<Object?> call(String method,
        [Map<String, Object?> params = const <String, Object?>{}]) async {
      socket.writeln(jsonEncode(
          <String, Object?>{'id': ++id, 'method': method, 'params': params}));
      if (!await replies.moveNext()) throw StateError('connection closed');
      final Map<String, Object?> reply =
          jsonDecode(replies.current) as Map<String, Object?>;
      if (reply['ok'] != true) throw StateError('$method: ${reply['error']}');
      return reply['result'];
    }

    Future<void> step(String what, Future<bool> Function() run) async {
      bool ok;
      try {
        ok = await run();
      } on Object catch (error) {
        stderr.writeln('CONTROL      $what: $error');
        ok = false;
      }
      stderr.writeln('CONTROL ${ok ? 'ok  ' : 'FAIL'} $what');
      if (!ok) failures.add(what);
    }

    Future<Object?> execute(String command,
            [Map<String, Object?> params = const <String, Object?>{}]) =>
        call('engine.execute',
            <String, Object?>{'command': command, 'params': params});

    await step('the editor lists its commands', () async {
      final List<Object?> commands =
          await call('engine.commands') as List<Object?>;
      return commands.length > 60;
    });
    await step('a new drawing', () async {
      await execute('file.new');
      final Map<String, Object?> doc =
          await call('document.inspect') as Map<String, Object?>;
      return (doc['documents']! as List<Object?>).length == 2;
    });
    await step('a picture drawn in one undo step', () async {
      await call('engine.batch', <String, Object?>{
        'label': 'Picture',
        'steps': <Object?>[
          <String, Object?>{
            'command': 'shape.rectangle',
            'params': <String, Object?>{
              'x': 40, 'y': 40, 'width': 300, 'height': 180, //
            },
          },
          <String, Object?>{
            'command': 'object.fill',
            'params': <String, Object?>{'color': '#1565c0'},
          },
          <String, Object?>{
            'command': 'shape.ellipse',
            'params': <String, Object?>{
              'x': 380, 'y': 40, 'width': 180, 'height': 180, //
            },
          },
          <String, Object?>{
            'command': 'object.fill',
            'params': <String, Object?>{'color': '#ffb300'},
          },
          <String, Object?>{
            'command': 'shape.text',
            'params': <String, Object?>{
              'x': 40, 'y': 290, 'text': 'Drawn by an agent', 'size': 36, //
            },
          },
        ],
      });
      final Map<String, Object?> doc =
          await call('document.inspect') as Map<String, Object?>;
      final List<Object?> objects = ((doc['layers']! as List<Object?>).first!
          as Map<String, Object?>)['objects']! as List<Object?>;
      return objects.length == 3 && doc['undo'] == 'Picture';
    });
    await step('a typo is refused with a hint', () async {
      try {
        await execute('shape.rectangle',
            <String, Object?>{'x': 0, 'y': 0, 'widht': 1, 'height': 1});
        return false;
      } on StateError catch (error) {
        return '$error'.contains('did you mean `width`');
      }
    });
    await step('the menus are listed with their state', () async {
      final List<Object?> rows = await call('ui.menu.list') as List<Object?>;
      return rows.cast<Map<String, Object?>>().any((row) =>
          row['command'] == 'object.toCurves' && row['path'] is List);
    });
    await step('fit the page and take a screenshot', () async {
      await execute('view.zoomPage');
      final Map<String, Object?> shot = await call('ui.screenshot',
              <String, Object?>{'path': '${out.absolute.path}/editor.png'})
          as Map<String, Object?>;
      return (shot['width'] as num) > 0 &&
          File('${out.path}/editor.png').lengthSync() > 1000;
    });
    await step('save the drawing as SVG by path', () async {
      final Map<String, Object?> saved = await execute('file.save',
              <String, Object?>{'path': '${out.absolute.path}/drawing.svg'})
          as Map<String, Object?>;
      return File(saved['path'] as String)
          .readAsStringSync()
          .contains('Drawn by an agent');
    });
    await step('undo takes the whole picture back', () async {
      await execute('edit.undo');
      final Map<String, Object?> doc =
          await call('document.inspect') as Map<String, Object?>;
      return (((doc['layers']! as List<Object?>).first!
              as Map<String, Object?>)['objects']! as List<Object?>)
          .isEmpty;
    });
    await socket.close();
  } on Object catch (error) {
    stderr.writeln('CONTROL FAIL $error');
    failures.add('$error');
  } finally {
    editor.kill();
  }
  stderr.writeln('CONTROL done failures=${failures.length}');
  exit(failures.isEmpty ? 0 : 1);
}
