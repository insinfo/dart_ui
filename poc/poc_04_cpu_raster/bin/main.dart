import 'package:poc_04_cpu_raster/poc_04_cpu_raster.dart';

void main(List<String> args) {
  final quick = args.contains('--quick');
  final width = quick ? 400 : 800;
  final height = quick ? 300 : 600;
  final frames = quick ? 180 : 120;
  final targetFps = quick ? 60 : 30;
  final scene = BenchmarkScene(width, height);

  // Warm up JIT. The measured loop only reuses the scene and its byte buffer.
  for (var i = 0; i < 30; i++) {
    scene.render(i);
  }

  final watch = Stopwatch()..start();
  for (var i = 0; i < frames; i++) {
    scene.render(i);
  }
  watch.stop();

  final msPerFrame = watch.elapsedMicroseconds / 1000 / frames;
  final fps = 1000 / msPerFrame;
  final buffer = scene.buffer;
  print('POC-04: CPU raster — ${width}x$height');
  print('Format: BGRA8888 premultiplied | stride: ${buffer.stride} bytes');
  print('Buffer: ${buffer.data.length} bytes | $frames frames');
  print(
      '${msPerFrame.toStringAsFixed(2)} ms/frame | ${fps.toStringAsFixed(1)} FPS');

  if (fps < targetFps) {
    throw StateError(
      'Performance gate failed: ${fps.toStringAsFixed(1)} FPS < $targetFps FPS.',
    );
  }
  print('✅ Performance gate passed (>= $targetFps FPS).');
}
