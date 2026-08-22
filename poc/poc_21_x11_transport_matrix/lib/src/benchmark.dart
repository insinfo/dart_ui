library;

import 'dart:convert';
import 'dart:io';

import 'direct_client.dart';
import 'display.dart';
import 'xcb_client.dart';

enum BenchmarkBackend { xcb, dartIo, libcFfi }

final class BenchmarkConfiguration {
  const BenchmarkConfiguration({
    this.noOperations = 100000,
    this.roundTrips = 1000,
    this.putImages = 300,
    this.imageWidth = 128,
    this.imageHeight = 128,
    this.warmupNoOperations = 1000,
    this.warmupRoundTrips = 20,
    this.warmupPutImages = 10,
  });

  const BenchmarkConfiguration.quick()
      : noOperations = 5000,
        roundTrips = 100,
        putImages = 30,
        imageWidth = 128,
        imageHeight = 128,
        warmupNoOperations = 100,
        warmupRoundTrips = 5,
        warmupPutImages = 3;

  final int noOperations;
  final int roundTrips;
  final int putImages;
  final int imageWidth;
  final int imageHeight;
  final int warmupNoOperations;
  final int warmupRoundTrips;
  final int warmupPutImages;

  int get bytesPerImage => imageWidth * imageHeight * 4;
}

final class BenchmarkMeasurement {
  const BenchmarkMeasurement({
    required this.backend,
    required this.connectMicroseconds,
    required this.noOpMicroseconds,
    required this.roundTripMicroseconds,
    required this.putImageMicroseconds,
    required this.configuration,
  });

  final String backend;
  final int connectMicroseconds;
  final int noOpMicroseconds;
  final int roundTripMicroseconds;
  final int putImageMicroseconds;
  final BenchmarkConfiguration configuration;

  double get noOperationsPerSecond =>
      configuration.noOperations * 1000000 / noOpMicroseconds;
  double get meanRoundTripMicroseconds =>
      roundTripMicroseconds / configuration.roundTrips;
  double get putImageMegabytesPerSecond =>
      configuration.putImages *
      configuration.bytesPerImage /
      putImageMicroseconds;

  Map<String, Object> toJson() => <String, Object>{
        'backend': backend,
        'connectUs': connectMicroseconds,
        'noOperations': configuration.noOperations,
        'noOpElapsedUs': noOpMicroseconds,
        'noOpsPerSecond': noOperationsPerSecond,
        'roundTrips': configuration.roundTrips,
        'roundTripElapsedUs': roundTripMicroseconds,
        'meanRoundTripUs': meanRoundTripMicroseconds,
        'putImages': configuration.putImages,
        'imageBytes': configuration.bytesPerImage,
        'putImageElapsedUs': putImageMicroseconds,
        'putImagePayloadMBps': putImageMegabytesPerSecond,
      };
}

Future<List<BenchmarkMeasurement>> runX11TransportMatrix({
  required X11DisplayTarget display,
  BenchmarkConfiguration configuration = const BenchmarkConfiguration(),
  Set<BenchmarkBackend> backends = const <BenchmarkBackend>{
    BenchmarkBackend.xcb,
    BenchmarkBackend.dartIo,
    BenchmarkBackend.libcFfi,
  },
}) async {
  final clients = <X11BenchmarkClient>[
    if (backends.contains(BenchmarkBackend.xcb))
      XcbBenchmarkClient(
        display: display,
        imageWidth: configuration.imageWidth,
        imageHeight: configuration.imageHeight,
      ),
    if (backends.contains(BenchmarkBackend.dartIo))
      DirectX11Client(
        kind: DirectTransportKind.dartIo,
        display: display,
        imageWidth: configuration.imageWidth,
        imageHeight: configuration.imageHeight,
      ),
    if (backends.contains(BenchmarkBackend.libcFfi))
      DirectX11Client(
        kind: DirectTransportKind.libcFfi,
        display: display,
        imageWidth: configuration.imageWidth,
        imageHeight: configuration.imageHeight,
      ),
  ];
  final results = <BenchmarkMeasurement>[];
  for (final client in clients) {
    final connectWatch = Stopwatch()..start();
    await client.connect();
    connectWatch.stop();
    try {
      await client.noOperations(configuration.warmupNoOperations);
      await client.roundTrips(configuration.warmupRoundTrips);
      await client.putImages(configuration.warmupPutImages);

      final noOpWatch = Stopwatch()..start();
      await client.noOperations(configuration.noOperations);
      noOpWatch.stop();

      final roundTripWatch = Stopwatch()..start();
      await client.roundTrips(configuration.roundTrips);
      roundTripWatch.stop();

      final putImageWatch = Stopwatch()..start();
      await client.putImages(configuration.putImages);
      putImageWatch.stop();

      results.add(BenchmarkMeasurement(
        backend: client.name,
        connectMicroseconds: connectWatch.elapsedMicroseconds,
        noOpMicroseconds: noOpWatch.elapsedMicroseconds,
        roundTripMicroseconds: roundTripWatch.elapsedMicroseconds,
        putImageMicroseconds: putImageWatch.elapsedMicroseconds,
        configuration: configuration,
      ));
    } finally {
      await client.close();
    }
  }
  return results;
}

