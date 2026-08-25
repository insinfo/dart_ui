library;

import 'video_decoder.dart';

Future<VideoDecoder> openPlatformVideoDecoder(
  String path,
  VideoDecoderOptions options,
) =>
    throw const VideoDecoderException(
      'open',
      'video decoding is not available on this Dart platform',
    );
