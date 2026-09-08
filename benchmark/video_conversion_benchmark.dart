/// What one displayed video frame costs on the CPU presentation path.
///
/// The number this file exists to defend: the CPU renderer converts a frame
/// once per *displayed* frame, so that conversion is a ceiling on the frame
/// rate that no amount of decoder speed can lift. The decoder alone sustains
/// 148 fps on the h264 clip this was tuned against and the player showed 12.7;
/// the difference was here, and §68 of the roadmap has the trace that proved
/// it.
///
/// ## Run it compiled, always
///
/// `dart run` front-end compiles this package for about six seconds before
/// `main` (`tool/startup_cost.dart`), and the JIT then needs hundreds of
/// iterations to reach the code an AOT binary starts with. A JIT number from
/// this file is not a smaller version of the AOT number, it is a different
/// measurement:
///
/// ```powershell
/// dart compile exe -o build\video_bench.exe .\benchmark\video_conversion_benchmark.dart
/// .\build\video_bench.exe
/// ```
///
/// ## Why the variants are interleaved and the minimum is printed
///
/// Both are scars. Run as one block of forty rounds per variant, two rows
/// executing *identical* code reported 23 ms and 36 ms, because a laptop with
/// four efficiency cores and a busy desktop drifts more over the length of a
/// block than the difference being measured. Sampling every variant once per
/// round puts the same drift under all of them, and the `CONTROL` row - a
/// deliberate duplicate of the row above it - says how much of the remaining
/// spread is noise. The minimum is printed beside the median because under
/// interference the fastest round is the one that got the machine to itself.
///
/// ## What the rows mean
///
/// The destination is smaller than the source, which is the normal case - a
/// 1080p film in a window - and it is what separates the rows. `whole +
/// resample` converts every source pixel and then throws two thirds of them
/// away; `direct at destination` converts only the pixels the resample would
/// have kept. They produce the same bytes, which
/// `test/graphics/video/video_color_conversion_test.dart` asserts pixel for
/// pixel rather than leaving to this benchmark to imply.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/video/video_color_conversion.dart';
import 'package:dart_ui/src/graphics/video/video_frame.dart';

const int _sourceWidth = 1920;
const int _sourceHeight = 1080;

/// The window the player was measured in, so the numbers here and the ones in
/// §68 are about the same picture.
const int _destinationWidth = 1084;
const int _destinationHeight = 610;

const int _rounds = 40;

void main(List<String> arguments) {
  stdout.writeln(
    '${_sourceWidth}x$_sourceHeight -> '
    '${_destinationWidth}x$_destinationHeight premultiplied BGRA, '
    '$_rounds interleaved rounds',
  );

  for (final VideoPixelFormat format in <VideoPixelFormat>[
    VideoPixelFormat.nv12,
    VideoPixelFormat.bgra8888,
  ]) {
    stdout.writeln('\n== ${format.name} ==');
    final VideoFrame frame = _syntheticFrame(format);
    const VideoRegion whole =
        VideoRegion.wholeFrame(_sourceWidth, _sourceHeight);
    final Uint8List wholeBuffer = Uint8List(_sourceWidth * _sourceHeight * 4);
    final Uint8List destinationBuffer =
        Uint8List(_destinationWidth * _destinationHeight * 4);

    void direct() {
      convertVideoFrameToRgba(
        frame,
        region: whole,
        order: ImageChannelOrder.bgra,
        into: destinationBuffer,
        destinationWidth: _destinationWidth,
        destinationHeight: _destinationHeight,
      );
    }

    _interleaved(<String, void Function()>{
      'convert whole, fresh buffer': () {
        convertVideoFrameToRgba(
          frame,
          region: whole,
          order: ImageChannelOrder.bgra,
        );
      },
      'convert whole, reused buffer': () {
        convertVideoFrameToRgba(
          frame,
          region: whole,
          order: ImageChannelOrder.bgra,
          into: wholeBuffer,
        );
      },
      'resample 1:1 -> destination': () {
        DecodedImage(
          width: _sourceWidth,
          height: _sourceHeight,
          order: ImageChannelOrder.bgra,
          pixels: wholeBuffer,
          hasAlpha: true,
        ).resample(width: _destinationWidth, height: _destinationHeight);
      },
      'convert whole + resample': () {
        convertVideoFrameToRgba(
          frame,
          region: whole,
          order: ImageChannelOrder.bgra,
          into: wholeBuffer,
        );
        DecodedImage(
          width: _sourceWidth,
          height: _sourceHeight,
          order: ImageChannelOrder.bgra,
          pixels: wholeBuffer,
          hasAlpha: true,
        ).resample(width: _destinationWidth, height: _destinationHeight);
      },
      'direct at destination': direct,
      'CONTROL, the row above again': direct,
    });
  }
}

