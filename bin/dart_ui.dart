import 'dart:io';

import 'package:dart_ui/src/tooling/dart_ui_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await DartUiCli().run(arguments);
}
