import 'dart:typed_data';

import 'native_pixel_buffer.dart';

final class BufferBenchmarkResult {
  const BufferBenchmarkResult({
    required this.strategy,
    required this.elapsed,
    required this.pixelWrites,
    required this.checksum,
  });

  final String strategy;
  final Duration elapsed;
  final int pixelWrites;
  final int checksum;

  double get nanosecondsPerPixel => elapsed.inMicroseconds * 1000 / pixelWrites;

  double get gibibytesPerSecond {
    if (elapsed.inMicroseconds == 0) return double.infinity;
    final bytes = pixelWrites * Uint32List.bytesPerElement;
    return bytes /
        (1024 * 1024 * 1024) /
        (elapsed.inMicroseconds / Duration.microsecondsPerSecond);
  }
}

/// Runs equivalent packed-BGRA clears against Dart and native storage.
final class NativeBufferBenchmark {
  const NativeBufferBenchmark({
    required this.width,
    required this.height,
    required this.iterations,
    this.warmupIterations = 2,
  });

  final int width;
  final int height;
  final int iterations;
  final int warmupIterations;

  int get pixelCount => width * height;

  List<BufferBenchmarkResult> run() {
    if (iterations <= 0 || warmupIterations < 0) {
      throw ArgumentError('Benchmark iteration counts are invalid.');
    }

    final results = <BufferBenchmarkResult>[];
    final dartBytes = Uint8List(pixelCount * 4);
    results.add(_measure(
      'Dart Uint8List byte loop',
      (color) => _fillBytes(dartBytes, color),
      () => _byteChecksum(dartBytes),
    ));

    final dartWords = Uint32List(pixelCount);
    results.add(_measure(
      'Dart Uint32List index loop',
      (color) => _fillWordsLoop(dartWords, color),
      () => _wordChecksum(dartWords),
    ));
    results.add(_measure(
      'Dart Uint32List fillRange',
      (color) => dartWords.fillRange(0, dartWords.length, color),
      () => _wordChecksum(dartWords),
    ));

    final native = NativePixelBuffer(width, height);
    try {
      results.add(_measure(
        'FFI Pointer<Uint32> index loop',
        native.fillWithPointer,
        native.sampleChecksum,
      ));
      results.add(_measure(
        'FFI native view fillRange',
        native.fillWithView,
        native.sampleChecksum,
      ));

      final source = Uint32List(pixelCount);
      results.add(_measure(
        'Heap fill + copy to FFI buffer',
        (color) {
          source.fillRange(0, source.length, color);
          native.copyFrom(source);
        },
        native.sampleChecksum,
      ));
    } finally {
      native.dispose();
    }
    return results;
  }

  BufferBenchmarkResult _measure(
    String strategy,
    void Function(int color) operation,
    int Function() checksum,
  ) {
    for (var iteration = 0; iteration < warmupIterations; iteration++) {
      operation(_colorFor(iteration));
    }

    final stopwatch = Stopwatch()..start();
    for (var iteration = 0; iteration < iterations; iteration++) {
      operation(_colorFor(iteration));
    }
    stopwatch.stop();
    return BufferBenchmarkResult(
      strategy: strategy,
      elapsed: stopwatch.elapsed,
      pixelWrites: pixelCount * iterations,
      checksum: checksum(),
    );
  }

  static int _colorFor(int iteration) =>
      0xff000000 |
      (((iteration * 29) & 0xff) << 16) |
      (((iteration * 47) & 0xff) << 8) |
      ((iteration * 71) & 0xff);

  static void _fillBytes(Uint8List target, int color) {
    final b = color & 0xff;
    final g = (color >> 8) & 0xff;
    final r = (color >> 16) & 0xff;
    final a = (color >> 24) & 0xff;
    for (var offset = 0; offset < target.length; offset += 4) {
      target[offset] = b;
      target[offset + 1] = g;
      target[offset + 2] = r;
      target[offset + 3] = a;
    }
  }

  static void _fillWordsLoop(Uint32List target, int color) {
    for (var index = 0; index < target.length; index++) {
      target[index] = color;
    }
  }

  static int _wordChecksum(Uint32List values) =>
      values.first ^ values[values.length ~/ 2] ^ values.last;

  static int _byteChecksum(Uint8List values) {
    final data = ByteData.sublistView(values);
    final middle = (values.length ~/ 8) * 4;
    return data.getUint32(0, Endian.little) ^
        data.getUint32(middle, Endian.little) ^
        data.getUint32(values.length - 4, Endian.little);
  }
}
