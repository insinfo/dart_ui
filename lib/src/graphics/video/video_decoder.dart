/// Portable contract between a compressed video file and dart_ui's renderer.
library;

import 'video_decoder_platform_stub.dart'
    if (dart.library.io) 'video_decoder_platform_io.dart' as platform;
import 'video_frame.dart';

enum VideoDecoderAcceleration { automatic, software }

final class VideoDecoderOptions {
  const VideoDecoderOptions({
    this.acceleration = VideoDecoderAcceleration.automatic,
    this.enableFfmpegFallback = true,
    this.executable,
    this.probeExecutable,
    this.maxWidth = 8192,
    this.maxHeight = 8192,
    this.maxFrameBytes = 256 * 1024 * 1024,
  });

  final VideoDecoderAcceleration acceleration;

  /// Allows the external FFmpeg adapter only after the operating-system
  /// decoder could not be opened. Set to false for deployments that require a
  /// strictly native Media Foundation, GStreamer or AVFoundation path.
  final bool enableFfmpegFallback;

  /// Optional path to the last-resort ffmpeg fallback. When omitted it searches
  /// `DART_UI_FFMPEG`, the application directory and PATH, in that order.
  final String? executable;

  /// Optional path to ffprobe for that fallback. The discovery rules are the
  /// same as [executable].
  final String? probeExecutable;
  final int maxWidth;
  final int maxHeight;
  final int maxFrameBytes;

  /// Validates limits that do not depend on the input stream.
  ///
  /// Kept on the portable contract so platform adapters all reject the same
  /// configuration before starting a native decoder.
  void validate() {
    if (maxWidth <= 0 || maxHeight <= 0 || maxFrameBytes <= 0) {
      throw const VideoDecoderException(
        'open',
        'decoder limits must be positive',
      );
    }
  }

  /// Checks decoded frame geometry and returns its byte size.
  ///
  /// [bytesPerPixel] describes the adapter's output format, not the compressed
  /// input. The current FFmpeg adapter emits BGRA and therefore passes four.
  int validateDecodedFrame({
    required int width,
    required int height,
    required int bytesPerPixel,
  }) {
    validate();
    if (width <= 0 || height <= 0 || bytesPerPixel <= 0) {
      throw VideoDecoderException(
        'probe',
        'invalid decoded frame geometry: ${width}x$height at '
            '$bytesPerPixel bytes per pixel',
      );
    }
    if (width > maxWidth || height > maxHeight) {
      throw VideoDecoderException(
        'probe',
        '${width}x$height exceeds the configured '
            '${maxWidth}x$maxHeight limit',
      );
    }
    final int frameBytes = width * height * bytesPerPixel;
    if (frameBytes > maxFrameBytes) {
      throw VideoDecoderException(
        'probe',
        'a decoded frame needs $frameBytes bytes, above the '
            '$maxFrameBytes-byte limit',
      );
    }
    return frameBytes;
  }
}

final class VideoStreamInfo {
  const VideoStreamInfo({
    required this.width,
    required this.height,
    required this.frameRate,
    required this.duration,
    required this.codec,
    required this.backend,
    required this.hardwareAcceleration,
  });

  final int width;
  final int height;
  final double frameRate;
  final Duration duration;
  final String codec;

  /// Human-readable native path selected by the current operating system.
  final String backend;
  final bool hardwareAcceleration;

  Duration get nominalFrameDuration {
    final double effectiveRate =
        frameRate.isFinite && frameRate > 0 ? frameRate : 30;
    final int microseconds =
        (Duration.microsecondsPerSecond / effectiveRate).round();
    return Duration(microseconds: microseconds < 1 ? 1 : microseconds);
  }
}

final class VideoSample {
  const VideoSample({
    required this.frame,
    required this.timestamp,
    required this.duration,
  });

  final VideoFrame frame;
  final Duration timestamp;
  final Duration duration;
}

final class VideoDecoderException implements Exception {
  const VideoDecoderException(this.operation, this.message, {this.cause});

  final String operation;
  final String message;
  final Object? cause;

  @override
  String toString() => 'VideoDecoderException: $operation: $message';
}

abstract interface class VideoDecoder {
  VideoStreamInfo get info;
  bool get isClosed;

  /// Reads the next decoded frame. Returns null when end-of-stream is reached;
  /// callers do not have to parse process output or native status.
  Future<VideoSample?> readFrame();

  /// Restarts decoding at (or immediately before) [position].
  Future<void> seek(Duration position);

  Future<void> close();
}

abstract final class VideoDecoders {
  static Future<VideoDecoder> openFile(
    String path, {
    VideoDecoderOptions options = const VideoDecoderOptions(),
  }) =>
      platform.openPlatformVideoDecoder(path, options);
}
