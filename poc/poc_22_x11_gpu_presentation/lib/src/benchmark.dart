library;

import 'dart:convert';
import 'dart:io';

import 'egl_presenter.dart';
import 'presenter.dart';
import 'vulkan_presenter.dart';
import 'xcb_presenters.dart';

enum PresentationBackend { putImage, mitShm, eglOpenGl, vulkan }

final class PresentationConfiguration {
  const PresentationConfiguration({
    this.width = 640,
    this.height = 360,
    this.frames = 600,
    this.warmupFrames = 60,
  });

  const PresentationConfiguration.quick()
      : width = 640,
        height = 360,
        frames = 120,
        warmupFrames = 15;

  final int width;
  final int height;
  final int frames;
  final int warmupFrames;

  int get frameBytes => width * height * 4;
}

final class PresentationMeasurement {
  const PresentationMeasurement({
    required this.backend,
    required this.device,
    required this.mode,
    required this.setupMicroseconds,
    required this.elapsedMicroseconds,
    required this.configuration,
  });

  final String backend;
  final String device;
  final String mode;
  final int setupMicroseconds;
  final int elapsedMicroseconds;
  final PresentationConfiguration configuration;

  double get framesPerSecond =>
      configuration.frames * 1000000 / elapsedMicroseconds;
  double get meanFrameMicroseconds =>
      elapsedMicroseconds / configuration.frames;
  double get equivalentMegabytesPerSecond =>
      configuration.frames * configuration.frameBytes / elapsedMicroseconds;

  Map<String, Object> toJson() => <String, Object>{
        'backend': backend,
        'device': device,
        'mode': mode,
        'setupUs': setupMicroseconds,
        'frames': configuration.frames,
        'elapsedUs': elapsedMicroseconds,
        'framesPerSecond': framesPerSecond,
        'meanFrameUs': meanFrameMicroseconds,
        'equivalentFrameMBps': equivalentMegabytesPerSecond,
      };
}

Future<List<PresentationMeasurement>> runPresentationMatrix({
  PresentationConfiguration configuration = const PresentationConfiguration(),
  Set<PresentationBackend> backends = const <PresentationBackend>{
    PresentationBackend.putImage,
    PresentationBackend.mitShm,
    PresentationBackend.eglOpenGl,
    PresentationBackend.vulkan,
  },
}) async {
  final factories = <PresentationBackend, FramePresenter Function()>{
    PresentationBackend.putImage: () => PutImagePresenter(
          configuration.width,
          configuration.height,
        ),
    PresentationBackend.mitShm: () => MitShmPresenter(
          configuration.width,
          configuration.height,
        ),
    PresentationBackend.eglOpenGl: () => EglOpenGlPresenter(
          configuration.width,
          configuration.height,
        ),
    PresentationBackend.vulkan: () => VulkanPresenter(
          configuration.width,
          configuration.height,
        ),
  };
  final measurements = <PresentationMeasurement>[];
  for (final backend in PresentationBackend.values) {
    if (!backends.contains(backend)) continue;
    final presenter = factories[backend]!();
    final setup = Stopwatch()..start();
    presenter.initialize();
    setup.stop();
    try {
      for (var frame = 0; frame < configuration.warmupFrames; frame++) {
        presenter.present(frame);
      }
      presenter.finish();
      final watch = Stopwatch()..start();
      for (var frame = 0; frame < configuration.frames; frame++) {
        presenter.present(frame);
      }
      presenter.finish();
      watch.stop();
      measurements.add(PresentationMeasurement(
        backend: presenter.name,
        device: presenter.device,
        mode: presenter.mode,
        setupMicroseconds: setup.elapsedMicroseconds,
        elapsedMicroseconds: watch.elapsedMicroseconds,
        configuration: configuration,
      ));
    } finally {
      presenter.dispose();
    }
  }
  return measurements;
}

Future<int> runPresentationCommand(
  List<String> arguments, {
  Set<PresentationBackend>? forcedBackends,
}) async {
  if (!Platform.isLinux) {
    stderr.writeln('POC-22 requires Linux with a local X11 server.');
    return 2;
  }
  if ((Platform.environment['DISPLAY'] ?? '').isEmpty) {
    stderr.writeln('DISPLAY is not set.');
    return 2;
  }
  final quick = arguments.contains('--quick');
  final json = arguments.contains('--json');
  final configuration = quick
      ? const PresentationConfiguration.quick()
      : const PresentationConfiguration();
  final backends = forcedBackends ?? _parseBackends(arguments);
  final results = await runPresentationMatrix(
    configuration: configuration,
    backends: backends,
  );
  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(<String, Object>{
      'poc': 22,
      'display': Platform.environment['DISPLAY']!,
      'dartVersion': Platform.version,
      'width': configuration.width,
      'height': configuration.height,
      'results': results.map((result) => result.toJson()).toList(),
    }));
    return 0;
  }
  stdout.writeln('POC-22 - X11 presentation matrix');
  stdout.writeln(
    '${configuration.width}x${configuration.height}, '
    '${configuration.frames} measured frames',
  );
  for (final result in results) {
    stdout.writeln(
      '${result.backend}: ${result.framesPerSecond.toStringAsFixed(1)} fps, '
      '${result.meanFrameMicroseconds.toStringAsFixed(1)} us/frame, '
      '${result.device}, ${result.mode}',
    );
  }
  return 0;
}

Set<PresentationBackend> _parseBackends(List<String> arguments) {
  String? value;
  for (final argument in arguments) {
    if (argument.startsWith('--backend=')) {
      value = argument.substring('--backend='.length);
    }
  }
  if (value == null || value == 'all') {
    return PresentationBackend.values.toSet();
  }
  return <PresentationBackend>{
    switch (value) {
      'put-image' => PresentationBackend.putImage,
      'mit-shm' => PresentationBackend.mitShm,
      'egl' || 'opengl' => PresentationBackend.eglOpenGl,
      'vulkan' => PresentationBackend.vulkan,
      _ => throw FormatException('unknown backend: $value'),
    },
  };
}
