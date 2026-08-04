import 'dart:io';

import 'package:poc_12_native_buffers/poc_12_native_buffers.dart';

void main(List<String> args) {
  final ci = args.contains('--ci');
  final width = ci ? 800 : 1920;
  final height = ci ? 600 : 1080;
  final iterations = ci ? 12 : 30;
  final benchmark = NativeBufferBenchmark(
    width: width,
    height: height,
    iterations: iterations,
  );

  print('POC-12: Dart heap vs FFI-native BGRA buffers');
  print(
      'Runtime: ${Platform.operatingSystem} ${Platform.version.split(' ').first}');
  print('Frame: ${width}x$height (${width * height * 4 ~/ (1024 * 1024)} MiB)');
  print('Iterations: $iterations\n');

  final results = benchmark.run();
  final fastest = results
      .map((result) => result.nanosecondsPerPixel)
      .reduce((left, right) => left < right ? left : right);

  print('Strategy                              ns/pixel    GiB/s   relative');
  print('----------------------------------------------------------------');
  for (final result in results) {
    final relative = result.nanosecondsPerPixel / fastest;
    print(
      '${result.strategy.padRight(37)}'
      '${result.nanosecondsPerPixel.toStringAsFixed(2).padLeft(9)}  '
      '${result.gibibytesPerSecond.toStringAsFixed(2).padLeft(7)}  '
      '${relative.toStringAsFixed(2).padLeft(6)}x',
    );
  }
  print('\nAll strategies produced checksum '
      '0x${results.first.checksum.toRadixString(16)}.');
}
