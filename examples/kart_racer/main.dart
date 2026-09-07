library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/graphics/mesh/mesh_loaders.dart';
import 'package:dart_ui/src/platform/model_asset_resolver.dart';

import 'game/race.dart';
import 'game/shell.dart';

export 'game/shell.dart';

String? _valueOf(List<String> arguments, String name) {
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
    if (argument == name && i + 1 < arguments.length) return arguments[i + 1];
  }
  return null;
}

bool _hasFlag(List<String> arguments, String name) =>
    arguments.contains(name) ||
    arguments.any((argument) => argument.startsWith('$name='));

Future<void> main(List<String> arguments) async {
  final laps = int.tryParse(_valueOf(arguments, '--laps') ?? '') ?? 3;
  final opponents = int.tryParse(_valueOf(arguments, '--opponents') ?? '') ?? 2;
  final replay = _hasFlag(arguments, '--replay') ||
      (_hasFlag(arguments, '--headless') && _hasFlag(arguments, '--frames'));
  if (replay) {
    final frames = int.tryParse(_valueOf(arguments, '--replay') ?? '') ??
        int.tryParse(_valueOf(arguments, '--frames') ?? '') ??
        6000;
    for (final autopilot in <bool>[false, true]) {
      final race = runScriptedRace(
        frames: frames,
        opponents: opponents,
        totalLaps: laps,
        autopilot: autopilot,
      );
      stdout
          .writeln('RESULT ${autopilot ? 'auto  ' : 'script'} ${race.summary}');
      for (final racer in race.racers) {
        stdout.writeln('  ${racer.position}. ${racer.name} '
            'lap=${math.max(1, racer.counter.lap)} '
            'progress=${racer.counter.progress.toStringAsFixed(1)} '
            'best=${racer.counter.bestLap?.toStringAsFixed(3) ?? '-'}'
            '${racer.finishTime == null ? '' : ' finished=${racer.finishTime!.toStringAsFixed(3)}'}');
      }
    }
    return;
  }

  Mesh3D? prop;
  final propPath = _valueOf(arguments, '--prop');
  if (propPath != null) {
    final file = File(propPath);
    if (!file.existsSync()) {
      stderr.writeln('não encontrei $propPath');
    } else {
      try {
        prop = loadMesh(
          Uint8List.fromList(file.readAsBytesSync()),
          name: file.uri.pathSegments.last,
          resolveBuffer: ModelAssetResolver(file).call,
        );
      } on MeshParseException catch (failure) {
        stderr.writeln('modelo recusado: ${failure.message}');
      }
    }
  }

  FrameworkFonts.install();
  forceKartCpuRendering(arguments.contains('--cpu-mesh'));
  final session = GameSession();
  final options = ApplicationOptions.fromArguments(
    arguments,
    environment: Platform.environment,
    title: 'dart_ui Kart Racer',
    size: const Size(1120, 760),
    minimumSize: const Size(720, 480),
    theme: ThemeData.neutralDark,
    clearColor: const Color(0xFF6FA8D8),
    frameBudget: int.tryParse(_valueOf(arguments, '--frames') ?? '') ?? 0,
    frameLoop: _hasFlag(arguments, '--uncapped')
        ? const FrameLoopOptions.continuous(
            presentMode: PresentMode.immediate,
            frameInterval: Duration(microseconds: 1000),
          )
        : const FrameLoopOptions.continuous(),
    onError: (failure) => stderr.writeln('$failure'),
  );
  final application = await Application.start(
    rootWidget: KartRacer(
      session: session,
      laps: laps,
      opponents: opponents,
      prop: prop,
    ),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  session.application = application;
  try {
    await application.run();
  } finally {
    if (arguments.contains('--report')) {
      stdout.writeln('REPORT draw=${session.drawPath} '
          'renderer=${session.rendererName} triangles=${session.stats.triangles} '
          'fps=${session.framesPerSecond.toStringAsFixed(1)} '
          'presented=${application.framesPresented} ${session.race?.summary ?? ''}');
    }
    application.dispose();
    await application.closed;
  }
}
