/// Picture thumbnails from the disk, decoded away from the window's isolate.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_ui/dart_ui.dart' show DecodedImage, decodeImage;

/// Files larger than this are not decoded for a thumbnail.
const int kMaxThumbnailSource = 64 << 20;

/// Reads pictures' thumbnails, each in an isolate of its own, and can stop
/// them all.
///
/// Reading, decoding and scaling run in another isolate because a folder of
/// photographs must not freeze the window. That isolate is the application's
/// to stop: [close] kills the ones still decoding when the window goes away,
/// so a 60-megapixel photograph half way through its decode does not keep
/// the process alive after its last window closed.
final class ThumbnailWorkers {
  ThumbnailWorkers({this.maxSide = 256});

  /// The longest side of a thumbnail, in pixels.
  final int maxSide;

  final Set<_Job> _running = <_Job>{};
  bool _closed = false;

  /// [path]'s picture, scaled to fit [maxSide] pixels, or null when it is not
  /// one this can read - or when the workers were closed first.
  Future<DecodedImage?> load(String path) async {
    if (_closed) return null;
    final _Job job = _Job();
    _running.add(job);
    try {
      final Isolate isolate = await Isolate.spawn<(SendPort, String, int)>(
        _decode,
        (job.port.sendPort, path, maxSide),
        onExit: job.port.sendPort,
        debugName: 'thumbnail',
      );
      if (_closed) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        job.isolate = isolate;
      }
      final Object? message = await job.result;
      return message is DecodedImage ? message : null;
    } on Object {
      return null;
    } finally {
      job.finish();
      _running.remove(job);
    }
  }

  /// Stops every decode still running; their [load]s answer null. Later
  /// [load]s answer null without starting one.
  void close() {
    _closed = true;
    for (final _Job job in List<_Job>.of(_running)) {
      job.isolate?.kill(priority: Isolate.immediate);
      job.finish();
    }
    _running.clear();
  }
}

/// One decode: its isolate, and the port its answer - or its exit - lands on.
final class _Job {
  _Job() {
    port.listen((Object? message) {
      if (!_done.isCompleted) _done.complete(message);
      port.close();
    });
  }

  final ReceivePort port = ReceivePort();
  final Completer<Object?> _done = Completer<Object?>();
  Isolate? isolate;

  Future<Object?> get result => _done.future;

  void finish() {
    if (!_done.isCompleted) _done.complete(null);
    port.close();
  }
}

void _decode((SendPort, String, int) request) {
  final (SendPort reply, String path, int maxSide) = request;
  DecodedImage? image;
  try {
    final File file = File(path);
    if (file.lengthSync() <= kMaxThumbnailSource) {
      image = decodeImage(file.readAsBytesSync(), maxSide: maxSide);
    }
  } on Object {
    image = null;
  }
  Isolate.exit(reply, image);
}
