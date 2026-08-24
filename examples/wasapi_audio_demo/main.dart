import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

import 'app.dart';
import 'synth_engine.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr.writeln('Este exemplo requer Windows 10 ou posterior.');
    exitCode = 2;
    return;
  }

  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();
  final SynthEngine engine = SynthEngine();
  try {
    await engine.start();
    await runApp(
      SynthesizerApp(engine: engine),
      options: ApplicationOptions.fromArguments(
        arguments,
        environment: Platform.environment,
        title: 'dart_ui Realtime Synth',
        size: const Size(1060, 640),
        minimumSize: const Size(720, 480),
        theme: ThemeData.neutralDark,
        clearColor: const Color(0xFF07111F),
      ),
    );
  } finally {
    await engine.stop();
    engine.dispose();
  }
}
