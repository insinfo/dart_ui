/// Portable audio sample and channel layout descriptions.
library;

/// The representation of one sample in an [AudioFormat].
enum AudioSampleFormat {
  unsigned8(1, false),
  signed16(2, false),
  signed24(3, false),
  signed32(4, false),
  float32(4, true),
  float64(8, true);

  const AudioSampleFormat(this.bytesPerSample, this.isFloatingPoint);

  final int bytesPerSample;
  final bool isFloatingPoint;
}

/// A linear PCM format shared by every platform audio backend.
final class AudioFormat {
  const AudioFormat({
    required this.sampleRate,
    required this.channels,
    required this.sampleFormat,
    this.interleaved = true,
    this.channelMask,
  })  : assert(sampleRate > 0),
        assert(channels > 0);

  final int sampleRate;
  final int channels;
  final AudioSampleFormat sampleFormat;
  final bool interleaved;

  /// Platform-neutral speaker mask, when the source declares one.
  ///
  /// The bit meanings follow the WAVE extensible speaker positions because
  /// that is also the convention used by CoreAudio and ALSA adapters. Null
  /// means that only channel order is known.
  final int? channelMask;

  int get bytesPerSample => sampleFormat.bytesPerSample;
  int get bytesPerFrame => bytesPerSample * channels;
  int get bytesPerSecond => bytesPerFrame * sampleRate;

  int framesFor(Duration duration) =>
      (duration.inMicroseconds * sampleRate ~/ Duration.microsecondsPerSecond);

  Duration durationForFrames(int frames) {
    if (frames < 0) {
      throw RangeError.value(frames, 'frames', 'must not be negative');
    }
    return Duration(
      microseconds: frames * Duration.microsecondsPerSecond ~/ sampleRate,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AudioFormat &&
      other.sampleRate == sampleRate &&
      other.channels == channels &&
      other.sampleFormat == sampleFormat &&
      other.interleaved == interleaved &&
      other.channelMask == channelMask;

  @override
  int get hashCode => Object.hash(
        sampleRate,
        channels,
        sampleFormat,
        interleaved,
        channelMask,
      );

  @override
  String toString() => '$sampleRate Hz, $channels ch, '
      '${sampleFormat.name}${interleaved ? ', interleaved' : ', planar'}';
}
