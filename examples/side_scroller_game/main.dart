/// Um jogo de plataforma lateral, em Dart puro, desenhado em 3D pela GPU —
/// a porta de entrada nativa.
///
/// Corra, pule, role, esmague os inimigos, pegue os anéis e chegue à bandeira.
///
/// ```powershell
/// dart run .\examples\side_scroller_game\main.dart
/// dart run .\examples\side_scroller_game\main.dart --frames=600 --demo --report
/// dart run .\examples\side_scroller_game\main.dart --script
/// ```
///
/// Setas ou A/D correm, espaço, W ou seta para cima pulam — segure para pular
/// mais alto. ESC pausa, R recomeça.
///
/// Para jogar no navegador, veja `web/main.dart` ao lado deste arquivo e a
/// receita no README.
///
/// ## What is left in this file, and why the rest moved
///
/// The game — the widget tree, the keyboard, the HUD, the drawing — is in
/// `game/shell.dart`, and it is pure Dart. What is here is the four things a
/// browser has none of: `arguments`, `Platform.environment`, `stdout` and
/// `stderr`, and the platform resolver that picks a windowing backend by
/// operating system. `game/shell.dart` explains why that became a second
/// entrypoint rather than a conditional import.
///
/// This file re-exports the shell, so an importer that reached the game through
/// `main.dart` — `test/examples/side_scroller_game/game_shell_test.dart` does —
/// still finds [SideScrollerGame] and [GameSession] here, unchanged.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

import 'game/actors.dart';
import 'game/autopilot.dart';
import 'game/level.dart';
import 'game/scene.dart';
import 'game/shell.dart';
import 'game/world.dart';

export 'game/shell.dart';

/// The value of `--name=value`, or of `--name value`.
String? _valueOf(List<String> arguments, String name) {
  for (var i = 0; i < arguments.length; i++) {
    final String argument = arguments[i];
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
    if (argument == name && i + 1 < arguments.length) return arguments[i + 1];
  }
  return null;
}

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--script')) {
    _runScript(int.tryParse(_valueOf(arguments, '--steps') ?? '') ?? 6000);
    return;
  }

  final int frameBudget =
      int.tryParse(_valueOf(arguments, '--frames') ?? '') ?? 0;

  FrameworkFonts.install();
  final GameSession session = GameSession(demo: arguments.contains('--demo'));
  final ApplicationOptions options = ApplicationOptions.fromArguments(
    arguments,
    environment: Platform.environment,
    title: 'dart_ui · Corrida do Lobo',
    size: const Size(1120, 700),
    minimumSize: const Size(760, 480),
    theme: ThemeData.neutralDark,
    clearColor: const Color(Palette.sky),
    frameBudget: frameBudget,
    // A game is the other shape of loop this framework supports: a frame is
    // produced because time passed, not because something asked. Without this
    // the window draws once and then sleeps in the message pump, and the
    // character stands still while the keyboard does nothing — which looks
    // exactly like the input being broken.
    frameLoop: const FrameLoopOptions.continuous(),
    onError: (FrameworkError failure) => stderr.writeln('$failure'),
  );

  final Application application = await Application.start(
    rootWidget: SideScrollerGame(session: session),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  session.application = application;

  try {
    await application.run();
  } finally {
    if (arguments.contains('--report')) {
      final SceneStats scene = session.sceneStats;
      stdout.writeln(
        'REPORT path=${session.drawPath} '
        'renderer=${session.rendererName} '
        'presenter=${session.presenterName} '
        'triangles=${session.triangles} '
        'dyn_vertices=${scene.dynamicVertices} '
        'dyn_triangles=${scene.dynamicTriangles} '
        'primitives=${scene.primitives} '
        'scene_build_us=${scene.buildMicroseconds} '
        'raster_us=${session.meshStats.microseconds} '
        'frame_ms=${session.frameMilliseconds.toStringAsFixed(2)} '
        'fps=${session.framesPerSecond.toStringAsFixed(1)} '
        'presented=${application.framesPresented} '
        'steps=${session.steps} dropped_ms=${session.droppedMilliseconds} '
        '| ${session.finalState}',
      );
    }
    application.dispose();
    await application.closed;
  }
}

/// Plays the whole level with no window at all and prints where it ended.
///
/// The regression this exists for is not "does it crash": it is "is the level
/// still completable". A change to gravity, to the jump's cut speed, to the
/// collision's epsilon or to the width of one gap can all leave a game that
/// runs perfectly and cannot be finished, and none of them is visible in a
/// screenshot. See `game/autopilot.dart`.
void _runScript(int maxSteps) {
  final Level level = buildDemoLevel();
  final GameWorld world = GameWorld(level: level);
  final Stopwatch watch = Stopwatch()..start();
  final int steps = runAutopilot(world, maxSteps: maxSteps);
  watch.stop();
  stdout
    ..writeln('level: ${level.name}')
    ..writeln('steps: $steps de $maxSteps '
        '(${(steps * world.stepSeconds).toStringAsFixed(2)} s simulados '
        'em ${watch.elapsedMilliseconds} ms)')
    ..writeln(world.describe());
  if (world.outcome != GameOutcome.finished) {
    stderr.writeln('o piloto automático não chegou ao fim');
    exitCode = 1;
  }
}
