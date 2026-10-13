/// Plays a video against its own audio clock with no window, ticking at a
/// chosen interval, and seeks halfway at three seconds - the player's loop
/// without the paint. A slow tick is a slow window: `old` consumes one frame
/// per tick, as the player did, and its drift grows until a resync; `skip`
/// skips frames already in the past at decode time and stays within a tick.
///
/// ```
/// dart run tool/sync_probe.dart video.mp4 60 skip
/// ```
library;

import 'dart:async';
import 'dart:io';
import 'package:dart_ui/audio.dart';
import 'package:dart_ui/dart_ui.dart';

Future<void> main(List<String> args) async {
  final VideoDecoder decoder = await VideoDecoders.openFile(args.first);
  final PcmAudioPlayer audio = PcmAudioPlayers.openFile(args.first)!;
  final Duration length = decoder.info.duration;
  print('video $length audio ${audio.duration} ${audio.sampleRate} Hz');
  final int tick = int.parse(args[1]);
  final bool skip = args[2] == 'skip';
  var skipped = 0;
  final AvSynchronizer sync = AvSynchronizer();
  VideoSample? pending = await decoder.readFrame();
  VideoSample? shown;
  audio.play();
  final Stopwatch wall = Stopwatch()..start();
  var seeked = false;
  var lastLog = 0;
  while (wall.elapsedMilliseconds < 9000) {
    await Future<void>.delayed(Duration(milliseconds: tick));
    if (!seeked && wall.elapsedMilliseconds > 3000) {
      seeked = true;
      final Duration target = length * 0.5;
      audio.pause();
      pending?.release();
      shown?.release();
      pending = shown = null;
      audio.seek(target);
      await decoder.seek(target);
      pending = await decoder.readFrame();
      sync.reset();
      audio.play();
      print('-- seek to $target');
    }
    VideoSample? next = pending ?? await decoder.readFrame();
    while (skip &&
        pending == null &&
        next != null &&
        next.timestamp + next.duration + sync.dropThreshold < audio.position) {
      next.release();
      skipped++;
      next = await decoder.readFrame();
    }
    pending = next;
    if (next == null) break;
    final AvSyncDecision d = sync.evaluate(
        framePts: next.timestamp,
        clock: audio.position,
        frameDuration: next.duration);
    switch (d.action) {
      case AvSyncAction.present:
        shown?.release();
        shown = next;
        pending = null;
      case AvSyncAction.drop:
      case AvSyncAction.resync:
        next.release();
        pending = null;
      case AvSyncAction.wait:
        break;
    }
    if (wall.elapsedMilliseconds - lastLog >= 500) {
      lastLog = wall.elapsedMilliseconds;
      final AvSyncStats s = sync.stats;
      print(
          '${wall.elapsedMilliseconds}ms audio ${audio.position} frame ${next.timestamp} '
          'presented ${s.presented} dropped ${s.dropped} resync ${s.resynced} '
          'drift ${s.recentAverageDrift.inMilliseconds} skipped $skipped');
    }
  }
  await audio.dispose();
  await decoder.close();
  exit(0);
}