Future<int> runBenchmarkCommand(
  List<String> arguments, {
  Set<BenchmarkBackend>? forcedBackends,
}) async {
  if (!Platform.isLinux) {
    stderr.writeln('POC-21 requires Linux and a local X11 server.');
    return 2;
  }
  final quick = arguments.contains('--quick');
  final json = arguments.contains('--json');
  final displayValue = _stringArgument(arguments, '--display=') ??
      Platform.environment['DISPLAY'];
  if (displayValue == null || displayValue.isEmpty) {
    stderr.writeln('DISPLAY is not set; start Xvfb or an X11 session.');
    return 2;
  }
  final display = X11DisplayTarget.parse(displayValue);
  final requested = forcedBackends ?? _parseBackends(arguments);
  final configuration = quick
      ? const BenchmarkConfiguration.quick()
      : const BenchmarkConfiguration();
  final results = await runX11TransportMatrix(
    display: display,
    configuration: configuration,
    backends: requested,
  );
  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(<String, Object>{
      'poc': 21,
      'display': displayValue,
      'dartVersion': Platform.version,
      'results': results.map((result) => result.toJson()).toList(),
    }));
    return 0;
  }
  stdout.writeln('POC-21 — matriz de transportes X11');
  stdout.writeln(
      'DISPLAY=$displayValue, Dart ${Platform.version.split(' ').first}');
  stdout.writeln(
    'carga: ${configuration.noOperations} NoOp, '
    '${configuration.roundTrips} round-trips, '
    '${configuration.putImages} PutImage de '
    '${configuration.imageWidth}x${configuration.imageHeight}',
  );
  stdout.writeln('');
  stdout.writeln(
    '${'backend'.padRight(39)} ${'connect'.padLeft(10)} '
    '${'NoOp/s'.padLeft(12)} ${'RTT medio'.padLeft(12)} '
    '${'PutImage MB/s'.padLeft(14)}',
  );
  stdout.writeln('-' * 93);
  for (final result in results) {
    stdout.writeln(
      '${result.backend.padRight(39)} '
      '${_duration(result.connectMicroseconds).padLeft(10)} '
      '${result.noOperationsPerSecond.toStringAsFixed(0).padLeft(12)} '
      '${('${result.meanRoundTripMicroseconds.toStringAsFixed(1)} us').padLeft(12)} '
      '${result.putImageMegabytesPerSecond.toStringAsFixed(1).padLeft(14)}',
    );
  }
  return 0;
}

Set<BenchmarkBackend> _parseBackends(List<String> arguments) {
  final value = _stringArgument(arguments, '--backend=');
  if (value == null || value == 'all') return BenchmarkBackend.values.toSet();
  return <BenchmarkBackend>{
    switch (value) {
      'xcb' => BenchmarkBackend.xcb,
      'dart-io' => BenchmarkBackend.dartIo,
      'libc-ffi' => BenchmarkBackend.libcFfi,
      _ => throw FormatException('unknown backend: $value'),
    }
  };
}

String? _stringArgument(List<String> arguments, String prefix) {
  for (final argument in arguments) {
    if (argument.startsWith(prefix)) return argument.substring(prefix.length);
  }
  return null;
}

String _duration(int microseconds) => microseconds >= 1000
    ? '${(microseconds / 1000).toStringAsFixed(1)} ms'
    : '$microseconds us';
