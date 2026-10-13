/// The editor without a window: the same engine and commands, driven from a
/// command line.
///
/// An adapter, like the window: it parses arguments, builds the engine,
/// runs commands through the registry and prints JSON. It imports nothing of
/// the user interface (`test/layers_test.dart` checks), which is what makes
/// "the engine runs anywhere" a fact rather than an intention.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../engine/editor_commands.dart';
import '../engine/editor_files.dart';
import '../engine/editor_host.dart';
import '../engine/editor_inspect.dart';
import '../engine/editor_model.dart';

const String usage = '''
Usage: dart run bin/vector_cli.dart <command> [options]

  commands                      every command, as JSON
  run <script.json> [options]   run a script: a JSON list of
                                {"command": "...", "params": {...}}
  exec <command> [<params>]     run one command; params as a JSON object

Options:
  --open <drawing>   start from this SVG or CDR instead of an empty page
  --out <file>       write the result (svg, pdf or cdr, by extension)
  --inspect          print the document as JSON at the end
''';

/// A host with no dialogs: a command that would have to ask refuses, saying
/// which parameter to give instead.
final class _NoDialogHost implements EditorHost {
  @override
  Size get viewport => const Size(1000, 750);

  @override
  void pickAndOpen() => throw const CommandError(
      'no dialogs on the command line: give file.open a "path"');

  @override
  void pickAndSave(String format) => throw CommandError(
      'no dialogs on the command line: give a "path" to write the $format');

  @override
  void closeDocument(int index) => throw const CommandError(
      'the command line keeps its document; nothing to close');

  @override
  void quit() {}

  @override
  void findReplace() {}
}

/// Runs the command line with [arguments], writing to [out] and [err].
/// Returns the exit code: 0 on success, 1 when a command failed, 64 on a
/// usage error.
Future<int> runVectorCli(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
}) async {
  final StringSink stdoutSink = out ?? stdout;
  final StringSink stderrSink = err ?? stderr;
  if (arguments.isEmpty) {
    stderrSink.write(usage);
    return 64;
  }

  String? option(String name) {
    final int at = arguments.indexOf(name);
    return at >= 0 && at + 1 < arguments.length ? arguments[at + 1] : null;
  }

  FrameworkFonts.install();
  VectorTextMetrics.install();
  final EditorModel model = EditorModel(onChanged: () {});
  final CommandRegistry registry = CommandRegistry();
  registerEditorCommands(registry, model, _NoDialogHost());

  final String? open = option('--open');
  if (open != null) {
    final File file = File(open);
    if (!file.existsSync()) {
      stderrSink.writeln('no file at $open');
      return 64;
    }
    model.addDocument(DocumentSession(
      document: readDrawing(open, file.readAsBytesSync()),
      name: basenameOf(open),
      filePath: open,
    ));
  } else {
    model.newDocument();
  }

  const JsonEncoder json = JsonEncoder.withIndent('  ');
  final List<({String command, Map<String, Object?> params})> steps;
  switch (arguments.first) {
    case 'commands':
      stdoutSink.writeln(json.convert(registry.describe()));
      return 0;
    case 'run':
      if (arguments.length < 2) {
        stderrSink.write(usage);
        return 64;
      }
      final Object? script;
      try {
        script = jsonDecode(File(arguments[1]).readAsStringSync());
      } on Object catch (error) {
        stderrSink.writeln('could not read ${arguments[1]}: $error');
        return 64;
      }
      if (script is! List) {
        stderrSink.writeln('a script is a JSON list of {command, params}');
        return 64;
      }
      steps = <({String command, Map<String, Object?> params})>[
        for (final Object? step in script)
          if (step is Map && step['command'] is String)
            (
              command: step['command']! as String,
              params: step['params'] is Map
                  ? (step['params']! as Map).cast<String, Object?>()
                  : const <String, Object?>{},
            )
          else
            (command: '', params: const <String, Object?>{}),
      ];
    case 'exec':
      if (arguments.length < 2) {
        stderrSink.write(usage);
        return 64;
      }
      Map<String, Object?> params = const <String, Object?>{};
      if (arguments.length > 2 && !arguments[2].startsWith('--')) {
        final Object? decoded = jsonDecode(arguments[2]);
        if (decoded is! Map) {
          stderrSink.writeln('params are a JSON object');
          return 64;
        }
        params = decoded.cast<String, Object?>();
      }
      steps = <({String command, Map<String, Object?> params})>[
        (command: arguments[1], params: params),
      ];
    default:
      stderrSink.write(usage);
      return 64;
  }

  var failed = false;
  for (final step in steps) {
    final CommandOutcome outcome = registry.execute(step.command, step.params);
    stdoutSink.writeln(jsonEncode(<String, Object?>{
      'command': step.command,
      ...outcome.toJson(),
    }));
    if (!outcome.ok) {
      failed = true;
      break;
    }
  }

  final String? output = option('--out');
  if (!failed && output != null) {
    final CommandOutcome saved =
        registry.execute('file.export', <String, Object?>{'path': output});
    if (!saved.ok) {
      stderrSink.writeln('could not write $output: ${saved.error}');
      failed = true;
    }
  }
  if (arguments.contains('--inspect')) {
    stdoutSink.writeln(json.convert(inspectDocument(model)));
  }
  return failed ? 1 : 0;
}
