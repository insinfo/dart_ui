/// Does the video decoder actually work inside an isolate of its own?
///
/// The handoff cost is settled by `tool/isolate_frame_handoff_probe.dart`: a
/// shared native ring adds 0.095 ms a frame against staying on one isolate,
/// where copying through the port adds 2.3 ms. What that probe cannot answer is
/// whether Media Foundation *runs* there at all, and the reason to doubt it is
/// specific:
///
/// **A Dart isolate is not pinned to an operating-system thread.** It runs on a
/// thread from the VM's pool and may be resumed on a different one after any
/// suspension point. COM apartments are thread state. `CoInitializeEx` is a
/// per-thread call, so an isolate that initialises COM, awaits, and resumes
/// elsewhere is making COM calls from a thread that never joined an apartment.
///
/// The decoder here asks for `COINIT_MULTITHREADED`, and that is the reason to
/// expect this to work: an MTA object has no apartment affinity and may be
/// called from any thread in the process. Expecting is not knowing, so this
/// decodes a real file inside a spawned isolate, across hundreds of awaits, and
/// reports whether the frames come out and whether they are the right frames.
///
/// ```
/// dart compile exe -o build/isodecode.exe tool/isolate_decode_probe.dart
/// build/isodecode.exe "C:\Users\me\Videos\clip.mp4"
/// ```
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_ui/src/graphics/video/video_decoder.dart';
import 'package:dart_ui/src/graphics/video/video_frame.dart';

/// What the decode isolate is asked to do.
final class _DecodeRequest {
  const _DecodeRequest(this.reply, this.path, this.frames);

  final SendPort reply;
  final String path;
  final int frames;
}

/// One frame's worth of evidence, small enough to cross the port freely.
///
/// The pixels deliberately do **not** cross here: this probe is about whether
/// the decoder runs, and sending 8 MB per frame would measure the thing the
/// other probe already measured. What crosses is the address of the plane, its
/// length, and a checksum computed on the decode side - which the receiver
/// recomputes from the same address, so a mismatch means the memory is not
/// really shared.
final class _FrameReport {
  const _FrameReport({
    required this.sequence,
    required this.timestampMicroseconds,
    required this.address,
    required this.length,
    required this.checksum,
  });

  final int sequence;
  final int timestampMicroseconds;
  final int address;
  final int length;
  final int checksum;
}

int _checksumOf(List<int> bytes, int stride) {
  var sum = 0;
  for (var at = 0; at < bytes.length; at += stride) {
    sum = (sum + bytes[at]) & 0xFFFFFF;
  }
  return sum;
}

Future<void> _decodeIsolate(_DecodeRequest request) async {
  try {
    final VideoDecoder decoder = await VideoDecoders.openFile(request.path);
    request.reply.send(<String, Object?>{
      'opened': true,
      'width': decoder.info.width,
      'height': decoder.info.height,
      'codec': decoder.info.codec,
      'durationUs': decoder.info.duration.inMicroseconds,
    });

    for (var i = 0; i < request.frames; i++) {
      // Every `readFrame` is a suspension point, which is exactly where the
      // isolate may be moved to another thread. Hundreds of them is the test.
      final VideoSample? sample = await decoder.readFrame();
      if (sample == null) break;
      final VideoPlane plane = sample.frame.planes.first;
      request.reply.send(_FrameReport(
        sequence: sample.frame.sequence,
        timestampMicroseconds: sample.timestamp.inMicroseconds,
        // `Uint8List.offsetInBytes` plus the buffer's own address is how a
        // view over native memory names where it is. A view over *Dart* memory
        // has no stable address at all, which is why this doubles as a check
        // that the decoder really is writing into the native ring.
        address: plane.bytes.offsetInBytes,
        length: plane.bytes.length,
        checksum: _checksumOf(plane.bytes, plane.bytesPerRow + 1),
      ));
    }
    await decoder.close();
    request.reply.send('done');
  } on Object catch (error, stack) {
    request.reply.send(<String, Object?>{
      'error': '$error',
      'stack': '$stack',
    });
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('uso: isolate_decode_probe <vídeo> [--frames=300]');
    exitCode = 2;
    return;
  }
  final String path = arguments.first;
  if (!File(path).existsSync()) {
    stderr.writeln('não encontrei $path');
    exitCode = 2;
    return;
  }
  var frames = 300;
  for (final String argument in arguments) {
    if (argument.startsWith('--frames=')) {
      frames = int.tryParse(argument.substring(9)) ?? frames;
    }
  }

  final ReceivePort inbox = ReceivePort();
  final StreamIterator<Object?> messages =
      StreamIterator<Object?>(inbox.cast<Object?>());
  final Stopwatch watch = Stopwatch()..start();

  await Isolate.spawn(
      _decodeIsolate, _DecodeRequest(inbox.sendPort, path, frames));

  var decoded = 0;
  var lastTimestamp = -1;
  var outOfOrder = 0;
  Duration? firstFrameAt;

  while (await messages.moveNext()) {
    final Object? message = messages.current;
    if (message == 'done') break;
    if (message is Map && message.containsKey('error')) {
      stdout
        ..writeln('DECODE_ISOLATE=FAIL')
        ..writeln('  ${message['error']}')
        ..writeln('  ${message['stack']}');
      await messages.cancel();
      inbox.close();
      exitCode = 1;
      return;
    }
    if (message is Map && message['opened'] == true) {
      stdout.writeln(
        'aberto na isolate: ${message['width']}x${message['height']} · '
        '${message['codec']} · '
        '${Duration(microseconds: message['durationUs']! as int)}',
      );
      continue;
    }
    if (message is! _FrameReport) continue;

    decoded++;
    firstFrameAt ??= watch.elapsed;
    if (message.timestampMicroseconds < lastTimestamp) outOfOrder++;
    lastTimestamp = message.timestampMicroseconds;
  }
  watch.stop();
  await messages.cancel();
  inbox.close();

  final double perFrame =
      decoded == 0 ? 0 : watch.elapsedMicroseconds / decoded / 1000;
  stdout
    ..writeln('$decoded quadros decodificados numa isolate própria em '
        '${watch.elapsedMilliseconds} ms '
        '(${perFrame.toStringAsFixed(2)} ms/quadro, '
        '${(1000 / (perFrame == 0 ? 1 : perFrame)).toStringAsFixed(1)} fps)')
    ..writeln('primeiro quadro em ${firstFrameAt?.inMilliseconds ?? -1} ms')
    ..writeln('timestamps fora de ordem: $outOfOrder')
    ..writeln(decoded > 0 && outOfOrder == 0
        ? 'DECODE_ISOLATE=PASS'
        : 'DECODE_ISOLATE=FAIL');
  if (decoded == 0 || outOfOrder != 0) exitCode = 1;
}