void _interleaved(Map<String, void Function()> cases) {
  final Map<String, List<double>> samples = <String, List<double>>{
    for (final String name in cases.keys) name: <double>[],
  };
  // Untimed rounds first. Under the JIT this is the difference between timing
  // the optimised code and timing the interpreter warming up to it; under AOT
  // it costs a fraction of a second and removes the question.
  for (final void Function() body in cases.values) {
    for (var i = 0; i < 3; i++) {
      body();
    }
  }
  final watch = Stopwatch();
  for (var round = 0; round < _rounds; round++) {
    cases.forEach((String name, void Function() body) {
      watch
        ..reset()
        ..start();
      body();
      watch.stop();
      samples[name]!.add(watch.elapsedMicroseconds / 1000.0);
    });
  }
  samples.forEach((String name, List<double> values) {
    values.sort();
    stdout.writeln('${name.padRight(30)} '
        'min ${values.first.toStringAsFixed(2)}  '
        'median ${values[values.length ~/ 2].toStringAsFixed(2)} ms');
  });
}

/// A frame with content, not zeros.
///
/// A buffer of zeros converts at a different speed on a path with a clamp in
/// it, and a black frame would also hide an addressing mistake that a gradient
/// shows immediately.
VideoFrame _syntheticFrame(VideoPixelFormat pixelFormat) {
  final VideoFrame frame = VideoFrame.allocate(
    VideoFrameFormat(
      pixelFormat: pixelFormat,
      width: _sourceWidth,
      height: _sourceHeight,
      range: VideoColorRange.limited,
    ),
    streamId: 1,
  );
  if (pixelFormat == VideoPixelFormat.nv12) {
    final VideoPlane luma = frame.plane(0);
    for (var y = 0; y < _sourceHeight; y++) {
      final int row = luma.rowOffset(y);
      for (var x = 0; x < _sourceWidth; x++) {
        luma.bytes[row + x] = 16 + (x * 7 + y * 3) % 220;
      }
    }
    final VideoPlane chroma = frame.plane(1);
    for (var y = 0; y < _sourceHeight ~/ 2; y++) {
      final int row = chroma.rowOffset(y);
      for (var x = 0; x < _sourceWidth ~/ 2; x++) {
        chroma.bytes[row + x * 2] = 16 + (x * 5 + y) % 224;
        chroma.bytes[row + x * 2 + 1] = 16 + (x + y * 5) % 224;
      }
    }
  } else {
    final VideoPlane plane = frame.plane(0);
    for (var y = 0; y < _sourceHeight; y++) {
      final int row = plane.rowOffset(y);
      for (var x = 0; x < _sourceWidth; x++) {
        plane.bytes[row + x * 4] = (x * 3 + y) & 0xFF;
        plane.bytes[row + x * 4 + 1] = (x + y * 3) & 0xFF;
        plane.bytes[row + x * 4 + 2] = (x * 5 + y * 7) & 0xFF;
        plane.bytes[row + x * 4 + 3] = 255;
      }
    }
  }
  return frame;
}
