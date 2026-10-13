/// The vector editor's engine on the command line - no window.
///
/// ```
/// dart run bin/vector_cli.dart commands
/// dart run bin/vector_cli.dart run script.json --out drawing.svg
/// dart run bin/vector_cli.dart exec shape.rectangle '{"x":0,"y":0,"width":50,"height":20}' --inspect
/// ```
library;

import 'dart:io';

import 'package:vector_editor_demo/src/cli/vector_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runVectorCli(arguments);
}
