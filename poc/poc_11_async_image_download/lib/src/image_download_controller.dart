import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

enum DownloadPhase { idle, downloading, decoding, complete, cancelled, failed }

final class DecodedBgraImage {
  const DecodedBgraImage(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint8List pixels;
}

final class DownloadSnapshot {
  const DownloadSnapshot({
    required this.phase,
    this.receivedBytes = 0,
    this.totalBytes,
    this.image,
    this.error,
  });

  final DownloadPhase phase;
  final int receivedBytes;
  final int? totalBytes;
  final DecodedBgraImage? image;
  final Object? error;

  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0, 1);
  }
}

/// Streams an image over HTTP and decodes it on a helper isolate.
final class ImageDownloadController {
  DownloadSnapshot _snapshot =
      const DownloadSnapshot(phase: DownloadPhase.idle);
  HttpClient? _client;
  int _generation = 0;

  DownloadSnapshot get snapshot => _snapshot;
  void Function(DownloadSnapshot snapshot)? onChanged;

  bool get isActive =>
      _snapshot.phase == DownloadPhase.downloading ||
      _snapshot.phase == DownloadPhase.decoding;

  Future<void> start(Uri uri) async {
    cancel(notify: false);
    final generation = ++_generation;
    final client = HttpClient();
    _client = client;
    var received = 0;
    int? total;

    _emit(const DownloadSnapshot(phase: DownloadPhase.downloading));
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'HTTP ${response.statusCode} ${response.reasonPhrase}',
          uri: uri,
        );
      }

      total = response.contentLength > 0 ? response.contentLength : null;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (generation != _generation) return;
        bytes.add(chunk);
        received += chunk.length;
        _emit(DownloadSnapshot(
          phase: DownloadPhase.downloading,
          receivedBytes: received,
          totalBytes: total,
        ));
      }
      if (generation != _generation) return;

      _emit(DownloadSnapshot(
        phase: DownloadPhase.decoding,
        receivedBytes: received,
        totalBytes: total,
      ));
      final decoded = await Isolate.run(() => _decodeBgra(bytes.takeBytes()));
      if (generation != _generation) return;
      _emit(DownloadSnapshot(
        phase: DownloadPhase.complete,
        receivedBytes: received,
        totalBytes: total,
        image: decoded,
      ));
    } catch (error) {
      if (generation != _generation) return;
      _emit(DownloadSnapshot(
        phase: DownloadPhase.failed,
        receivedBytes: received,
        totalBytes: total,
        error: error,
      ));
    } finally {
      if (generation == _generation) {
        client.close();
        _client = null;
      }
    }
  }

  void cancel({bool notify = true}) {
    if (!isActive && _client == null) return;
    _generation++;
    _client?.close(force: true);
    _client = null;
    if (notify) {
      _emit(DownloadSnapshot(
        phase: DownloadPhase.cancelled,
        receivedBytes: _snapshot.receivedBytes,
        totalBytes: _snapshot.totalBytes,
      ));
    }
  }

  void _emit(DownloadSnapshot value) {
    _snapshot = value;
    onChanged?.call(value);
  }
}

DecodedBgraImage _decodeBgra(Uint8List encoded) {
  image.Image? decoded;
  try {
    decoded = image.decodeImage(encoded);
  } catch (error) {
    throw FormatException('Unsupported image data: $error');
  }
  if (decoded == null) throw const FormatException('Unsupported image data.');
  final rgba = decoded.getBytes(order: image.ChannelOrder.rgba);
  final bgra = Uint8List(rgba.length);
  for (var offset = 0; offset < rgba.length; offset += 4) {
    final alpha = rgba[offset + 3];
    bgra[offset] = (rgba[offset + 2] * alpha + 127) ~/ 255;
    bgra[offset + 1] = (rgba[offset + 1] * alpha + 127) ~/ 255;
    bgra[offset + 2] = (rgba[offset] * alpha + 127) ~/ 255;
    bgra[offset + 3] = alpha;
  }
  return DecodedBgraImage(decoded.width, decoded.height, bgra);
}
