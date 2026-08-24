import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

import 'app.dart';
import 'drum_engine.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr.writeln('Este exemplo requer Windows 10 ou posterior.');
    exitCode = 2;
    return;
  }

  final String sampleDirectory = _sampleDirectory();
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();
  final DrumEngine engine = DrumEngine(sampleDirectory: sampleDirectory);
  try {
    await engine.start();
    await runApp(
      DrumerApp(engine: engine),
      options: ApplicationOptions.fromArguments(
        arguments,
        environment: Platform.environment,
        title: 'dart_ui Realtime Drumer',
        size: const Size(1120, 760),
        minimumSize: const Size(760, 600),
        theme: ThemeData.neutralDark,
        clearColor: const Color(0xFF07111F),
      ),
    );
  } finally {
    await engine.stop();
    engine.dispose();
  }
}

String _sampleDirectory() {
  final Directory besideScript = Directory(
      '${File.fromUri(Platform.script).parent.path}${Platform.pathSeparator}drum_sounds');
  if (besideScript.existsSync()) return besideScript.absolute.path;
  final Directory fromWorkspace = Directory(
      'examples${Platform.pathSeparator}drumer${Platform.pathSeparator}drum_sounds');
  if (fromWorkspace.existsSync()) return fromWorkspace.absolute.path;
  throw StateError('Diretório drum_sounds não encontrado ao lado do exemplo.');
}
