import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:poc_01_win32_window/poc_01_win32_window.dart';
import 'package:poc_10_event_loop/poc_10_event_loop.dart';
import 'package:poc_13_native_dib_present/poc_13_native_dib_present.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    print('POC-13 requires Windows GDI.');
    return;
  }

  final smokeTest = args.contains('--smoke-test');
  final frames = smokeTest ? 30 : 180;
  final width = smokeTest ? 640 : 1280;
  final height = smokeTest ? 480 : 720;

  Win32Window.initializeWin32();
  final eventLoop = Win32EventLoop();
  try {
    final dartCopy = await _runPipeline(
      eventLoop,
      backend: FramebufferBackend.dartCopy,
      frames: frames,
      width: width,
      height: height,
    );
    final nativeDib = await _runPipeline(
      eventLoop,
      backend: FramebufferBackend.nativeDib,
      frames: frames,
      width: width,
      height: height,
    );
    final comparison = PipelineComparison(
      dartCopy: dartCopy,
      nativeDib: nativeDib,
    );
    _printResults(comparison);

    if (dartCopy.frames < frames || nativeDib.frames < frames) exitCode = 1;
  } finally {
    eventLoop.dispose();
    Win32Window.shutdownWin32();
  }
}

Future<PipelineMetrics> _runPipeline(
  Win32EventLoop eventLoop, {
  required FramebufferBackend backend,
  required int frames,
  required int width,
  required int height,
}) async {
  final window = Win32Window(framebufferBackend: backend);
  var rendered = 0;
  var renderMicroseconds = 0;
  var closeScheduled = false;
  var pixelsPerFrame = 0;
  final renderStopwatch = Stopwatch();

  window.onPaint = (current) {
    if (rendered >= frames) return;
    final pixelCount = current.clientWidth * current.clientHeight;
    pixelsPerFrame = pixelCount;
    final color = 0xff000000 |
        (((rendered * 29) & 0xff) << 16) |
        (((rendered * 47) & 0xff) << 8) |
        ((rendered * 71) & 0xff);
    renderStopwatch
      ..reset()
      ..start();
    if (backend == FramebufferBackend.nativeDib) {
      _fillPointer(current.nativeFramebufferPointer, pixelCount, color);
    } else {
      final bytes = current.framebuffer!;
      _fillWords(
        Uint32List.view(
          bytes.buffer,
          bytes.offsetInBytes,
          pixelCount,
        ),
        color,
      );
    }
    renderStopwatch.stop();
    renderMicroseconds += renderStopwatch.elapsedMicroseconds;
    rendered++;
    if (rendered >= frames && !closeScheduled) {
      closeScheduled = true;
      Timer.run(current.close);
    }
  };

  window.create(
    title: 'POC-13 ${backend.name}',
    width: width,
    height: height,
  );
  final elapsed = Stopwatch()..start();
  window.show();
  while (!window.isDestroyed) {
    window.invalidate();
    await eventLoop.pump(Duration.zero);
  }
  elapsed.stop();

  return PipelineMetrics(
    name: backend.name,
    frames: rendered,
    pixelsPerFrame: pixelsPerFrame,
    elapsed: elapsed.elapsed,
    renderMicroseconds: renderMicroseconds,
    presentMicroseconds: window.totalPresentMicroseconds,
  );
}

void _fillPointer(Pointer<Uint32> target, int length, int color) {
  for (var index = 0; index < length; index++) {
    target[index] = color;
  }
}

void _fillWords(Uint32List target, int color) {
  for (var index = 0; index < target.length; index++) {
    target[index] = color;
  }
}

void _printResults(PipelineComparison comparison) {
  print('POC-13: Persistent native DIB vs copied Dart framebuffer');
  print('Pipeline       FPS    render us    present us    frame us');
  print('----------------------------------------------------------');
  for (final result in [comparison.dartCopy, comparison.nativeDib]) {
    print(
      '${result.name.padRight(12)}'
      '${result.framesPerSecond.toStringAsFixed(1).padLeft(7)}  '
      '${result.averageRenderMicroseconds.toStringAsFixed(1).padLeft(11)}  '
      '${result.averagePresentMicroseconds.toStringAsFixed(1).padLeft(12)}  '
      '${result.averageFrameMicroseconds.toStringAsFixed(1).padLeft(10)}',
    );
  }
  print('Presentation speedup: '
      '${comparison.presentationSpeedup.toStringAsFixed(2)}x');
  print('End-to-end throughput: '
      '${comparison.throughputSpeedup.toStringAsFixed(2)}x');
}
