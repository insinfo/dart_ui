/// Opens a video and seeks around it the way the scrub bar does, timing
/// each seek and the frame after it, so a seek that never returns shows up
/// as a TIMEOUT line instead of a frozen window.
///
/// ```
/// dart run tool/seek_probe.dart video.mp4
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/seek_probe.dart <video>');
    exit(64);
  }
  final VideoDecoder decoder = await VideoDecoders.openFile(args.first);
  stdout.writeln('SEEK opened ${decoder.info.width}x${decoder.info.height} '
      '${decoder.info.codec} ${decoder.info.backend} '
      '${decoder.info.duration}');
  var failures = 0;

  Future<void> timed(String what, Future<Object?> Function() run) async {
    final Stopwatch watch = Stopwatch()..start();
    try {
      final Object? result = await run().timeout(const Duration(seconds: 5));
      if (result is VideoSample) result.release();
      stdout.writeln('SEEK ok   $what ${watch.elapsedMilliseconds} ms');
    } on TimeoutException {
      failures++;
      stdout.writeln('SEEK TIMEOUT $what after 5 s');
    } on Object catch (error) {
      failures++;
      stdout.writeln('SEEK FAIL $what: $error');
    }
  }

  for (var i = 0; i < 3; i++) {
    await timed('read frame $i', decoder.readFrame);
  }
  final Duration length = decoder.info.duration;
  for (final double fraction in <double>[0.5, 0.1, 0.9, 0.0, 0.33]) {
    final Duration target = length * fraction;
    await timed('seek ${fraction * 100}%',
        () => decoder.seek(target).then((_) => null));
    // The frame after a seek is the target's, not the file's first.
    final VideoSample? sample = await decoder.readFrame();
    final Duration? at = sample?.timestamp;
    sample?.release();
    final bool right = at != null &&
        at >= target &&
        at - target < const Duration(milliseconds: 500);
    if (!right) failures++;
    stdout.writeln('SEEK ${right ? 'ok  ' : 'FAIL'} frame after '
        '${fraction * 100}% is at $at (target $target)');
  }
  // A drag: seeks issued back to back, each awaited as the player does.
  for (var i = 0; i < 10; i++) {
    final double fraction = 0.2 + i * 0.05;
    await timed('drag seek ${(fraction * 100).round()}%',
        () => decoder.seek(length * fraction).then((_) => null));
    await timed('drag frame ${(fraction * 100).round()}%', decoder.readFrame);
  }
  await decoder.close();
  stdout.writeln('SEEK done failures=$failures');
  exit(failures == 0 ? 0 : 1);
}
