/// Contracts for operating-system and pure-Dart audio codecs.
library;

import 'audio_format.dart';

enum AudioContainerFormat { wave, aiff, flac, mp3, aac, opus, ogg }

final class AudioCodecCapability {
  const AudioCodecCapability({
    required this.container,
    required this.canDecode,
    required this.canEncode,
    this.hardwareAccelerated = false,
  });

  final AudioContainerFormat container;
  final bool canDecode;
  final bool canEncode;
  final bool hardwareAccelerated;
}

final class AudioDecodeConfiguration {
  const AudioDecodeConfiguration({
    required this.format,
    this.frameCount,
    this.duration,
  });

  final AudioFormat format;
  final int? frameCount;
  final Duration? duration;
}

/// Codec discovery contract. Streaming pointer-based transfer is supplied by
/// the native audio barrel as platform implementations are added.
abstract interface class AudioCodecProvider {
  String get id;
  String get name;
  List<AudioCodecCapability> get capabilities;
}
