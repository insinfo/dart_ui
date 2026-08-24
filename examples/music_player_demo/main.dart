import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

import 'app.dart';
import 'music_player_engine.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr.writeln('Este exemplo requer Windows 10 ou posterior.');
    exitCode = 2;
    return;
  }
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();
  final MusicPlayerEngine engine = MusicPlayerEngine();
  final List<String> initialFiles = <String>[
    for (final String value in arguments)
      if (!value.startsWith('--') && File(value).existsSync())
        File(value).absolute.path,
  ];
  try {
    await runApp(
      MusicPlayerApp(engine: engine, initialPaths: initialFiles),
      options: ApplicationOptions.fromArguments(
        arguments,
        environment: Platform.environment,
        title: 'dart_ui Music Player',
        size: const Size(1180, 720),
        minimumSize: const Size(880, 600),
        theme: ThemeData.neutralDark,
        clearColor: const Color(0xFF07111F),
      ),
    );
  } finally {
    await engine.stop();
    engine.dispose();
  }
}
